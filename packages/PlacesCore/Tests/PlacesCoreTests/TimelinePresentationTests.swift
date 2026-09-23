import Foundation
import Testing
import GRDB
@testable import PlacesCore

private let day = Date(timeIntervalSince1970: 1_735_732_800)
private let origin = Coordinate(latitude: 0, longitude: 0)
private func at(_ seconds: Double) -> Date { day.addingTimeInterval(seconds) }
private func entry(_ id: String, _ start: Double, _ end: Double?, kind: TimelineKind = .stay,
                   place: String? = "home", edited: Bool = false) -> TimelineItem {
    TimelineItem(id: id, kind: kind, start: at(start), end: end.map(at), placeID: place,
                 evidenceIDs: [id], isUserEdited: edited, lastEvidenceAt: at(end ?? start), coordinate: origin)
}
private func fix(_ seconds: Double, coordinate: Coordinate = origin) -> SensorObservation {
    SensorObservation(id: "fix-\(seconds)", timestamp: at(seconds), source: .location,
                      coordinate: coordinate, horizontalAccuracy: 10)
}

@Test func adjacentCorrectedVisitsBecomeOneOngoingStayWithoutLosingOriginals() {
    let input = [entry("a", 0, 120), entry("b", 120, 120.3, edited: true),
                 entry("c", 120.3, 121, edited: true), entry("d", 121, nil)]
    let result = TimelinePresentation.make(items: input, observations: [], places: [])
    #expect(result.count == 1)
    #expect(result[0].start == day && result[0].end == nil)
    #expect(result[0].originalItems == input)
    #expect(result[0].isUserEdited)
    #expect(result[0].evidenceIDs == ["a", "b", "c", "d"])
}

@Test func shortRecoveryIsGroupedButItsUnknownEvidenceSurvives() {
    let input = [entry("a", 0, 100), entry("gap", 100, 650, kind: .gap, place: nil), entry("b", 650, nil)]
    let values = [fix(100), SensorObservation(timestamp: at(100), source: .recovery), fix(650)]
    let home = Place(id: "home", name: "Fixture Home", coordinate: origin)
    let result = TimelinePresentation.make(items: input, observations: values, places: [home])
    #expect(result.count == 1)
    #expect(result[0].originalItems?[1].kind == .gap)
    #expect(result[0].unrecordedDuration == 550)
    let split = TimelinePresentation.make(items: input, observations: values, places: [home], separatedAt: [at(100), at(650)])
    #expect(split.map(\.kind) == [.stay, .gap, .stay])
}

@Test func explicitUnknownLongGapPauseAndMovementAreNotHidden() {
    let home = Place(id: "home", name: "Fixture Home", coordinate: origin)
    let input = [entry("a", 0, 100), entry("gap", 100, 200, kind: .gap, place: nil), entry("b", 200, nil)]
    var corrected = input; corrected[1].isUserEdited = true
    #expect(TimelinePresentation.make(items: corrected, observations: [], places: [home]).count == 3)
    var long = input; long[1].end = at(1000); long[2].start = at(1000)
    #expect(TimelinePresentation.make(items: long, observations: [], places: [home]).count == 3)
    for source in [ObservationSource.paused, .regionExit, .visitDeparture] {
        let observation = SensorObservation(timestamp: at(150), source: source)
        #expect(TimelinePresentation.make(items: input, observations: [observation], places: [home]).count == 3)
    }
    #expect(TimelinePresentation.make(items: input, observations: [fix(150, coordinate: .init(latitude: 0, longitude: 0.01))], places: [home]).count == 3)
    let walking = SensorObservation(timestamp: at(150), source: .motion, motion: .walking)
    #expect(TimelinePresentation.make(items: input, observations: [walking], places: [home]).count == 3)
}

@Test func groupingDoesNotConfuseDifferentPlacesOrHideATrip() {
    let input = [entry("a", 0, 100), entry("b", 100, 200, place: "work"), entry("c", 200, nil)]
    #expect(TimelinePresentation.make(items: input, observations: [], places: []).count == 3)
    var trip = input; trip[1].kind = .journey; trip[1].placeID = nil
    #expect(TimelinePresentation.make(items: trip, observations: [], places: []).count == 3)
    var discontinuous = [input[0], input[2]]; discontinuous[1].start = at(101)
    #expect(TimelinePresentation.make(items: discontinuous, observations: [], places: []).count == 2)
}

@Test func unnamedStopsUseAnchoredProximityAndTransportModesRemainDistinct() {
    var stops = [entry("a", 0, 100, place: nil), entry("b", 100, 200, place: nil), entry("c", 200, nil, place: nil)]
    stops[1].coordinate = .init(latitude: 0, longitude: 0.0004)
    stops[2].coordinate = .init(latitude: 0, longitude: 0.0008)
    #expect(TimelinePresentation.make(items: stops, observations: [], places: []).count == 2)
    var journeys = [entry("a", 0, 100, kind: .journey, place: nil), entry("b", 100, 200, kind: .journey, place: nil)]
    #expect(TimelinePresentation.make(items: journeys, observations: [], places: []).count == 1)
    journeys[1].mode = .ferry
    #expect(TimelinePresentation.make(items: journeys, observations: [], places: []).count == 2)
}

