import Foundation

/// A small live transfer can drain many one-fix files with one durable phone write.
/// Original batch IDs survive retries and are acknowledged only after that write.
public enum WatchDelivery {
    public static let maximumBatches = 32
    public static let maximumBytes = 48_000

    public struct Receipt: Codable, Equatable, Sendable {
        public let linkID: UUID
        public let batchIDs: [UUID]

        public init(linkID: UUID, batchIDs: [UUID]) {
            self.linkID = linkID; self.batchIDs = batchIDs
        }
    }

    public static func payloads(from batches: [CompanionBatch], link: WatchLink) throws -> [Data] {
        var payloads: [Data] = [], bytes = 0, samples = 0
        for batch in batches where batch.linkID == link.id {
            let data = try CompanionCipher.seal(batch, key: link.key)
            guard payloads.count < maximumBatches, bytes + data.count <= maximumBytes,
                  samples + batch.samples.count <= 64 else { break }
            payloads.append(data); bytes += data.count; samples += batch.samples.count
        }
        return payloads
    }

    @MainActor public static func receive(_ payloads: [Data], link: WatchLink,
                                         isEnabled: () -> Bool,
                                         persist: (CompanionBatch) async throws -> Void) async throws -> Receipt {
        guard isEnabled() else { throw CompanionError.disabled }
        guard !payloads.isEmpty, payloads.count <= maximumBatches,
              payloads.reduce(0, { $0 + $1.count }) <= maximumBytes else { throw CompanionError.invalidPayload }
        let batches = try payloads.map { payload in
            let batch = try CompanionCipher.open(CompanionBatch.self, data: payload, key: link.key)
            try batch.validate(linkID: link.id, kind: .watch)
            return batch
        }
        guard Set(batches.map(\.id)).count == batches.count else { throw CompanionError.invalidPayload }
        let combined = CompanionBatch(linkID: link.id, samples: batches.flatMap(\.samples))
        try combined.validate(linkID: link.id, kind: .watch)
        try await persist(combined)
        guard isEnabled() else { throw CompanionError.disabled }
        return Receipt(linkID: link.id, batchIDs: batches.map(\.id))
    }

    public static func acknowledge(_ receipt: Receipt, linkID: UUID, outbox: CompanionOutbox) async throws {
        guard receipt.linkID == linkID, !receipt.batchIDs.isEmpty,
              receipt.batchIDs.count <= maximumBatches else { throw CompanionError.invalidPayload }
        for id in receipt.batchIDs { try await outbox.acknowledge(id) }
    }
}
