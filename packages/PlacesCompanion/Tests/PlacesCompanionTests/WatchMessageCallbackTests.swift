import Dispatch
import Foundation
import Testing
@testable import PlacesCompanion

@MainActor @Test func watchHintsAcceptBackgroundRepliesAndErrors() async {
    // Match WCSession's Objective-C callback queue, not the caller's main actor.
    let callbacks = WatchMessageCallbacks.ignored
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            dispatchPrecondition(condition: .notOnQueue(.main))
            callbacks.reply([:])
            callbacks.error(NSError(domain: "WCErrorDomain", code: 7007))
            continuation.resume()
        }
    }
}

@MainActor @Test func watchReceiptResumesOnBackgroundSuccess() async throws {
    let expected = WatchDelivery.Receipt(linkID: UUID(), batchIDs: [UUID()])
    let data = try JSONEncoder().encode(expected)
    let received = await withCheckedContinuation { continuation in
        let callbacks = WatchMessageCallbacks { continuation.resume(returning: $0) }
        DispatchQueue.global().async {
            dispatchPrecondition(condition: .notOnQueue(.main))
            callbacks.reply(["receipt": data])
        }
    }
    #expect(received == expected)
}

@MainActor @Test func failedOrInvalidWatchRepliesNeverAcknowledgeData() async {
    // A disconnected Watch, an old peer without receipts, and damaged replies
    // must all finish the live attempt without acknowledging the queued data.
    for response in 0..<4 {
        let received = await withCheckedContinuation { continuation in
            let callbacks = WatchMessageCallbacks { continuation.resume(returning: $0) }
            DispatchQueue.global().async {
                dispatchPrecondition(condition: .notOnQueue(.main))
                switch response {
                case 0: callbacks.error(NSError(domain: "WCErrorDomain", code: 7007))
                case 1: callbacks.reply([:])
                case 2: callbacks.reply(["receipt": "invalid"])
                default: callbacks.reply(["receipt": Data("invalid".utf8)])
                }
            }
        }
        #expect(received == nil)
    }
}

@MainActor @Test func liveWatchDeliveryTimesOutWithoutLosingQueuedData() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let link = WatchLink()
    let batch = CompanionBatch(linkID: link.id, samples: [CompanionSample(deviceID: UUID(), kind: .watch,
        timestamp: Date(), latitude: 1, longitude: 1, accuracy: 10)])
    let outbox = try CompanionOutbox(directory: directory, localKey: CompanionCipher.newKey())
    try await outbox.append(batch)
    var lateCallbacks: WatchMessageCallbacks?
    let result = await WatchMessageCallbacks.receive(timeout: .milliseconds(20)) { lateCallbacks = $0 }
    #expect(result == nil)
    let receipt = WatchDelivery.Receipt(linkID: link.id, batchIDs: [batch.id])
    let data = try JSONEncoder().encode(receipt)
    let callbacks = try #require(lateCallbacks)
    await Task.detached {
        callbacks.reply(["receipt": data])
        callbacks.error(NSError(domain: "WCErrorDomain", code: 7007))
    }.value
    #expect(try await outbox.pending() == [batch])
    // The next opportunity retries the same durable batch and can acknowledge it.
    let retry = await WatchMessageCallbacks.receive { callbacks in
        DispatchQueue.global().async { callbacks.reply(["receipt": data]) }
    }
    try await WatchDelivery.acknowledge(#require(retry), linkID: link.id, outbox: outbox)
    #expect(try await outbox.pending().isEmpty)
}

@MainActor @Test func cancelledWatchDeliveryDoesNotWaitForAReply() async {
    let (started, signal) = AsyncStream<WatchMessageCallbacks>.makeStream()
    let work = Task {
        await WatchMessageCallbacks.receive(timeout: .seconds(60)) { signal.yield($0); signal.finish() }
    }
    var iterator = started.makeAsyncIterator()
    let callbacks = await iterator.next()
    work.cancel()
    let result = await work.value
    #expect(result == nil)
    await Task.detached { callbacks?.reply([:]) }.value
}
