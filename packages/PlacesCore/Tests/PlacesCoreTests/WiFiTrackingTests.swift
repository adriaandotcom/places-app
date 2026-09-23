import Foundation
import Testing
import GRDB
@testable import PlacesCore

private let wifiEpoch = Date(timeIntervalSince1970: 1_735_732_800)
private let wifiHome = Place(id: "wifi-home", name: "Fixture Home", coordinate: .init(latitude: 1, longitude: 1))
private let wifiNetwork = WiFiNetwork(id: "wifi-network", ssid: "Fixture Network", firstSeen: wifiEpoch, lastSeen: wifiEpoch)
private let wifiAP = WiFiAccessPoint(id: "wifi-ap", networkID: wifiNetwork.id, bssid: "02:00:00:00:00:ab", placeID: wifiHome.id, lastSeen: wifiEpoch)
private func connection(_ seconds: Double = 0) -> SensorObservation {
    SensorObservation(timestamp: wifiEpoch.addingTimeInterval(seconds), source: .wifi,
                      ssid: wifiNetwork.ssid, bssid: wifiAP.bssid)
}

@Test func learnedConnectionNamesPlaceWithoutFabricatingGPS() {
    let observation = connection()
    let place = TrackingPolicy.connectedPlace(for: observation, places: [wifiHome], networks: [wifiNetwork], accessPoints: [wifiAP])
    #expect(place?.id == wifiHome.id)
    #expect(observation.coordinate == nil)
    #expect(!TrackingPolicy.sensors(state: .knownWiFi, motion: .walking, lowPower: false).standardUpdates)
    let history = InferenceEngine.infer(observations: [observation, connection(3600)], places: [wifiHome], networks: [wifiNetwork], accessPoints: [wifiAP])
    #expect(history.count == 1 && history[0].kind == .stay && history[0].placeID == wifiHome.id)
    #expect(history[0].lastEvidenceAt == wifiEpoch.addingTimeInterval(3600))
    #expect(history[0].coordinate == wifiHome.coordinate)
}

@Test func wifiRequiresLearnedBSSIDAndEligibleClassification() {
    for classification in [WiFiClassification.portable, .ignored, .unclassified] {
        var network = wifiNetwork; network.classification = classification
        #expect(TrackingPolicy.connectedPlace(for: connection(), places: [wifiHome], networks: [network], accessPoints: [wifiAP]) == nil)
    }
    for bssid in [nil, "", "02:00:00:00:00:99"] {
        var observation = connection(); observation.bssid = bssid
        #expect(TrackingPolicy.connectedPlace(for: observation, places: [wifiHome], networks: [wifiNetwork], accessPoints: [wifiAP]) == nil)
    }
    #expect(TrackingPolicy.connectedPlace(for: connection(), places: [], networks: [wifiNetwork], accessPoints: [wifiAP]) == nil)
    var observation = connection(); observation.bssid = wifiAP.bssid.uppercased()
    #expect(TrackingPolicy.connectedPlace(for: observation, places: [wifiHome], networks: [wifiNetwork], accessPoints: [wifiAP])?.id == wifiHome.id)
}

@Test func sharedSSIDResolvesOnlyItsSpecificAccessPointAndSupportsRoaming() {
    let other = Place(id: "wifi-other", name: "Fixture Branch", coordinate: .init(latitude: 2, longitude: 2))
    var network = wifiNetwork; network.classification = .shared
    var second = wifiAP; second.id = "second"; second.bssid = "02:00:00:00:00:02"
    var branch = second; branch.id = "branch"; branch.bssid = "02:00:00:00:00:03"; branch.placeID = other.id
    for point in [wifiAP, second, branch] {
        var observation = connection(); observation.bssid = point.bssid
        #expect(TrackingPolicy.connectedPlace(for: observation, places: [wifiHome, other], networks: [network], accessPoints: [wifiAP, second, branch])?.id == point.placeID)
    }
    var conflicting = wifiAP; conflicting.placeID = other.id
    #expect(TrackingPolicy.connectedPlace(for: connection(), places: [wifiHome, other], networks: [network], accessPoints: [wifiAP, conflicting]) == nil)
}

