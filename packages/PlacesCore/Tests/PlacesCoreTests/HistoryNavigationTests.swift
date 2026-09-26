import Foundation
import Testing
@testable import PlacesCore

private let epoch = Date(timeIntervalSince1970: 1_735_732_800)
private let point = Coordinate(latitude: 1, longitude: 1)
private func moment(_ seconds: Double) -> Date { epoch.addingTimeInterval(seconds) }
private func stay(_ id: String, _ start: Double, _ end: Double, _ place: String?) -> TimelineItem {
    TimelineItem(id: id, kind: .stay, start: moment(start), end: moment(end), placeID: place, lastEvidenceAt: moment(end))
}

@Test func periodsFollowRecordedVisitsAndDoNotJoinReturnTripsOrUnknownStops() {
    let a = Place(id: "a", name: "Fixture A", coordinate: point, locality: .init(city: "City A", country: "Country A"))
    let b = Place(id: "b", name: "Fixture B", coordinate: point, locality: .init(city: "City B", country: "Country B"))
    let items = [stay("1", 0, 10, "a"), stay("2", 20, 30, "a"), stay("3", 40, 50, "b"), stay("4", 60, 70, "a"), stay("5", 80, 90, nil), stay("6", 100, 110, "a")]
    let periods = HistoryPeriod.visits(items: items, places: [a, b], now: moment(120))
    let countryA = periods.filter { $0.isCountry && $0.title == "Country A" }.sorted { $0.interval.start < $1.interval.start }
    #expect(countryA.map(\.interval) == [DateInterval(start: moment(0), end: moment(30)), DateInterval(start: moment(60), end: moment(70)), DateInterval(start: moment(100), end: moment(110))])
    #expect(periods.filter { !$0.isCountry && $0.title == "City B" }.count == 1)
}

@Test func rangeQueryClipsAtExclusiveEndAcrossDaylightSavingTime() async throws {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
    let day = calendar.date(from: DateComponents(year: 2025, month: 3, day: 30))!
    let interval = calendar.dateInterval(of: .day, for: day)!
    #expect(interval.duration == 23 * 3600)
    let store = try PlacesStore()
    try await store.savePlace(Place(id: "a", name: "Fixture", coordinate: point))
    try await store.append([
        SensorObservation(timestamp: day.addingTimeInterval(-300), source: .visitArrival, coordinate: point, horizontalAccuracy: 10),
        SensorObservation(timestamp: interval.end.addingTimeInterval(300), source: .location, coordinate: point, horizontalAccuracy: 10)
    ])
    let ranged = try await store.timeline(in: interval)
    #expect(ranged == (try await store.timeline(on: day, calendar: calendar)))
    #expect(ranged.allSatisfy { $0.start >= day && ($0.end ?? .distantFuture) <= interval.end })
    let outside = stay("outside", 10, 20, "a")
    #expect(InferenceEngine.within(DateInterval(start: moment(0), end: moment(10)), items: [outside]).isEmpty)
}

@Test func selectingOnlyFirstOriginalLeavesRemainingEntriesCombinedAndSurvivesReopen() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try PlacesStore(path: path)
    try await store.savePlace(Place(id: "a", name: "Fixture", coordinate: point))
    func fix(_ seconds: Double) -> SensorObservation { SensorObservation(timestamp: moment(seconds), source: .location, coordinate: point, horizontalAccuracy: 10) }
    try await store.append([fix(0), fix(100), SensorObservation(timestamp: moment(101), source: .recovery), fix(110)])
    try await store.correct(UserOverride(start: moment(100), end: moment(110), kind: .stay, placeID: "a"))
    let combined = try #require(await store.timeline(on: epoch).first)
    let originals = try #require(combined.originalItems)
    #expect(originals.count == 3)
    try await store.split(combined, selecting: [originals[0].id])
    let reopened = try PlacesStore(path: path)
    let result = try await reopened.timeline(on: epoch)
    #expect(result.count == 2)
    #expect(result.last?.originalItems?.count == 2)
    #expect(try await reopened.observations().count == 4)
}

