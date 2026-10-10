import Foundation
import PlacesCore
import PlacesRouting

struct TraccarRouteResult: Sendable {
    var trace: TraccarMatchingTrace
    var matches: [TraccarMatchedSection]
    var pointCount: Int
    var matchedPointCount: Int { Set(matches.flatMap(\.pointIDs)).count }
    var distanceMeters: Double { matches.reduce(0) { $0 + $1.distanceMeters } }
    var observedSeconds: Double { matches.reduce(0) { $0 + $1.observedSeconds } }
}

/// One serial, non-main worker owns the native graph reader. Only the independent
/// Traccar data type can enter it; Places/photos/Watch evidence has no adapter here.
actor TraccarRouteExperiment {
    private var native: OfflineValhalla?
    private var pack: RoutingPack?
    private var cache: [String: TraccarMatchedSection] = [:]
    private let testing: Bool
    init(testing: Bool = false) { self.testing = testing }

    private func directory() throws -> URL {
        let parent = testing ? FileManager.default.temporaryDirectory : try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var url = parent.appendingPathComponent(testing ? "PlacesRouting-QA" : "PlacesRouting", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        let active = url.appendingPathComponent("active"), previous = url.appendingPathComponent("previous")
        if FileManager.default.fileExists(atPath: previous.path) {
            if !FileManager.default.fileExists(atPath: active.path) { try FileManager.default.moveItem(at: previous, to: active) }
            else { try FileManager.default.removeItem(at: previous) }
        }
        for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            where UUID(uuidString: child.lastPathComponent) != nil {
            try FileManager.default.removeItem(at: child)
        }
        return url
    }
    func installed() -> RoutingPack? {
        guard let root = try? directory() else { return nil }
        return RoutingPack.installed(in: root.appendingPathComponent("active"))
    }
    func install(_ zip: URL) throws -> RoutingPack {
        let scoped = zip.startAccessingSecurityScopedResource()
        defer { if scoped { zip.stopAccessingSecurityScopedResource() } }
        let root = try directory(), stage = root.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stage) }
        let newPack = try RoutingPack.prepare(zip: zip, in: stage)
        try Task.checkCancellation()
        close()
        let active = root.appendingPathComponent("active"), rollback = root.appendingPathComponent("previous")
        let manager = FileManager.default
        // Recover safely if a prior installation stopped between renames.
        if manager.fileExists(atPath: rollback.path) {
            if !manager.fileExists(atPath: active.path) { try manager.moveItem(at: rollback, to: active) }
            else { try manager.removeItem(at: rollback) }
        }
        if manager.fileExists(atPath: active.path) { try manager.moveItem(at: active, to: rollback) }
        do { try manager.moveItem(at: stage, to: active) }
        catch {
            if manager.fileExists(atPath: rollback.path) { try? manager.moveItem(at: rollback, to: active) }
            throw error
        }
        try? manager.removeItem(at: rollback)
        cache = [:]
        return newPack
    }
    func remove() throws {
        close(); cache = [:]
        try FileManager.default.removeItem(at: directory())
    }
    func close() { native?.close(); native = nil; pack = nil }
    func clear() { close(); cache = [:] }

    func match(_ points: [TraccarPoint], mode: TraccarMatchingMode) throws -> TraccarRouteResult {
        try Task.checkCancellation()
        guard points.count <= 10_000 else { throw Failure.tooManyPoints }
        let trace = TraccarMatchingTrace(points: points, mode: mode)
        let root = try directory(), active = root.appendingPathComponent("active")
        guard let current = RoutingPack.installed(in: active) else { throw Failure.noPack }
        if native == nil || pack != current {
            close()
            native = try OfflineValhalla(tileExtract: active.appendingPathComponent("tiles.tar"), workspace: root)
            pack = current
        }
        var matches: [TraccarMatchedSection] = []
        for section in trace.sections {
            try Task.checkCancellation()
            guard section.allSatisfy({ current.contains(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }) else { continue }
            let key = current.sha256 + mode.rawValue + section.map(\.id).joined()
            if let cached = cache[key] { matches.append(cached); continue }
            do {
                let request = try TraccarMatchingTrace.request(for: section, mode: mode)
                let response = try native!.traceAttributes(request: request)
                try Task.checkCancellation()
                let match = try TraccarMatchedSection.decode(response, points: section)
                if cache.count >= 40 { cache = [:] }
                cache[key] = match; matches.append(match)
            } catch is CancellationError { throw CancellationError() }
            catch { /* Leave this original trace dashed; never force a match. */ }
        }
        return TraccarRouteResult(trace: trace, matches: matches, pointCount: points.count)
    }
    enum Failure: Error { case noPack, tooManyPoints }
}
