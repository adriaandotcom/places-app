import Foundation
import Testing
import GRDB
import CryptoKit
@testable import PlacesCore

@Test func bundledCatalogHasBothRegionsAndLocalSearch() async throws {
    let catalog = PlaceCatalog()
    let packs = try await catalog.packs()
    #expect(Set(packs.map(\.id)) == ["amsterdam", "kos"])
    #expect(try await catalog.covers(Coordinate(latitude: 52.31, longitude: 4.76)))
    #expect(try await catalog.covers(Coordinate(latitude: 36.79, longitude: 27.09)))
    #expect(try await !catalog.covers(Coordinate(latitude: 40, longitude: 10)))
    let results = try await catalog.search("hotel")
    #expect(!results.isEmpty)
    _ = try await catalog.search("\" OR * --")
    #expect(try await catalog.search("").isEmpty)
    #expect(PlaceCatalog.normalized("ΚΑΦΈΣ") == PlaceCatalog.normalized("καφες"))
    #expect(PlaceCatalog.normalized("Café") == "cafe")
    let greek = try await catalog.search("Αγία")
    let unaccented = try await catalog.search("ΑΓΙΑ")
    #expect(!greek.isEmpty)
    #expect(greek.map(\.id) == unaccented.map(\.id))
    let kos = try await catalog.search("hotel", near: Coordinate(latitude: 36.89, longitude: 27.29))
    #expect(kos.first?.reference.packID == "kos")
    let point = try #require(kos.first?.coordinate)
    let nearby = try await catalog.nearby(point)
    #expect(!nearby.isEmpty && nearby.count <= 5)
    #expect(nearby.allSatisfy { $0.coordinate.distance(to: point) <= 1_000 })
    #expect(try await catalog.nearby(point).map(\.id) == nearby.map(\.id))
}

@Test func airportSuggestionsPrioritizeTheMainVenueAndStayLocal() async throws {
    let catalog = PlaceCatalog()
    for (point, airport, pack) in [
        (Coordinate(latitude: 36.8014, longitude: 27.0906), "Kos Airport “Ippokratis”", "kos"),
        (Coordinate(latitude: 52.309, longitude: 4.762), "Amsterdam Airport Schiphol", "amsterdam")
    ] {
        #expect(try await catalog.nearby(point).first?.name == airport)
        let results = try await catalog.search("airport", near: point)
        #expect(results.first?.name == airport)
        #expect(results.allSatisfy { $0.reference.packID == pack && $0.coordinate.distance(to: point) <= 15_000 })
    }
    let kos = Coordinate(latitude: 36.8014, longitude: 27.0906)
    #expect(try await catalog.search("Schiphol", near: kos).isEmpty)
    #expect(try await !catalog.search("Schiphol").isEmpty)
    #expect(try await catalog.search("airport", near: Coordinate(latitude: 0, longitude: 0)).isEmpty)
    #expect(try await catalog.search("Gate 2", near: kos).first?.name == "Gate 2")
    #expect(try await catalog.search("Κρατικός Αερολιμένας Κω", near: kos).first?.name == "Kos Airport “Ippokratis”")
    // Large airports have off-terminal centroids; include the main venue beyond 1 km.
    #expect(try await catalog.nearby(Coordinate(latitude: 52.30, longitude: 4.762)).first?.name == "Amsterdam Airport Schiphol")
}

@Test func venueRankingBalancesLandmarksDistanceAndExplicitNames() {
    let origin = Coordinate(latitude: 0, longitude: 0)
    func place(_ name: String, latitude: Double, importance: Int = 0) -> (CatalogPlace, Double) {
        (CatalogPlace(reference: .init(sourceID: name, packID: "test", release: "test"), name: name,
                      address: "", coordinate: .init(latitude: latitude, longitude: 0), category: "test", region: "Test",
                      importance: importance), 0)
    }
    let places = [place("Gate 2", latitude: 0), place("Museum", latitude: 0.0018, importance: 1),
                  place("Airport", latitude: 0.012, importance: 2), place("Far museum", latitude: 0.008, importance: 1)]
    let ranked = PlaceCatalog.ranked(places, query: "", near: origin, limit: 5).map(\.name)
    #expect(ranked == ["Airport", "Museum", "Gate 2", "Far museum"])
    #expect(PlaceCatalog.ranked(places, query: "Gate 2", near: origin, limit: 1).first?.name == "Gate 2")
    #expect(PlaceCatalog.ranked(places, query: "", near: origin, limit: 0).isEmpty)
}

