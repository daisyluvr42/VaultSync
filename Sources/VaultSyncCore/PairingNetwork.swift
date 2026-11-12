import Foundation
import Darwin

public struct TailnetDevice: Sendable, Identifiable, Equatable {
    public var host: String
    public var name: String
    public var id: String { host }
    public init(host: String, name: String) { self.host = host; self.name = name }
}
public struct NearbyDevice: Sendable, Identifiable {
    public var peer: Peer
    public var pairingPort: UInt16
    public var isBase: Bool
    public var id: String { peer.id }
    public init(peer: Peer, pairingPort: UInt16 = 22081, isBase: Bool = false) {
        self.peer = peer; self.pairingPort = pairingPort; self.isBase = isBase
    }
}
public struct PairingRequest: Sendable, Codable, Identifiable {
    public var id: String
    public var token: String
    public var code: String
    public var peer: Peer
    public var created: Double
    public init(peer: Peer) {
        id = UUID().uuidString; token = UUID().uuidString + UUID().uuidString
        code = String(Int.random(in: 100000...999999)); self.peer = peer; created = Date().timeIntervalSince1970
    }
}
public struct PairingPacket: Sendable, Codable {
    public var schema: Int = 1
    public var action: String
    public var request: PairingRequest?
    public var requestID: String?
    public var token: String?
    public var offer: PairingOffer?
    public init(action: String, request: PairingRequest? = nil, requestID: String? = nil, token: String? = nil, offer: PairingOffer? = nil) {
        self.action = action; self.request = request; self.requestID = requestID; self.token = token; self.offer = offer
    }
}
public struct PairingReply: Sendable, Codable {
    public var state: String
    public var offer: PairingOffer?
    public var message: String?
    public var isBase: Bool?
    public init(state: String, offer: PairingOffer? = nil, message: String? = nil, isBase: Bool? = nil) {
        self.state = state; self.offer = offer; self.message = message; self.isBase = isBase
    }
}

/// A small, bounded request/response protocol over the encrypted tailnet. No Vault payloads or
/// engine API credentials are exposed. Only explicit approval releases the Vault catalogue.
public final class PairingServer: @unchecked Sendable {
    public private(set) var port: UInt16 = 22081
    private let queue = DispatchQueue(label: "app.vaultsync.pairing.server")
    private var listener: DispatchSourceRead?
    private var connections: [UUID: Int32] = [:]
    private var offer: PairingOffer
    private var isBase: Bool
    private struct Entry { var request: PairingRequest; var origin: String; var state: String = "pending" }
    private var entries: [String: Entry] = [:]
    private let testLoopback: Bool
    public var onRequests: (@Sendable ([PairingRequest]) -> Void)?
    public var onAcknowledged: (@Sendable (PairingOffer) -> Void)?
    public init(offer: PairingOffer, isBase: Bool = false, allowLoopbackForTesting: Bool = false) {
        self.offer = offer; self.isBase = isBase; testLoopback = allowLoopbackForTesting
    }
    public func updateOffer(_ value: PairingOffer, isBase: Bool) {
        queue.async { self.offer = value; self.isBase = isBase }
    }
    public func start(host: String, port: UInt16 = 22081) async throws {
        guard (host.contains(".") && Peer.isTailIP(host)) || (testLoopback && host == "127.0.0.1") else { throw VaultSyncError.invalidConfiguration("配对服务需要 Tailscale IPv4 地址。") }
        let fd = try PairingSocket.socket()
        do {
            var reuse: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            var address = try PairingSocket.address(host, port: port)
            let bound = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard bound == 0, Darwin.listen(fd, 16) == 0 else { throw PairingSocket.failure("启动配对服务") }
            var actual = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &actual) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
            self.port = UInt16(bigEndian: actual.sin_port)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.accept(fd) }
            source.setCancelHandler { Darwin.close(fd) }
            queue.sync { listener = source }; source.resume()
        } catch { Darwin.close(fd); throw error }
    }
    private func accept(_ listenerFD: Int32) {
        while true {
            var address = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let fd = withUnsafeMutablePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(listenerFD, $0, &length) } }
            guard fd >= 0 else { return }
            var ip = address.sin_addr, text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            _ = inet_ntop(AF_INET, &ip, &text, socklen_t(text.count))
            let origin = String(cString: text)
            guard connections.count < 32, Peer.isTailIP(origin) || (testLoopback && origin == "127.0.0.1") else { Darwin.close(fd); continue }
            let id = UUID(); connections[id] = fd
            PairingSocket.suppressPipeSignal(fd)
            DispatchQueue.global(qos: .utility).async { [self] in
                defer { queue.async { self.connections.removeValue(forKey: id); Darwin.close(fd) } }
                let reply: PairingReply
                do {
                    let packet = try JSONDecoder().decode(PairingPacket.self, from: PairingSocket.readLine(fd))
                    reply = try queue.sync { guard listener != nil else { throw VaultSyncError.invalidConfiguration("配对服务已停止。") }; return try handle(packet, origin: origin) }
                } catch { reply = PairingReply(state: "error", message: error.localizedDescription) }
                if let data = try? Codec.encode(reply) { try? PairingSocket.write(data + Data([10]), to: fd) }
            }
        }
    }
    private func publish() { onRequests?(entries.values.filter { $0.state == "pending" }.map(\.request).sorted { $0.created < $1.created }) }
    private func handle(_ packet: PairingPacket, origin: String) throws -> PairingReply {
        guard packet.schema == 1 else { throw VaultSyncError.invalidConfiguration("两台设备的配对协议不兼容，请更新应用。") }
        let now = Date().timeIntervalSince1970
        entries = entries.filter { now - $0.value.request.created < 600 }
        switch packet.action {
        case "hello":
            return PairingReply(state: "hello", offer: PairingOffer(peer: offer.peer, vaults: []), isBase: isBase ? true : nil)
        case "request":
            guard var request = packet.request, UUID(uuidString: request.id) != nil, request.token.count >= 64,
                  request.code.count == 6, request.code.allSatisfy(\.isNumber), entries.count < 64 else { throw VaultSyncError.invalidConfiguration("配对请求无效或待处理请求过多。") }
            try request.peer.validate()
            guard testLoopback || request.peer.host == origin else { throw VaultSyncError.invalidConfiguration("请求设备与网络来源不一致。") }
            guard request.peer.id != offer.peer.id else { throw VaultSyncError.invalidConfiguration("不能与本机配对。") }
            if let existing = entries[request.id] {
                guard existing.request.token == request.token, existing.origin == origin else { throw VaultSyncError.invalidConfiguration("配对请求身份不匹配。") }
                return response(existing)
            }
            request.created = now
            // Repeated clicks from one device replace its pending request instead of flooding UI.
            entries = entries.filter { $0.value.request.peer.id != request.peer.id || $0.value.state != "pending" }
            entries[request.id] = Entry(request: request, origin: origin); publish()
            return PairingReply(state: "pending")
        case "status", "ack", "cancel":
            guard let id = packet.requestID, let entry = entries[id], entry.origin == origin, packet.token == entry.request.token else {
                throw VaultSyncError.invalidConfiguration("配对请求已过期，请重新发起。")
            }
            if packet.action == "cancel" { entries[id]?.state = "cancelled"; publish(); return PairingReply(state: "cancelled") }
            if packet.action == "ack" {
                guard ["approved", "complete"].contains(entry.state), let remote = packet.offer, remote.peer == entry.request.peer else { throw VaultSyncError.invalidConfiguration("配对尚未确认，或设备身份已变化。") }
                _ = try PairingOffer.parse(String(decoding: Codec.encode(remote), as: UTF8.self))
                onAcknowledged?(remote); entries[id]?.state = "complete"; publish()
                return PairingReply(state: "complete")
            }
            return response(entry)
        default: throw VaultSyncError.invalidConfiguration("不支持的配对操作。")
        }
    }
    private func response(_ entry: Entry) -> PairingReply {
        PairingReply(state: entry.state, offer: entry.state == "approved" || entry.state == "complete" ? offer : nil)
    }
    public func approve(_ id: String) { queue.sync { if entries[id]?.state == "pending" { entries[id]?.state = "approved" }; publish() } }
    public func reject(_ id: String) { queue.sync { entries[id]?.state = "rejected"; publish() } }
    public func stop() {
        queue.async {
            self.listener?.cancel(); self.listener = nil
            for fd in self.connections.values { _ = Darwin.shutdown(fd, SHUT_RDWR) }
        }
    }

}