@Test func currentContradictoryFixOverridesWiFiButOldCoordinatesAreNotReused() {
    var observation = connection(3600)
    observation.coordinate = .init(latitude: 2, longitude: 2); observation.horizontalAccuracy = 10
    observation.coordinateTimestamp = observation.timestamp
    #expect(TrackingPolicy.connectedPlace(for: observation, places: [wifiHome], networks: [wifiNetwork], accessPoints: [wifiAP]) == nil)
    observation.coordinateTimestamp = wifiEpoch
    #expect(TrackingPolicy.connectedPlace(for: observation, places: [wifiHome], networks: [wifiNetwork], accessPoints: [wifiAP])?.id == wifiHome.id)
    #expect(observation.usableCoordinate == nil)
}

@Test func losingWiFiDoesNotInventDepartureAndGPSCanEstablishTravel() {
    let missing = SensorObservation(timestamp: wifiEpoch.addingTimeInterval(100), source: .wifi)
    let stopped = InferenceEngine.infer(observations: [connection(), missing], places: [wifiHome], networks: [wifiNetwork], accessPoints: [wifiAP])
    #expect(stopped.count == 1 && stopped[0].kind == .stay)
    #expect(stopped[0].lastEvidenceAt == wifiEpoch)
    let moving = SensorObservation(timestamp: wifiEpoch.addingTimeInterval(150), source: .location,
        coordinate: .init(latitude: 1, longitude: 1.01), horizontalAccuracy: 10, speed: 4)
    let journey = InferenceEngine.infer(observations: [connection(), missing, moving], places: [wifiHome], networks: [wifiNetwork], accessPoints: [wifiAP])
    #expect(journey.map(\.kind) == [.stay, .journey])
}

@Test func wifiOnlyEvidencePersistsReplaysAndDoesNotBecomeRoutePoints() async throws {
    let store = try PlacesStore(); try await store.savePlace(wifiHome)
    var first = connection(); first.coordinate = wifiHome.coordinate; first.coordinateTimestamp = first.timestamp; first.horizontalAccuracy = 10
    try await store.append([first, connection(3600)])
    let observations = try await store.observations()
    #expect(observations.count == 2 && observations.first?.coordinate == nil)
    #expect(try await store.routePoints(from: wifiEpoch, to: wifiEpoch.addingTimeInterval(4000)).isEmpty)
    let fixture = try InferenceTestCase.decode(await store.exportTestCase())
    #expect(fixture.replay() == fixture.expectedTimeline)
    #expect(fixture.expectedTimeline.count == 1)
}

@Test func wifiMigrationPreservesEvidenceCorrectionsAndSplitPreferences() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try PlacesStore(path: path); try await store.savePlace(wifiHome)
    var first = connection(); first.coordinate = wifiHome.coordinate; first.coordinateTimestamp = first.timestamp; first.horizontalAccuracy = 10
    try await store.append([first, connection(3600)])
    try await store.correct(UserOverride(start: wifiEpoch.addingTimeInterval(60), end: wifiEpoch.addingTimeInterval(90), kind: .gap))
    let queue = try DatabaseQueue(path: path)
    try await queue.write { db in
        try db.execute(sql: "INSERT INTO timelineSeparations(timestamp) VALUES (?); DELETE FROM grdb_migrations WHERE identifier = 'v4-connected-wifi-evidence'", arguments: [wifiEpoch.timeIntervalSince1970 + 60])
    }
    let reopened = try PlacesStore(path: path)
    let fixture = try InferenceTestCase.decode(await reopened.exportTestCase())
    #expect(fixture.replay() == fixture.expectedTimeline)
    #expect(fixture.input.observations.count == 2 && fixture.input.corrections.count == 1)
    #expect(fixture.input.separatedAt?.count == 1)
}
