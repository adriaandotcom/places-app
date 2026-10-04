import Foundation

/// WatchConnectivity invokes replies and errors on its own background queue.
/// Explicit Sendable types prevent closures created by a MainActor caller from
/// inheriting that actor, which would trap before the callback body even runs.
public struct WatchMessageCallbacks: Sendable {
    public let reply: @Sendable ([String: Any]) -> Void
    public let error: @Sendable (any Error) -> Void

    /// Live hints also have a persisted delivery path, so failure needs no action.
    public static let ignored = WatchMessageCallbacks { _ in }

    public init(receivedReceipt: @escaping @Sendable (WatchDelivery.Receipt?) -> Void) {
        reply = { response in
            let receipt = (response["receipt"] as? Data).flatMap {
                try? JSONDecoder().decode(WatchDelivery.Receipt.self, from: $0)
            }
            receivedReceipt(receipt)
        }
        error = { _ in receivedReceipt(nil) }
    }

    /// WCSession's reply timeout can exceed a Watch background task's allowance.
    /// Finish our wait early; a late reply cannot resume a continuation twice or
    /// acknowledge data that the caller has already left queued for retry.
    @MainActor public static func receive(timeout: Duration = .seconds(5),
                                         send: (WatchMessageCallbacks) -> Void) async -> WatchDelivery.Receipt? {
        guard !Task.isCancelled else { return nil }
        let (responses, continuation) = AsyncStream<WatchDelivery.Receipt?>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let callbacks = WatchMessageCallbacks {
            continuation.yield($0)
            continuation.finish()
        }
        let deadline = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            continuation.finish()
        }
        defer { deadline.cancel(); continuation.finish() }
        send(callbacks)
        var iterator = responses.makeAsyncIterator()
        return await iterator.next() ?? nil
    }
}