@Test func localRankingDoesNotDiscardNearbyMatchesBeforeSorting() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("test.sqlite")
    let queue = try DatabaseQueue(path: file.path)
    try await queue.write { db in
        try db.execute(sql: """
            PRAGMA user_version=2;
            CREATE TABLE places(id TEXT, name TEXT, address TEXT, latitude REAL, longitude REAL, category TEXT, importance INTEGER);
            CREATE VIRTUAL TABLE search USING fts5(searchText);
            """)
        for index in 0..<151 {
            // The near match is last and has weaker text relevance. Others are
            // inside the SQL bounding box, but some exceed the exact radius.
            let near = index == 150
            let offset = index < 125 ? 0.08 : 0.10
            try db.execute(sql: "INSERT INTO places VALUES (?, ?, '', ?, ?, 'cafe', 0)",
                arguments: ["\(index)", near ? "Nearby Coffee House" : "Coffee Stop", near ? 0.001 : offset, near ? 0 : offset])
            try db.execute(sql: "INSERT INTO search VALUES (?)", arguments: [near ? "Nearby Coffee House" : "Coffee Stop"])
        }
    }
    try queue.close()
    let digest = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
    let pack = PlaceCatalogPack(id: "test", name: "Test", bounds: [-1, -1, 1, 1], schemaVersion: 2,
                               release: "test", count: 151, filename: "test.sqlite", sha256: digest)
    try JSONEncoder().encode([pack]).write(to: directory.appendingPathComponent("manifest.json"))
    let results = try await PlaceCatalog(directory: directory).search("coffee", near: Coordinate(latitude: 0, longitude: 0))
    #expect(results.first?.name == "Nearby Coffee House")
    #expect(results.count == 30)
    #expect(results.allSatisfy { $0.coordinate.distance(to: Coordinate(latitude: 0, longitude: 0)) <= 15_000 })
}

@Test func unavailableOrCorruptCatalogFailsWithoutChangingPrivateData() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let catalog = PlaceCatalog(directory: directory)
    await #expect(throws: (any Error).self) { try await catalog.search("cafe") }
    try Data("[]".utf8).write(to: directory.appendingPathComponent("manifest.json"))
    await #expect(throws: PlaceCatalog.CatalogError.self) { try await catalog.search("cafe") }
    let pack = PlaceCatalogPack(id: "broken", name: "Broken", bounds: [0, 0, 1, 1], schemaVersion: 2,
                                release: "test", count: 1, filename: "broken.sqlite", sha256: "incorrect")
    try JSONEncoder().encode([pack]).write(to: directory.appendingPathComponent("manifest.json"))
    try Data("not a database".utf8).write(to: directory.appendingPathComponent("broken.sqlite"))
    await #expect(throws: PlaceCatalog.CatalogError.self) { try await catalog.search("cafe") }
}

@Test func catalogReferencePersistsButIsRemovedFromTestExports() async throws {
    let reference = PlaceCatalogReference(sourceID: "synthetic-public-source-id", packID: "test-region", release: "test-release")
    let place = Place(name: "Synthetic cafe", coordinate: Coordinate(latitude: 10, longitude: 10), catalogReference: reference)
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
    let store = try PlacesStore(path: path)
    try await store.savePlace(place)
    let reopened = try PlacesStore(path: path)
    let saved = try await reopened.places()
    #expect(reference.savedPlace(in: saved)?.id == place.id)
    let testExport = try await store.exportTestCase()
    #expect(!String(decoding: testExport, as: UTF8.self).contains(reference.sourceID))
    #expect(try InferenceTestCase.decode(testExport).input.places.first?.catalogReference == nil)
    var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(place)) as? [String: Any])
    legacy.removeValue(forKey: "catalogReference")
    let decoded = try JSONDecoder().decode(Place.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(decoded.catalogReference == nil)
    #expect(decoded.name == place.name)
}
