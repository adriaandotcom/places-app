import XCTest
import CryptoKit
import PlacesCore
@testable import Places

@MainActor final class OfflineMapTests: XCTestCase {
    func testWalkingVisitShowsItsPlaceAndRecordedPath() async throws {
        let date = Date(timeIntervalSince1970: 1_735_689_600)
        var place = Place(name: "Fixture park", coordinate: .init(latitude: 0, longitude: 0), radius: 500)
        place.countsWalksAsVisits = true
        let store = try PlacesStore()
        try await store.savePlace(place)
        let samples = [0, 90, 180].map { second in
            SensorObservation(timestamp: date.addingTimeInterval(Double(second)), source: .location,
                coordinate: .init(latitude: 0, longitude: Double(second) / 100_000), horizontalAccuracy: 10,
                speed: 1, motion: .walking)
        }
        try await store.append(samples)
        let visits = try await store.timeline(on: date)
        let points = try await store.routePoints(from: date, to: date.addingTimeInterval(180))
        let map = MapPresentation(items: visits, routePoints: points, places: [place])
        XCTAssertEqual(map.pins.first?.placeID, place.id)
        XCTAssertEqual(map.paths.first?.coordinates, samples.compactMap(\.coordinate))
        XCTAssertEqual(map.paths.first?.dashed, false)
    }

    func testGroupedParkWalkDoesNotDrawThroughAnUnrecordedInterval() async throws {
        let date = Date(timeIntervalSince1970: 1_735_689_600)
        var place = Place(name: "Fixture park", coordinate: .init(latitude: 0, longitude: 0), radius: 500)
        place.countsWalksAsVisits = true
        let store = try PlacesStore()
        try await store.savePlace(place)
        let samples = [0, 90, 180, 240, 330, 420].map { second in
            SensorObservation(timestamp: date.addingTimeInterval(Double(second)), source: .location,
                coordinate: .init(latitude: 0, longitude: Double(second) / 100_000), horizontalAccuracy: 10,
                speed: 1, motion: .walking)
        }
        try await store.append(samples + [SensorObservation(timestamp: date.addingTimeInterval(181), source: .recovery)])
        let visits = try await store.timeline(on: date)
        XCTAssertEqual(visits.count, 1)
        XCTAssertEqual(visits.first?.originalItems?.count, 3)
        let points = try await store.routePoints(from: date, to: date.addingTimeInterval(420))
        let map = MapPresentation(items: visits, routePoints: points, places: [place])
        XCTAssertEqual(map.paths.count, 2)
        XCTAssertEqual(map.paths.map { $0.coordinates.count }, [3, 3])
    }

    func testRawMapPreservesInaccurateAndCoincidentPointsWithoutInventingARoute() throws {
        let start = Date(timeIntervalSince1970: 1_735_732_800)
        let point = Coordinate(latitude: 1, longitude: 1)
        let inaccurate = SensorObservation(id: "a", timestamp: start, source: .location, coordinate: point,
            coordinateTimestamp: start.addingTimeInterval(-600), horizontalAccuracy: 900)
        let watch = SensorObservation(id: "b", timestamp: start, source: .location, coordinate: point,
            horizontalAccuracy: 10, companionDevice: .watch)
        let later = SensorObservation(id: "c", timestamp: start.addingTimeInterval(300), source: .location,
            coordinate: Coordinate(latitude: 2, longitude: 2), horizontalAccuracy: 5, companionDevice: .mac)
        let missing = SensorObservation(timestamp: start, source: .motion)
        let invalid = SensorObservation(timestamp: start, source: .location, coordinate: Coordinate(latitude: 100, longitude: 1))
        let photo = PhotoLocationEvidence(id: "a", assetID: "synthetic", capturedAt: start.addingTimeInterval(120), coordinate: point, cameraModel: "Fixture")
        let map = MapPresentation(observations: [later, watch, missing, inaccurate, invalid], photos: [photo])
        XCTAssertEqual(map.rawPoints.map(\.id), ["sensor:a", "sensor:b", "photo:a", "sensor:c"])
        XCTAssertEqual(map.rawPoints.map(\.number), [1, 2, 3, 4])
        XCTAssertEqual(map.rawPoints.map(\.device), ["iPhone", "Apple Watch", "Photos", "Mac"])
        XCTAssertEqual(map.rawPoints.first?.accuracy, 900)
        XCTAssertEqual(map.rawPoints.first?.measuredAt, start.addingTimeInterval(-600))
        XCTAssertTrue(map.pins.isEmpty)
        XCTAssertEqual(map.paths.count, 1)
        XCTAssertTrue(map.paths[0].dashed)
        XCTAssertEqual(map.paths[0].coordinates, map.rawPoints.map(\.coordinate))
        XCTAssertNotNil(map.fittingViewport)
        XCTAssertTrue(MapPresentation(observations: [inaccurate]).paths.isEmpty)
        XCTAssertNil(MapPresentation(observations: [missing]).fittingViewport)
    }

