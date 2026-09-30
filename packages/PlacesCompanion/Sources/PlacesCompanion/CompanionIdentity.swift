import Foundation

public enum CompanionIdentity {
    public static func deviceID(keys: CompanionKeychain = CompanionKeychain()) throws -> UUID {
        let bytes = try keys.createIfMissing("device-id", value: Data(UUID().uuidString.utf8))
        guard let id = UUID(uuidString: String(decoding: bytes, as: UTF8.self)) else { throw CompanionError.invalidPayload }
        return id
    }
    public static func outbox(keychain: CompanionKeychain = CompanionKeychain(), directory: URL? = nil) throws -> CompanionOutbox {
        let root = try directory ?? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("CompanionOutbox")
        let existing = try keychain.read("outbox-key")
        // Never silently generate a replacement key over unreadable pending observations.
        if existing == nil, FileManager.default.fileExists(atPath: root.path),
           try FileManager.default.contentsOfDirectory(atPath: root.path).contains(where: { $0.hasSuffix(".sealed") }) {
            throw CompanionError.missingKey
        }
        let key = try existing ?? keychain.createIfMissing("outbox-key", value: CompanionCipher.newKey())
        return try CompanionOutbox(directory: root, localKey: key)
    }
    public static func message(for error: any Error) -> String {
        switch error as? CompanionError {
        case .missingKey: "Waiting for the encryption key. Enable companions on your iPhone and turn on iCloud Keychain on both devices."
        case .wrongAccount: "Sign in to the same iCloud account on your iPhone and Mac."
        case .notLinked: "Open Places on your iPhone to connect this companion."
        case .disabled: "Companion collection is paused on your iPhone."
        default: "Could not finish syncing. Your queued observations are kept on this device. Try again when connected."
        }
    }
}

public struct WatchLink: Codable, Equatable, Sendable {
    public let id: UUID
    public let key: Data
    public init(id: UUID = UUID(), key: Data = CompanionCipher.newKey()) { self.id = id; self.key = key }
}
