import Foundation
import CryptoKit
import PlacesCore

enum MapPackFiles {
    enum Failure: Error { case invalidSize, invalidArchive, checksumMismatch, insufficientSpace }

    static func directory(testing: Bool = false) throws -> URL {
        let root = testing ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(ProcessInfo.processInfo.arguments.contains("--ui-on-device-map") ? "OfflineMapsUITests" : (ProcessInfo.processInfo.arguments.contains("--ui-background-map-downloads") ? "OfflineMapsDownloadTests" : "OfflineMapsUITests-\(ProcessInfo.processInfo.processIdentifier)"))
            : try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("OfflineMaps")
        var directory = root
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        return directory
    }

    static func validate(_ file: URL, pack: MapPack) throws {
        guard pack.isValid else { throw Failure.invalidArchive }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        guard try handle.seekToEnd() == UInt64(pack.bytes) else { throw Failure.invalidSize }
        try handle.seek(toOffset: 0)
        let header = try handle.read(upToCount: 127) ?? Data()
        guard header.count == 127, header.prefix(8) == Data([80, 77, 84, 105, 108, 101, 115, 3]),
              header[99] == 1, header[100] == UInt8(pack.minZoom), header[101] == UInt8(pack.maxZoom) else {
            throw Failure.invalidArchive
        }
        var hash = SHA256(); hash.update(data: header)
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == pack.sha256 else {
            throw Failure.checksumMismatch
        }
    }

    static func checkSpace(at directory: URL, pack: MapPack) throws {
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let available = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
        guard MapDownloadPolicy.hasSpace(available: available, packBytes: pack.bytes) else { throw Failure.insufficientSpace }
    }

    // Called only after validation, on the manager's serial actor. The final
    // filename never points at a partial transfer and rename is on one volume.
    static func installValidated(_ temporary: URL, pack: MapPack, directory: URL) throws -> URL {
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: temporary.path)
        let destination = directory.appendingPathComponent(pack.filename)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else { try FileManager.default.moveItem(at: temporary, to: destination) }
        return destination
    }
}
