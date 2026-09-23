import Foundation
import PlacesCore

enum ProtectedStorage {
    struct Locked: Error {}
    static func open() throws -> PlacesStore {
        let manager = FileManager.default
        let parent = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var directory = parent.appendingPathComponent("PrivateHistory", isDirectory: true)
        // Class C is also iOS's default for newly created app files, including
        // SQLite sidecars. Keep it explicit here without overriding it through
        // a Data Protection entitlement that automatic profiles set to class A.
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        // Probe the same file-protection class as the database before opening it.
        // Unlike isProtectedDataAvailable, this stays readable on ordinary locks
        // after first unlock. It also works in unsigned Simulator development builds.
        let probe = directory.appendingPathComponent("storage-access")
        do {
            if !manager.fileExists(atPath: probe.path) {
                try Data([1]).write(to: probe, options: .completeFileProtectionUntilFirstUserAuthentication)
            }
            _ = try Data(contentsOf: probe)
        } catch let error as CocoaError where [.fileReadNoPermission, .fileWriteNoPermission].contains(error.code) {
            throw Locked()
        }
        let store = try PlacesStore(path: directory.appendingPathComponent("history.sqlite").path)
        for file in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
        }
        return store
    }
}
