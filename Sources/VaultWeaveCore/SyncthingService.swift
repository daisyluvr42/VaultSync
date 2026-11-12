import Foundation
import Darwin

public struct Peer: Sendable, Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var host: String
    public var port: Int
    public init(id: String, name: String, host: String, port: Int = 22080) {
        self.id = id; self.name = name; self.host = host; self.port = port
    }
    public func validate() throws {
        let raw = id.replacingOccurrences(of: "-", with: "")
        guard raw.count == 56, raw.allSatisfy({ "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".contains($0) }),
              (1...65535).contains(port), !host.isEmpty,
              host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".:-".contains($0)) }),
              host.hasSuffix(".ts.net") || Self.isTailIP(host) else {
            throw WeaveError.invalidConfiguration("请输入有效设备 ID 和 Tailscale IP / 完整的 .ts.net 主机名。")
        }
    }
    public static func isTailIP(_ host: String) -> Bool {
        let raw = host.split(separator: ".", omittingEmptySubsequences: false)
        let parts = raw.compactMap { Int($0) }
        if raw.count == 4, parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }), parts[0] == 100, (64...127).contains(parts[1]) { return true }
        var address = in6_addr()
        return host.lowercased().hasPrefix("fd7a:115c:a1e0:") && inet_pton(AF_INET6, host, &address) == 1
    }
    public var address: String { "tcp://\(host.contains(":") ? "[\(host)]" : host):\(port)" }
}

public struct PairingOffer: Sendable, Codable {
    public var schema: Int = 1
    public var peer: Peer
    public var vaults: [VaultMapping]
    public init(peer: Peer, vaults: [VaultMapping]) {
        self.peer = peer
        self.vaults = vaults.map { VaultMapping(id: $0.id, name: $0.name, path: "", syncSettings: $0.syncSettings) }
    }
    public static func parse(_ text: String) throws -> PairingOffer {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}"))
        if value.hasPrefix("```") {
            var lines = value.components(separatedBy: .newlines)
            guard lines.count >= 3, lines.last?.trimmingCharacters(in: .whitespaces) == "```" else { throw WeaveError.invalidConfiguration("配对文本的代码块不完整，请复制完整内容。") }
            lines.removeFirst(); lines.removeLast(); value = lines.joined(separator: "\n")
        }
        if let quoted = try? JSONDecoder().decode(String.self, from: Data(value.utf8)) { value = quoted }
        let offer: PairingOffer
        do { offer = try JSONDecoder().decode(PairingOffer.self, from: Data(value.utf8)) }
        catch { throw WeaveError.invalidConfiguration("配对信息不完整，请重新复制。") }
        guard offer.schema == 1 else { throw WeaveError.invalidConfiguration("配对信息版本不受支持，请更新两台 Mac 上的 VaultSync。") }
        try offer.peer.validate()
        for vault in offer.vaults { guard Codec.validVaultID(vault.id) else { throw WeaveError.invalidConfiguration("配对信息中的文库 ID 无效。") } }
        return offer
    }
}

