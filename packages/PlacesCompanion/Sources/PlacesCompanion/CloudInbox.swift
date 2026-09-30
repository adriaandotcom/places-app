#if !os(watchOS)
import CloudKit
import CryptoKit
import Foundation

public struct CompanionLink: Codable, Equatable, Sendable {
    public let version: Int
    public let id: UUID
    public let receiverID: UUID
    public var enabled: Bool
    public init(receiverID: UUID) {
        version = 1; id = UUID(); self.receiverID = receiverID; enabled = true
    }
}

/// A private, encrypted delivery inbox, not a copy of the user's history database.
/// Construct only after an explicit iCloud companion opt-in.
public actor CloudInbox {
    public static let containerID = "iCloud.com.adriaan.places"
    private let container: CKContainer
    private let keys: CompanionKeychain
    private let zoneID = CKRecordZone.ID(zoneName: "CompanionInbox-v1", ownerName: CKCurrentUserDefaultName)

    public init(consented: Bool, keychainGroup: String) throws {
        guard consented else { throw CompanionError.disabled }
        container = CKContainer(identifier: Self.containerID)
        keys = CompanionKeychain(service: "com.adriaan.places.companion.cloud",
                                 accessGroup: keychainGroup, synchronizable: true)
    }
    private var database: CKDatabase { container.privateCloudDatabase }
    private var configID: CKRecord.ID { CKRecord.ID(recordName: "receiver", zoneID: zoneID) }
    private func account() async throws -> String {
        guard try await container.accountStatus() == .available else { throw CompanionError.wrongAccount }
        let record = try await container.userRecordID()
        return SHA256.hash(data: Data(record.recordName.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func context() async throws -> (String, Data) {
        let account = try await account()
        let record = try await database.record(for: configID)
        guard let keyID = record["keyID"] as? String, UUID(uuidString: keyID) != nil,
              let key = try keys.read(account + ":" + keyID), key.count == 32 else {
            throw CompanionError.missingKey
        }
        return (account, key)
    }
    private func checkAccount(_ expected: String) async throws {
        guard try await account() == expected else { throw CompanionError.wrongAccount }
    }
    public func enableReceiver(_ receiverID: UUID) async throws -> CompanionLink {
        let account = try await account()
        _ = try await database.save(CKRecordZone(zoneID: zoneID))
        var record: CKRecord
        do { record = try await database.record(for: configID) }
        catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: "PlacesCompanion", recordID: configID)
        }
        var link: CompanionLink
        let key: Data
        if record.recordChangeTag != nil {
            guard let keyID = record["keyID"] as? String,
                  let existing = try keys.read(account + ":" + keyID) else { throw CompanionError.missingKey }
            key = existing
            link = try decodeLink(record, key: key)
            guard link.receiverID == receiverID else { throw CompanionError.notLinked }
            link.enabled = true
        } else {
            // Each configuration owns a unique key. Concurrent device setup cannot overwrite
            // another receiver's synchronized key; CloudKit detects configuration conflicts.
            let keyID = UUID().uuidString
            key = try keys.createIfMissing(account + ":" + keyID, value: CompanionCipher.newKey())
            record["keyID"] = keyID as CKRecordValue
            link = CompanionLink(receiverID: receiverID)
        }
        try await checkAccount(account)
        record["payload"] = try CompanionCipher.seal(link, key: key) as CKRecordValue
        _ = try await database.save(record)
        let subscription = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: "companion-delivery")
        let info = CKSubscription.NotificationInfo(); info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        _ = try await database.save(subscription)
        return link
    }
    public func link() async throws -> CompanionLink {
        let (account, key) = try await context()
        let link = try decodeLink(try await database.record(for: configID), key: key)
        try await checkAccount(account)
        guard link.enabled else { throw CompanionError.disabled }
        return link
    }
    public func setReceiverEnabled(_ enabled: Bool, receiverID: UUID) async throws {
        let (account, key) = try await context()
        let record = try await database.record(for: configID)
        var link = try decodeLink(record, key: key)
        guard link.receiverID == receiverID else { throw CompanionError.notLinked }
        link.enabled = enabled
        try await checkAccount(account)
        record["payload"] = try CompanionCipher.seal(link, key: key) as CKRecordValue
        _ = try await database.save(record)
    }
    public func upload(_ batch: CompanionBatch) async throws {
        let (account, key) = try await context()
        let link = try decodeLink(try await database.record(for: configID), key: key)
        guard link.enabled else { throw CompanionError.disabled }
        try batch.validate(linkID: link.id, kind: .mac)
        let id = CKRecord.ID(recordName: batch.id.uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: "PlacesCompanion", recordID: id)
        record["payload"] = try CompanionCipher.seal(batch, key: key) as CKRecordValue
        try await checkAccount(account)
        let results = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
        _ = try results.saveResults[id]?.get()
        guard results.saveResults[id] != nil else { throw CompanionError.invalidPayload }
    }
    public func pending(receiverID: UUID) async throws -> [CompanionBatch] {
        let (account, key) = try await context()
        let link = try decodeLink(try await database.record(for: configID), key: key)
        guard link.enabled, link.receiverID == receiverID else { throw CompanionError.notLinked }
        var token: CKServerChangeToken?
        var pending: [UUID: CompanionBatch] = [:]
        repeat {
            let page = try await database.recordZoneChanges(inZoneWith: zoneID, since: token, resultsLimit: 100)
            for (id, modification) in page.modificationResultsByID where id != configID {
                let record = try modification.get().record
                guard let payload = record["payload"] as? Data else { throw CompanionError.invalidPayload }
                let batch = try CompanionCipher.open(CompanionBatch.self, data: payload, key: key)
                guard batch.id.uuidString == id.recordName else { throw CompanionError.invalidPayload }
                try batch.validate(linkID: link.id, kind: .mac)
                pending[batch.id] = batch
            }
            for deletion in page.deletions {
                if let id = UUID(uuidString: deletion.recordID.recordName) { pending[id] = nil }
            }
            token = page.changeToken
            if !page.moreComing { break }
        } while true
        try await checkAccount(account)
        return pending.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    /// Call only after the iPhone's database transaction commits successfully.
    public func acknowledge(_ batch: CompanionBatch, receiverID: UUID) async throws {
        let link = try await link()
        guard link.receiverID == receiverID, link.id == batch.linkID else { throw CompanionError.notLinked }
        do { _ = try await database.deleteRecord(withID: CKRecord.ID(recordName: batch.id.uuidString, zoneID: zoneID)) }
        catch let error as CKError where error.code == .unknownItem { /* Already acknowledged. */ }
    }
    public func erase(receiverID: UUID) async throws {
        let account = try await account()
        let record: CKRecord
        do {
            record = try await database.record(for: configID)
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem { return }
        guard let keyID = record["keyID"] as? String, let key = try keys.read(account + ":" + keyID) else {
            throw CompanionError.missingKey
        }
        guard try decodeLink(record, key: key).receiverID == receiverID else { throw CompanionError.notLinked }
        _ = try await database.deleteRecordZone(withID: zoneID)
        try await checkAccount(account)
        try keys.remove(account + ":" + keyID)
    }
    private func decodeLink(_ record: CKRecord, key: Data) throws -> CompanionLink {
        guard let data = record["payload"] as? Data else { throw CompanionError.invalidPayload }
        let link = try CompanionCipher.open(CompanionLink.self, data: data, key: key)
        guard link.version == 1 else { throw CompanionError.unsupportedVersion }
        return link
    }
}
#endif
