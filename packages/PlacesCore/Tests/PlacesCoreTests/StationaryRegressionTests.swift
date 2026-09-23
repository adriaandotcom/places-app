import Foundation
import Testing
import GRDB
@testable import PlacesCore

private let start = Date(timeIntervalSince1970: 1_735_689_600)
private func sample(_ seconds: Double, metres: Double = 0, speed: Double = -1, source: ObservationSource = .location) -> SensorObservation {
    SensorObservation(timestamp: start.addingTimeInterval(seconds), source: source,
                      coordinate: Coordinate(latitude: 0, longitude: metres / 111_195), horizontalAccuracy: 30, speed: speed)
}

@Test func stationaryWiFiAndGPSJitterStayInOneUnnamedEntry() async throws {
    var observations: [SensorObservation] = []
    for second in stride(from: 0, through: 900, by: 30) {
        let drift = [0.0, 18, -12, 25][second / 30 % 4]
        observations.append(sample(Double(second), metres: drift))
        var wifi = sample(Double(second + 1), metres: drift, source: .wifi)
        wifi.speed = nil; wifi.coordinateTimestamp = start.addingTimeInterval(Double(second))
        observations.append(wifi)
    }
    let items = InferenceEngine.infer(observations: observations, places: [])
    #expect(items.count == 1)
    #expect(items.first?.kind == .stay)
    #expect(items.first?.placeID == nil)
    #expect(items.first?.start == start)
    // The result must be independent of batch size and incremental rebuilds.
    let store = try PlacesStore()
    for observation in observations { try await store.append([observation]) }
    let persisted = try await store.timeline(on: start)
    #expect(persisted.count == 1)
    #expect(persisted.first?.kind == .stay)
}

@Test func isolatedGPSOutlierDoesNotInventJourney() {
    let observations = [sample(0), sample(90), sample(190), sample(240, metres: 300), sample(270, metres: 5), sample(450)]
    let items = InferenceEngine.infer(observations: observations, places: [])
    #expect(items.count == 1)
    #expect(items.first?.kind == .stay)
}

@Test func confirmedDepartureStillCreatesJourney() {
    let observations = [sample(0), sample(90), sample(190), sample(240, metres: 150), sample(270, metres: 260), sample(300, metres: 350)]
    let items = InferenceEngine.infer(observations: observations, places: [])
    #expect(items.map(\.kind) == [.stay, .journey])
    #expect(items.first?.end == start.addingTimeInterval(240))
}

@Test func repeatedCachedWiFiIsNotIndependentDepartureEvidence() {
    let departure = sample(240, metres: 150)
    var cached = sample(270, metres: 150, source: .wifi)
    cached.coordinateTimestamp = departure.timestamp
    let items = InferenceEngine.infer(observations: [sample(0), sample(190), departure, cached, sample(300)], places: [])
    #expect(items.map(\.kind) == [.stay])
}

@Test func firstFixDoesNotClaimTravel() {
    #expect(InferenceEngine.infer(observations: [sample(0)], places: []).first?.kind != .journey)
}

@Test func iconSearchUnderstandsNamesAliasesAndSeveralWords() {
    for query in ["work", "briefcase", "office briefcase", "WORK"] {
        #expect(PlaceIconCatalog.search(query).contains { $0.symbol == "briefcase.fill" })
    }
    #expect(PlaceIconCatalog.search("cafe").contains { $0.title == "Café" })
    #expect(PlaceIconCatalog.search("xyznotaplace").isEmpty)
    #expect(Set(PlaceIconCatalog.icons.map(\.symbol)).count == PlaceIconCatalog.icons.count)
}

@Test func versionTwoRebuildsHistoryAndPreservesRawEvidenceAndCorrections() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try PlacesStore(path: path)
    let observations = [sample(0), sample(90), sample(190), sample(300)]
    try await store.append(observations)
    try await store.correct(UserOverride(start: start.addingTimeInterval(60), end: start.addingTimeInterval(90), kind: .gap))
    try await store.savePlace(Place(name: "Fixture Remote", coordinate: Coordinate(latitude: 1, longitude: 1), expectedSSIDs: ["Fixture Wi-Fi"]))
    var network = try #require(await store.networks().first)
    network.classification = .unclassified
    let legacyNetwork = network
    let queue = try DatabaseQueue(path: path)
    try await queue.write { db in
        // Recreate the old migration boundary, derived cache, and default classification.
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v2-stationary-history'")
        try db.execute(sql: "UPDATE wifiNetworks SET payload = ? WHERE id = ?", arguments: [try JSONEncoder().encode(legacyNetwork), legacyNetwork.id])
        try db.execute(sql: "DELETE FROM timeline")
    }
    let reopened = try PlacesStore(path: path)
    #expect(try await reopened.observations().count == observations.count)
    #expect(try await reopened.networks().first?.classification == .fixed)
    let items = try await reopened.timeline(on: start)
    #expect(items.map(\.kind) == [.stay, .gap, .stay])
    #expect(items[1].isUserEdited)
    #expect(!items.contains { $0.kind == .journey })
}

