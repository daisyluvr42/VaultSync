import Foundation

/// Checked between files and after reads, so a removed mapping cannot continue publishing work.
public final class ScanControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public func check() throws { if isCancelled { throw CancellationError() } }
}