    func testLocalParkMetadataLoadsGzipAndRejectsInvalidOffsets() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pmtiles")
        defer { try? FileManager.default.removeItem(at: file) }
        let compressed = Data(base64Encoded: "H4sIAAAAAAAC/52Qyw6CMBBFf4V0rSQ+EPQD3KkLl4aYBkZsrJ2mD6Mh/XfbAhth5WpmzpzcTtoSyWkF+koVUE12SUteoDRD4fvFLCGSqkfgl5aw2ldyY29jFczDgnhB0CcEvu94MvAKUdVMUAMxlVPDjK3DkC3T1cYbHEUzsHVaFM6zcEb0JfJPg6J/Gq0B1bU/Qdk4KPdBIy//39tOedmUV3p4Rw7x6jKOGq2q4Nh/0kmCOBsFYA5UEudK574ogPU2ggEAAA==")!
        var archive = Data(repeating: 0, count: 127)
        archive.replaceSubrange(0..<7, with: Data("PMTiles".utf8)); archive[7] = 3; archive[97] = 2
        func set(_ value: UInt64, at offset: Int) {
            for byte in 0..<8 { archive[offset + byte] = UInt8((value >> (8 * byte)) & 255) }
        }
        set(127, at: 24); set(UInt64(compressed.count), at: 32); archive.append(compressed)
        try archive.write(to: file)
        let parks = try MapParkCatalog.read(file)
        XCTAssertEqual(parks.map(\.name), ["Fixture park"])
        XCTAssertTrue(parks[0].area.contains(parks[0].coordinate))
        let catalog = MapParkCatalog()
        let nearby = await catalog.nearby(Coordinate(latitude: 52.36, longitude: 4.88), files: [file])
        XCTAssertTrue(nearby.available); XCTAssertEqual(nearby.parks.count, 1)
        let distant = await catalog.nearby(Coordinate(latitude: 40, longitude: 10), files: [file])
        XCTAssertTrue(distant.available); XCTAssertTrue(distant.parks.isEmpty)
        let removed = await catalog.nearby(parks[0].coordinate, files: [])
        XCTAssertFalse(removed.available)
        set(UInt64.max, at: 24); try archive.write(to: file)
        XCTAssertThrowsError(try MapParkCatalog.read(file))
        set(127, at: 24); archive[archive.count - 1] ^= 1; try archive.write(to: file)
        XCTAssertThrowsError(try MapParkCatalog.read(file))
    }

    func testPeriodMapsContainEveryPlaceAndKeepRecordedPathsDistinctFromEndpointLinks() async throws {
        let store = try PlacesStore()
        try await DemoFixtures.seedMapPeriods(store)
        let places = try await store.places()
        let visits = try await store.suggestedPeriods()
        let kos = try XCTUnwrap(visits.first { $0.title == "Kos" })
        for (interval, count) in [(kos.interval, 2), (DateInterval(start: .distantPast, end: Date()), 4)] {
            let items = try await store.timeline(in: interval)
            let points = try await store.routePoints(from: interval.start, to: interval.end)
            let map = MapPresentation(items: items, routePoints: points, places: places)
            XCTAssertEqual(Set(map.pins.compactMap(\.placeID)).count, count)
            XCTAssertTrue(map.paths.contains { !$0.dashed }, "Recorded travel stays visible")
            XCTAssertTrue(map.paths.contains { $0.dashed }, "Unrecorded links stay distinct")
            let viewport = try XCTUnwrap(map.fittingViewport)
            for point in map.coordinates {
                XCTAssertLessThan(abs(point.latitude - viewport.center.latitude), viewport.latitudeSpan / 2)
                XCTAssertLessThan(abs(point.longitude - viewport.center.longitude), viewport.longitudeSpan / 2)
            }
            if count == 2 { XCTAssertLessThan(viewport.latitudeSpan, 1) }
            else { XCTAssertGreaterThan(viewport.latitudeSpan, 15) }
        }
    }

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

    func testReplacementCancelAndCorruptRestartKeepPreviousMap() async throws {
        let (directory, old, data) = try archiveFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(old.filename)
        try data.write(to: file)
        let manager = MapDownloads(testing: true, storage: directory, manifest: [old])
        manager.start(); try await waitUntilReady(manager)
        manager.cancel(.world)
        XCTAssertEqual(manager.installed[.world], file)
        XCTAssertEqual(manager.totalInstalledBytes, old.bytes)
        manager.stopForTesting()
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        object["version"] = "20260929.1"
        object["url"] = "https://github.com/adriaandotcom/places-app/releases/download/maps-20260929.1/world.pmtiles"
        let newer = try JSONDecoder().decode(MapPack.self, from: JSONSerialization.data(withJSONObject: object))
        var broken = data; broken[200] = 1
        try broken.write(to: directory.appendingPathComponent(newer.filename))
        let transfer = MapPackTransfer(token: "replacement", phase: .verifying, received: newer.bytes, pack: newer)
        try JSONEncoder().encode([MapPack.ID.world: transfer]).write(to: directory.appendingPathComponent("transfers.json"))
        let restored = MapDownloads(testing: true, storage: directory, manifest: [old])
        restored.start(); try await waitUntilReady(restored)
        XCTAssertEqual(restored.installed[.world], file)
        XCTAssertEqual(restored.installedPacks[.world], old)
        XCTAssertEqual(restored.transfers[.world]?.phase, .failed)
        XCTAssertEqual(try Data(contentsOf: file), data)
        // A verified replacement swaps once, cleans up the old version and
        // remains the installed descriptor across process restarts.
        let staging = directory.appendingPathComponent("replacement.partial")
        try data.write(to: staging); try MapPackFiles.validate(staging, pack: newer)
        try restored.install(staging, pack: newer)
        XCTAssertEqual(restored.installedPacks[.world], newer)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        restored.stopForTesting()
        let again = MapDownloads(testing: true, storage: directory, manifest: [old])
        again.start(); try await waitUntilReady(again)
        XCTAssertEqual(again.installedPacks[.world], newer)
        XCTAssertEqual(again.totalInstalledBytes, newer.bytes)
        again.stopForTesting()
    }

    func testLegacyPausedDownloadBindsItsOriginalTargetOnUpgrade() async throws {
        let (directory, pack, _) = try archiveFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transfer = MapPackTransfer(token: "legacy", phase: .paused, received: 120)
        try JSONEncoder().encode([MapPack.ID.world: transfer]).write(to: directory.appendingPathComponent("transfers.json"))
        let manager = MapDownloads(testing: true, storage: directory, manifest: [pack])
        manager.start(); try await waitUntilReady(manager)
        XCTAssertEqual(manager.transfers[.world]?.pack, pack)
        XCTAssertEqual(manager.transfers[.world]?.phase, .paused)
        manager.stopForTesting()
    }

    func testNewCatalogOffersUpdateInTheInstalledDetailWithoutChangingStoredMap() async throws {
        let (directory, _, _) = try archiveFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = MapDownloads(testing: true, storage: directory)
        manager.loadPreviewCatalogForTesting()
        manager.start(); try await waitUntilReady(manager)
        let latest = try XCTUnwrap(manager.choices(.netherlands).first { $0.detail == .normal })
        var data = Data(repeating: 0, count: 256)
        data.replaceSubrange(0..<8, with: [80, 77, 84, 105, 108, 101, 115, 3])
        data[99] = 1; data[100] = 7; data[101] = 14
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(latest)) as! [String: Any]
        old["version"] = "20260901.1"; old["bytes"] = data.count
        old["url"] = latest.url.absoluteString.replacingOccurrences(of: latest.version, with: "20260901.1")
        old["sha256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let installed = try JSONDecoder().decode(MapPack.self, from: JSONSerialization.data(withJSONObject: old))
        let staging = directory.appendingPathComponent("old-map.partial")
        try data.write(to: staging); try MapPackFiles.validate(staging, pack: installed)
        try manager.install(staging, pack: installed)
        XCTAssertEqual(manager.update(.netherlands), latest)
        XCTAssertEqual(manager.update(.netherlands)?.detail, .normal)
        XCTAssertEqual(manager.installedPacks[.netherlands], installed)
        XCTAssertEqual(manager.totalInstalledBytes, 256)
        manager.cancel(.netherlands)
        XCTAssertEqual(manager.installedPacks[.netherlands], installed)
        manager.stopForTesting()
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
        for id in MapPack.ID.bootstrapIDs where id != .world {
            XCTAssertEqual(MapDownloadPolicy.canSuggest(id: id, zoom: 9, installed: [], pending: [],
                dismissedAt: nil, now: Date(), offeredThisSession: offered), id != .netherlands)
        }
    }

    func testBundledManifestIsCompleteAndLimitedToImmutableReleaseAssets() throws {
        let downloads = MapDownloads(testing: true)
        XCTAssertEqual(Set(downloads.packs.map(\.id)), Set(MapPack.ID.bootstrapIDs))
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

    func testNewCatalogCountriesCanBeSuggestedWithoutACoordinateRequest() throws {
        let germany = try XCTUnwrap(MapPack.ID(rawValue: "germany"))
        let berlin = Coordinate(latitude: 52.52, longitude: 13.405)
        XCTAssertNil(OfflineMapCoverage.country(at: berlin))
        XCTAssertEqual(OfflineMapCoverage.country(at: berlin, available: [germany]), germany)
        XCTAssertEqual(OfflineMapCoverage.countries(in: MapViewport(center: berlin, latitudeSpan: 0.2, longitudeSpan: 0.2), available: [germany]), [germany])
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
