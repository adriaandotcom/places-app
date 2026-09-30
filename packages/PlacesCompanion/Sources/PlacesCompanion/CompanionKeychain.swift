import Foundation
import Security

public struct CompanionKeychain: Sendable {
    private let service: String
    private let accessGroup: String?
    private let synchronizable: Bool
    public init(service: String = "com.adriaan.places.companion.local", accessGroup: String? = nil,
                synchronizable: Bool = false) {
        self.service = service; self.accessGroup = accessGroup; self.synchronizable = synchronizable
    }
    private func query(_ account: String) -> [String: Any] {
        var result: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable]
        if let accessGroup { result[kSecAttrAccessGroup as String] = accessGroup }
        #if os(macOS)
        result[kSecUseDataProtectionKeychain as String] = true
        #endif
        return result
    }
    public func read(_ account: String) throws -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw CompanionError.keychain(status) }
        return data
    }
    /// Does not replace an existing key: concurrently enabling another device cannot destroy ciphertext.
    public func createIfMissing(_ account: String, value: Data) throws -> Data {
        if let existing = try read(account) { return existing }
        var query = query(account)
        query[kSecValueData as String] = value
        query[kSecAttrAccessible as String] = synchronizable
            ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else { throw CompanionError.keychain(status) }
        guard let stored = try read(account) else { throw CompanionError.missingKey }
        return stored
    }
    public func remove(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CompanionError.keychain(status) }
    }
    public func storeState(_ account: String, value: Data) throws {
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if status == errSecItemNotFound { _ = try createIfMissing(account, value: value) }
        else if status != errSecSuccess { throw CompanionError.keychain(status) }
    }
}
