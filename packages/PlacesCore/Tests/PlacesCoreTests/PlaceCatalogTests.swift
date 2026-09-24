import Foundation
import Testing
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
    let distances = nearby.map { $0.coordinate.distance(to: point) }
    #expect(distances == distances.sorted())
}

@Test func unavailableOrCorruptCatalogFailsWithoutChangingPrivateData() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let catalog = PlaceCatalog(directory: directory)
    await #expect(throws: (any Error).self) { try await catalog.search("cafe") }
    try Data("[]".utf8).write(to: directory.appendingPathComponent("manifest.json"))
    await #expect(throws: PlaceCatalog.CatalogError.self) { try await catalog.search("cafe") }
    let pack = PlaceCatalogPack(id: "broken", name: "Broken", bounds: [0, 0, 1, 1], schemaVersion: 1,
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
