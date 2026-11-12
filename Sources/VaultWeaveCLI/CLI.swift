import Foundation
import Darwin
import VaultWeaveCore

@main struct VaultWeaveCLI {
    static func main() async {
        setbuf(stdout, nil)
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard let command = args.first else { throw WeaveError.invalidConfiguration("Commands: scan, merge, transport-probe") }
            var flags: [String: String] = [:]
            var index = 1
            while index + 1 < args.count { flags[args[index]] = args[index+1]; index += 2 }
            func flag(_ name: String) throws -> String { guard let value = flags["--" + name] else { throw WeaveError.invalidConfiguration("Missing --" + name) }; return value }
            if command == "pairing-integration" {
                try await runPairingIntegration(home: URL(fileURLWithPath: try flag("home")), executable: URL(fileURLWithPath: try flag("engine")))
                return
            }
            if command == "pairing-request" {
                try await runPairingRequest(home: URL(fileURLWithPath: try flag("home")), executable: URL(fileURLWithPath: try flag("engine")), host: try flag("host"), port: UInt16(try flag("port"))!)
                return
            }
            if command == "tailscale-probe" {
                let candidates = flags["--binary"].map { [URL(fileURLWithPath: $0)] }
                _ = try SyncthingService.tailscaleAddress(candidates: candidates)
                print("{\"connected\":true,\"cliMode\":true}")
                return
            }
            if command == "transport-probe" || command == "transport-daemon" {
                let base = URL(fileURLWithPath: try flag("home"))
                let service = try SyncthingService(home: base.appendingPathComponent("engine"), objects: base.appendingPathComponent("objects"),
                    executable: URL(fileURLWithPath: try flag("engine")), apiPort: Int(flags["--api-port"] ?? "28384")!, syncPort: Int(flags["--sync-port"] ?? "32080")!)
                defer { service.stop() }
                try await service.start(peers: [], deviceName: "VaultWeave isolated probe")
                let config = try await service.request("GET", "config/options")
                let folder = try await service.request("GET", "config/folders/vaultweave-objects-v1")
                let report: [String: Any] = ["started": true, "deviceID": service.deviceID, "host": service.tailHost, "listenAddresses": config["listenAddresses"] ?? [],
                    "globalDiscovery": config["globalAnnounceEnabled"] ?? true, "relays": config["relaysEnabled"] ?? true,
                    "folderID": folder["id"] ?? "", "folderPath": folder["path"] ?? ""]
                let encoded = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
                print(String(decoding: encoded, as: UTF8.self))
                if command == "transport-daemon" {
                    let ready = URL(fileURLWithPath: try flag("ready"))
                    try encoded.write(to: ready, options: .atomic)
                    var lastPeers = Data()
                    while !FileManager.default.fileExists(atPath: try flag("stop")) {
                        if let path = flags["--peers-file"], let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data != lastPeers {
                            let peers = try JSONDecoder().decode([Peer].self, from: data)
                            try await service.configure(peers: peers, deviceName: flags["--device"] ?? "Integration node")
                            lastPeers = data
                        }
                        try await Task.sleep(nanoseconds: 250_000_000)
                    }
                }
                return
            }
            let mapping = VaultMapping(id: try flag("vault-id"), name: "CLI", path: try flag("vault"))
            let engine = try VaultEngine(mapping: mapping, transportRoot: URL(fileURLWithPath: try flag("objects")), stateRoot: URL(fileURLWithPath: try flag("state")), device: try flag("device"))
            let report: SyncReport
            if command == "merge" {
                let data = flags["--delete"] == "yes" ? nil : try Data(contentsOf: URL(fileURLWithPath: try flag("file")))
                report = try engine.resolve(path: try flag("path"), expectedHeads: try flag("heads").split(separator: ",").map(String.init), data: data)
            } else if command == "scan" { report = try engine.scan() }
            else { throw WeaveError.invalidConfiguration("Unknown command") }
            let conflicts: [[String: Any]] = report.conflicts.map { ["path": $0.path, "heads": $0.heads.map(\.id), "base": $0.base?.id ?? ""] }
            let json: [String: Any] = ["files": report.files, "revisions": report.revisions, "conflicts": conflicts, "notices": report.notices]
            print(String(decoding: try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]), as: UTF8.self))
        } catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
    }
}