@Test func sparseUnknownEvidenceKeepsOneGapAndUniqueIdentifiers() async throws {
    let observations = [sample(0), sample(1500), sample(1590), sample(1700)]
    let inferred = InferenceEngine.infer(observations: observations, places: [])
    #expect(Set(inferred.map(\.id)).count == inferred.count)
    #expect(inferred.map(\.kind) == [.gap, .stay])
    let store = try PlacesStore()
    for observation in observations { try await store.append([observation]) }
    #expect(try await store.timeline(on: start).count == 2)
}

@Test func journeyEvidenceGapDoesNotReuseThePendingStopIdentifier() async throws {
    let observations = [sample(0), sample(190), sample(240, metres: 500, speed: 4),
                        sample(2000, metres: 1000), sample(2100, metres: 1005), sample(2200, metres: 1000)]
    let inferred = InferenceEngine.infer(observations: observations, places: [])
    #expect(Set(inferred.map(\.id)).count == inferred.count)
    #expect(inferred.map(\.kind) == [.stay, .gap, .stay])
    let store = try PlacesStore()
    for observation in observations { try await store.append([observation]) }
    #expect(try await store.timeline(on: start).count == 3)
}

@Test func versionTwoMigratesAnUnconfirmedFixAfterALongGap() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try PlacesStore(path: path)
    try await store.append([sample(0), sample(1500)])
    let queue = try DatabaseQueue(path: path)
    try await queue.write { db in
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v2-stationary-history'")
        try db.execute(sql: "DELETE FROM timeline")
    }
    let reopened = try PlacesStore(path: path)
    #expect(try await reopened.observations().count == 2)
    #expect(try await reopened.timeline(on: start).map(\.kind) == [.gap])
}

@Test(arguments: [false, true]) func versionTwoReplacesLegacyEvidenceAndRoutesWithoutOrphans(moving: Bool) async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try PlacesStore(path: path)
    let observations = [sample(0), sample(190), sample(240, metres: moving ? 500 : 0, speed: moving ? 4 : -1),
                        sample(300, metres: moving ? 900 : 0, speed: moving ? 4 : -1)]
    try await store.append(observations)
    let queue = try DatabaseQueue(path: path)
    try await queue.write { db in
        // Model v1's false journey with its real foreign-key children still present.
        // GRDB defers foreign-key checks during migrations, so relying on delete
        // cascades alone would leave these legacy IDs orphaned by the rebuild.
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v2-stationary-history'")
        try db.execute(sql: "DELETE FROM timeline")
        let legacy = TimelineItem(id: "legacy-journey", kind: .journey, start: start,
                                  evidenceIDs: [observations[0].id], lastEvidenceAt: observations[3].timestamp)
        try db.execute(sql: "INSERT INTO timeline(id, start, payload) VALUES (?, ?, ?)",
                       arguments: [legacy.id, start.timeIntervalSince1970, try JSONEncoder().encode(legacy)])
        try db.execute(sql: "INSERT INTO evidenceLinks(timelineID, observationID) VALUES (?, ?)",
                       arguments: [legacy.id, observations[0].id])
        let route = RoutePoint(id: observations[3].id, observationID: observations[3].id, timelineID: legacy.id,
                               timestamp: observations[3].timestamp, coordinate: observations[3].coordinate!, horizontalAccuracy: 30)
        try db.execute(sql: "INSERT INTO routePoints(id, observationID, timelineID, timestamp, payload) VALUES (?, ?, ?, ?, ?)",
                       arguments: [route.id, route.observationID, route.timelineID, route.timestamp.timeIntervalSince1970, try JSONEncoder().encode(route)])
    }
    let reopened = try PlacesStore(path: path)
    #expect(try await reopened.observations().count == observations.count)
    let history = try await reopened.timeline(on: start)
    #expect(history.map(\.kind) == (moving ? [.stay, .journey] : [.stay]))
    let routes = try await reopened.routePoints(from: start, to: start.addingTimeInterval(600))
    #expect(routes.isEmpty == !moving)
    #expect(routes.allSatisfy { point in history.contains { $0.id == point.timelineID && $0.kind == .journey } })
    #expect(try await queue.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").isEmpty })
}
