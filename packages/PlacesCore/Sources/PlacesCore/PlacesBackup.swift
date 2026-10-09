import Foundation
import CryptoKit
import GRDB
import ZIPFoundation

public enum BackupError: Error, LocalizedError {
    case invalid, newerVersion, tooLarge, cancelled
    public var errorDescription: String? {
        switch self {
        case .invalid: "This backup is incomplete, damaged, or not a Places backup. Your current data has not changed."
        case .newerVersion: "This backup needs a newer version of Places. Update the app and try again."
        case .tooLarge: "There isn’t enough free space to prepare this backup, or a file exceeds the supported size. Free some space and try again."
        case .cancelled: "The backup was cancelled. Your current data has not changed."
        }
    }
}

public struct BackupManifest: Codable, Sendable {
    public let format: String
    public let version: Int
    public let createdAt: Date
    public let counts: [String: Int]
    public let files: [File]
    public struct File: Codable, Sendable {
        public let path: String
        public let bytes: UInt64
        public let sha256: String
    }
}

public struct PreparedBackup: Sendable {
    public let manifest: BackupManifest
    let databaseURL: URL
}

/// Only generated JSON records are imported. No SQL, HTML, scripts or database
/// schema supplied by a ZIP is ever run. All work stays in a private directory.
public enum PlacesBackup {
    static let maxFiles = 250_000
    static let maxBytes: UInt64 = 64 * 1024 * 1024 * 1024
    static let maxLine = 4 * 1024 * 1024

    public static func createWorkspace(in parent: URL) throws -> URL {
        let root = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try BackupIO.directory(root)
        return root.resolvingSymlinksInPath()
    }

