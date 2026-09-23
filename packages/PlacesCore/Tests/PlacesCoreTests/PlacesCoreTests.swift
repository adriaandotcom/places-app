import Foundation
import Testing
@testable import PlacesCore

private let epoch = Date(timeIntervalSince1970: 1_735_689_600)
private let origin = Coordinate(latitude: 0, longitude: 0)
private func fix(_ seconds: Double, coordinate: Coordinate = origin, speed: Double = 0) -> SensorObservation {
    SensorObservation(timestamp: epoch.addingTimeInterval(seconds), source: .location, coordinate: coordinate,
                horizontalAccuracy: 10, speed: speed, timezoneIdentifier: "UTC")
}
private func home() -> Place { Place(id: "fixture-home", name: "Fixture Home", coordinate: origin) }
private func wifi(_ seconds: Double, ssid: String = "Fixture Network", bssid: String = "02:00:00:00:00:01",
                  coordinate: Coordinate = origin) -> SensorObservation {
    SensorObservation(timestamp: epoch.addingTimeInterval(seconds), source: .wifi, coordinate: coordinate,
                horizontalAccuracy: 10, ssid: ssid, bssid: bssid)
}

@Test func duplicateCallbacksKeepOneRawObservation() async throws {
    let store = try PlacesStore()
    let a = fix(0), b = fix(0)
    #expect(a.id != b.id)
    #expect(try await store.append([a, b]) == 1)
    #expect(try await store.observations().count == 1)
}

@Test func knownPlaceToJourneyToPlace() {
    let destination = Place(id: "fixture-stop", name: "Fixture Stop", coordinate: Coordinate(latitude: 0, longitude: 0.02))
    let items = InferenceEngine.infer(observations: [fix(0), fix(60), fix(180, coordinate: Coordinate(latitude: 0, longitude: 0.005), speed: 4),
        fix(300, coordinate: destination.coordinate)], places: [home(), destination])
    #expect(items.map(\.kind) == [.stay, .journey, .stay])
    #expect(items.first?.placeID == home().id)
    #expect(items.last?.placeID == destination.id)
}

@Test func recoveryDoesNotInventContinuityOrShutdownReason() {
    let items = InferenceEngine.infer(observations: [fix(0), fix(60),
        SensorObservation(timestamp: epoch.addingTimeInterval(3600), source: .recovery), fix(3610)], places: [home()])
    let gap = items.first { $0.kind == .gap }
    #expect(gap?.start == epoch.addingTimeInterval(60))
    #expect(gap?.end == epoch.addingTimeInterval(3610))
    #expect(gap?.reasons.joined().contains("off") == false)
}

@Test func missingMovingEvidenceMakesGap() {
    let items = InferenceEngine.infer(observations: [fix(0, speed: 4), fix(60, speed: 4), fix(2000, speed: 4)], places: [])
    #expect(items.contains { $0.kind == .gap && $0.start == epoch.addingTimeInterval(60) && $0.end == epoch.addingTimeInterval(2000) })
}

@Test func stationaryClusterBecomesUnnamedStay() {
    let items = InferenceEngine.infer(observations: [fix(0), fix(90), fix(190)], places: [])
    #expect(items.count == 1)
    #expect(items.first?.kind == .stay)
    #expect(items.first?.placeID == nil)
}

@Test func unrelatedRegionExitDoesNotEndKnownStay() {
    let values = [fix(0), SensorObservation(timestamp: epoch.addingTimeInterval(30), source: .regionExit,
        monitoredPlaceID: "fixture-neighbour"), fix(60),
        SensorObservation(timestamp: epoch.addingTimeInterval(90), source: .regionExit, monitoredPlaceID: home().id)]
    let items = InferenceEngine.infer(observations: values, places: [home()])
    #expect(items.map(\.kind) == [.stay, .journey])
    #expect(items.first?.end == epoch.addingTimeInterval(90))
}

@Test func incrementalInferenceRetainsMotionBeforeJourneyBoundary() async throws {
    let store = try PlacesStore(); try await store.savePlace(home())
    var values = [fix(0), SensorObservation(timestamp: epoch.addingTimeInterval(60), source: .motion, motion: .cycling)]
    values += [120.0, 600, 1200, 1800, 2400].map { fix($0, coordinate: Coordinate(latitude: 0, longitude: 0.02), speed: 4) }
    for value in values { try await store.append([value]) }
    let inferred = try await store.timeline(on: epoch, calendar: utcCalendar())
    #expect(inferred.first { $0.kind == .journey }?.mode == .cycling)
}

