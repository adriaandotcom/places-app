import Foundation
import Testing
import GRDB
@testable import PlacesCore

private let suggestionAnchor = Coordinate(latitude: 1, longitude: 1)
private let suggestionDate = Date(timeIntervalSince1970: 1_800_000_000)
private func sighting(_ name: String, _ seconds: Double = 0, at coordinate: Coordinate? = suggestionAnchor,
                      bssid: String = "02:00:00:00:00:01") -> SensorObservation {
    SensorObservation(timestamp: suggestionDate.addingTimeInterval(seconds), source: .wifi,
        coordinate: coordinate, horizontalAccuracy: coordinate == nil ? nil : 10, ssid: name, bssid: bssid)
}

@Test func wifiSuggestionsGroupAccessPointsAndExcludeUnrelatedOrUnreliableEvidence() async throws {
    let store = try PlacesStore()
    var stale = sighting("Stale location"); stale.coordinateTimestamp = suggestionDate.addingTimeInterval(-500)
    var inaccurate = sighting("Inaccurate"); inaccurate.horizontalAccuracy = 5_000
    try await store.append([
        sighting("Fixture Guest"), sighting("Fixture Guest", 60, bssid: "02:00:00:00:00:02"),
        sighting("Fixture Garden", 120, at: .init(latitude: 1.01, longitude: 1)),
        sighting("Other city", 180, at: .init(latitude: 2, longitude: 2)),
        sighting("No location", 240, at: nil), stale, inaccurate,
        sighting("Portable", 300), sighting("Ignored", 360)
    ])
    for network in try await store.networks() where ["Portable", "Ignored"].contains(network.ssid) {
        try await store.classifyNetwork(id: network.id, as: network.ssid == "Portable" ? .portable : .ignored)
    }
    let values = try await store.wifiSuggestions(near: suggestionAnchor)
    #expect(values.map(\.ssid) == ["Fixture Garden", "Fixture Guest"])
    #expect(values.last?.lastSeen == suggestionDate.addingTimeInterval(60))
    #expect(values.allSatisfy { !$0.isConnected })
    // Suggestions and adding an expected name must not bind distant or unverified access points.
    try await store.savePlace(Place(name: "Fixture Place", coordinate: suggestionAnchor, expectedSSIDs: ["Fixture Guest"]))
    #expect(try await store.accessPoints().allSatisfy { $0.placeID == nil })
}

@Test func currentConnectionRequiresRelevantFreshEvidenceNotJustTheSameSSID() async throws {
    let store = try PlacesStore()
    try await store.append([sighting("Shared Guest")])
    let local = sighting("Shared Guest", 30, at: nil)
    #expect(try await store.wifiSuggestions(near: suggestionAnchor, connected: local, now: local.timestamp).first?.isConnected == true)
    let far = sighting("Shared Guest", 30, at: .init(latitude: 2, longitude: 2))
    #expect(try await store.wifiSuggestions(near: suggestionAnchor, connected: far, now: far.timestamp).first?.isConnected == false)
    let differentAP = sighting("Shared Guest", 30, at: nil, bssid: "02:00:00:00:00:09")
    #expect(try await store.wifiSuggestions(near: suggestionAnchor, connected: differentAP, now: differentAP.timestamp).first?.isConnected == false)
    #expect(try await store.wifiSuggestions(near: suggestionAnchor, connected: local, now: local.timestamp.addingTimeInterval(61)).first?.isConnected == false)
    let fresh = sighting("New connection", 30)
    #expect(try await store.wifiSuggestions(near: suggestionAnchor, connected: fresh, now: fresh.timestamp).first?.ssid == "New connection")
    #expect(try await store.wifiSuggestions(near: .init(latitude: .nan, longitude: 0)).isEmpty)
}

@Test func learnedWiFiWorksWithoutRecentGPSButManualExpectationsAreNotSightings() async throws {
    let store = try PlacesStore()
    let place = Place(name: "Fixture Place", coordinate: suggestionAnchor, expectedSSIDs: ["Never seen"])
    try await store.savePlace(place)
    try await store.append([sighting("Learned"), sighting("Learned", 3600, at: nil)])
    let current = sighting("Learned", 7200, at: nil)
    let values = try await store.wifiSuggestions(near: suggestionAnchor, connected: current, now: current.timestamp)
    #expect(values.map(\.ssid) == ["Learned"])
    #expect(values.first?.isConnected == true)
    #expect(try await store.wifiSuggestions(near: .init(latitude: 2, longitude: 2), connected: current, now: current.timestamp).isEmpty)
}

@Test func wifiSuggestionSearchHandlesDateLineAndPlaceRadius() async throws {
    let store = try PlacesStore()
    try await store.append([sighting("Across date line", at: .init(latitude: 0, longitude: -179.999)),
                            sighting("Large complex", at: .init(latitude: 1.017, longitude: 1))])
    #expect(try await store.wifiSuggestions(near: .init(latitude: 0, longitude: 179.999)).map(\.ssid) == ["Across date line"])
    #expect(try await store.wifiSuggestions(near: suggestionAnchor).isEmpty)
    #expect(try await store.wifiSuggestions(near: suggestionAnchor, placeRadius: 1000).map(\.ssid) == ["Large complex"])
}

@Test func wifiSuggestionMigrationBackfillsPreservesRawHistoryAndErasesIndex() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try PlacesStore(path: path)
    let observation = sighting("Existing history")
    try await store.append([observation, observation])
    let before = try await store.exportHistory()
    let queue = try DatabaseQueue(path: path)
    try await queue.write { db in
        try db.execute(sql: "DROP TABLE wifiObservationLocations; DELETE FROM grdb_migrations WHERE identifier = 'v5-nearby-wifi-suggestions'")
    }
    let migrated = try PlacesStore(path: path)
    #expect(try await migrated.wifiSuggestions(near: suggestionAnchor).map(\.ssid) == ["Existing history"])
    #expect(try await migrated.exportHistory() == before)
    try await migrated.eraseHistory()
    #expect(try await migrated.wifiSuggestions(near: suggestionAnchor).isEmpty)
    #expect(try await queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM wifiObservationLocations") } == 0)
}
