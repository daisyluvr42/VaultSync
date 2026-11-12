import AppKit
import SwiftUI
import ServiceManagement
import VaultSyncCore

struct AppConfig: Codable {
    var localID = UUID().uuidString
    var deviceName = Host.current().localizedName ?? "我的 Mac"
    var vaults: [VaultMapping] = []
    var peers: [Peer] = []
    var isBase: Bool?
    var offeredVaults: [VaultMapping] = []
    var transportEnabled = false
    var scanInterval: Double = 5 // Retain the legacy setting for rollback compatibility.
}
struct VaultStatus: Identifiable {
    var mapping: VaultMapping
    var report = SyncReport()
    var error: String?
    var updated: Date?
    var id: String { mapping.id }
}
struct ConflictItem: Identifiable {
    var vaultID: String
    var vaultName: String
    var conflict: FileConflict
    var id: String { vaultID + ":" + conflict.path }
}
struct RevisionContent: Identifiable {
    var revision: Revision
    var data: Data?
    var id: String { revision.id }
    var text: String? { data.flatMap { $0.contains(0) ? nil : String(data: $0, encoding: .utf8) } }
}

private final class EngineWorkspace: @unchecked Sendable {
    let queue = DispatchQueue(label: "app.vaultsync.core", qos: .utility)
    var engines: [String: VaultEngine] = [:]
}