    public static func prepare(zip url: URL, in workspace: URL) throws -> PreparedBackup {
        let root = workspace.appendingPathComponent("import", isDirectory: true)
        try BackupIO.directory(root)
        let databaseURL = workspace.appendingPathComponent("restored.sqlite")
        do {
            let archive = try Archive(url: url, accessMode: .read)
            var entries: [String: Entry] = [:]
            var seen: Set<String> = []; var total: UInt64 = 0
            for entry in archive {
                guard entries.count < maxFiles, entry.type == .file, safePath(entry.path),
                      seen.insert(entry.path.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw BackupError.invalid }
                guard entry.uncompressedSize <= maxBytes - total else { throw BackupError.tooLarge }
                total += entry.uncompressedSize; entries[entry.path] = entry
            }
            guard let manifestEntry = entries["manifest.json"], manifestEntry.uncompressedSize <= 32 * 1024 * 1024 else { throw BackupError.invalid }
            var manifestData = Data()
            let manifestCRC = try archive.extract(manifestEntry) { chunk in
                guard manifestData.count + chunk.count <= 32 * 1024 * 1024 else { throw BackupError.tooLarge }
                manifestData.append(chunk)
            }
            guard manifestCRC == manifestEntry.checksum, manifestData.count == manifestEntry.uncompressedSize else { throw BackupError.invalid }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(BackupManifest.self, from: manifestData)
            guard manifest.format == "PlacesBackup" else { throw BackupError.invalid }
            guard (1...2).contains(manifest.version) else { throw BackupError.newerVersion }
            let tables = manifest.version == 1 ? BackupTable.all.filter { $0.name != "traccarPoints" } : BackupTable.all
            let paths = Set(manifest.files.map(\.path))
            guard paths.count == manifest.files.count, !paths.contains("manifest.json"),
                  paths == Set(entries.keys).subtracting(["manifest.json"]),
                  Set(tables.map(\.path)).isSubset(of: paths),
                  Set(manifest.counts.keys) == Set(tables.map(\.name)),
                  manifest.counts.values.allSatisfy({ $0 >= 0 }) else { throw BackupError.invalid }
            // Extraction plus the staged database and the live rollback journal.
            // Fail before writing if there is not enough room for the complete restore.
            let available = try workspace.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
            if let available, UInt64(max(0, available)) < total * 3 + 32 * 1024 * 1024 { throw BackupError.tooLarge }
            for file in manifest.files {
                try Task.checkCancellation()
                guard let entry = entries[file.path], file.bytes == entry.uncompressedSize,
                      file.sha256.count == 64 else { throw BackupError.invalid }
                let destination = root.appendingPathComponent(file.path)
                try BackupIO.directory(destination.deletingLastPathComponent())
                let output = try BackupIO.writer(destination)
                defer { try? output.close() }
                var bytes: UInt64 = 0; var hash = SHA256()
                let crc = try archive.extract(entry) { chunk in
                    try Task.checkCancellation()
                    guard UInt64(chunk.count) <= file.bytes - bytes else { throw BackupError.invalid }
                    bytes += UInt64(chunk.count); hash.update(data: chunk)
                    try output.write(contentsOf: chunk)
                }
                guard crc == entry.checksum, bytes == file.bytes, BackupIO.hex(hash.finalize()) == file.sha256 else { throw BackupError.invalid }
            }
            let destination = try PlacesStore(path: databaseURL.path)
            try destination.queue.write { db in
                for table in tables {
                    var count = 0
                    try BackupIO.lines(root.appendingPathComponent(table.path)) { line in
                        try table.restore(line, root: root, files: paths, db: db); count += 1
                    }
                    guard count == manifest.counts[table.name] else { throw BackupError.invalid }
                }
                try BackupTable.validateRelationships(db)
                try db.execute(sql: "INSERT INTO placeSearch(placeID, name, address) SELECT id, name, address FROM places")
            }
            try destination.queue.close()
            return PreparedBackup(manifest: manifest, databaseURL: databaseURL)
        } catch {
            try? FileManager.default.removeItem(at: root)
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: databaseURL.path + suffix) }
            if error is CancellationError { throw BackupError.cancelled }
            if let error = error as? BackupError { throw error }
            if let error = error as? CocoaError, error.code == .fileWriteOutOfSpace { throw BackupError.tooLarge }
            throw BackupError.invalid
        }
    }

    static func safePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 240,
              path.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./").contains($0) }) else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func package(snapshot: URL, workspace: URL) throws -> URL {
        let root = workspace.appendingPathComponent("contents", isDirectory: true).resolvingSymlinksInPath()
        try BackupIO.directory(root.appendingPathComponent("data", isDirectory: true))
        try BackupIO.directory(root.appendingPathComponent("photos", isDirectory: true))
        var configuration = Configuration(); configuration.readonly = true
        let source = try DatabaseQueue(path: snapshot.path, configuration: configuration)
        defer { try? source.close() }
        var counts: [String: Int] = [:]
        try source.read { db in
            try BackupTable.checkSchema(db)
            for table in BackupTable.all {
                let output = try BackupIO.writer(root.appendingPathComponent(table.path))
                defer { try? output.close() }
                var count = 0
                let cursor = try Row.fetchCursor(db, sql: table.select)
                while let row = try cursor.next() {
                    try Task.checkCancellation()
                    let data = try autoreleasepool { try table.export(row) { try BackupIO.media($0, root: root) } }
                    guard data.count <= maxLine else { throw BackupError.tooLarge }
                    try output.write(contentsOf: data); try output.write(contentsOf: Data([10])); count += 1
                }
                counts[table.name] = count
            }
            try BackupReadable.write(db: db, root: root, counts: counts)
        }
        var files: [BackupManifest.File] = []
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { throw BackupError.invalid }
        for case let path as String in enumerator {
            let file = root.appendingPathComponent(path)
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let (bytes, hash) = try BackupIO.digest(file)
            files.append(.init(path: path, bytes: bytes, sha256: hash))
        }
        guard files.count < maxFiles, files.reduce(UInt64(0), { $0 + $1.bytes }) <= maxBytes else { throw BackupError.tooLarge }
        let manifest = BackupManifest(format: "PlacesBackup", version: 2, createdAt: Date(), counts: counts, files: files.sorted { $0.path < $1.path })
        let manifestData = try StoreSQL.exportEncoder.encode(manifest)
        guard manifestData.count <= 32 * 1024 * 1024 else { throw BackupError.tooLarge }
        try manifestData.write(to: root.appendingPathComponent("manifest.json"))
        let zip = workspace.appendingPathComponent("Places-backup.zip")
        do {
            let archive = try Archive(url: zip, accessMode: .create)
            for path in manifest.files.map(\.path) + ["manifest.json"] {
                try Task.checkCancellation()
                try archive.addEntry(with: path, relativeTo: root, compressionMethod: path.hasSuffix(".jpg") ? .none : .deflate)
            }
        } catch { try? FileManager.default.removeItem(at: zip); throw error }
        return zip
    }
}

