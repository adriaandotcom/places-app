import XCTest
import CryptoKit
import PlacesCore
@testable import Places

@MainActor final class OfflineMapTests: XCTestCase {
    func testRestartRecoversVerifiedFilesAndRejectsCorruptedInstalledFiles() async throws {
        let (directory, pack, data) = try archiveFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(pack.filename)
        try data.write(to: file)
        // Simulate termination after the atomic rename, before saving progress.
        let manager = MapDownloads(testing: true, storage: directory, manifest: [pack])
        manager.start()
        try await waitUntilReady(manager)
        XCTAssertEqual(manager.installed[.world], file)
        XCTAssertEqual(manager.transfers[.world]?.phase, .installed)
        manager.stopForTesting()

        var corrupt = data; corrupt[200] = 1
        try corrupt.write(to: file)
        let restarted = MapDownloads(testing: true, storage: directory, manifest: [pack])
        restarted.start()
        try await waitUntilReady(restarted)
        XCTAssertNil(restarted.installed[.world])
        XCTAssertEqual(restarted.transfers[.world]?.phase, .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        restarted.stopForTesting()
    }

    func testInterruptedVerificationCanRestartAndDeletionRejectsLateCompletion() async throws {
        let (directory, pack, data) = try archiveFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transfer = MapPackTransfer(token: "old-transfer", phase: .verifying, received: pack.bytes)
        try JSONEncoder().encode([MapPack.ID.world: transfer]).write(to: directory.appendingPathComponent("transfers.json"))
        try data.write(to: directory.appendingPathComponent("old-transfer.partial"))
        let manager = MapDownloads(testing: true, storage: directory, manifest: [pack])
        manager.start()
        try await waitUntilReady(manager)
        XCTAssertNil(manager.installed[.world])
        XCTAssertEqual(manager.transfers[.world]?.phase, .paused)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("old-transfer.partial").path))
        try manager.deleteAll()

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel(); manager.stopForTesting() }
        let task = session.downloadTask(with: pack.url)
        task.taskDescription = "world|old-transfer"
        let delivered = directory.appendingPathComponent("late-download")
        try data.write(to: delivered)
        manager.urlSession(session, downloadTask: task, didFinishDownloadingTo: delivered)
        XCTAssertTrue(manager.installed.isEmpty)
        XCTAssertTrue(manager.transfers.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    private func archiveFixture() throws -> (URL, MapPack, Data) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var data = Data(repeating: 0, count: 256)
        data.replaceSubrange(0..<8, with: [80, 77, 84, 105, 108, 101, 115, 3])
        data[99] = 1; data[100] = 0; data[101] = 6
        let base = try XCTUnwrap(MapDownloads(testing: true).pack(.world))
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as! [String: Any]
        object["bytes"] = data.count
        object["sha256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (directory, try JSONDecoder().decode(MapPack.self, from: JSONSerialization.data(withJSONObject: object)), data)
    }

    private func waitUntilReady(_ manager: MapDownloads) async throws {
        for _ in 0..<100 where !manager.ready { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(manager.ready)
    }

    func testDownloadCoverageIncludesVisibleGreekIslandsWithCameraAtSea() {
        for point in [Coordinate(latitude: 36.85, longitude: 27.16), Coordinate(latitude: 35.3, longitude: 24.8),
                      Coordinate(latitude: 37.98, longitude: 23.72), Coordinate(latitude: 52.37, longitude: 4.9)] {
            let viewport = MapViewport(center: point, latitudeSpan: 0.4, longitudeSpan: 0.4)
            let expected: MapPack.ID = point.latitude > 50 ? .netherlands : .greece
            XCTAssertTrue(OfflineMapCoverage.countries(in: viewport).contains(expected))
        }
        XCTAssertTrue(OfflineMapCoverage.countries(in: MapViewport(center: Coordinate(latitude: 36.8, longitude: 27.3),
            latitudeSpan: 0.3, longitudeSpan: 0.3)).contains(.greece))
        XCTAssertTrue(OfflineMapCoverage.countries(in: MapViewport(center: Coordinate(latitude: 0, longitude: 0),
            latitudeSpan: 0.3, longitudeSpan: 0.3)).isEmpty)
        let offered: Set<MapPack.ID> = [.netherlands]
        for id in MapPack.ID.allCases where id != .world {
            XCTAssertEqual(MapDownloadPolicy.canSuggest(id: id, zoom: 9, installed: [], pending: [],
                dismissedAt: nil, now: Date(), offeredThisSession: offered), id != .netherlands)
        }
    }

    func testBundledManifestIsCompleteAndLimitedToImmutableReleaseAssets() throws {
        let downloads = MapDownloads(testing: true)
        XCTAssertEqual(Set(downloads.packs.map(\.id)), Set(MapPack.ID.allCases))
        XCTAssertTrue(downloads.packs.allSatisfy(\.isValid))
        XCTAssertLessThanOrEqual(try XCTUnwrap(downloads.pack(.world)).bytes, 100_000_000)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(downloads.packs[0])) as! [String: Any]
        for url in ["https://example.invalid/maps.pmtiles", downloads.packs[0].url.absoluteString + "?latitude=1",
                    downloads.packs[0].url.absoluteString + "#position", "http://github.com/adriaandotcom/places-app/releases/download/maps-20260925.1/world.pmtiles"] {
            object["url"] = url
            let pack = try JSONDecoder().decode(MapPack.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertFalse(pack.isValid)
        }
    }

    func testCorruptAndPartialDownloadsNeverReplaceAnInstalledFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var data = Data(repeating: 0, count: 256)
        data.replaceSubrange(0..<8, with: [80, 77, 84, 105, 108, 101, 115, 3])
        data[99] = 1; data[100] = 0; data[101] = 6
        let base = try XCTUnwrap(MapDownloads(testing: true).pack(.world))
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as! [String: Any]
        object["bytes"] = data.count
        object["sha256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let pack = try JSONDecoder().decode(MapPack.self, from: JSONSerialization.data(withJSONObject: object))
        let staging = directory.appendingPathComponent("test.partial")
        let final = directory.appendingPathComponent(pack.filename)
        try Data("existing map".utf8).write(to: final)
        try data.prefix(128).write(to: staging)
        XCTAssertThrowsError(try MapPackFiles.validate(staging, pack: pack))
        var corrupt = data; corrupt[200] = 1
        try corrupt.write(to: staging)
        XCTAssertThrowsError(try MapPackFiles.validate(staging, pack: pack))
        XCTAssertEqual(try String(contentsOf: final, encoding: .utf8), "existing map")
        try data.write(to: staging)
        try MapPackFiles.validate(staging, pack: pack)
        _ = try MapPackFiles.installValidated(staging, pack: pack, directory: directory)
        XCTAssertEqual(try Data(contentsOf: final), data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testLocalCoverageRecognizesAmsterdamKosAndBorderingUnsupportedCountries() {
        XCTAssertEqual(OfflineMapCoverage.country(at: Coordinate(latitude: 52.3676, longitude: 4.9041)), .netherlands)
        XCTAssertEqual(OfflineMapCoverage.country(at: Coordinate(latitude: 36.8915, longitude: 27.2877)), .greece)
        XCTAssertEqual(OfflineMapCoverage.country(at: Coordinate(latitude: 36.8014, longitude: 27.0906)), .greece)
        XCTAssertNil(OfflineMapCoverage.country(at: Coordinate(latitude: 50.8503, longitude: 4.3517)))
        XCTAssertNil(OfflineMapCoverage.country(at: Coordinate(latitude: 36.999, longitude: 27.43)))
        XCTAssertNil(OfflineMapCoverage.country(at: Coordinate(latitude: 0, longitude: 0)))
    }

    func testEveryStyleResourceIsLocalAndCountryLabelsReplaceWorldLabels() throws {
        let files: [MapPack.ID: URL] = [.world: URL(fileURLWithPath: "/tmp/world.pmtiles"), .greece: URL(fileURLWithPath: "/tmp/greece.pmtiles")]
        for dark in [false, true] {
            let text = try OfflineMapStyle.make(installed: files, dark: dark)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            let glyphs = try XCTUnwrap(json["glyphs"] as? String)
            XCTAssertTrue(glyphs.hasPrefix("file://"))
            XCTAssertFalse(text.contains("https:")); XCTAssertFalse(text.contains("http:"))
            let sources = try XCTUnwrap(json["sources"] as? [String: [String: Any]])
            XCTAssertEqual(sources.count, 2)
            XCTAssertTrue(sources.values.allSatisfy { ($0["url"] as? String)?.hasPrefix("pmtiles://file://") == true })
            let layers = try XCTUnwrap(json["layers"] as? [[String: Any]])
            let worldLabels = try XCTUnwrap(layers.first { $0["id"] as? String == "world-settlements" })
            let overview = try XCTUnwrap(layers.first { $0["id"] as? String == "world-settlements-overview" })
            XCTAssertEqual(overview["maxzoom"] as? Int, 7)
            XCTAssertEqual(worldLabels["minzoom"] as? Int, 7)
            let overviewFilter = try JSONSerialization.data(withJSONObject: XCTUnwrap(overview["filter"]))
            XCTAssertFalse(String(decoding: overviewFilter, as: UTF8.self).contains("within"))
            let filter = try JSONSerialization.data(withJSONObject: XCTUnwrap(worldLabels["filter"]))
            XCTAssertTrue(String(decoding: filter, as: UTF8.self).contains("within"))
        }
        let greekGlyphs = OfflineMapStyle.resourceRoot.appendingPathComponent("fonts/Noto Sans Regular/768-1023.pbf")
        XCTAssertGreaterThan(try Data(contentsOf: greekGlyphs).count, 1_000)
    }
}