@Test func gapUsesKnownEndpointsWithoutInventingAJourneyOrTransportMode() {
    let destination = Coordinate(latitude: 0, longitude: 0.01)
    let work = Place(id: "work", name: "Fixture Work", coordinate: destination)
    let input = [entry("a", 0, 100), entry("gap", 100, 1000, kind: .gap, place: nil), entry("b", 1000, nil, place: "work")]
    let result = TimelinePresentation.make(items: input, observations: [], places: [work])
    #expect(result[1].kind == .gap && result[1].mode == .unknown)
    #expect(result[1].connection?.from.coordinate == origin)
    #expect(result[1].connection?.to.coordinate == destination)
    #expect(result[1].connection?.to.placeID == work.id)
    let firstGap = [entry("gap", 0, 1000, kind: .gap, place: nil), input[2]]
    let fromFix = TimelinePresentation.make(items: firstGap, observations: [fix(0)], places: [work])
    #expect(fromFix[0].connection?.from.coordinate == origin)
    #expect(fromFix[0].connection?.to.coordinate == destination)
    #expect(TimelinePresentation.make(items: [firstGap[0]], observations: [fix(0)], places: []).first?.connection == nil)
    var stale = fix(900); stale.coordinateTimestamp = at(0)
    #expect(TimelinePresentation.make(items: [firstGap[0]], observations: [fix(0), stale], places: []).first?.connection == nil)
}

@Test func splitPersistsAcrossRebuildReopenExportAndCanBeMergedAgain() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try PlacesStore(path: path)
    try await store.savePlace(Place(id: "home", name: "Fixture Home", coordinate: origin))
    try await store.append([fix(0), fix(100), SensorObservation(timestamp: at(101), source: .recovery), fix(110)])
    try await store.correct(UserOverride(start: at(100), end: at(110), kind: .stay, placeID: "home"))
    let combined = try #require(await store.timeline(on: day).first)
    #expect(combined.originalItems?.count == 3)
    try await store.split(combined)
    try await store.append([fix(300)])
    let reopened = try PlacesStore(path: path)
    let split = try await reopened.timeline(on: day)
    #expect(split.count == 3 && split.allSatisfy { $0.isSeparated == true })
    #expect(split[1].isUserEdited)
    #expect(try await reopened.observations().count == 5)
    let fixture = try InferenceTestCase.decode(await reopened.exportTestCase())
    #expect(fixture.input.separatedAt?.count == 2)
    #expect(fixture.replay() == fixture.expectedTimeline)
    try await reopened.mergeAdjacent(to: split[1])
    #expect(try await reopened.timeline(on: day).count == 1)
    try await reopened.split(combined)
    try await reopened.eraseHistory(resetSettings: true)
    let erased = try InferenceTestCase.decode(await reopened.exportTestCase())
    #expect(erased.input.separatedAt == [])
}

@Test func groupingMigrationPreservesExistingHistoryAndCorrections() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try PlacesStore(path: path)
    try await store.append([fix(0), fix(200)])
    try await store.correct(UserOverride(start: at(50), end: at(90), kind: .gap))
    let queue = try DatabaseQueue(path: path)
    try await queue.write { db in
        try db.execute(sql: "DROP TABLE timelineSeparations; DELETE FROM grdb_migrations WHERE identifier = 'v3-reversible-timeline-grouping'")
    }
    let reopened = try PlacesStore(path: path)
    #expect(try await reopened.timeline(on: day).map(\.kind) == [.stay, .gap, .stay])
    #expect(try await reopened.observations().count == 2)
}

@Test func combinedVisitsClipToLocalDayAcrossMidnightAndDST() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Europe/Amsterdam"))
    let date = try #require(calendar.date(from: .init(year: 2025, month: 3, day: 30)))
    let interval = try #require(calendar.dateInterval(of: .day, for: date))
    var a = entry("a", 0, 100), b = entry("b", 100, nil)
    a.start = interval.start.addingTimeInterval(-500); a.end = interval.start.addingTimeInterval(500)
    b.start = a.end!; b.end = interval.end.addingTimeInterval(500)
    let combined = TimelinePresentation.make(items: [a, b], observations: [], places: [])
    let clipped = InferenceEngine.onDay(date, calendar: calendar, items: combined)
    #expect(clipped.count == 1 && clipped[0].duration() == 23 * 3600)
    #expect(clipped[0].originalItems?.count == 2)
}