@Test func portableLearningReevaluatesEarlierAmbiguousWiFiEvidence() async throws {
    let store = try PlacesStore()
    let neighbour = Place(name: "Fixture Neighbour", coordinate: Coordinate(latitude: 0, longitude: 0.0015))
    let destination = Place(name: "Fixture Destination", coordinate: Coordinate(latitude: 0, longitude: 0.02))
    for place in [home(), neighbour, destination] { try await store.savePlace(place) }
    let values = [wifi(0), wifi(10, coordinate: Coordinate(latitude: 0, longitude: 0.00075)),
                  fix(300, coordinate: destination.coordinate)]
    try await store.append(values)
    try await store.append([wifi(4000, coordinate: Coordinate(latitude: 1, longitude: 1))])
    let items = try await store.timeline(on: epoch, calendar: utcCalendar())
    #expect(try await store.networks().first?.classification == .portable)
    #expect(items.first?.end == epoch.addingTimeInterval(10))
}

private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!; return calendar
}

@Test func staleOrCoarseEvidenceDoesNotNamePlace() {
    var coarse = fix(0); coarse.horizontalAccuracy = 500
    var stale = wifi(600); stale.coordinateTimestamp = epoch
    #expect(TrackingPolicy.matchingPlace(for: coarse, places: [home()]) == nil)
    #expect(TrackingPolicy.matchingPlace(for: stale, places: [home()]) == nil)
    let overlap = Place(name: "Fixture Neighbour", coordinate: Coordinate(latitude: 0, longitude: 0.0001))
    #expect(TrackingPolicy.matchingPlace(for: fix(0), places: [home(), overlap]) == nil)
}

@Test func manyNetworksAndAccessPointsCanBelongToOnePlace() async throws {
    let store = try PlacesStore(); try await store.savePlace(home())
    try await store.append([wifi(1), wifi(2, bssid: "02:00:00:00:00:02"), wifi(3, ssid: "Fixture Guest")])
    #expect(try await store.networks().count == 2)
    let points = try await store.accessPoints()
    #expect(points.count == 3)
    #expect(points.allSatisfy { $0.placeID == home().id })
}

@Test func sameSSIDAtDistantPlacesBecomesShared() async throws {
    let store = try PlacesStore(); try await store.savePlace(home())
    let far = Place(name: "Fixture Branch", coordinate: Coordinate(latitude: 1, longitude: 1))
    try await store.savePlace(far)
    try await store.append([wifi(1), wifi(2, bssid: "02:00:00:00:00:02", coordinate: far.coordinate)])
    #expect(try await store.networks().first?.classification == .shared)
    #expect(Set(try await store.accessPoints().compactMap(\.placeID)).count == 2)
}

@Test func movingAccessPointBecomesPortable() async throws {
    let store = try PlacesStore(); try await store.savePlace(home())
    try await store.append([wifi(1), wifi(2, coordinate: Coordinate(latitude: 1, longitude: 1))])
    #expect(try await store.networks().first?.classification == .portable)
}

@Test(arguments: [WiFiClassification.portable, .ignored])
func explicitClassificationsSurviveLearning(classification: WiFiClassification) async throws {
    let store = try PlacesStore(); try await store.savePlace(home()); try await store.append([wifi(1)])
    let id = try #require(await store.networks().first?.id)
    try await store.classifyNetwork(id: id, as: classification)
    try await store.append([wifi(2, bssid: "02:00:00:00:00:02")])
    #expect(try await store.networks().first?.classification == classification)
    #expect(try await store.accessPoints().first { $0.bssid == "02:00:00:00:00:02" }?.placeID == nil)
}

@Test func portableNetworkNeverResolvesOverlappingPlaces() {
    let a = home(), b = Place(name: "Fixture Neighbour", coordinate: Coordinate(latitude: 0, longitude: 0.0001))
    let net = WiFiNetwork(id: "fixture-net", ssid: "Fixture Network", classification: .portable, userClassified: true, firstSeen: epoch, lastSeen: epoch)
    let ap = WiFiAccessPoint(id: "fixture-ap", networkID: net.id, bssid: "02:00:00:00:00:01", placeID: a.id, lastSeen: epoch)
    let items = InferenceEngine.infer(observations: [wifi(0)], places: [a, b], networks: [net], accessPoints: [ap])
    #expect(items.allSatisfy { $0.placeID == nil })
}

@Test func correctionsSurviveNewEvidenceAndReopen() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try PlacesStore(path: path); try await store.savePlace(home())
    try await store.append([fix(0), fix(100)])
    try await store.correct(UserOverride(start: epoch, end: epoch.addingTimeInterval(100), kind: .gap))
    try await store.append([fix(200)])
    let reopened = try PlacesStore(path: path)
    let items = try await reopened.timeline(on: epoch)
    #expect(items.first?.kind == .gap)
    #expect(items.first?.isUserEdited == true)
    #expect(try await reopened.observations().count == 3)
    #expect(try await reopened.places().count == 1)
}

