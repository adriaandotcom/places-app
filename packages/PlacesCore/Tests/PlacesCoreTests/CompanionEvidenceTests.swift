import Foundation
import Testing
@testable import PlacesCore

private let base = Date(timeIntervalSince1970: 1_000_000)
private func fix(_ id: String, seconds: Double, device: ObservationDevice? = nil) -> SensorObservation {
    SensorObservation(id: id, timestamp: base.addingTimeInterval(seconds), source: .location,
        coordinate: Coordinate(latitude: 12, longitude: 34), horizontalAccuracy: 20,
        timezoneIdentifier: "GMT", companionDevice: device, companionDeviceID: device.map { $0.rawValue })
}

@Test func phoneWinsNearbyWatchThenMacButRetainsDistantEvidence() {
    let phone = fix("phone", seconds: 0), watch = fix("watch", seconds: 240, device: .watch)
    let mac = fix("mac", seconds: 250, device: .mac), later = fix("later", seconds: 900, device: .mac)
    #expect(CompanionEvidence.selected([later, mac, watch, phone]).map(\.id) == ["phone", "later"])
    #expect(CompanionEvidence.selected([mac, watch]).map(\.id) == ["watch"])
}

@Test func knownPhoneWiFiOutranksMacWithoutGPS() {
    let place = Place(id: "home", name: "Fixture home", coordinate: Coordinate(latitude: 12, longitude: 34))
    let network = WiFiNetwork(id: "network", ssid: "Fixture network", classification: .fixed, firstSeen: base, lastSeen: base)
    let accessPoint = WiFiAccessPoint(id: "ap", networkID: network.id, bssid: "02:00:00:00:00:01", placeID: place.id, lastSeen: base)
    let wifi = SensorObservation(id: "wifi", timestamp: base, source: .wifi, ssid: network.ssid, bssid: accessPoint.bssid)
    let mac = fix("mac", seconds: 60, device: .mac)
    let selected = CompanionEvidence.selected([wifi, mac], places: [place], networks: [network], accessPoints: [accessPoint])
    #expect(selected.map(\.id) == ["wifi"])
}

@Test func changingDeviceDoesNotInventAConnectingJourney() {
    let phone = fix("phone", seconds: 0), phone2 = fix("phone2", seconds: 600)
    var mac = fix("mac", seconds: 3_600, device: .mac)
    mac.coordinate = Coordinate(latitude: 40, longitude: 40); mac.speed = 20
    let timeline = InferenceEngine.infer(observations: [phone, phone2, mac], places: [])
    #expect(!timeline.contains { $0.kind == .journey })
    #expect(timeline.contains { $0.kind == .gap && $0.start == phone2.timestamp })
}

@Test func suppressedCompanionCannotAppearOnThePhoneRoute() async throws {
    let store = try PlacesStore()
    let home = Place(name: "Fixture origin", coordinate: Coordinate(latitude: 12, longitude: 34))
    try await store.savePlace(home)
    var moving = fix("moving", seconds: 180)
    moving.coordinate = Coordinate(latitude: 12, longitude: 34.005); moving.speed = 4
    var later = fix("moving-later", seconds: 240)
    later.coordinate = Coordinate(latitude: 12, longitude: 34.010); later.speed = 4
    var mac = fix("unrelated-mac", seconds: 200, device: .mac)
    mac.coordinate = Coordinate(latitude: 40, longitude: 40)
    try await store.append([fix("home", seconds: 0), fix("home-later", seconds: 60), moving, later, mac])
    let points = try await store.routePoints(from: base, to: base.addingTimeInterval(300))
    #expect(points.contains { $0.observationID == "moving" })
    #expect(!points.contains { $0.observationID == "unrelated-mac" })
    #expect(try await store.observations().count == 5)
}

@Test func legacyObservationsDecodeWithoutACompanionAndKeepDedupKeys() throws {
    let original = fix("phone", seconds: 0)
    let encoded = try JSONEncoder().encode(original)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("companionDevice"))
    let decoded = try JSONDecoder().decode(SensorObservation.self, from: encoded)
    #expect(decoded.companionDevice == nil)
    #expect(decoded.deduplicationKey == original.deduplicationKey)
    var companion = original; companion.companionDevice = .watch; companion.companionDeviceID = "watch"
    #expect(companion.deduplicationKey != original.deduplicationKey)
}

@Test func delayedPhoneEvidenceRebuildsWithoutDeletingCompanionRawDataOrCorrections() async throws {
    let store = try PlacesStore()
    let mac = [fix("mac1", seconds: 0, device: .mac), fix("mac2", seconds: 600, device: .mac)]
    try await store.append(mac)
    try await store.correct(UserOverride(start: base.addingTimeInterval(120), end: base.addingTimeInterval(240), kind: .journey, mode: .walking))
    let phone = [fix("phone1", seconds: 0), fix("phone2", seconds: 600)]
    #expect(try await store.append(phone) == 2)
    #expect(try await store.append(mac) == 0)
    #expect(try await store.observations().count == 4)
    let timeline = try await store.timeline(on: base)
    #expect(timeline.contains { $0.isUserEdited && $0.start == base.addingTimeInterval(120) })
    #expect(!timeline.flatMap(\.evidenceIDs).contains("mac1"))
    #expect(!timeline.flatMap(\.evidenceIDs).contains("mac2"))
    let redacted = String(decoding: try await store.exportTestCase(), as: UTF8.self)
    #expect(!redacted.contains("\"companionDeviceID\":\"mac\""))
    #expect(redacted.contains("device-"))
}
