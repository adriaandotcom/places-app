import Foundation
import Testing
import GRDB
@testable import PlacesCore

private let visitEpoch = Date(timeIntervalSince1970: 1_735_689_600)
private func visitFix(_ seconds: Double, metres: Double = 0, speed: Double = 0,
                      motion: MotionKind? = nil, accuracy: Double = 10) -> SensorObservation {
    SensorObservation(timestamp: visitEpoch.addingTimeInterval(seconds), source: .location,
        coordinate: .init(latitude: 0, longitude: metres / 111_195), horizontalAccuracy: accuracy,
        speed: speed, motion: motion, timezoneIdentifier: "UTC")
}
private func visitPlace(walks: Bool = false) -> Place {
    var place = Place(id: "fixture-park", name: "Fixture Park", coordinate: .init(latitude: 0, longitude: 0), radius: 500)
    place.countsWalksAsVisits = walks ? true : nil
    return place
}

@Suite struct VisitPolicyTests {
@Test(arguments: [MotionKind.walking, .cycling, .automotive])
func passingSavedPlaceDoesNotBecomeVisit(motion: MotionKind) {
    let fixes = [visitFix(0, metres: -800, speed: 5, motion: motion), visitFix(60, metres: -400, speed: 5),
                 visitFix(120, metres: 0, speed: 5), visitFix(180, metres: 400, speed: 5), visitFix(240, metres: 800, speed: 5)]
    let items = InferenceEngine.infer(observations: fixes, places: [visitPlace()])
    #expect(!items.contains { $0.kind == .stay })
    #expect(items.contains { $0.kind == .journey })
    #expect(items.first?.kind == .journey && items.first?.start == visitEpoch)
}

@Test func confirmedPlaceSurvivesOneSlightlyDisplacedFix() {
    var place = visitPlace(); place.radius = 30
    let items = InferenceEngine.infer(observations: [visitFix(0), visitFix(180), visitFix(210, metres: 40)], places: [place])
    #expect(items.count == 1 && items.first?.placeID == place.id)
}

@Test func knownAndUnknownStopsRequireThreeMinutesAndBackdateArrival() {
    for places in [[], [visitPlace()]] {
        let samples = [visitFix(0), visitFix(90, metres: 4), visitFix(179, metres: -3)]
        #expect(!InferenceEngine.infer(observations: samples, places: places).contains { $0.kind == .stay })
        let items = InferenceEngine.infer(observations: samples + [visitFix(180)], places: places)
        #expect(items.count == 1)
        #expect(items.first?.kind == .stay)
        #expect(items.first?.start == visitEpoch)
        #expect(items.first?.placeID == places.first?.id)
    }
}

@Test func MovementAndLongSilenceResetStopConfirmation() {
    var check = VisitConfirmation()
    check.observe(visitFix(0), place: nil, motion: .stationary)
    check.motionChanged(.walking)
    #expect(check.observe(visitFix(180), place: nil, motion: .stationary) == nil)
    #expect(check.observe(visitFix(360), place: nil, motion: .stationary) != nil)
    let items = InferenceEngine.infer(observations: [visitFix(0), visitFix(600)], places: [visitPlace()])
    #expect(!items.contains { $0.kind == .stay })
}

@Test func PoorAccuracyAndSlowProgressCannotEstablishStop() {
    for motion in [MotionKind.walking, .unknown] {
        let samples = stride(from: 0, through: 180, by: 60).map {
            visitFix(Double($0), metres: Double($0) * 0.75, motion: motion, accuracy: 80)
        }
        #expect(!InferenceEngine.infer(observations: samples, places: []).contains { $0.kind == .stay })
    }
}

@Test func walkingOptInRequiresThreeMinutesAndKeepsItsRoute() async throws {
    let samples = stride(from: 0, through: 240, by: 60).map { visitFix(Double($0), metres: Double($0), speed: 1, motion: .walking) }
    #expect(!InferenceEngine.infer(observations: Array(samples.prefix(3)), places: [visitPlace(walks: true)]).contains { $0.kind == .stay })
    #expect(!InferenceEngine.infer(observations: samples, places: [visitPlace()]).contains { $0.kind == .stay })
    let store = try PlacesStore()
    try await store.savePlace(visitPlace(walks: true))
    for sample in samples { try await store.append([sample]) }
    let items = try await store.timeline(on: visitEpoch)
    #expect(items.count == 1)
    #expect(items.first?.kind == .stay && items.first?.mode == .walking)
    #expect(items.first?.start == visitEpoch)
    #expect(try await store.routePoints(from: visitEpoch, to: visitEpoch.addingTimeInterval(240)).count == samples.count)
    let exported = try InferenceTestCase.decode(await store.exportTestCase())
    #expect(exported.input.places.first?.countsWalksAsVisits == true)
    #expect(exported.replay() == exported.expectedTimeline)
}

@Test func cyclingAndUnknownActivityNeverUseWalkingOptIn() {
    for motion in [MotionKind.cycling, .automotive, .unknown] {
        let samples = stride(from: 0, through: 600, by: 60).map { visitFix(Double($0), metres: Double($0) / 2, speed: 1, motion: motion) }
        #expect(!InferenceEngine.infer(observations: samples, places: [visitPlace(walks: true)]).contains { $0.kind == .stay })
    }
}

@Test func stoppingAfterCyclingStartsNewDwellInterval() {
    let values = [visitFix(0, metres: -300, speed: 5, motion: .cycling), visitFix(60, speed: 5),
                  visitFix(120, motion: .stationary), visitFix(210), visitFix(300)]
    let stay = InferenceEngine.infer(observations: values, places: [visitPlace(walks: true)]).first { $0.kind == .stay }
    #expect(stay?.start == visitEpoch.addingTimeInterval(120))
}

@Test func redLightRetainsVehicleContext() {
    #expect(VisitConfirmation.motion(stationary: true, walking: false, running: false, cycling: false, automotive: true) == .automotive)
    let samples = [visitFix(0, motion: .automotive), visitFix(90), visitFix(180)]
    #expect(!InferenceEngine.infer(observations: samples, places: [visitPlace()]).contains { $0.kind == .stay })
}

@Test func freshWiFiNeedsDwellAndCachedCoordinatesDoNotAdvanceClock() {
    let place = visitPlace()
    var check = VisitConfirmation()
    let first = SensorObservation(timestamp: visitEpoch, source: .wifi, ssid: "Fixture Network", bssid: "02:00:00:00:00:01")
    #expect(check.observe(first, place: place, connectedPlace: place, motion: .unknown) == nil)
    var later = first; later.timestamp = visitEpoch.addingTimeInterval(179)
    #expect(check.observe(later, place: place, connectedPlace: place, motion: .unknown) == nil)
    later.timestamp = visitEpoch.addingTimeInterval(180)
    #expect(check.observe(later, place: place, connectedPlace: place, motion: .unknown) != nil)
    check.reset()
    check.observe(visitFix(0), place: nil, motion: .unknown)
    var cached = visitFix(90); cached.coordinateTimestamp = visitEpoch
    #expect(check.observe(cached, place: nil, motion: .unknown) == nil)
    #expect(check.candidate?.lastMeasuredAt == visitEpoch)
}

@Test func duplicateConfirmedFixKeepsStopAndFastWalkingSignalDoesNotConfirmPark() {
    var check = VisitConfirmation()
    check.observe(visitFix(0), place: nil, motion: .stationary)
    let confirmed = visitFix(180)
    #expect(check.observe(confirmed, place: nil, motion: .stationary) != nil)
    #expect(check.observe(confirmed, place: nil, motion: .stationary) != nil)
    check.reset()
    for second in [0.0, 90, 180] {
        #expect(check.observe(visitFix(second, speed: 6), place: visitPlace(walks: true), motion: .walking) == nil)
    }
    #expect(check.candidate == nil)
}

@Test func stopConfirmationDoesNotDependOnPlaceMembershipAtAnEdge() {
    var check = VisitConfirmation()
    check.observe(visitFix(0), place: nil, motion: .unknown)
    check.observe(visitFix(90, metres: 10), place: visitPlace(), motion: .unknown)
    let confirmed = check.observe(visitFix(180, metres: 5), place: visitPlace(), motion: .unknown)
    #expect(confirmed?.first.timestamp == visitEpoch)
    #expect(confirmed?.placeID == visitPlace().id)
}

@Test func connectedWiFiDoesNotInterruptOrConfirmAnInProgressWalk() {
    let place = visitPlace(walks: true)
    var check = VisitConfirmation()
    check.observe(visitFix(0, speed: 1), place: place, motion: .walking)
    let wifi = SensorObservation(timestamp: visitEpoch.addingTimeInterval(180), source: .wifi)
    #expect(check.observe(wifi, place: place, connectedPlace: place, motion: .walking) == nil)
    #expect(check.candidate?.first.timestamp == visitEpoch)
    #expect(check.observe(visitFix(180, metres: 180, speed: 1), place: place, motion: .walking)?.confirmed == true)
}

@Test func shortSystemVisitsDoNotBypassDwellAndReportedLongVisitsStillWork() {
    var arrival = visitFix(0)
    arrival.source = .visitArrival
    for duration in [60.0, 179, 180, 600] {
        arrival.systemVisitDuration = duration
        let items = InferenceEngine.infer(observations: [arrival], places: [visitPlace()])
        #expect(items.contains { $0.kind == .stay } == (duration >= 180))
    }
}

@Test func completedSystemVisitExtendsAnEarlierShortArrivalReport() async throws {
    let store = try PlacesStore()
    var arrival = visitFix(0); arrival.source = .visitArrival; arrival.systemVisitDuration = 60
    try await store.append([arrival])
    #expect(try await store.timeline(on: visitEpoch).allSatisfy { $0.kind != .stay })
    // Core Location can report arrival once more when departure becomes known.
    // The duplicate arrival is deduplicated; its departure must still confirm it.
    var repeated = arrival; repeated.id = UUID().uuidString; repeated.systemVisitDuration = 600
    var departure = visitFix(600); departure.source = .visitDeparture
    try await store.append([repeated, departure])
    let stay = try #require(try await store.timeline(on: visitEpoch).first { $0.kind == .stay })
    #expect(stay.start == visitEpoch && stay.end == departure.timestamp)
    #expect(try await store.observations().count == 2)
}

@Test func oldPlacesDefaultToStationaryAndWalkChoiceRoundTrips() throws {
    let data = try JSONEncoder().encode(visitPlace())
    #expect(try JSONDecoder().decode(Place.self, from: data).countsWalksAsVisits != true)
    let enabled = try JSONEncoder().encode(visitPlace(walks: true))
    #expect(try JSONDecoder().decode(Place.self, from: enabled).countsWalksAsVisits == true)
}

@Test func passingThroughAndUndoPreserveEarlierEditsAndMeasuredPath() async throws {
    let store = try PlacesStore()
    try await store.savePlace(visitPlace())
    try await store.append([visitFix(0), visitFix(90), visitFix(180), visitFix(240, metres: 2)])
    let original = try #require(try await store.timeline(on: visitEpoch).first)
    let earlier = UserOverride(start: visitEpoch, end: visitEpoch.addingTimeInterval(240), kind: .stay, placeID: visitPlace().id)
    try await store.correct(earlier)
    var closed = original; closed.end = visitEpoch.addingTimeInterval(240)
    let correction = try await store.passingThrough(closed)
    #expect(try await store.timeline(on: visitEpoch).first?.kind == .journey)
    #expect(try await store.routePoints(from: visitEpoch, to: closed.end!).count == 4)
    try await store.undoCorrection(id: correction.id)
    #expect(try await store.timeline(on: visitEpoch).first?.placeID == visitPlace().id)
    #expect(try await store.timeline(on: visitEpoch).first?.isUserEdited == true)
    #expect(try await store.observations().count == 4)
}

@Test func visitPolicyMigrationRetainsRawDataAndCorrections() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try PlacesStore(path: path)
    try await store.savePlace(visitPlace(walks: true))
    let samples = [visitFix(0), visitFix(90), visitFix(180)]
    try await store.append(samples)
    let edit = UserOverride(start: visitEpoch, end: visitEpoch.addingTimeInterval(180), kind: .journey, mode: .walking)
    try await store.correct(edit)
    let queue = try DatabaseQueue(path: path)
    try await queue.write { db in
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v9-confirmed-visits-and-walking-routes'")
    }
    let reopened = try PlacesStore(path: path)
    #expect(try await reopened.observations().count == samples.count)
    #expect(try await reopened.places().first?.countsWalksAsVisits == true)
    #expect(try await reopened.timeline(on: visitEpoch).first?.kind == .journey)
    #expect(try await reopened.timeline(on: visitEpoch).first?.isUserEdited == true)
    #expect(try await queue.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").isEmpty })
}

}
