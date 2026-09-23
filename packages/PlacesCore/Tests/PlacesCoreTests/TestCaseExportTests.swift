import Foundation
import Testing
import GRDB
@testable import PlacesCore

private let testDate = Date(timeIntervalSince1970: 1_711_845_000.125)
private let testCoordinate = Coordinate(latitude: 35.123456, longitude: 150.654321)

@Test func storageFailureCodesNeverIncludeDatabaseContents() {
    let error = DatabaseError(resultCode: .SQLITE_CONSTRAINT_FOREIGNKEY,
                              message: "Example Private Network in a row", sql: "SELECT 'Example Private Home'",
                              arguments: ["Example Private Street"], publicStatementArguments: true)
    #expect(PlacesStore.failureCode(error) == "database-787")
    #expect(PlacesStore.failureCode(CocoaError(.fileReadNoPermission)) == "file-257")
}

private func populatedExportStore(path: String = ":memory:") async throws -> PlacesStore {
    let store = try PlacesStore(path: path)
    let place = Place(id: "private-place-id", name: "Example Private Home", address: "Example Private Street",
                      coordinate: testCoordinate, expectedSSIDs: ["Example Private Network"], createdAt: testDate)
    try await store.savePlace(place)
    try await store.append([
        SensorObservation(id: "private-observation-a", timestamp: testDate, source: .location,
                          coordinate: testCoordinate, horizontalAccuracy: 8, timezoneIdentifier: "Europe/Amsterdam"),
        SensorObservation(id: "private-observation-b", timestamp: testDate.addingTimeInterval(60), source: .wifi,
                          coordinate: testCoordinate, horizontalAccuracy: 8, monitoredPlaceID: place.id,
                          ssid: "Example Private Network", bssid: "02:ab:cd:12:34:56", timezoneIdentifier: "Europe/Amsterdam"),
        SensorObservation(id: "private-observation-c", timestamp: testDate.addingTimeInterval(3_600), source: .location,
                          coordinate: Coordinate(latitude: 35.133456, longitude: 150.654321), horizontalAccuracy: 8,
                          speed: 2, motion: .walking, timezoneIdentifier: "Europe/Amsterdam")
    ])
    try await store.correct(UserOverride(id: "private-correction-id", start: testDate.addingTimeInterval(10),
                                       end: testDate.addingTimeInterval(20), kind: .gap, createdAt: testDate.addingTimeInterval(4_000)))
    try await store.record(TrackingEvent(timestamp: testDate, state: .knownPlace, reason: "private free text",
                                        previousStateDuration: 60, standardLocationActive: false, build: "private-device-build"))
    return store
}

@Test func testCaseExportRedactsIdentifiersAndReplaysCorrectedExpectation() async throws {
    let store = try await populatedExportStore()
    let data = try await store.exportTestCase()
    let text = String(decoding: data, as: UTF8.self)
    for sensitive in ["private-", "Private", "02:ab:cd", "Europe/Amsterdam", "35.123456", "150.654321", "1711845000"] {
        #expect(!text.contains(sensitive))
    }
    let fixture = try InferenceTestCase.decode(data)
    #expect(fixture.formatVersion == 1)
    #expect(fixture.input.observations.count == 3)
    #expect(fixture.input.corrections.count == 1)
    #expect(fixture.expectedTimeline.contains { $0.isUserEdited && $0.kind == .gap })
    #expect(fixture.replay() == fixture.expectedTimeline)
    #expect(fixture.input.places.allSatisfy { $0.address.isEmpty && $0.symbol == "mappin" })
    let observation = fixture.input.observations[1]
    #expect(observation.monitoredPlaceID == fixture.input.places[0].id)
    #expect(observation.ssid == fixture.input.networks[0].ssid)
    #expect(observation.bssid == fixture.input.accessPoints[0].bssid)
    #expect(fixture.input.places[0].expectedSSIDs == [fixture.input.networks[0].ssid])
    #expect(abs(fixture.input.observations[2].timestamp.timeIntervalSince(fixture.input.observations[0].timestamp) - 3_600) < 0.00001)
    #expect(fixture.input.observations.first?.timezoneIdentifier != fixture.input.observations.last?.timezoneIdentifier)
    // Export is repeatable and does not mutate or truncate the source history.
    #expect(try await store.exportTestCase() == data)
    #expect(try await store.places().first?.name == "Example Private Home")
    #expect(try await store.observations().count == 3)
    var changed = fixture
    changed.expectedTimeline[0].kind = .journey
    #expect(changed.replay() != changed.expectedTimeline)
}

@Test func redactionPreservesDistancesAcrossPolesAndDateLine() throws {
    let coordinates = [Coordinate(latitude: 89.9, longitude: 179.9), Coordinate(latitude: 89.9, longitude: -179.9),
                       Coordinate(latitude: -89.9, longitude: -179.9), Coordinate(latitude: 0, longitude: 90)]
    let observations = coordinates.enumerated().map { index, point in
        SensorObservation(id: "sample-\(index)", timestamp: testDate.addingTimeInterval(Double(index) * 60),
                          source: .location, coordinate: point, horizontalAccuracy: 5)
    }
    let archive = HistoryArchive(formatVersion: 1, exportedAt: testDate, places: [], observations: observations,
                                 timeline: [], corrections: [], networks: [], accessPoints: [], routePoints: [], trackingEvents: [])
    let fixture = InferenceTestCase.redacting(archive)
    for i in coordinates.indices {
        let transformed = try #require(fixture.input.observations[i].coordinate)
        #expect(transformed.isValid)
        for j in coordinates.indices {
            let other = try #require(fixture.input.observations[j].coordinate)
            #expect(abs(transformed.distance(to: other) - coordinates[i].distance(to: coordinates[j])) < 0.001)
        }
    }
}

@Test func testCaseRetainsSharedAndPortableWiFiRelationships() async throws {
    let store = try await populatedExportStore()
    let network = try #require(await store.networks().first)
    for classification in [WiFiClassification.shared, .portable, .ignored] {
        try await store.classifyNetwork(id: network.id, as: classification)
        let fixture = try InferenceTestCase.decode(await store.exportTestCase())
        #expect(fixture.input.networks[0].classification == classification)
        #expect(fixture.input.networks[0].userClassified)
        #expect(fixture.replay() == fixture.expectedTimeline)
    }
}

@Test func resetRemovesDataAndPreferencesAcrossReopen() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("test.sqlite").path
    let store = try await populatedExportStore(path: path)
    for key in ["mapsEnabled", "mapsChoiceMade", "onboardingComplete", "nerdMode", "trackingEnabled"] {
        try await store.setSetting(key, value: "true")
    }
    try await store.eraseHistory(resetSettings: true)
    let reopened = try PlacesStore(path: path)
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let empty = try decoder.decode(HistoryArchive.self, from: await reopened.exportHistory())
    #expect(empty.observations.isEmpty && empty.places.isEmpty && empty.timeline.isEmpty && empty.corrections.isEmpty)
    #expect(empty.networks.isEmpty && empty.accessPoints.isEmpty && empty.routePoints.isEmpty && empty.trackingEvents.isEmpty)
    #expect(try await reopened.search("Example").isEmpty)
    for key in ["mapsEnabled", "mapsChoiceMade", "onboardingComplete", "nerdMode"] {
        #expect(try await reopened.setting(key) == nil)
    }
    #expect(try await reopened.setting("trackingEnabled") == "false")
    let fixture = try InferenceTestCase.decode(await reopened.exportTestCase())
    #expect(fixture.input.observations.isEmpty && fixture.replay().isEmpty && fixture.expectedTimeline.isEmpty)
}
