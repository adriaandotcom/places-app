import Foundation

/// WatchConnectivity's Objective-C reply block has no Sendable annotation. It is
/// explicitly asynchronous; move it to the persistence actor and invoke it once.
/// The lock protects ownership of the block, not any application state.
public final class WatchMessageReply: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (([String: Any]) -> Void)?
    public init(_ handler: @escaping ([String: Any]) -> Void) { self.handler = handler }
    public func send(receipt: Data? = nil) {
        let callback = lock.withLock {
            let value = handler; handler = nil; return value
        }
        callback?(receipt.map { ["receipt": $0] } ?? [:])
    }
}