@Test func localityIsBackwardCompatibleAndDoesNotOverwriteConcurrentManualEdits() async throws {
    var place = Place(id: "a", name: "Fixture", coordinate: point)
    let data = try JSONEncoder().encode(place)
    #expect(try JSONDecoder().decode(Place.self, from: data).locality == nil)
    let store = try PlacesStore()
    try await store.savePlace(place)
    try await store.saveLocality(.init(city: "Wrong", source: .apple), for: place.id, at: .init(latitude: 2, longitude: 2))
    #expect(try await store.places().first?.locality == nil)
    place.locality = .init(city: "Chosen city")
    try await store.savePlace(place)
    try await store.saveLocality(.init(city: "Late result", source: .apple), for: place.id, at: point)
    #expect(try await store.places().first?.locality?.city == "Chosen city")
    let fixture = try InferenceTestCase.decode(await store.exportTestCase())
    #expect(fixture.input.places.first?.locality == nil, "Test exports must not leak real city/country metadata")
}

@Test func wifiRecordsFiveMinuteContinuityAndImmediateChanges() {
    var gate = WiFiEvidenceGate()
    func wifi(_ second: Double, bssid: String? = "02:00:00:00:00:01", coordinate: Coordinate? = nil) -> SensorObservation {
        SensorObservation(timestamp: moment(second), source: .wifi, coordinate: coordinate, horizontalAccuracy: coordinate == nil ? nil : 10, ssid: bssid == nil ? nil : "Fixture", bssid: bssid)
    }
    let recorded1 = gate.shouldRecord(wifi(0), placeID: "a")
    #expect(recorded1)
    let recorded2 = !gate.shouldRecord(wifi(1), placeID: "a")
    #expect(recorded2)
    let recorded3 = !gate.shouldRecord(wifi(299), placeID: "a")
    #expect(recorded3)
    let recorded4 = gate.shouldRecord(wifi(300), placeID: "a")
    #expect(recorded4)
    let recorded5 = gate.shouldRecord(wifi(301, bssid: nil), placeID: nil)
    #expect(recorded5)
    let recorded6 = gate.shouldRecord(wifi(302), placeID: "a")
    #expect(recorded6)
    let recorded7 = gate.shouldRecord(wifi(303, coordinate: point), placeID: "a")
    #expect(recorded7)
    let recorded8 = gate.shouldRecord(wifi(304, bssid: "02:00:00:00:00:02"), placeID: "a")
    #expect(recorded8)
    let recorded9 = gate.shouldRecord(wifi(305, bssid: "02:00:00:00:00:02"), placeID: nil)
    #expect(recorded9)
}

@Test func evidenceGroupsKeepRawChecksAndDoNotHideConnectionTransitions() {
    let a = SensorObservation(timestamp: moment(0), source: .wifi, ssid: "Fixture", bssid: "02:00:00:00:00:01")
    var b = a; b.id = "b"; b.timestamp = moment(1)
    let disconnected = SensorObservation(timestamp: moment(2), source: .wifi)
    var c = a; c.id = "c"; c.timestamp = moment(3)
    let groups = EvidenceGroup.make([a, a, b, disconnected, c])
    #expect(groups.map { $0.observations.count } == [2, 1, 1])
    #expect(groups.flatMap(\.observations).count == 4)
}

@Test func historyCalendarCountsUniquePlacesAndHonorsMidnightAndMissingDays() {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
    // The DST transition has a 23-hour day.
    let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 28))!
    let next = calendar.date(byAdding: .day, value: 1, to: start)!
    let third = calendar.date(byAdding: .day, value: 2, to: start)!
    let fifth = calendar.date(byAdding: .day, value: 4, to: start)!
    func stay(_ id: String, _ begin: Date, _ end: Date?, _ place: String?) -> TimelineItem {
        TimelineItem(id: id, kind: .stay, start: begin, end: end, placeID: place, lastEvidenceAt: begin)
    }
    let days = HistoryDay.summarize([stay("a", start, next, "home"), stay("b", next, third, "home"),
        stay("c", next.addingTimeInterval(100), third, "home"), stay("d", next.addingTimeInterval(200), third, nil),
        stay("e", fifth, nil, "office"),
        TimelineItem(id: "missing", kind: .gap, start: third, end: fifth, lastEvidenceAt: third)], now: fifth.addingTimeInterval(60), calendar: calendar)
    #expect(days.map(\.date) == [start, next, fifth])
    #expect(days.map(\.placeCount) == [1, 2, 1])
}

