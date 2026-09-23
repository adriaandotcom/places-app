import Foundation
import Security
import PlacesCore

enum ProtectedStorage {
    struct Locked: Error {}
    static func open() throws -> PlacesStore {
        // isProtectedDataAvailable becomes false on an ordinary lock too. A class-C
        // Keychain item checks the first-unlock boundary without stopping locked-phone tracking.
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.adriaan.places.storage-access",
            kSecAttrAccount as String: "first-unlock", kSecReturnData as String: true]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            var item = query
            item.removeValue(forKey: kSecReturnData as String)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            item[kSecValueData as String] = Data([1])
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw Locked() }
        } else if status != errSecSuccess { throw Locked() }

        let manager = FileManager.default
        let parent = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var directory = parent.appendingPathComponent("PrivateHistory", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let store = try PlacesStore(path: directory.appendingPathComponent("history.sqlite").path)
        for file in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
        }
        return store
    }
}
