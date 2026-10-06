import Foundation
import Testing
import GRDB
@testable import PlacesCore

private let epoch = Date(timeIntervalSince1970: 1_735_689_600)
private func at(_ seconds: Double) -> Date { epoch.addingTimeInterval(seconds) }
private let home = Place(id: "fixture-home", name: "Fixture Home", coordinate: .init(latitude: 0, longitude: 0))
private func fix(_ seconds: Double, metres: Double = 0, speed: Double = 0,
                 motion: MotionKind? = nil) -> SensorObservation {
    SensorObservation(id: "fix-\(seconds)", timestamp: at(seconds), source: .location,
        coordinate: .init(latitude: 0, longitude: metres / 111_195), horizontalAccuracy: 15,
        speed: speed, motion: motion, timezoneIdentifier: "UTC")
}
private func entry(_ id: String, _ start: Double, _ end: Double?, kind: TimelineKind = .stay,
                   mode: TransportMode = .unknown) -> TimelineItem {
    TimelineItem(id: id, kind: kind, start: at(start), end: end.map(at),
        placeID: kind == .stay ? home.id : nil, mode: mode, evidenceIDs: [id],
        lastEvidenceAt: at(end ?? start), coordinate: home.coordinate)
}
private func bounce() -> [TimelineItem] {
    [entry("before", 0, 240), entry("blip", 240, 258, kind: .journey, mode: .driving), entry("after", 258, nil)]
}

@Test(arguments: [false, true]) func speedSpikeAtEstablishedStopDoesNotCreateJourney(saved: Bool) {
    let samples = [fix(0), fix(180), fix(240, metres: 11, speed: 6, motion: .automotive),
                   fix(246, metres: 14, motion: .stationary), fix(258, metres: 8), fix(438, metres: 10)]
    let items = InferenceEngine.infer(observations: samples, places: saved ? [home] : [])
    #expect(items.count == 1 && items[0].kind == .stay && items[0].end == nil)
    #expect(Set(items[0].evidenceIDs) == Set(samples.map(\.id)))
}

@Test func singleDistantSpeedSpikeAndStaleDepartureCandidateCannotSplitStay() {
    for samples in [
        [fix(0), fix(180), fix(240, metres: 500, speed: 6, motion: .automotive), fix(250, motion: .stationary)],
        [fix(0), fix(180), fix(240, metres: 150, speed: 2), fix(600, metres: 200, speed: 2), fix(610)],
        [fix(0), fix(180), fix(240, metres: 150, speed: 2), fix(245), fix(260, metres: 200, speed: 2)]
    ] {
        #expect(InferenceEngine.infer(observations: samples, places: [home]).map(\.kind) == [.stay])
    }
}

@Test func genuineShortJourneySurvivesAndBackdatesToFirstDisplacedFix() {
    let destination = Place(id: "fixture-nearby", name: "Fixture Nearby", coordinate: fix(0, metres: 400).coordinate!)
    let samples = [fix(0), fix(180), fix(240, metres: 180, speed: 4, motion: .cycling),
                   fix(255, metres: 300, speed: 4), fix(270, metres: 400, motion: .stationary), fix(450, metres: 400)]
    let items = InferenceEngine.infer(observations: samples, places: [home, destination])
    #expect(items.map(\.kind) == [.stay, .journey, .stay])
    #expect(items[1].start == at(240) && items[1].end == at(270) && items[1].mode == .cycling)
}

@Test func sustainedCyclingWithinLargePlaceEndsWalkingVisit() {
    var park = home; park.radius = 500; park.countsWalksAsVisits = true
    let samples = [fix(0, speed: 1, motion: .walking), fix(180, metres: 100, speed: 1),
                   fix(240, metres: 200, speed: 4, motion: .cycling), fix(255, metres: 300, speed: 4)]
    let items = InferenceEngine.infer(observations: samples, places: [park])
    #expect(items.map(\.kind) == [.stay, .journey])
    #expect(items[0].mode == .walking && items[1].mode == .cycling && items[1].start == at(240))
}

@Test func wifiOnlyStayCanConfirmDepartureWithoutGPSAnchor() {
    let network = WiFiNetwork(id: "fixture-network", ssid: "Fixture Wi-Fi", firstSeen: epoch, lastSeen: epoch)
    let point = WiFiAccessPoint(id: "fixture-ap", networkID: network.id, bssid: "02:00:00:00:00:01", placeID: home.id, lastSeen: epoch)
    let wifi = [0.0, 180].map { SensorObservation(timestamp: at($0), source: .wifi, ssid: network.ssid, bssid: point.bssid) }
    let items = InferenceEngine.infer(observations: wifi + [fix(240, metres: 200, speed: 3, motion: .cycling), fix(255, metres: 300, speed: 3)],
        places: [home], networks: [network], accessPoints: [point])
    #expect(items.map(\.kind) == [.stay, .journey])
    #expect(items[1].start == at(240))
}

@Test func briefSamePlaceDepartureGroupsOnlyWithStationaryFixesAndKeepsSplit() {
    let items = bounce()
    let samples = [fix(240, metres: 10, speed: 6, motion: .automotive), fix(246, metres: 13), fix(258, metres: 8)]
    let grouped = TimelinePresentation.make(items: items, observations: samples, places: [home])
    #expect(grouped.count == 1 && grouped[0].kind == .stay && !grouped[0].recordsRoute)
    #expect(grouped[0].originalItems == items)
    #expect(TimelinePresentation.make(items: grouped, observations: samples, places: [home]) == grouped)
    for boundary in [240.0, 258] {
        #expect(TimelinePresentation.make(items: grouped, observations: samples, places: [home], separatedAt: [at(boundary)]).count == 3)
    }
}

