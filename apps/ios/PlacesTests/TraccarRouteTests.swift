import XCTest
import PlacesCore
import ZIPFoundation
import CryptoKit
@testable import PlacesRouting
@testable import Places

final class TraccarRouteTests: XCTestCase {
    private func points() -> [TraccarPoint] {
        let start = Date(timeIntervalSince1970: 1_760_000_000)
        return [
            TraccarPoint(timestamp: start, coordinate: Coordinate(latitude: 42.5063, longitude: 1.5218), accuracy: 25),
            TraccarPoint(timestamp: start.addingTimeInterval(180), coordinate: Coordinate(latitude: 42.5086, longitude: 1.5394), accuracy: 25)
        ]
    }
    func testRealNativeMatchPreservesEvidenceAndUsesObservedTime() async throws {
        let graph = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "valhalla-andorra", withExtension: "tar"))
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let input = points()
        let store = try PlacesStore()
        for point in input { try await store.appendTraccar(point) }
        let engine = try OfflineValhalla(tileExtract: graph, workspace: workspace)
        defer { engine.close() }
        let response = try engine.traceAttributes(request: TraccarMatchingTrace.request(for: input, mode: .driving))
        let result: TraccarMatchedSection
        do { result = try TraccarMatchedSection.decode(response, points: input) }
        catch {
            let json = try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any]
            let matches = (json?["matched_points"] as? [[String: Any]] ?? []).map { $0.filter {
                ["type", "distance_from_trace_point", "begin_route_discontinuity", "end_route_discontinuity"].contains($0.key)
            } }
            XCTFail("Public-fixture matching metadata: \(matches)")
            throw error
        }
        XCTAssertGreaterThan(result.coordinates.count, 2)
        XCTAssertGreaterThan(result.distanceMeters, 1_000)
        XCTAssertLessThan(result.distanceMeters, 5_000)
        XCTAssertEqual(result.observedSeconds, 180)
        XCTAssertEqual(result.pointIDs, input.map(\.id))
        let observations = input.enumerated().map { index, point in
            SensorObservation(timestamp: point.timestamp, source: .location, coordinate: point.coordinate,
                horizontalAccuracy: 25, companionDevice: index == 0 ? .watch : .mac)
        }
        let raw = MapPresentation(observations: observations, photos: [], traccar: input,
            showPlaces: true, showTraccar: true)
        let rendered = raw.comparing(TraccarRouteResult(trace: TraccarMatchingTrace(points: input, mode: .driving),
            matches: [result], pointCount: input.count))
        XCTAssertEqual(rendered.rawPoints, raw.rawPoints)
        XCTAssertEqual(rendered.paths.first { $0.id == "places-order" }, raw.paths.first { $0.id == "places-order" })
        let orange = try XCTUnwrap(rendered.paths.first { $0.id == "traccar-match-0" })
        XCTAssertFalse(orange.dashed)
        XCTAssertEqual(orange.coordinates, result.coordinates)
        XCTAssertEqual(orange.colorIndex, 2)
        let after = try await store.traccarPoints(from: input[0].timestamp, to: input[1].timestamp.addingTimeInterval(1))
        XCTAssertEqual(after, input)
        let timeline = try await store.timeline(on: input[0].timestamp)
        XCTAssertTrue(timeline.isEmpty)
    }
    func testComparisonReplacesOnlyOrangePathsAndPreservesRawPoints() {
        let input = points()
        let raw = MapPresentation(observations: [], photos: [], traccar: input, showPlaces: true, showTraccar: true)
        let result = TraccarRouteResult(trace: TraccarMatchingTrace(points: input, mode: .driving), matches: [], pointCount: 2)
        let rendered = raw.comparing(result)
        XCTAssertEqual(rendered.rawPoints, raw.rawPoints)
        XCTAssertEqual(rendered.paths.count, 1)
        XCTAssertEqual(rendered.paths[0].colorIndex, 2)
        XCTAssertTrue(rendered.paths[0].dashed)
        XCTAssertEqual(rendered.paths[0].coordinates, input.map(\.coordinate))
    }
    func testWorkerRejectsMissingPackInsteadOfSendingTraceElsewhere() async {
        let worker = TraccarRouteExperiment(testing: true)
        try? await worker.remove()
        do {
            _ = try await worker.match(points(), mode: .driving)
            XCTFail("Missing local graph must not match")
        } catch { XCTAssertTrue(error is TraccarRouteExperiment.Failure) }
    }

    func testRoutingImportPinsMetadataAndChecksEveryGraphByte() throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let graph = Data("Synthetic checksum fixture; never passed to native parsing.".utf8)
        let pack = RoutingPack(name: "Synthetic", version: "1", engine: "3.9.1", bytes: UInt64(graph.count),
            sha256: SHA256.hash(data: graph).map { String(format: "%02x", $0) }.joined(), south: 0, west: 0, north: 1, east: 1)
        func zip(_ name: String, graph data: Data, extraPath: String? = nil) throws -> URL {
            let url = workspace.appendingPathComponent(name + ".zip")
            let archive = try Archive(url: url, accessMode: .create)
            var files = ["pack.json": try JSONEncoder().encode(pack), "tiles.tar": data, "README.txt": Data("Public fixture".utf8)]
            if let extraPath { files[extraPath] = Data("Rejected".utf8) }
            for (path, bytes) in files {
                try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(bytes.count)) { offset, size in
                    bytes.subdata(in: Int(offset)..<min(bytes.count, Int(offset) + size))
                }
            }
            return url
        }
        let valid = try zip("valid", graph: graph)
        let prepared = try RoutingPack.prepare(zip: valid, in: workspace.appendingPathComponent("good"), acceptedPacks: [pack])
        XCTAssertEqual(prepared, pack)
        XCTAssertThrowsError(try RoutingPack.prepare(zip: valid, in: workspace.appendingPathComponent("unapproved")))
        var changed = graph; changed[0] ^= 1
        let tampered = try zip("tampered", graph: changed)
        XCTAssertThrowsError(try RoutingPack.prepare(zip: tampered, in: workspace.appendingPathComponent("bad"), acceptedPacks: [pack]))
        let traversal = try zip("traversal", graph: graph, extraPath: "../outside")
        XCTAssertThrowsError(try RoutingPack.prepare(zip: traversal, in: workspace.appendingPathComponent("unsafe"), acceptedPacks: [pack]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.deletingLastPathComponent().appendingPathComponent("outside").path))
    }
}
