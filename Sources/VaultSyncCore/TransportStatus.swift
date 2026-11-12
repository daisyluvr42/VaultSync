import Foundation

public struct TransportStatus: Sendable, Decodable, Equatable {
    public let state: String
    public let globalFiles: Int
    public let globalBytes: Int64
    public let needBytes: Int64
    public let needFiles: Int
    public let errors: Int
    public let pullErrors: Int
    public var isReceiving: Bool { needBytes > 0 || needFiles > 0 }
    public var fractionReceived: Double {
        guard globalBytes > 0 else { return isReceiving ? 0 : 1 }
        return min(1, max(0, 1 - Double(needBytes) / Double(globalBytes)))
    }
}