public enum PairingClient {
    public static func exchange(host: String, port: UInt16 = 22081, packet: PairingPacket, allowLoopbackForTesting: Bool = false) async throws -> PairingReply {
        guard Peer.isTailIP(host) || (allowLoopbackForTesting && host == "127.0.0.1") else { throw VaultSyncError.invalidConfiguration("请选择有效的 Tailscale 地址。") }
        let payload = try Codec.encode(packet) + Data([10])
        guard payload.count <= 65536 else { throw VaultSyncError.invalidConfiguration("配对信息过大。") }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let fd = try PairingSocket.connect(host, port: port)
                    defer { Darwin.close(fd) }
                    try PairingSocket.write(payload, to: fd)
                    let reply = try JSONDecoder().decode(PairingReply.self, from: PairingSocket.readLine(fd))
                    if reply.state == "error" { throw VaultSyncError.invalidConfiguration(reply.message ?? "对端配对失败。") }
                    continuation.resume(returning: reply)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    public static func discover(_ devices: [TailnetDevice], port: UInt16 = 22081) async -> [NearbyDevice] {
        // Only probe known, online tailnet peers; never scan a LAN or public address range.
        var found: [NearbyDevice] = []
        for start in stride(from: 0, to: min(devices.count, 64), by: 6) {
            let batch = Array(devices[start..<min(start + 6, devices.count)])
            let result = await withTaskGroup(of: NearbyDevice?.self, returning: [NearbyDevice].self) { group in
                for device in batch {
                    group.addTask {
                        guard let reply = try? await exchange(host: device.host, port: port, packet: PairingPacket(action: "hello")),
                              reply.state == "hello",
                              let offer = reply.offer, offer.peer.host == device.host, (try? offer.peer.validate()) != nil else { return nil }
                        return NearbyDevice(peer: offer.peer, pairingPort: port, isBase: reply.isBase == true)
                    }
                }
                var values: [NearbyDevice] = []; for await value in group { if let value { values.append(value) } }; return values
            }
            found += result
        }
        return found.sorted { $0.peer.name < $1.peer.name }
    }
}
