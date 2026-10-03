import Foundation
import PlacesCompanion

@MainActor enum WatchStorage {
    static let group = "group.com.adriaan.places.watch"
    static let defaults = UserDefaults(suiteName: group)!
    static var deliveryEnabled: Bool { defaults.bool(forKey: "phoneEnabled") }
    static var enabled: Bool {
        get { defaults.bool(forKey: "enabled") && deliveryEnabled }
        set { defaults.set(newValue, forKey: "enabled") }
    }
    static var frequent: Bool {
        get { defaults.object(forKey: "frequent") == nil || defaults.bool(forKey: "frequent") }
        set { defaults.set(newValue, forKey: "frequent") }
    }
    static var lastRecorded: Date? { defaults.object(forKey: "lastRecorded") as? Date }
    static var lastPhoneContact: Date? { defaults.object(forKey: "lastPhoneContact") as? Date }
    static var lastSynced: Date? { defaults.object(forKey: "lastSynced") as? Date }
    static func keys() throws -> CompanionKeychain {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "WatchKeychainGroup") as? String,
              !group.contains("$(") else { throw CompanionError.notLinked }
        return CompanionKeychain(service: "com.adriaan.places.watch", accessGroup: group)
    }
    static func link() throws -> WatchLink? {
        guard let data = try keys().read("watch-link") else { return nil }
        return try JSONDecoder().decode(WatchLink.self, from: data)
    }
    static func outbox() throws -> CompanionOutbox {
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw CompanionError.notLinked
        }
        return try CompanionIdentity.outbox(keychain: keys(), directory: directory.appendingPathComponent("Outbox"))
    }
    static func record(latitude: Double, longitude: Double, accuracy: Double, speed: Double?, date: Date) async throws {
        guard enabled, abs(date.timeIntervalSinceNow) <= 120, let link = try link() else { return }
        let sample = CompanionSample(deviceID: try CompanionIdentity.deviceID(keys: keys()), kind: .watch,
            timestamp: date, latitude: latitude, longitude: longitude, accuracy: accuracy, speed: speed)
        guard sample.isValid() else { return }
        let batch = CompanionBatch(linkID: link.id, samples: [sample]), outbox = try outbox()
        try await outbox.append(batch)
        // A reset / re-pair can happen while the file is being written, including
        // in the complication process. Finish that erase instead of reviving old data.
        guard try self.link()?.id == link.id else { try await outbox.acknowledge(batch.id); return }
        defaults.set(date, forKey: "lastRecorded")
    }
}