public final class SyncthingService {
    public let home: URL
    public let objects: URL
    public let apiPort: Int
    public let syncPort: Int
    private let executable: URL
    private let apiKey: String
    private var process: Process?
    private var logHandle: FileHandle?
    public private(set) var deviceID: String = ""
    public private(set) var tailHost: String = ""
    public init(home: URL, objects: URL, executable: URL, apiPort: Int = 18384, syncPort: Int = 22080) throws {
        self.home = home; self.objects = objects; self.executable = executable; self.apiPort = apiPort; self.syncPort = syncPort
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: objects, withIntermediateDirectories: true)
        let keyFile = home.appendingPathComponent("vaultweave-api-key")
        if FileManager.default.fileExists(atPath: keyFile.path) { apiKey = try String(contentsOf: keyFile, encoding: .utf8) }
        else {
            apiKey = UUID().uuidString + UUID().uuidString
            try Data(apiKey.utf8).write(to: keyFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
        }
    }
    deinit { stop() }
    public static func bundledExecutable() -> URL? {
        let candidates = [Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/syncthing"),
                          URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/syncthing")]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    private static func engineHostExecutable() -> URL? {
        let candidates = [Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/VaultWeaveEngineHost"),
                          URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("VaultWeaveEngineHost")]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    public static func tailscaleAddress(candidates: [URL]? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        try parseTailscaleStatus(tailscaleStatusData(candidates: candidates, environment: environment))
    }
    private static func tailscaleStatusData(candidates: [URL]? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Data {
        let defaults = ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"].map { URL(fileURLWithPath: $0) }
        let paths = (candidates ?? defaults).filter { FileManager.default.isExecutableFile(atPath: $0.path) }
        guard !paths.isEmpty else {
            throw WeaveError.invalidConfiguration("请先安装 Tailscale，并将这台 Mac 加入你的网络。")
        }
        var cliEnvironment = environment
        // The macOS executable doubles as a GUI app. Finder launches have no shell markers;
        // without this flag it can return GUI startup prose (and exit 0) instead of JSON.
        cliEnvironment["TAILSCALE_BE_CLI"] = "1"
        var failures: [String] = []
        for path in paths {
            do {
                let result = try command(path, ["status", "--json"], environment: cliEnvironment)
                _ = try parseTailscaleStatus(result)
                return result
            } catch { failures.append("\(path.path)：\(error.localizedDescription)") }
        }
        throw WeaveError.invalidConfiguration("无法读取 Tailscale 状态。请确认 Tailscale 已登录并连接，再重试。\n" + failures.joined(separator: "\n"))
    }
    public static func tailnetPeers() throws -> [TailnetDevice] {
        try parseTailnetPeers(tailscaleStatusData())
    }
    public static func parseTailnetPeers(_ data: Data) throws -> [TailnetDevice] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let peers = json["Peer"] as? [String: [String: Any]] ?? [:]
        return peers.values.compactMap { peer in
            guard peer["Online"] as? Bool == true, let ips = peer["TailscaleIPs"] as? [String],
                  let host = ips.first(where: { $0.contains(".") && Peer.isTailIP($0) }) else { return nil }
            return TailnetDevice(host: host, name: peer["HostName"] as? String ?? host)
        }.sorted { $0.name < $1.name }
    }
    public static func parseTailscaleStatus(_ result: Data) throws -> String {
        guard let value = try? JSONSerialization.jsonObject(with: result), let json = value as? [String: Any] else {
            throw WeaveError.invalidConfiguration("Tailscale 没有返回有效的 JSON 状态，请重新打开 Tailscale 后重试。")
        }
        guard let state = json["BackendState"] as? String else {
            throw WeaveError.invalidConfiguration("Tailscale 状态中缺少连接状态（BackendState）。")
        }
        guard state == "Running" else {
            throw WeaveError.invalidConfiguration("Tailscale 当前未连接（\(state)），请连接后再启动同步。")
        }
        let own = json["Self"] as? [String: Any]
        let ips = (own?["TailscaleIPs"] as? [String] ?? []) + (json["TailscaleIPs"] as? [String] ?? [])
        guard let ip = ips.first(where: { $0.contains(".") && Peer.isTailIP($0) }) else {
            throw WeaveError.invalidConfiguration("Tailscale 已运行，但尚未提供有效的本机 IPv4 地址，请等待连接完成后重试。")
        }
        return ip
    }
    private static func command(_ url: URL, _ args: [String], environment: [String: String]? = nil) throws -> Data {
        let task = Process(), pipe = Pipe()
        task.executableURL = url; task.arguments = args; task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
        if let environment { task.environment = environment }
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw WeaveError.invalidConfiguration("\(url.lastPathComponent) 执行失败，请检查安装和网络状态。") }
        return data
    }
    public func start(peers: [Peer], deviceName: String) async throws {
        guard process == nil || process?.isRunning == false else { try await configure(peers: peers, deviceName: deviceName); return }
        tailHost = try Self.tailscaleAddress()
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw WeaveError.invalidConfiguration("未找到 Syncthing 引擎，请重新打包应用。") }
        if !FileManager.default.fileExists(atPath: home.appendingPathComponent("config.xml").path) {
            _ = try Self.command(executable, ["generate", "--home", home.path, "--no-port-probing"])
        }
        // Restrict the very first launch too; don't briefly advertise a default public listener.
        let configFile = home.appendingPathComponent("config.xml")
        let xml: XMLDocument
        do { xml = try XMLDocument(contentsOf: configFile) }
        catch { throw WeaveError.invalidConfiguration("无法读取同步引擎配置 config.xml：\(error.localizedDescription)") }
        guard let root = xml.rootElement(), let options = root.elements(forName: "options").first else { throw WeaveError.invalidConfiguration("同步引擎配置格式不受支持。") }
        for folder in root.elements(forName: "folder") where folder.attribute(forName: "id")?.stringValue != "vaultweave-objects-v1" { folder.detach() }
        let identityFile = home.appendingPathComponent("vaultweave-device-id")
        let ownID = (try? String(contentsOf: identityFile, encoding: .utf8)) ?? root.elements(forName: "device").first?.attribute(forName: "id")?.stringValue ?? ""
        let allowed = Set(peers.map(\.id) + [ownID])
        for node in root.elements(forName: "device") where !allowed.contains(node.attribute(forName: "id")?.stringValue ?? "") { node.detach() }
        for folder in root.elements(forName: "folder") {
            for node in folder.elements(forName: "device") where !allowed.contains(node.attribute(forName: "id")?.stringValue ?? "") { node.detach() }
        }
        func set(_ name: String, _ value: String) {
            for node in options.elements(forName: name) { node.detach() }
            options.addChild(XMLElement(name: name, stringValue: value))
        }
        set("listenAddress", "tcp://\(tailHost):\(syncPort)")
        for name in ["globalAnnounceEnabled", "localAnnounceEnabled", "relaysEnabled", "natEnabled", "startBrowser", "crashReportingEnabled"] { set(name, "false") }
        set("autoUpgradeIntervalH", "0"); set("urAccepted", "-1")
        try xml.xmlData.write(to: configFile, options: .atomic)
        let log = home.appendingPathComponent("engine.log")
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        logHandle = try FileHandle(forWritingTo: log); try logHandle?.seekToEnd()
        guard let hostExecutable = Self.engineHostExecutable() else { throw WeaveError.invalidConfiguration("缺少同步引擎生命周期组件，请重新安装完整的应用包。") }
        let task = Process(); task.executableURL = hostExecutable
        task.arguments = ["--parent", String(ProcessInfo.processInfo.processIdentifier), "--engine", executable.path,
                          "--record", home.appendingPathComponent("engine-host.json").path, "--",
                          "serve", "--home", home.path, "--no-browser", "--no-restart", "--no-upgrade", "--gui-address", "127.0.0.1:\(apiPort)"]
        var environment = ProcessInfo.processInfo.environment; environment["STGUIAPIKEY"] = apiKey
        task.environment = environment
        task.standardOutput = logHandle; task.standardError = logHandle
        try task.run(); process = task
        do {
            var ready = false
            for _ in 0..<40 {
                guard task.isRunning else { throw WeaveError.invalidConfiguration("同步引擎已退出，请查看本机 engine.log。") }
                if let info = try? await request("GET", "system/status"), let id = info["myID"] as? String { deviceID = id; ready = true; break }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            guard ready else { throw WeaveError.invalidConfiguration("同步引擎启动超时；请检查本机端口是否被占用。") }
            try Data(deviceID.utf8).write(to: identityFile, options: .atomic)
            try await configure(peers: peers, deviceName: deviceName)
        } catch { stop(); throw error }
    }
    public func configure(peers: [Peer], deviceName: String) async throws {
        for peer in peers { try peer.validate() }
        guard !deviceID.isEmpty else { return }
        for peer in peers where peer.id != deviceID {
            _ = try await request("POST", "config/devices", body: ["deviceID": peer.id, "name": peer.name,
                  "addresses": [peer.address], "allowedNetworks": ["100.64.0.0/10", "fd7a:115c:a1e0::/48"], "autoAcceptFolders": false])
        }
        _ = try await request("PATCH", "config/devices/\(deviceID)", body: ["name": deviceName])
        var folder = try await request("GET", "config/defaults/folder")
        folder["id"] = "vaultweave-objects-v1"; folder["label"] = "VaultSync"
        folder["path"] = objects.path; folder["type"] = "sendreceive"
        folder["devices"] = ([deviceID] + peers.map(\.id)).map { ["deviceID": $0] }
        folder["fsWatcherEnabled"] = true; folder["fsWatcherDelayS"] = 1; folder["rescanIntervalS"] = 0
        folder["maxConflicts"] = -1
        _ = try await request("POST", "config/folders", body: folder)
        let current = try await request("GET", "config")
        for device in current["devices"] as? [[String: Any]] ?? [] {
            if let id = device["deviceID"] as? String, id != deviceID, !peers.contains(where: { $0.id == id }) {
                _ = try await request("DELETE", "config/devices/\(id)")
            }
        }
    }
    @discardableResult public func request(_ method: String, _ endpoint: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        let url = URL(string: "http://127.0.0.1:\(apiPort)/rest/\(endpoint)")!
        var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = 3
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw WeaveError.invalidConfiguration("同步引擎请求失败：\(endpoint)")
        }
        if data.isEmpty { return [:] }
        guard let value = try? JSONSerialization.jsonObject(with: data), let result = value as? [String: Any] else {
            throw WeaveError.invalidConfiguration("同步引擎返回了无效的 JSON 数据：\(endpoint)")
        }
        return result
    }
    public func connections() async throws -> [String: Bool] {
        let result = try await request("GET", "system/connections")
        let entries = result["connections"] as? [String: [String: Any]] ?? [:]
        return entries.mapValues { $0["connected"] as? Bool ?? false }
    }
    public func transferStatus() async throws -> TransportStatus {
        let value = try await request("GET", "db/status?folder=vaultweave-objects-v1")
        return try JSONDecoder().decode(TransportStatus.self, from: JSONSerialization.data(withJSONObject: value))
    }
    public func stop() {
        if let process, process.isRunning { process.terminate() }
        process = nil; try? logHandle?.close(); logHandle = nil; deviceID = ""
    }
}