extension PlacesStore {
    /// Take one consistent SQLite snapshot, then release the live actor while
    /// encoding/compressing it. New observations can continue to be stored.
    public func makeBackup(in workspace: URL) async throws -> URL {
        let url = workspace.appendingPathComponent("snapshot.sqlite")
        let snapshot = try DatabaseQueue(path: url.path)
        try queue.backup(to: snapshot)
        try snapshot.close()
        let task = Task.detached(priority: .userInitiated) {
            defer { try? FileManager.default.removeItem(at: url) }
            return try PlacesBackup.package(snapshot: url, workspace: workspace)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// The preview has already decoded and checked every row in a fresh store.
    /// Copying only known tables in one transaction makes replacement atomic.
    public func restoreBackup(_ backup: PreparedBackup) throws {
        guard FileManager.default.fileExists(atPath: backup.databaseURL.path) else { throw BackupError.invalid }
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "ATTACH DATABASE ? AS restored", arguments: [backup.databaseURL.path])
            defer { try? db.execute(sql: "DETACH DATABASE restored") }
            try db.inTransaction {
                try Task.checkCancellation()
                try db.execute(sql: "DELETE FROM placeSearch")
                for table in BackupTable.all.reversed() { try db.execute(sql: "DELETE FROM \(table.name)") }
                for table in BackupTable.all {
                    try Task.checkCancellation()
                    let columns = table.columns.joined(separator: ",")
                    try db.execute(sql: "INSERT INTO \(table.name)(\(columns)) SELECT \(columns) FROM restored.\(table.name)")
                    guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table.name)") == (backup.manifest.counts[table.name] ?? 0) else { throw BackupError.invalid }
                }
                try BackupTable.validateRelationships(db)
                try db.execute(sql: "INSERT INTO placeSearch(placeID, name, address) SELECT id, name, address FROM places")
                // A portable backup never grants permissions or resumes sensors,
                // network services or library scanning on another device.
                for key in ["traccarEnabled", "traccarPaused", "trackingEnabled", "mapsEnabled", "mapsChoiceMade", "placeLookupEnabled", "placeLookupExplained",
                            "photoEvidenceEnabled", "monthlyRewindReminders", "weeklyReviewReminders"] {
                    try db.execute(sql: "INSERT OR REPLACE INTO settings(key, value) VALUES (?, 'false')", arguments: [key])
                }
                try db.execute(sql: "INSERT OR REPLACE INTO settings(key, value) VALUES ('mapProvider', 'off'), ('onboardingComplete', 'true')")
                try db.execute(sql: "DELETE FROM settings WHERE key IN ('photoEvidenceCursor', 'photoEvidenceLastScan')")
                return .commit
            }
        }
    }
}

enum BackupIO {
    static func directory(_ url: URL) throws {
        #if os(iOS)
        let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
        let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #endif
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: attributes)
        var url = url; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
    static func writer(_ url: URL) throws -> FileHandle {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        return try FileHandle(forWritingTo: url)
    }
    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
    static func digest(_ url: URL) throws -> (UInt64, String) {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256(); var count: UInt64 = 0
        while let data = try file.read(upToCount: 256 * 1024), !data.isEmpty {
            try Task.checkCancellation(); hash.update(data: data); count += UInt64(data.count)
        }
        return (count, hex(hash.finalize()))
    }
    static func media(_ data: Data, root: URL) throws -> String {
        let path = "photos/\(hex(SHA256.hash(data: data))).jpg"
        let url = root.appendingPathComponent(path)
        if !FileManager.default.fileExists(atPath: url.path) { try data.write(to: url) }
        return path
    }
    static func lines(_ url: URL, consume: (Data) throws -> Void) throws {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var buffer = Data()
        while let chunk = try file.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try Task.checkCancellation(); buffer.append(chunk)
            while let end = buffer.firstIndex(of: 10) {
                guard end - buffer.startIndex <= PlacesBackup.maxLine else { throw BackupError.tooLarge }
                let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
                guard !line.isEmpty else { throw BackupError.invalid }
                try autoreleasepool { try consume(line) }
            }
            guard buffer.count <= PlacesBackup.maxLine else { throw BackupError.tooLarge }
        }
        guard buffer.isEmpty else { throw BackupError.invalid }
    }
}
