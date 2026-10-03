import Foundation

/// One encrypted file per immutable batch. Only the receiver's durable acknowledgement removes it.
/// Small atomic files avoid making watchOS depend on the iPhone database or its map catalog.
public actor CompanionOutbox {
    private let directory: URL
    private let localKey: Data
    public init(directory: URL, localKey: Data) throws {
        guard localKey.count == 32 else { throw CompanionError.missingKey }
        self.directory = directory; self.localKey = localKey
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var url = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
    public func append(_ batch: CompanionBatch) throws {
        let file = directory.appendingPathComponent(batch.id.uuidString).appendingPathExtension("sealed")
        if FileManager.default.fileExists(atPath: file.path) {
            let existing = try CompanionCipher.open(CompanionBatch.self, data: Data(contentsOf: file), key: localKey)
            guard existing == batch else { throw CompanionError.invalidPayload }
            return
        }
        let data = try CompanionCipher.seal(batch, key: localKey)
        #if os(iOS) || os(watchOS)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: file, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    public func pending() throws -> [CompanionBatch] {
        try files().map { try CompanionCipher.open(CompanionBatch.self, data: Data(contentsOf: $0), key: localKey) }
            .sorted { ($0.samples.first?.timestamp ?? .distantPast, $0.id.uuidString)
                < ($1.samples.first?.timestamp ?? .distantPast, $1.id.uuidString) }
    }
    public func acknowledge(_ id: UUID) throws {
        let file = directory.appendingPathComponent(id.uuidString).appendingPathExtension("sealed")
        // A live receipt and a previously queued receipt can arrive together, even
        // through separate actor instances. Unlink atomically; a missing file is success.
        do { try FileManager.default.removeItem(at: file) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { }
    }
    public func erase() throws { for file in try files() { try FileManager.default.removeItem(at: file) } }
    private func files() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "sealed" }
    }
}
