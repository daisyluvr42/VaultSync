import Foundation
import VaultWeaveCore

extension VaultWeaveCLI {
    static func runPairingRequest(home: URL, executable: URL, host: String, port: UInt16) async throws {
        let engine = try SyncthingService(home:home.appendingPathComponent("engine"),objects:home.appendingPathComponent("objects"),executable:executable,apiPort:29940,syncPort:33940)
        defer { engine.stop() }; try await engine.start(peers:[],deviceName:"Pairing UI test Mac")
        let own = PairingOffer(peer:Peer(id:engine.deviceID,name:"配对流程测试 Mac",host:engine.tailHost,port:33940),vaults:[])
        let request = PairingRequest(peer:own.peer)
        _ = try await PairingClient.exchange(host:host,port:port,packet:PairingPacket(action:"request",request:request))
        print("Waiting for UI approval, code:",request.code)
        for _ in 0..<180 {
            let result = try await PairingClient.exchange(host:host,port:port,packet:PairingPacket(action:"status",requestID:request.id,token:request.token))
            if result.state == "approved", let offer = result.offer {
                try await engine.configure(peers:[offer.peer],deviceName:own.peer.name)
                _ = try await PairingClient.exchange(host:host,port:port,packet:PairingPacket(action:"ack",requestID:request.id,token:request.token,offer:own))
                print("PASS native UI approval completed both peers")
                try await Task.sleep(nanoseconds:10_000_000_000); return
            }
            if result.state == "rejected" { print("Request rejected"); return }
            try await Task.sleep(nanoseconds:1_000_000_000)
        }
        throw WeaveError.invalidConfiguration("UI confirmation timed out")
    }
    static func runPairingIntegration(home: URL, executable: URL) async throws {
        let aRoot = home.appendingPathComponent("a"), bRoot = home.appendingPathComponent("b")
        let a = try SyncthingService(home:aRoot.appendingPathComponent("engine"),objects:aRoot.appendingPathComponent("objects"),executable:executable,apiPort:29401,syncPort:33401)
        let b = try SyncthingService(home:bRoot.appendingPathComponent("engine"),objects:bRoot.appendingPathComponent("objects"),executable:executable,apiPort:29402,syncPort:33402)
        defer { a.stop(); b.stop() }
        try await a.start(peers:[],deviceName:"Pair test A"); try await b.start(peers:[],deviceName:"Pair test B")
        let peerA = Peer(id:a.deviceID,name:"Pair test A",host:a.tailHost,port:33401)
        let peerB = Peer(id:b.deviceID,name:"Pair test B",host:b.tailHost,port:33402)
        let vaultID = UUID().uuidString.lowercased()
        let mapA = VaultMapping(id:vaultID,name:"Pairing fixture",path:aRoot.appendingPathComponent("vault").path)
        let mapB = VaultMapping(id:vaultID,name:"Pairing fixture",path:bRoot.appendingPathComponent("vault").path)
        for mapping in [mapA,mapB] { try FileManager.default.createDirectory(atPath:mapping.path,withIntermediateDirectories:true) }
        let offerA = PairingOffer(peer:peerA,vaults:[mapA]), offerB = PairingOffer(peer:peerB,vaults:[mapB])
        let server = PairingServer(offer:offerB); defer { server.stop() }
        try await server.start(host:b.tailHost,port:33403)
        print("Pairing listener port:",server.port)
        _ = try await PairingClient.exchange(host:b.tailHost,port:server.port,packet:PairingPacket(action:"hello"))
        let found = await PairingClient.discover([TailnetDevice(host:b.tailHost,name:peerB.name)],port:33403)
        guard found.count == 1, found[0].peer.id == b.deviceID else { throw WeaveError.invalidConfiguration("设备发现验证失败。") }
        print("PASS discovered real device identity over Tailscale")
        func exchange(_ packet: PairingPacket) async throws -> PairingReply {
            try await PairingClient.exchange(host:b.tailHost,port:33403,packet:packet)
        }
        var spoofed = peerA; spoofed.host = "100.64.0.1"
        var rejected = false
        do { _ = try await exchange(PairingPacket(action:"request",request:PairingRequest(peer:spoofed))) } catch { rejected = true }
        guard rejected else { throw WeaveError.invalidConfiguration("来源地址校验未生效。") }
        let request = PairingRequest(peer:peerA)
        let sent = try await exchange(PairingPacket(action:"request",request:request))
        try await Task.sleep(nanoseconds:500_000_000)
        let pending = try await exchange(PairingPacket(action:"status",requestID:request.id,token:request.token))
        guard sent.state == "pending", pending.state == "pending", pending.offer == nil else { throw WeaveError.invalidConfiguration("请求不应在确认前开放文库目录。") }
        print("PASS sequential pairing request waits for explicit approval")
        try await b.configure(peers:[peerA],deviceName:peerB.name); server.approve(request.id)
        let approved = try await exchange(PairingPacket(action:"status",requestID:request.id,token:request.token))
        guard approved.state == "approved", approved.offer?.peer == peerB else { throw WeaveError.invalidConfiguration("确认后的设备身份校验失败。") }
        try await a.configure(peers:[peerB],deviceName:peerA.name)
        let ack = try await exchange(PairingPacket(action:"ack",requestID:request.id,token:request.token,offer:offerA))
        guard ack.state == "complete" else { throw WeaveError.invalidConfiguration("双向配对没有完成。") }
        var connected = false
        for _ in 0..<80 {
            if try await a.connections()[b.deviceID] == true { connected = true; break }
            try await Task.sleep(nanoseconds:250_000_000)
        }
        guard connected else { throw WeaveError.invalidConfiguration("配对已完成，但引擎未能连接。") }
        print("PASS automatic handshake configures both real Syncthing peers")
        let engineA = try VaultEngine(mapping:mapA,transportRoot:a.objects,stateRoot:aRoot.appendingPathComponent("state"),device:peerA.name)
        let engineB = try VaultEngine(mapping:mapB,transportRoot:b.objects,stateRoot:bRoot.appendingPathComponent("state"),device:peerB.name)
        let note = URL(fileURLWithPath:mapA.path).appendingPathComponent("pair-test.md")
        try Data("paired and synchronized\n".utf8).write(to:note); _ = try engineA.scan()
        var synchronized = false
        for _ in 0..<120 {
            _ = try engineB.scan()
            if (try? String(contentsOfFile:mapB.path + "/pair-test.md",encoding:.utf8)) == "paired and synchronized\n" { synchronized = true; break }
            try await Task.sleep(nanoseconds:250_000_000)
        }
        guard synchronized else { throw WeaveError.invalidConfiguration("配对后的文库传输验证超时。") }
        print("PASS note reaches second Vault after request and approval")
    }
}