@Test func mostRecentCorrectionWinsOnlyItsInterval() {
    let item = TimelineItem(id: "fixture", kind: .stay, start: epoch, end: epoch.addingTimeInterval(100), lastEvidenceAt: epoch)
    let a = UserOverride(start: epoch, end: epoch.addingTimeInterval(100), kind: .gap, createdAt: epoch)
    let b = UserOverride(start: epoch.addingTimeInterval(20), end: epoch.addingTimeInterval(40), kind: .journey, mode: .walking, createdAt: epoch.addingTimeInterval(1))
    let output = InferenceEngine.applying([a, b], to: [item])
    #expect(output.map(\.kind) == [.gap, .journey, .gap])
    #expect(output.reduce(0) { $0 + $1.duration() } == 100)
}

@Test func incrementalRebuildMatchesFullInference() async throws {
    let store = try PlacesStore(); try await store.savePlace(home())
    let samples = [fix(0), fix(60), fix(400, coordinate: Coordinate(latitude: 0, longitude: 0.01), speed: 4),
                   fix(1000, coordinate: Coordinate(latitude: 0, longitude: 0.02), speed: 4), fix(2400), fix(3600)]
    for sample in samples { try await store.append([sample]) }
    let expected = InferenceEngine.infer(observations: samples, places: [home()])
    #expect(try await store.timeline(on: epoch) == InferenceEngine.onDay(epoch, items: expected))
}

@Test func localSearchHandlesAccentsAndQuerySyntax() async throws {
    let store = try PlacesStore()
    try await store.savePlace(Place(name: "Fixture Café", address: "Sample Street, Test Town", coordinate: origin))
    #expect(try await store.search("cafe").count == 1)
    #expect(try await store.search("Test Town").count == 1)
    #expect(try await store.search("\"* OR NEAR(foo)").isEmpty)
    #expect(try await store.search("***").isEmpty)
}

@Test func dayClippingRespectsDSTAndMidnight() throws {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = try #require(TimeZone(identifier: "Europe/Amsterdam"))
    let day = try #require(calendar.date(from: DateComponents(year: 2025, month: 3, day: 30)))
    let interval = try #require(calendar.dateInterval(of: .day, for: day))
    #expect(interval.duration == 23 * 3600)
    let item = TimelineItem(id: "fixture", kind: .stay, start: day.addingTimeInterval(-3600), end: interval.end.addingTimeInterval(3600), lastEvidenceAt: day)
    let clipped = InferenceEngine.onDay(day, calendar: calendar, items: [item])
    #expect(clipped.first?.duration() == 82_800.0)
    #expect(clipped.first?.start == interval.start)
}

@Test func pausedTrackingLeavesExplicitGap() {
    let items = InferenceEngine.infer(observations: [fix(0), SensorObservation(timestamp: epoch.addingTimeInterval(50), source: .paused),
        SensorObservation(timestamp: epoch.addingTimeInterval(100), source: .resumed), fix(110)], places: [home()])
    #expect(items.map(\.kind) == [.stay, .gap, .stay])
    #expect(items[1].start == epoch.addingTimeInterval(50))
    #expect(items[1].end == epoch.addingTimeInterval(110))
}

@Test func stationaryAndLowPowerStatesStopStandardUpdates() {
    for state in [TrackingState.knownPlace, .stationaryUnknown, .lowPowerFallback, .paused] {
        #expect(!TrackingPolicy.sensors(state: state, motion: .stationary, lowPower: false).standardUpdates)
    }
    #expect(TrackingPolicy.sensors(state: .moving, motion: .cycling, lowPower: true).distanceFilter == 150)
}

@Test func exportAndDeletionCoverAllSensitiveTables() async throws {
    let store = try PlacesStore(); try await store.savePlace(home())
    try await store.append([fix(0), wifi(1)])
    try await store.correct(UserOverride(start: epoch, end: epoch.addingTimeInterval(1), kind: .gap))
    try await store.setSetting("mapsEnabled", value: "false")
    let diagnostic = try await store.exportDiagnostics()
    let diagnosticText = String(decoding: diagnostic, as: UTF8.self)
    #expect(!diagnosticText.contains("Fixture"))
    #expect(!diagnosticText.contains("02:00"))
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let archive = try decoder.decode(HistoryArchive.self, from: await store.exportHistory())
    #expect(archive.observations.count == 2)
    #expect(archive.corrections.count == 1)
    try await store.eraseHistory()
    let empty = try decoder.decode(HistoryArchive.self, from: await store.exportHistory())
    #expect(empty.observations.isEmpty && empty.places.isEmpty && empty.networks.isEmpty && empty.accessPoints.isEmpty)
    #expect(empty.timeline.isEmpty && empty.corrections.isEmpty && empty.routePoints.isEmpty && empty.trackingEvents.isEmpty)
    #expect(try await store.setting("mapsEnabled") == "false")
}