@Test func adjacentPlacesSuggestBothSidesWithoutAssigningOrDuplicatingThem() {
    let start = Date(timeIntervalSince1970: 1_000_000)
    func item(_ id: String, _ s: Double, _ e: Double, _ place: String?) -> TimelineItem {
        TimelineItem(id: id, kind: place == nil ? .gap : .stay, start: start.addingTimeInterval(s),
            end: start.addingTimeInterval(e), placeID: place, lastEvidenceAt: start.addingTimeInterval(s))
    }
    let gap = item("gap", 100, 500, nil)
    let home = item("before", 0, 100, "home")
    let after = item("after", 500, 900, "home")
    let both = AdjacentPlaceSuggestion.make(for: gap, in: [after, gap, home])
    #expect(both.count == 1 && both[0].before && both[0].after && both[0].placeID == "home")
    #expect(gap.kind == .gap && gap.placeID == nil)
    let different = AdjacentPlaceSuggestion.make(for: gap, in: [home, gap, item("office", 500, 900, "office")])
    #expect(different.map(\.placeID) == ["home", "office"])
    #expect(AdjacentPlaceSuggestion.make(for: gap, in: [gap]).isEmpty)
}

@Test func energyCountersMeasureRequestsWithoutInventingRelaunchTimeOrDoubleCounting() throws {
    var first = EnergyCounters()
    first.setStandardLocation(active: true, uptime: 100)
    first.setStandardLocation(active: true, uptime: 110)
    first.wifiReads = 3
    let earlier = first.snapshot(now: Date(timeIntervalSince1970: 10), uptime: 120)
    #expect(earlier.standardLocationSeconds == 20 && earlier.locationStarts == 1)
    first.setStandardLocation(active: false, uptime: 130)
    let final = first.snapshot(now: Date(timeIntervalSince1970: 20), uptime: 3000)
    #expect(final.standardLocationSeconds == 30)
    let laterLaunch = EnergyCounters().snapshot(now: Date(timeIntervalSince1970: 5000), uptime: 10000)
    let total = EnergySummary(snapshots: [earlier, final, laterLaunch])
    #expect(total.standardLocationSeconds == 30 && total.wifiReads == 3 && total.sessions == 2)
    let data = try JSONEncoder().encode(final)
    #expect(try JSONDecoder().decode(EnergySnapshot.self, from: data) == final)
    #expect(!String(decoding: data, as: UTF8.self).contains("ssid"))
}

@Test func activityDiagnosticsPersistExportWithoutLocationsAndEraseWithHistory() async throws {
    let store = try PlacesStore()
    var counters = EnergyCounters()
    counters.wifiReads = 4
    counters.setStandardLocation(active: true, uptime: 100)
    counters.setStandardLocation(active: false, uptime: 140)
    var event = TrackingEvent(timestamp: Date(), state: .knownWiFi, reason: "A known network", previousStateDuration: 40,
                              standardLocationActive: false, build: "test")
    event.energy = counters.snapshot(uptime: 150)
    try await store.record(event)
    let decoded = try JSONDecoder().decode(TrackingEvent.self, from: JSONEncoder().encode(event))
    #expect(decoded.energy == event.energy)
    var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as! [String: Any]
    legacy.removeValue(forKey: "energy")
    #expect(try JSONDecoder().decode(TrackingEvent.self, from: JSONSerialization.data(withJSONObject: legacy)).energy == nil)
    let report = try await store.diagnostics()
    #expect(report.energy?.wifiReads == 4 && report.energy?.standardLocationSeconds == 40)
    let export = String(decoding: try await store.exportDiagnostics(), as: UTF8.self)
    #expect(!export.contains("A known network") && !export.contains(event.id))
    try await store.eraseHistory(resetSettings: true)
    #expect(try await store.diagnostics().energy?.sessions == 0)
}