@Test func shortTripsMissingCoverageAndExplicitCorrectionsAreNotHidden() {
    let items = bounce()
    let stationary = [fix(240), fix(258)]
    var edited = items; edited[1].isUserEdited = true
    var different = items; different[2].placeID = "another-place"
    for input in [edited, different] {
        #expect(TimelinePresentation.make(items: input, observations: stationary, places: [home]).count == 3)
    }
    var cached = fix(258); cached.source = .wifi; cached.coordinateTimestamp = at(240)
    var coarse = fix(258); coarse.horizontalAccuracy = 150
    var companion = fix(258); companion.companionDevice = .watch; companion.companionDeviceID = "fixture-watch"
    for samples in [[], [fix(240)], [fix(240), cached], [fix(240), companion], [fix(240), coarse],
                    [fix(240), fix(248, metres: 200), fix(258)],
                    [fix(240, speed: 2), fix(258, speed: 2)],
                    stationary + [SensorObservation(timestamp: at(245), source: .motion, motion: .walking)],
                    stationary + [SensorObservation(timestamp: at(245), source: .paused)]] {
        #expect(TimelinePresentation.make(items: items, observations: samples, places: [home]).count == 3)
    }
}

@Test func oneSecondCorrectionTailJoinsItsOriginalJourneyButRemainsReversible() {
    let original = entry("trip", 0, 300, kind: .journey, mode: .driving)
    for interval in [DateInterval(start: at(0), end: at(299.001)), DateInterval(start: at(0.999), end: at(300))] {
        let edit = UserOverride(start: interval.start, end: interval.end, kind: .journey, mode: .cycling)
        let corrected = InferenceEngine.applying([edit], to: [original])
        let grouped = TimelinePresentation.make(items: corrected, observations: [], places: [])
        #expect(grouped.count == 1 && grouped[0].mode == .cycling && grouped[0].isUserEdited)
        #expect(grouped[0].start == original.start && grouped[0].end == original.end)
        #expect(grouped[0].originalItems == corrected)
        #expect(corrected.first(where: \.isUserEdited)?.start == edit.start)
        #expect(corrected.first(where: \.isUserEdited)?.end == edit.end)
        #expect(TimelinePresentation.make(items: grouped, observations: [], places: []) == grouped)
        #expect(TimelinePresentation.make(items: grouped, observations: [], places: [], separatedAt: [corrected[1].start]).count == 2)
    }
}

@Test func correctionGroupingPreservesDistinctExplicitModesAndLongerRemainders() {
    let original = entry("trip", 0, 300, kind: .journey, mode: .driving)
    let edit = UserOverride(start: at(0), end: at(298), kind: .journey, mode: .cycling)
    let longer = InferenceEngine.applying([edit], to: [original])
    #expect(TimelinePresentation.make(items: longer, observations: [], places: []).count == 2)
    var explicit = InferenceEngine.applying([UserOverride(start: at(0), end: at(299), kind: .journey, mode: .cycling)], to: [original])
    explicit[1].isUserEdited = true
    #expect(TimelinePresentation.make(items: explicit, observations: [], places: []).count == 2)
    explicit[1].isUserEdited = false; explicit[1].evidenceIDs = ["other-trip"]
    #expect(TimelinePresentation.make(items: explicit, observations: [], places: []).count == 2)
    let edits = [UserOverride(start: at(0), end: at(100), kind: .journey, mode: .cycling, createdAt: at(400)),
                 UserOverride(start: at(101), end: at(300), kind: .journey, mode: .ferry, createdAt: at(401))]
    let distinct = TimelinePresentation.make(items: InferenceEngine.applying(edits, to: [original]), observations: [], places: [])
    #expect(distinct.map(\.mode) == [.cycling, .ferry])
    #expect(distinct.last?.start == at(101))
}

@Test func departureMigrationRebuildsFalseJourneyWithoutLosingCorrectionsOrEvidence() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try PlacesStore(path: path)
    try await store.savePlace(home)
    let samples = [fix(0), fix(180), fix(240, metres: 11, speed: 6, motion: .automotive), fix(258, motion: .stationary), fix(438)]
    try await store.append(samples)
    try await store.correct(UserOverride(start: at(40), end: at(60), kind: .gap))
    let before = try await store.exportTestCase()
    let queue = try DatabaseQueue(path: path)
    try await queue.write { db in
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v10-confirmed-departures'")
        try db.execute(sql: "DELETE FROM evidenceLinks; DELETE FROM routePoints; DELETE FROM timeline")
        let legacy = entry("legacy-trip", 240, 258, kind: .journey, mode: .driving)
        try db.execute(sql: "INSERT INTO timeline(id, start, end, payload) VALUES (?, ?, ?, ?)",
            arguments: [legacy.id, legacy.start.timeIntervalSince1970, legacy.end!.timeIntervalSince1970, try JSONEncoder().encode(legacy)])
    }
    let reopened = try PlacesStore(path: path)
    #expect(try await reopened.exportTestCase() == before)
    #expect(try await reopened.observations().count == samples.count)
    #expect(try await reopened.timeline(on: epoch).map(\.kind) == [.stay, .gap, .stay])
    #expect(try await queue.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").isEmpty })
}
