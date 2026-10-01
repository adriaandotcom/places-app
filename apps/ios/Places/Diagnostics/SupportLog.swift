import Foundation
import CryptoKit

/// Independent of the history database so a storage failure can still be exported.
/// All disk work is serialized off the main actor. Nothing in this store is uploaded.
actor SupportLog {
    private struct Archive: Codable {
        var snapshot = SupportSnapshot()
        var seen: [String] = []
        var clearedAt = Date.distantPast
    }
    private let file: URL?
    private var archive = Archive()
    private var loaded = false
    private var storageAvailable = true

    init(directory: URL?) { file = directory?.appendingPathComponent("support.json") }

    static func directory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("LocalDiagnostics", isDirectory: true)
    }

    func record(_ value: SupportBreadcrumb, receivedAt: Date = Date()) {
        guard load(), receivedAt >= archive.clearedAt else { return }
        if let last = archive.snapshot.breadcrumbs.last,
           last.event == value.event, last.build == value.build, last.line == value.line,
           last.errorKind == value.errorKind, last.errorCode == value.errorCode {
            archive.snapshot.breadcrumbs[archive.snapshot.breadcrumbs.count - 1].repetitions = min(last.repetitions + 1, 1_000_000)
        } else { archive.snapshot.breadcrumbs.append(value) }
        archive.snapshot.breadcrumbs = Array(archive.snapshot.breadcrumbs.suffix(200))
        save()
    }

    func receive(incidents: [SupportIncident] = [], exits: [SupportExits] = [], begin: Date, end: Date) {
        guard load(), begin >= archive.clearedAt else { return }
        // The dates and digest are local deduplication bookkeeping, never exported.
        // Hash only the allowlisted content, not the original MetricKit payload.
        struct Delivery: Encodable { let incidents: [SupportIncident]; let exits: [SupportExits]; let begin: Date; let end: Date }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(Delivery(incidents: incidents, exits: exits, begin: begin, end: end)) else { return }
        let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard !archive.seen.contains(key) else { return }
        archive.seen = Array((archive.seen + [key]).suffix(200))
        archive.snapshot.incidents = Array((archive.snapshot.incidents + incidents).suffix(20))
        archive.snapshot.exitReports = Array((archive.snapshot.exitReports + exits).suffix(14))
        save()
    }

    func snapshot() -> SupportSnapshot {
        _ = load()
        var value = archive.snapshot; value.storageAvailable = storageAvailable
        return value
    }

    func clear(at date: Date = Date()) throws {
        // Persist the cutoff too: MetricKit can replay older reports next launch.
        archive = Archive(); archive.clearedAt = date; loaded = true
        try persist(); storageAvailable = true
    }

    private func load() -> Bool {
        if loaded { return true }
        guard let file else { storageAvailable = false; return false }
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file))
            }
            loaded = true; storageAvailable = true
            return true
        } catch {
            // Locked or unreadable diagnostics must not be overwritten with an empty file.
            storageAvailable = false
            return false
        }
    }
    private func save() {
        do { try persist(); storageAvailable = true }
        catch { storageAvailable = false }
    }
    private func persist() throws {
        guard let file else { throw CocoaError(.fileNoSuchFile) }
        let manager = FileManager.default
        var directory = file.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        try JSONEncoder().encode(archive).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
