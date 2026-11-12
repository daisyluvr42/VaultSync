import Foundation
import VaultWeaveCore

private final class AsyncOutcome: @unchecked Sendable { var error: Error? }
private func awaitCheck(_ body: @escaping @Sendable () async throws -> Void) throws {
    let gate = DispatchSemaphore(value: 0), outcome = AsyncOutcome()
    Task.detached { do { try await body() } catch { outcome.error = error }; gate.signal() }
    guard gate.wait(timeout: .now() + 15) == .success else { throw WeaveError.invalidConfiguration("配对验证超时。") }
    if let error = outcome.error { throw error }
}
extension EngineTests {
    private func offer(_ name: String, character: String = "A") -> PairingOffer {
        PairingOffer(peer: Peer(id: String(repeating: character, count: 56), name: name, host: "100.64.0.8"),
                     vaults: [VaultMapping(name: "Private Vault", path: "/private/not/transmitted")])
    }
    func testPairingTextFormatsAndClearError() throws {
        let input = try Codec.encode(offer("test")), text = String(decoding: input, as: UTF8.self)
        for variant in [text, " \n" + text + "\n", "\u{feff}" + text, "```json\n" + text + "\n```", String(decoding: try Codec.encode(text), as: UTF8.self)] {
            checkEqual(try PairingOffer.parse(variant).peer.name, "test")
        }
        for bad in ["", "复制配对信息", "{\"schema\":1", "```json\n{}"] {
            do { _ = try PairingOffer.parse(bad); checkTrue(false) }
            catch { checkFalse(error.localizedDescription.contains("The data couldn")); checkTrue(error.localizedDescription.contains("配对")) }
        }
    }
    func testTailnetDiscoveryOnlyUsesOnlinePrivatePeers() throws {
        let data = Data("""
        {"Peer":{"one":{"HostName":"Mac A","Online":true,"TailscaleIPs":["100.64.0.1"]},
        "two":{"HostName":"Sleeping","Online":false,"TailscaleIPs":["100.64.0.2"]},
        "three":{"HostName":"Public","Online":true,"TailscaleIPs":["8.8.8.8"]}}}
        """.utf8)
        let devices = try SyncthingService.parseTailnetPeers(data)
        checkEqual(devices.count,1); checkEqual(devices[0].name,"Mac A")
    }
    func testPairingWaitsForApprovalAndAuthenticatesRequest() throws {
        let local = offer("Receiver"), remote = offer("Sender",character:"B")
        try awaitCheck {
            let server = PairingServer(offer: local,allowLoopbackForTesting:true)
            defer { server.stop() }
            try await server.start(host:"127.0.0.1",port:0)
            func exchange(_ packet: PairingPacket) async throws -> PairingReply {
                try await PairingClient.exchange(host:"127.0.0.1",port:server.port,packet:packet,allowLoopbackForTesting:true)
            }
            let hello = try await exchange(PairingPacket(action:"hello"))
            checkEqual(hello.offer?.peer.name,"Receiver"); checkTrue(hello.offer?.vaults.isEmpty == true)
            let request = PairingRequest(peer:remote.peer)
            let sent = try await exchange(PairingPacket(action:"request",request:request))
            checkEqual(sent.state,"pending")
            // There is deliberately no simultaneous-click deadline. Polling remains pending.
            try await Task.sleep(nanoseconds:200_000_000)
            let pending = try await exchange(PairingPacket(action:"status",requestID:request.id,token:request.token))
            checkEqual(pending.state,"pending"); checkTrue(pending.offer == nil)
            do { _ = try await exchange(PairingPacket(action:"status",requestID:request.id,token:"wrong")); checkTrue(false) } catch {}
            do { _ = try await exchange(PairingPacket(action:"ack",requestID:request.id,token:request.token,offer:remote)); checkTrue(false) } catch {}
            server.approve(request.id)
            let approved = try await exchange(PairingPacket(action:"status",requestID:request.id,token:request.token))
            checkEqual(approved.state,"approved"); checkEqual(approved.offer?.vaults.count,1)
            let ack = PairingPacket(action:"ack",requestID:request.id,token:request.token,offer:remote)
            let firstAck = try await exchange(ack), repeatedAck = try await exchange(ack)
            checkEqual(firstAck.state,"complete"); checkEqual(repeatedAck.state,"complete")
        }
    }
    func testPairingRejectAndCancel() throws {
        let local = offer("Receiver"), remote = offer("Sender",character:"B")
        try awaitCheck {
            let server = PairingServer(offer:local,allowLoopbackForTesting:true)
            defer { server.stop() }; try await server.start(host:"127.0.0.1",port:0)
            func exchange(_ packet: PairingPacket) async throws -> PairingReply {
                try await PairingClient.exchange(host:"127.0.0.1",port:server.port,packet:packet,allowLoopbackForTesting:true)
            }
            let first = PairingRequest(peer:remote.peer)
            _ = try await exchange(PairingPacket(action:"request",request:first)); server.reject(first.id)
            let rejected = try await exchange(PairingPacket(action:"status",requestID:first.id,token:first.token))
            checkEqual(rejected.state,"rejected")
            let second = PairingRequest(peer:remote.peer)
            _ = try await exchange(PairingPacket(action:"request",request:second))
            let cancelled = try await exchange(PairingPacket(action:"cancel",requestID:second.id,token:second.token))
            checkEqual(cancelled.state,"cancelled")
        }
    }
}
