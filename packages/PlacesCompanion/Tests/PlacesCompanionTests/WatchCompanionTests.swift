import Foundation
import Testing
@testable import PlacesCompanion

@Test func watchRestsOnWiFiOrPositivePhoneAvailability() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    #expect(WatchCollectionPolicy.decision(enabled: true, wifiAvailable: true, phoneReachable: false,
        lastPhoneContact: nil, now: now) == .wifiAvailable)
    #expect(WatchCollectionPolicy.decision(enabled: true, wifiAvailable: false, phoneReachable: true,
        lastPhoneContact: nil, now: now) == .phoneAvailable)
    #expect(WatchCollectionPolicy.decision(enabled: true, wifiAvailable: nil, phoneReachable: false,
        lastPhoneContact: nil, now: now) == .checkingConnection)
    #expect(WatchCollectionPolicy.decision(enabled: false, wifiAvailable: false, phoneReachable: false,
        lastPhoneContact: nil, now: now) == .disabled)
    #expect(WatchCollectionPolicy.decision(enabled: true, wifiAvailable: false, phoneReachable: false,
        lastPhoneContact: nil, now: now) == .collect)
}

@Test func losingLiveMessagingDoesNotImmediatelyRestartWatchGPS() {
    let contact = Date(timeIntervalSince1970: 1_000_000)
    // watchOS suspending live messaging must not undo a just-confirmed handoff.
    for elapsed in [0.0, 1, 300, 599] {
        #expect(WatchCollectionPolicy.decision(enabled: true, wifiAvailable: false, phoneReachable: false,
            lastPhoneContact: contact, now: contact.addingTimeInterval(elapsed)) == .phoneAvailable)
    }
    #expect(WatchCollectionPolicy.decision(enabled: true, wifiAvailable: false, phoneReachable: false,
        lastPhoneContact: contact, now: contact.addingTimeInterval(600)) == .collect)
    #expect(WatchCollectionPolicy.decision(enabled: true, wifiAvailable: true, phoneReachable: false,
        lastPhoneContact: contact, now: contact.addingTimeInterval(86_400)) == .wifiAvailable)
    // A clock correction cannot leave collection permanently paused.
    #expect(WatchCollectionPolicy.decision(enabled: true, wifiAvailable: false, phoneReachable: false,
        lastPhoneContact: contact, now: contact.addingTimeInterval(-60)) == .collect)
}

private func watchBatches(_ count: Int, link: WatchLink) -> [CompanionBatch] {
    let device = UUID()
    return (0..<count).map { index in
        CompanionBatch(linkID: link.id, samples: [CompanionSample(deviceID: device, kind: .watch,
            timestamp: Date(timeIntervalSince1970: 1_000_000 + Double(index)),
            latitude: 12, longitude: 34, accuracy: 30, timezone: "GMT")])
    }
}
private enum WatchTestFailure: Error { case diskFull }

@MainActor @Test func watchOutboxDrainsAll77FilesAndLostReceiptsCanBeRetried() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = CompanionCipher.newKey(), link = WatchLink(), batches = watchBatches(77, link: link)
    let outbox = try CompanionOutbox(directory: directory, localKey: key)
    for batch in batches { try await outbox.append(batch) }
    var saved = Set<UUID>(), writes = 0
    let first = try WatchDelivery.payloads(from: await outbox.pending(), link: link)
    #expect(first.count == 32)
    // Simulate a durable phone write followed by a lost connection before its receipt arrives.
    _ = try await WatchDelivery.receive(first, link: link, isEnabled: { true }) { batch in
        saved.formUnion(batch.samples.map(\.id)); writes += 1
    }
    let reopened = try CompanionOutbox(directory: directory, localKey: key)
    #expect(try await reopened.pending().count == 77)
    while !(try await reopened.pending()).isEmpty {
        let pending = try await reopened.pending()
        let payloads = try WatchDelivery.payloads(from: pending, link: link)
        #expect(payloads.reduce(0, { $0 + $1.count }) <= WatchDelivery.maximumBytes)
        let receipt = try await WatchDelivery.receive(payloads, link: link, isEnabled: { true }) { batch in
            saved.formUnion(batch.samples.map(\.id)); writes += 1
        }
        #expect(receipt.batchIDs == pending.prefix(payloads.count).map(\.id))
        try await WatchDelivery.acknowledge(receipt, linkID: link.id, outbox: reopened)
    }
    #expect(saved == Set(batches.flatMap(\.samples).map(\.id)))
    #expect(writes == 4, "One retry plus three bounded writes, rather than 77 separate imports")
}

@MainActor @Test func failedOrRevokedWatchImportNeverProducesAReceipt() async throws {
    let link = WatchLink(), batches = watchBatches(3, link: link)
    let payloads = try WatchDelivery.payloads(from: batches, link: link)
    var enabled = true, writes = 0
    await #expect(throws: WatchTestFailure.diskFull) {
        try await WatchDelivery.receive(payloads, link: link, isEnabled: { enabled }) { _ in
            writes += 1; throw WatchTestFailure.diskFull
        }
    }
    await #expect(throws: CompanionError.disabled) {
        try await WatchDelivery.receive(payloads, link: link, isEnabled: { enabled }) { _ in
            writes += 1; enabled = false
        }
    }
    await #expect(throws: CompanionError.disabled) {
        try await WatchDelivery.receive(payloads, link: link, isEnabled: { enabled }) { _ in writes += 1 }
    }
    #expect(writes == 2)
}

@MainActor @Test func watchDeliveryRejectsForeignOrDamagedPayloadsBeforeWriting() async throws {
    let link = WatchLink(), batches = watchBatches(2, link: link)
    var payloads = try WatchDelivery.payloads(from: batches, link: link)
    var writes = 0
    payloads[1][0] ^= 1
    await #expect(throws: (any Error).self) {
        try await WatchDelivery.receive(payloads, link: link, isEnabled: { true }) { _ in writes += 1 }
    }
    let foreign = try WatchDelivery.payloads(from: batches, link: link)
    await #expect(throws: (any Error).self) {
        try await WatchDelivery.receive(foreign, link: WatchLink(), isEnabled: { true }) { _ in writes += 1 }
    }
    #expect(writes == 0)
}

@Test func foreignWatchReceiptCannotErasePendingLocations() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let link = WatchLink(), batch = watchBatches(1, link: link)[0]
    let outbox = try CompanionOutbox(directory: directory, localKey: CompanionCipher.newKey())
    try await outbox.append(batch)
    await #expect(throws: CompanionError.invalidPayload) {
        try await WatchDelivery.acknowledge(.init(linkID: UUID(), batchIDs: [batch.id]), linkID: link.id, outbox: outbox)
    }
    #expect(try await outbox.pending() == [batch])
    let receipt = WatchDelivery.Receipt(linkID: link.id, batchIDs: [batch.id])
    try await WatchDelivery.acknowledge(receipt, linkID: link.id, outbox: outbox)
    try await WatchDelivery.acknowledge(receipt, linkID: link.id, outbox: outbox)
    #expect(try await outbox.pending().isEmpty)
}

@Test func liveAndQueuedReceiptsCanAcknowledgeTheSameFilesConcurrently() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = CompanionCipher.newKey(), link = WatchLink()
    let live = try CompanionOutbox(directory: directory, localKey: key)
    let queued = try CompanionOutbox(directory: directory, localKey: key)
    for batch in watchBatches(32, link: link) {
        try await live.append(batch)
        async let first: Void = live.acknowledge(batch.id)
        async let second: Void = queued.acknowledge(batch.id)
        _ = try await (first, second)
    }
    #expect(try await live.pending().isEmpty)
}
