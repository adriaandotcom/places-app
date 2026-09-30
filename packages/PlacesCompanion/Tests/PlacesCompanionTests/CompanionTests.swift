import Foundation
import Testing
@testable import PlacesCompanion

private func sample() -> CompanionSample {
    CompanionSample(deviceID: UUID(), kind: .mac, timestamp: Date(timeIntervalSince1970: 1_000_000),
                    latitude: 12, longitude: 34, accuracy: 30, timezone: "GMT")
}

@Test func cloudCannotBeConstructedWithoutConsent() {
    #expect(throws: CompanionError.disabled) {
        try CloudInbox(consented: false, keychainGroup: "unused")
    }
}

@Test func cipherAuthenticatesAndUsesUniqueNonces() throws {
    let key = CompanionCipher.newKey(), value = sample()
    let a = try CompanionCipher.seal(value, key: key), b = try CompanionCipher.seal(value, key: key)
    #expect(a != b)
    #expect(try CompanionCipher.open(CompanionSample.self, data: a, key: key) == value)
    #expect(throws: (any Error).self) { try CompanionCipher.open(CompanionSample.self, data: a, key: CompanionCipher.newKey()) }
    var tampered = a; tampered[tampered.count - 1] ^= 1
    #expect(throws: (any Error).self) { try CompanionCipher.open(CompanionSample.self, data: tampered, key: key) }
}

@Test func batchRejectsForeignLinksKindsAndInvalidLocations() throws {
    let link = UUID(), value = sample()
    let batch = CompanionBatch(linkID: link, samples: [value])
    try batch.validate(linkID: link, kind: .mac)
    #expect(throws: CompanionError.invalidPayload) { try batch.validate(linkID: UUID(), kind: .mac) }
    #expect(throws: CompanionError.invalidPayload) { try batch.validate(linkID: link, kind: .watch) }
    #expect(throws: CompanionError.invalidPayload) {
        try CompanionBatch(linkID: link, samples: [value, value]).validate(linkID: link, kind: .mac)
    }
    var invalid = value; invalid.latitude = .nan
    #expect(!invalid.isValid())
    invalid = value; invalid.timestamp = Date().addingTimeInterval(120)
    #expect(!invalid.isValid())
}

@Test func encryptedOutboxSurvivesRestartAndRequiresAcknowledgement() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = CompanionCipher.newKey(), batch = CompanionBatch(linkID: UUID(), samples: [sample()])
    let first = try CompanionOutbox(directory: directory, localKey: key)
    try await first.append(batch); try await first.append(batch)
    let reopened = try CompanionOutbox(directory: directory, localKey: key)
    #expect(try await reopened.pending() == [batch])
    let bytes = try Data(contentsOf: directory.appendingPathComponent(batch.id.uuidString + ".sealed"))
    #expect(!String(decoding: bytes, as: UTF8.self).contains(batch.samples[0].deviceID.uuidString))
    #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    let wrongKey = try CompanionOutbox(directory: directory, localKey: CompanionCipher.newKey())
    await #expect(throws: (any Error).self) { try await wrongKey.pending() }
    #expect(try await reopened.pending() == [batch])
    try await reopened.acknowledge(UUID())
    #expect(try await reopened.pending() == [batch])
    try await reopened.acknowledge(batch.id)
    #expect(try await reopened.pending().isEmpty)
    try await reopened.append(batch)
    try await reopened.erase()
    #expect(try await reopened.pending().isEmpty)
}
