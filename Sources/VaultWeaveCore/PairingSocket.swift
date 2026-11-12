import Foundation
import Darwin

/// BSD sockets use the same routing semantics as Syncthing, including macOS VPN interfaces.
enum PairingSocket {
    static func failure(_ action: String) -> WeaveError {
        .invalidConfiguration("\(action)失败：\(String(cString: strerror(errno)))。请确认对端已启动同步，并允许 Tailscale TCP 22081。")
    }
    static func socket() throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw failure("创建配对连接") }
        suppressPipeSignal(fd); return fd
    }
    static func suppressPipeSignal(_ fd: Int32) {
        var flag: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &flag, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }
    static func address(_ host: String, port: UInt16) throws -> sockaddr_in {
        var value = sockaddr_in(); value.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        value.sin_family = sa_family_t(AF_INET); value.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &value.sin_addr) == 1 else { throw WeaveError.invalidConfiguration("请选择 Tailscale IPv4 地址。") }
        return value
    }
    private static func deadline() -> UInt64 { DispatchTime.now().uptimeNanoseconds + 4_000_000_000 }
    private static func ready(_ fd: Int32, event: Int16, until end: UInt64) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < end else { throw WeaveError.invalidConfiguration("等待设备响应超时。请检查对端同步状态和 Tailscale TCP 22081。") }
            var descriptor = pollfd(fd: fd, events: event, revents: 0)
            let result = Darwin.poll(&descriptor, 1, Int32(max(1, (end - now) / 1_000_000)))
            if result > 0 { return }
            if result < 0 && errno != EINTR { throw failure("等待配对连接") }
        }
    }
    static func connect(_ host: String, port: UInt16) throws -> Int32 {
        let fd = try socket()
        do {
            var value = try address(host, port: port)
            let result = withUnsafePointer(to: &value) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            if result != 0 {
                guard errno == EINPROGRESS else { throw failure("连接设备") }
                try ready(fd, event: Int16(POLLOUT), until: deadline())
                var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { if error != 0 { errno = error }; throw failure("连接设备") }
            }
            return fd
        } catch { Darwin.close(fd); throw error }
    }
    static func readLine(_ fd: Int32) throws -> Data {
        var result = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        let end = deadline()
        while result.count <= 65536 {
            try ready(fd, event: Int16(POLLIN), until: end)
            let count = Darwin.recv(fd, &buffer, buffer.count, 0)
            if count == 0 { throw WeaveError.invalidConfiguration("设备关闭了配对连接。") }
            if count < 0 { if errno == EAGAIN || errno == EINTR { continue }; throw failure("读取配对信息") }
            result.append(contentsOf: buffer.prefix(count))
            guard result.count <= 65536 else { break }
            if let end = result.firstIndex(of: 10) { return result.prefix(upTo: end) }
        }
        throw WeaveError.invalidConfiguration("配对信息超过大小限制。")
    }
    static func write(_ data: Data, to fd: Int32) throws {
        let end = deadline()
        try data.withUnsafeBytes { bytes in
            guard let pointer = bytes.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                try ready(fd, event: Int16(POLLOUT), until: end)
                let count = Darwin.send(fd, pointer.advanced(by: offset), data.count - offset, 0)
                if count < 0 { if errno == EAGAIN || errno == EINTR { continue }; throw failure("发送配对信息") }
                guard count > 0 else { throw WeaveError.invalidConfiguration("配对连接已关闭。") }; offset += count
            }
        }
    }
}