@MainActor final class AppModel: ObservableObject {
    @Published var config: AppConfig
    @Published var statuses: [VaultStatus] = []
    @Published var scanning = false
    @Published var error: String?
    @Published var networkMessage = "未启动"
    @Published var engineID = ""
    @Published var engineHost = ""
    @Published var connected: [String: Bool] = [:]
    @Published var transferStatus: TransportStatus?
    @Published var transportBusy = false
    @Published var paused = false
    @Published var nearby: [NearbyDevice] = []
    @Published var incoming: [PairingRequest] = []
    @Published var discovering = false
    @Published var pairingMessage = ""
    @Published var outboundName = ""
    @Published var outboundCode = ""
    @Published var approvingID: String?
    @Published var finishingPairing = false
    let base: URL
    let objects: URL
    let stateRoot: URL
    private let configFile: URL
    private nonisolated let workspace = EngineWorkspace()
    private var timer: Timer?
    private var scanControl: ScanControl?
    private var localWatches: [String: FileEventStream] = [:]
    private var objectWatch: FileEventStream?
    private var pendingScans: [String: ScanChanges] = [:]
    private var retryScans: [String: ScanChanges] = [:]
    private var retryTask: Task<Void, Never>?
    private var retryDelay: UInt64 = 2
    private var service: SyncthingService?
    private let apiPort: Int
    private let syncPort: Int
    private let pairingPort: UInt16
    private var pairingServer: PairingServer?
    private var pairingTask: Task<Void, Never>?
    private var outbound: (device: NearbyDevice, request: PairingRequest)?
    var conflicts: [ConflictItem] {
        statuses.flatMap { status in status.report.conflicts.map { ConflictItem(vaultID: status.id, vaultName: status.mapping.name, conflict: $0) } }
    }
    init() {
        let override = ProcessInfo.processInfo.environment["VAULTSYNC_HOME"]
        let env = ProcessInfo.processInfo.environment
        apiPort = override != nil ? Int(env["VAULTSYNC_API_PORT"] ?? "18384") ?? 18384 : 18384
        syncPort = override != nil ? Int(env["VAULTSYNC_SYNC_PORT"] ?? "22080") ?? 22080 : 22080
        pairingPort = override != nil ? UInt16(env["VAULTSYNC_PAIRING_PORT"] ?? "22081") ?? 22081 : 22081
        base = override.map { URL(fileURLWithPath: $0) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VaultSync")
        objects = base.appendingPathComponent("Objects"); stateRoot = base.appendingPathComponent("LocalState")
        configFile = base.appendingPathComponent("settings.json")
        config = AppConfig()
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if FileManager.default.fileExists(atPath: configFile.path) { config = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: configFile)) }
            else { try Codec.encode(config).write(to: configFile, options: .atomic) }
        } catch { self.error = "无法读取应用设置，已停止自动同步：\(error.localizedDescription)"; paused = true }
        statuses = config.vaults.map { VaultStatus(mapping: $0) }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.startWatches()
                await self?.refreshConnections()
            }
        }
        if CommandLine.arguments.contains("--demo") && override != nil { createDemo() }
        for mapping in config.vaults { enqueue(.full, for: mapping.id) }
        startWatches()
        if config.transportEnabled { Task { await startTransport() } }
    }
    func save() {
        do {
            try Codec.encode(config).write(to: configFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configFile.path)
            if let offer = ownOffer { pairingServer?.updateOffer(offer, isBase: config.isBase == true) }
        } catch { self.error = error.localizedDescription; paused = true }
    }
    func setBase(_ enabled: Bool) {
        config.isBase = enabled ? true : nil
        save()
    }
    func addVault(url: URL, id: String?, syncSettings: Bool) {
        let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
        let vaultID = id?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mapping = VaultMapping(id: (vaultID?.isEmpty == false ? vaultID! : UUID().uuidString.lowercased()), name: url.lastPathComponent, path: normalized.path, syncSettings: syncSettings)
        guard Codec.validVaultID(mapping.id), !config.vaults.contains(where: { $0.id == mapping.id || $0.path == mapping.path || $0.path.hasPrefix(mapping.path + "/") || mapping.path.hasPrefix($0.path + "/") }) else {
            error = "文库 ID 无效，或该文库 / 路径已经添加（也不能嵌套添加）。"; return
        }
        do {
            _ = try VaultEngine(mapping: mapping, transportRoot: objects, stateRoot: stateRoot, device: author)
            config.vaults.append(mapping); statuses.append(VaultStatus(mapping: mapping)); save()
            enqueue(.full, for: mapping.id)
            startWatches()
        } catch { self.error = error.localizedDescription }
    }
    func removeVault(_ id: String) {
        config.vaults.removeAll { $0.id == id }; statuses.removeAll { $0.id == id }; save()
        scanControl?.cancel()
        localWatches.removeValue(forKey: id)
        pendingScans.removeValue(forKey: id)
        retryScans.removeValue(forKey: id)
        workspace.queue.async { self.workspace.engines.removeValue(forKey: id) }
    }

    private func startWatches() {
        if objectWatch == nil {
            do {
                try FileManager.default.createDirectory(at: objects, withIntermediateDirectories: true)
                objectWatch = FileEventStream(root: objects) { [weak self] in self?.receiveObjects($0) }
                if objectWatch != nil {
                    for mapping in config.vaults { enqueue(ScanChanges(objects: nil), for: mapping.id) }
                }
            } catch { self.error = error.localizedDescription }
        }
        for mapping in config.vaults where localWatches[mapping.id] == nil {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: mapping.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            let watch = FileEventStream(root: URL(fileURLWithPath: mapping.path)) { [weak self] delta in
                guard let self else { return }
                let filtered = delta.map {
                    FileChanges(files: $0.files.filter(mapping.includes), directories: $0.directories.filter(mapping.includes))
                }
                if filtered?.isEmpty == true { return }
                self.enqueue(ScanChanges(local: filtered), for: mapping.id)
                self.drainScans()
            }
            if let watch {
                localWatches[mapping.id] = watch
                enqueue(.full, for: mapping.id)
            }
        }
        if objectWatch == nil || config.vaults.contains(where: { localWatches[$0.id] == nil }) {
            error = "无法监听部分同步目录，正在重试。"
        }
        drainScans()
    }

    private func receiveObjects(_ delta: FileChanges?) {
        for mapping in config.vaults {
            let prefix = mapping.id + "/"
            let changes = delta.map { delta in
                let files = delta.files.compactMap { path -> String? in
                    guard path.hasPrefix(prefix) else { return nil }
                    let relative = String(path.dropFirst(prefix.count))
                    let parts = relative.split(separator: "/")
                    guard parts.count == 2 else { return nil }
                    let name = String(parts[1])
                    if parts[0] == "revisions" && name.hasSuffix(".json") && Codec.validID(String(name.dropLast(5))) {
                        return relative
                    }
                    if parts[0] == "blobs" && Codec.validID(name) { return relative }
                    return nil
                }
                let directories = delta.directories.compactMap { path -> String? in
                    if path == mapping.id { return "" }
                    guard path.hasPrefix(prefix) else { return nil }
                    return String(path.dropFirst(prefix.count))
                }
                return FileChanges(files: Set(files), directories: Set(directories))
            }
            if changes?.isEmpty != true { enqueue(ScanChanges(objects: changes), for: mapping.id) }
        }
        drainScans()
    }

    private func enqueue(_ changes: ScanChanges, for id: String) {
        guard config.vaults.contains(where: { $0.id == id }) else { return }
        var combined = pendingScans[id] ?? ScanChanges()
        if let failed = retryScans.removeValue(forKey: id) { combined.formUnion(failed) }
        combined.formUnion(changes)
        pendingScans[id] = combined
    }

    func togglePaused() {
        paused.toggle()
        if paused { scanControl?.cancel() } else { drainScans() }
    }

    func scan() {
        guard !paused else { return }
        for mapping in config.vaults { enqueue(.full, for: mapping.id) }
        drainScans()
        if let service, !engineID.isEmpty {
            Task {
                do { try await service.request("POST", "db/scan?folder=vaultsync-objects-v1") }
                catch { self.error = error.localizedDescription }
            }
        }
    }

    private func scheduleRetry() {
        guard !retryScans.isEmpty, retryTask == nil else { return }
        let delay = retryDelay
        retryDelay = min(delay * 2, 60)
        retryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) } catch { return }
            guard let self else { return }
            self.retryTask = nil
            for (id, changes) in self.retryScans { self.enqueue(changes, for: id) }
            self.retryScans.removeAll()
            self.drainScans()
        }
    }

    private var author: String { config.deviceName + " [" + config.localID.prefix(8) + "]" }

    private func drainScans() {
        guard !scanning, !paused, !pendingScans.isEmpty else { return }
        let batch = pendingScans
        pendingScans.removeAll()
        scanning = true
        let control = ScanControl(); scanControl = control
        let mappings = config.vaults, objects = self.objects, stateRoot = self.stateRoot, device = author
        workspace.queue.async {
            var results: [VaultStatus] = []
            for mapping in mappings {
                guard let changes = batch[mapping.id] else { continue }
                do {
                    let engine: VaultEngine
                    try control.check()
                    if let cached = self.workspace.engines[mapping.id], cached.mapping == mapping { engine = cached }
                    else { engine = try VaultEngine(mapping: mapping, transportRoot: objects, stateRoot: stateRoot, device: device); self.workspace.engines[mapping.id] = engine }
                    results.append(VaultStatus(mapping: mapping, report: try engine.scan(changes: changes, control: control), updated: Date()))
                } catch is CancellationError { break }
                  catch { results.append(VaultStatus(mapping: mapping, error: error.localizedDescription)) }
            }
            DispatchQueue.main.async {
                if control.isCancelled {
                    for (id, changes) in batch { self.enqueue(changes, for: id) }
                } else {
                    for result in results where self.config.vaults.contains(result.mapping) {
                        if let index = self.statuses.firstIndex(where: { $0.id == result.id }) {
                            self.statuses[index] = result
                        }
                        if result.error != nil { self.retryScans[result.id] = batch[result.id] }
                    }
                    if self.retryScans.isEmpty { self.retryDelay = 2 }
                    self.scheduleRetry()
                }
                self.scanning = false
                self.scanControl = nil
                self.drainScans()
            }
        }
    }
    func loadContents(_ item: ConflictItem, completion: @escaping ([RevisionContent], RevisionContent?) -> Void) {
        workspace.queue.async {
            do {
                guard let engine = self.workspace.engines[item.vaultID] else { return }
                let variants = try item.conflict.heads.map { RevisionContent(revision: $0, data: try engine.content($0)) }
                let base = try item.conflict.base.map { RevisionContent(revision: $0, data: try engine.content($0)) }
                DispatchQueue.main.async { completion(variants, base) }
            } catch { DispatchQueue.main.async { self.error = error.localizedDescription } }
        }
    }
    func resolve(_ item: ConflictItem, data: Data?, completion: @escaping (Bool) -> Void) {
        workspace.queue.async {
            do {
                guard let engine = self.workspace.engines[item.vaultID] else { throw VaultSyncError.staleMerge }
                let report = try engine.resolve(path: item.conflict.path, expectedHeads: item.conflict.heads.map(\.id), data: data)
                DispatchQueue.main.async {
                    if let index = self.statuses.firstIndex(where: { $0.id == item.vaultID }) { self.statuses[index].report = report; self.statuses[index].updated = Date() }
                    completion(true)
                }
            } catch { DispatchQueue.main.async { self.error = error.localizedDescription; completion(false); self.scan() } }
        }
    }
    func history(vaultID: String, path: String, completion: @escaping ([RevisionContent]) -> Void) {
        workspace.queue.async {
            do {
                guard let engine = self.workspace.engines[vaultID] else { return }
                let revisions = try engine.history(path: path)
                let contents = try revisions.map { RevisionContent(revision: $0, data: try engine.content($0)) }
                DispatchQueue.main.async { completion(contents) }
            } catch { DispatchQueue.main.async { self.error = error.localizedDescription } }
        }
    }
    func historyPaths(vaultID: String, completion: @escaping ([String]) -> Void) {
        workspace.queue.async {
            do {
                guard let engine = self.workspace.engines[vaultID] else { DispatchQueue.main.async { completion([]) }; return }
                let paths = Array(Set(try engine.store.load(changes: FileChanges()).revisions.values.map { $0.payload.path })).sorted()
                DispatchQueue.main.async { completion(paths) }
            } catch { DispatchQueue.main.async { self.error = error.localizedDescription; completion([]) } }
        }
    }
    func restore(vaultID: String, revision: Revision) {
        workspace.queue.async {
            do {
                guard let engine = self.workspace.engines[vaultID] else { return }
                let report = try engine.restore(revision)
                DispatchQueue.main.async {
                    if let index = self.statuses.firstIndex(where: { $0.id == vaultID }) {
                        self.statuses[index].report = report
                        self.statuses[index].updated = Date()
                    }
                }
            } catch { DispatchQueue.main.async { self.error = error.localizedDescription } }
        }
    }
    func startTransport() async {
        guard !transportBusy else { return }; transportBusy = true
        defer { transportBusy = false }
        do {
            if service == nil {
                guard let executable = SyncthingService.bundledExecutable() else { throw VaultSyncError.invalidConfiguration("应用中缺少 Syncthing。开发时请运行 scripts/fetch-syncthing.py。") }
                service = try SyncthingService(home: base.appendingPathComponent("Syncthing"), objects: objects, executable: executable, apiPort: apiPort, syncPort: syncPort)
            }
            try await service!.start(peers: config.peers, deviceName: config.deviceName)
            engineID = service!.deviceID; engineHost = service!.tailHost
            config.transportEnabled = true; save(); networkMessage = "已启动"
            await startPairingServer()
            await refreshConnections()
        } catch { networkMessage = error.localizedDescription; self.error = error.localizedDescription }
    }
    func stopTransport() {
        pairingTask?.cancel(); pairingTask = nil; outbound = nil; outboundName = ""; outboundCode = ""
        pairingServer?.stop(); pairingServer = nil; nearby = []; incoming = []
        service?.stop(); service = nil; engineID = ""; connected = [:]; transferStatus = nil
        config.transportEnabled = false; save(); networkMessage = "已停止"
    }
    func refreshConnections() async {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(.main))
        #endif
        guard let service, !engineID.isEmpty else { return }
        do {
            let connections = try await service.connections()
            let status = try await service.transferStatus()
            if connected != connections { connected = connections }
            if transferStatus != status { transferStatus = status }
        } catch { networkMessage = "同步连接失败：\(error.localizedDescription)"; transferStatus = nil }
    }
    var transferSummary: String {
        guard !engineID.isEmpty, let status = transferStatus else { return networkMessage }
        if status.errors > 0 || status.pullErrors > 0 { return "传输异常" }
        if status.isReceiving {
            let remaining = ByteCountFormatter.string(fromByteCount: status.needBytes, countStyle: .file)
            return "接收中 · \(Int(status.fractionReceived * 100))% · 剩余 \(remaining)"
        }
        if status.state == "scanning" || status.state == "scan-waiting" { return "检查中…" }
        if status.globalFiles == 0 { return "等待同步" }
        if paused { return "已暂停" }
        if scanning { return scanControl?.isCancelled == true ? "正在停止旧扫描…" : "处理中…" }
        if statuses.contains(where: { $0.error != nil }) { return "文库异常" }
        if !conflicts.isEmpty { return "等待合并" }
        if statuses.contains(where: { !$0.report.notices.isEmpty }) { return "部分版本待处理" }
        return "已同步"
    }
    func copyPairing() {
        do {
            guard !engineID.isEmpty else { throw VaultSyncError.invalidConfiguration("请先启动同步引擎，再复制配对信息。") }
            let offer = PairingOffer(peer: Peer(id: engineID, name: config.deviceName, host: engineHost, port: syncPort), vaults: config.vaults)
            let data = try Codec.encode(offer)
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
        } catch { self.error = error.localizedDescription }
    }
    func addPeer(_ text: String) async throws {
        let offer = try PairingOffer.parse(text)
        try await acceptOffer(offer)
    }
    private func acceptOffer(_ offer: PairingOffer) async throws {
        MainActor.assertIsolated()
        guard offer.peer.id != engineID else { throw VaultSyncError.invalidConfiguration("这是本机设备的配对信息，请选择另一台 Mac。") }
        guard let service, !engineID.isEmpty else { throw VaultSyncError.invalidConfiguration("请先启动本机同步，再添加设备。") }
        try offer.peer.validate()
        let peers = config.peers.filter { $0.id != offer.peer.id } + [offer.peer]
        try await service.configure(peers: peers, deviceName: config.deviceName)
        config.peers = peers
        for vault in offer.vaults where !config.offeredVaults.contains(where: { $0.id == vault.id }) { config.offeredVaults.append(vault) }
        save()
        networkMessage = "正在连接 " + offer.peer.name
        await refreshConnections()
    }
    private var ownOffer: PairingOffer? {
        guard !engineID.isEmpty, !engineHost.isEmpty else { return nil }
        return PairingOffer(peer: Peer(id: engineID, name: config.deviceName, host: engineHost, port: syncPort), vaults: config.vaults)
    }
    private func rememberVaults(_ offer: PairingOffer) {
        for vault in offer.vaults where !config.offeredVaults.contains(where: { $0.id == vault.id }) { config.offeredVaults.append(vault) }
        save()
    }
    private func startPairingServer() async {
        guard pairingServer == nil, let offer = ownOffer else { return }
        let server = PairingServer(offer: offer, isBase: config.isBase == true)
        server.onRequests = { [weak self] requests in Task { @MainActor in self?.incoming = requests } }
        server.onAcknowledged = { [weak self] offer in Task { @MainActor in
            self?.rememberVaults(offer); self?.pairingMessage = "已配对 \(offer.peer.name)"
        } }
        do {
            try await server.start(host: engineHost, port: pairingPort)
            pairingServer = server
            if let offer = ownOffer { server.updateOffer(offer, isBase: config.isBase == true) }
            pairingMessage = ""
        }
        catch { server.stop(); pairingMessage = "设备发现服务未启动：\(error.localizedDescription)；仍可使用手动配对。" }
    }
    func discoverDevices() async {
        guard !discovering else { return }; discovering = true
        defer { discovering = false }
        if engineID.isEmpty { await startTransport() }
        guard !engineID.isEmpty else { pairingMessage = networkMessage; return }
        do {
            let peers = try await Task.detached { try SyncthingService.tailnetPeers() }.value
            nearby = await PairingClient.discover(peers).filter { $0.id != engineID }
            pairingMessage = nearby.isEmpty ? "未发现运行 VaultSync 的设备。" : ""
        } catch { pairingMessage = "查找设备失败：\(error.localizedDescription)" }
    }
    func requestPairing(_ device: NearbyDevice) async {
        guard outbound == nil, let offer = ownOffer else { return }
        let request = PairingRequest(peer: offer.peer)
        outbound = (device, request); outboundName = device.peer.name; outboundCode = request.code
        pairingMessage = "正在发送请求…"
        do {
            let reply = try await PairingClient.exchange(host: device.peer.host, port: device.pairingPort, packet: PairingPacket(action: "request", request: request))
            guard outbound?.request.id == request.id else {
                _ = try? await PairingClient.exchange(host: device.peer.host, port: device.pairingPort, packet: PairingPacket(action: "cancel", requestID: request.id, token: request.token)); return
            }
            guard ["pending", "approved", "complete"].contains(reply.state) else { throw VaultSyncError.invalidConfiguration("对方未接受配对请求。") }
            pairingMessage = ""
            pairingTask = Task { [weak self] in await self?.pollPairing(device, request: request) }
        } catch { if outbound?.request.id == request.id { pairingMessage = "发送失败：\(error.localizedDescription)"; outbound = nil; outboundName = ""; outboundCode = "" } }
    }
    private func pollPairing(_ device: NearbyDevice, request: PairingRequest) async {
        for _ in 0..<300 {
            guard !Task.isCancelled else { return }
            do {
                let reply = try await PairingClient.exchange(host: device.peer.host, port: device.pairingPort,
                    packet: PairingPacket(action: "status", requestID: request.id, token: request.token))
                try Task.checkCancellation()
                if ["approved", "complete"].contains(reply.state), let offer = reply.offer {
                    guard offer.peer == device.peer else { throw VaultSyncError.invalidConfiguration("对端设备身份变化，请重新查找并确认。") }
                    finishingPairing = true
                    try await acceptOffer(offer)
                    if ownOffer != nil {
                        let own = PairingOffer(peer: request.peer, vaults: config.vaults)
                        _ = try await PairingClient.exchange(host: device.peer.host, port: device.pairingPort,
                            packet: PairingPacket(action: "ack", requestID: request.id, token: request.token, offer: own))
                    }
                    pairingMessage = "已配对 \(device.peer.name)"
                    outbound = nil; outboundName = ""; outboundCode = ""; finishingPairing = false; return
                }
                if ["rejected", "cancelled"].contains(reply.state) {
                    pairingMessage = "对方已拒绝或取消请求。"; outbound = nil; outboundName = ""; outboundCode = ""; return
                }
            } catch {
                finishingPairing = false; if Task.isCancelled { return }
                if error.localizedDescription.contains("已过期") {
                    pairingMessage = "配对请求已过期或对端已重新启动，请再次发送请求。"; outbound = nil; outboundName = ""; outboundCode = ""; return
                }
                pairingMessage = "等待确认 / 重试连接：\(error.localizedDescription)"
            }
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
        }
        pairingMessage = "配对请求已结束，请重新发送。"; outbound = nil; outboundName = ""; outboundCode = ""
    }
    func approvePairing(_ request: PairingRequest) async {
        guard approvingID == nil else { return }; approvingID = request.id
        defer { approvingID = nil }
        do {
            try await acceptOffer(PairingOffer(peer: request.peer, vaults: []))
            pairingServer?.approve(request.id)
            pairingMessage = "等待对方完成配对…"
        } catch { pairingMessage = "确认失败：\(error.localizedDescription)" }
    }
    func rejectPairing(_ request: PairingRequest) { pairingServer?.reject(request.id) }
    func cancelPairing() {
        guard !finishingPairing else { return }
        pairingTask?.cancel(); pairingTask = nil
        if let outbound { Task { _ = try? await PairingClient.exchange(host: outbound.device.peer.host, port: outbound.device.pairingPort,
            packet: PairingPacket(action: "cancel", requestID: outbound.request.id, token: outbound.request.token)) } }
        outbound = nil; outboundName = ""; outboundCode = ""; pairingMessage = "已取消"
    }
    func removePeer(_ peer: Peer) {
        config.peers.removeAll { $0.id == peer.id }; connected.removeValue(forKey: peer.id); save()
        Task {
            if let service {
                do { try await service.configure(peers: config.peers, deviceName: config.deviceName) }
                catch { stopTransport(); self.error = "已停止同步。下次启动时会应用设备移除：\(error.localizedDescription)" }
            }
        }
    }
    func loginItem(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { self.error = "登录时启动设置失败：\(error.localizedDescription)" }
    }
    func quit() { scanControl?.cancel(); retryTask?.cancel(); pairingTask?.cancel(); pairingServer?.stop(); service?.stop(); NSApp.terminate(nil) }
    func openFolder(_ path: String) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
    private func createDemo() {
        guard config.vaults.isEmpty else { return }
        do {
            let path = base.appendingPathComponent("Demo Vault"); try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            let mapping = VaultMapping(name: "示例知识库", path: path.path)
            config.vaults = [mapping]; save()
            let engine = try VaultEngine(mapping: mapping, transportRoot: objects, stateRoot: stateRoot, device: author)
            let note = path.appendingPathComponent("项目想法.md")
            try Data("# 我的知识库\n\n共同的最初版本。\n\n下一步：连接其他 Mac。\n".utf8).write(to: note)
            _ = try engine.scan(); let first = try engine.history(path: "项目想法.md")[0]
            try Data("# 我的知识库\n\n桌面 Mac 补充了技术方案。\n\n下一步：连接其他 Mac。\n".utf8).write(to: note)
            _ = try engine.scan()
            _ = try engine.store.create(path: "项目想法.md", parents: [first.id], data: Data("# 我的知识库\n\n笔记本补充了产品想法。\n\n下一步：连接其他 Mac。\n".utf8), device: "MacBook [demo]")
            statuses = [VaultStatus(mapping: mapping)]
        } catch { self.error = error.localizedDescription }
    }
}
