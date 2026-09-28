import Foundation
import Testing
@testable import PlacesCore

private var rewindCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
    return calendar
}
private func date(_ year: Int = 2026, _ month: Int = 3, _ day: Int, _ hour: Int = 0) -> Date {
    rewindCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
}
private func stay(_ id: String, _ start: Date, _ end: Date, place: String? = "home", kind: TimelineKind = .stay) -> TimelineItem {
    TimelineItem(id: id, kind: kind, start: start, end: end, placeID: place, lastEvidenceAt: end)
}
private let home = Place(id: "home", name: "Home", coordinate: Coordinate(latitude: 1, longitude: 1))

@Test func rewindClipsMonthsCountsDistinctDaysAndHandlesDST() {
    let items = [stay("first", date(2026, 2, 28, 20), date(2026, 3, 1, 1)),
                 stay("again", date(2026, 3, 1, 12), date(2026, 3, 1, 13)),
                 stay("dst", date(2026, 3, 28, 23), date(2026, 3, 30)),
                 stay("last", date(2026, 3, 31, 23), date(2026, 4, 1, 2)),
                 stay("future", date(2026, 4, 2), date(2026, 4, 3))]
    let result = MonthlyRewind(month: date(2026, 3, 15), items: items, places: [home], library: MemoryLibrary(), now: date(2026, 4, 4), calendar: rewindCalendar)
    #expect(result.recordedDays == 4)
    #expect(result.places.count == 1)
    #expect(result.places.first?.days == 4)
    #expect(result.reviewItems.isEmpty)
}

@Test func rewindDoesNotCountUnknownSpansAsRecordedDaysOrTravel() {
    var combined = stay("combined", date(2026, 3, 1, 20), date(2026, 3, 3, 2))
    combined.originalItems = [stay("a", date(2026, 3, 1, 20), date(2026, 3, 2)),
        stay("gap", date(2026, 3, 2), date(2026, 3, 3), place: nil, kind: .gap),
        stay("b", date(2026, 3, 3), date(2026, 3, 3, 2))]
    var walk = stay("walk", date(2026, 3, 3, 2), date(2026, 3, 3, 3), place: nil, kind: .journey)
    walk.mode = .walking
    let result = MonthlyRewind(month: date(2026, 3, 15), items: [combined, walk], places: [home], library: MemoryLibrary(), now: date(2026, 4, 1), calendar: rewindCalendar)
    #expect(result.recordedDays == 2)
    #expect(result.places.first?.days == 2)
    #expect(result.journeys == [.walking: 3600])
}

@Test func rewindUsesMemoryDatesUniquePhotosAndExistingPeopleOnly() {
    var library = MemoryLibrary()
    library.people = [MemoryPerson(id: "alex", name: "Alex"), MemoryPerson(id: "other", name: "Other")]
    library.trips = [Trip(id: "visible", title: "City break", start: date(2026, 2, 28), end: date(2026, 3, 2), personIDs: ["alex", "deleted"]),
                     Trip(id: "hidden", title: "Hidden", start: date(2026, 3, 5), personIDs: ["other"], hidden: true)]
    library.memories = [PlaceMemory(date: date(2026, 3, 2), photoIDs: ["photo", "another"]),
                        PlaceMemory(date: date(2026, 3, 3), photoIDs: ["photo"]),
                        PlaceMemory(date: date(2026, 4, 1), personIDs: ["other"])]
    let result = MonthlyRewind(month: date(2026, 3, 1), items: [], places: [], library: library, now: date(2026, 4, 2), calendar: rewindCalendar)
    #expect(result.trips.map(\.id) == ["visible"])
    #expect(result.people.map(\.id) == ["alex"])
    #expect(result.memories.count == 2)
    #expect(result.photoIDs == ["photo", "another"])
    #expect(result.hasHighlights)
}

@Test func reviewHonoursCorrectionsAndDoesNotAskAboutJourneyModes() {
    var intentional = stay("intentional", date(2026, 3, 1), date(2026, 3, 2), place: nil, kind: .gap)
    intentional.isUserEdited = true
    let unnamed = stay("unnamed", date(2026, 3, 2), date(2026, 3, 2, 1), place: nil)
    let removed = stay("removed", date(2026, 3, 3), date(2026, 3, 3, 1), place: "deleted")
    let travel = stay("travel", date(2026, 3, 3, 2), date(2026, 3, 3, 3), place: nil, kind: .journey)
    let shortGap = stay("short", date(2026, 3, 4), date(2026, 3, 4).addingTimeInterval(60), place: nil, kind: .gap)
    #expect(TimelineReview.items(in: [intentional, unnamed, removed, travel, shortGap], places: [home]).map(\.id) == ["unnamed", "removed"])
}

@Test func remindersAreOptInRecentAndNeverRepeatBlindly() {
    let now = date(2026, 3, 27, 12) // Friday before a DST transition.
    let missing = stay("missing", date(2026, 3, 26, 10), date(2026, 3, 26, 12), place: nil)
    #expect(RewindReminder.plan(now: now, calendar: rewindCalendar, monthly: false, weekly: false, recordedMonths: [date(2026, 3, 1)], missingPlaces: [missing]).isEmpty)
    #expect(RewindReminder.plan(now: now, calendar: rewindCalendar, monthly: false, weekly: true, recordedMonths: [], missingPlaces: []).isEmpty)
    let plan = RewindReminder.plan(now: now, calendar: rewindCalendar, monthly: true, weekly: true, recordedMonths: [date(2026, 3, 1)], missingPlaces: [missing])
    #expect(plan.first { $0.kind == .monthly }?.fireAt == date(2026, 4, 1, 18))
    #expect(plan.first { $0.kind == .weekly }?.fireAt == date(2026, 3, 29, 18))
    let stale = stay("old", date(2026, 3, 1), date(2026, 3, 2), place: nil)
    #expect(RewindReminder.plan(now: now, calendar: rewindCalendar, monthly: false, weekly: true, recordedMonths: [], missingPlaces: [stale]).isEmpty)
}

@Test func monthlyRemindersCoverFirstEveningWithoutARecordingTodayAndAvoidDoubleNudge() {
    let now = date(2026, 11, 1, 12) // Sunday and first of the month.
    let missing = stay("missing", date(2026, 10, 30, 10), date(2026, 10, 30, 12), place: nil)
    let plan = RewindReminder.plan(now: now, calendar: rewindCalendar, monthly: true, weekly: true, recordedMonths: [date(2026, 10, 1)], missingPlaces: [missing])
    #expect(plan.count == 1)
    #expect(plan.first?.kind == .monthly)
    #expect(plan.first?.periodStart == date(2026, 10, 1))
    #expect(plan.first?.fireAt == date(2026, 11, 1, 18))
    #expect(RewindReminder.plan(now: date(2026, 11, 1, 19), calendar: rewindCalendar, monthly: true, weekly: false, recordedMonths: [date(2026, 10, 1)], missingPlaces: []).isEmpty)
}

@Test func rewindStoreReadsDurableCorrections() async throws {
    let store = try PlacesStore()
    try await store.savePlace(home)
    try await store.append([SensorObservation(timestamp: date(2026, 3, 1), source: .visitArrival, coordinate: Coordinate(latitude: 2, longitude: 2), horizontalAccuracy: 10),
                            SensorObservation(timestamp: date(2026, 3, 1, 2), source: .visitDeparture, coordinate: Coordinate(latitude: 2, longitude: 2), horizontalAccuracy: 10)])
    try await store.correct(UserOverride(start: date(2026, 3, 1), end: date(2026, 3, 1, 2), kind: .stay, placeID: home.id))
    let summary = try await store.monthlyRewind(for: date(2026, 3, 1), now: date(2026, 4, 1), calendar: rewindCalendar)
    #expect(summary.places.first?.id == home.id)
    #expect(!summary.reviewItems.contains { $0.kind == .stay })
    let reminderItems = try await store.rewindReminderItems(in: DateInterval(start: date(2026, 3, 1), end: date(2026, 4, 1)))
    #expect(!TimelineReview.items(in: reminderItems, places: [home]).contains { $0.kind == .stay })
    let reminderSummary = MonthlyRewind(month: date(2026, 3, 1), items: reminderItems, places: [home], library: MemoryLibrary(), now: date(2026, 4, 1), calendar: rewindCalendar)
    #expect(reminderSummary.places.first?.id == home.id)
    #expect(reminderSummary.recordedDays == summary.recordedDays)
}

@Test func rewindDoesNotExtendAnOldOpenJourneyThroughTheMonth() {
    var old = stay("open", date(2026, 2, 28, 10), date(2026, 4, 1), place: nil, kind: .journey)
    old.end = nil
    old.lastEvidenceAt = date(2026, 2, 28, 11)
    old.mode = .walking
    let result = MonthlyRewind(month: date(2026, 3, 1), items: [old], places: [], library: MemoryLibrary(), now: date(2026, 4, 2), calendar: rewindCalendar)
    #expect(result.recordedDays == 0)
    #expect(result.journeys.isEmpty)
    #expect(!result.hasHighlights)
}

@Test func weeklyReminderIgnoresStaleClippedOpenStaysAndDeliberateCorrections() {
    let now = date(2026, 3, 27, 12)
    var old = stay("old", date(2026, 3, 1), now, place: nil)
    old.lastEvidenceAt = date(2026, 3, 2)
    var edited = stay("reviewed", date(2026, 3, 26), now, place: nil)
    edited.isUserEdited = true
    let plan = RewindReminder.plan(now: now, calendar: rewindCalendar, monthly: false, weekly: true, recordedMonths: [], missingPlaces: [old, edited])
    #expect(plan.isEmpty)
}

@Test func closedVisitsUseTheirObservedDepartureEvenWithOnlyArrivalEvidence() {
    var visit = stay("visit", date(2026, 3, 2, 10), date(2026, 3, 2, 12))
    visit.lastEvidenceAt = visit.start
    let result = MonthlyRewind(month: date(2026, 3, 1), items: [visit], places: [home], library: MemoryLibrary(), now: date(2026, 4, 1), calendar: rewindCalendar)
    #expect(result.recordedDays == 1)
    #expect(result.places.first?.id == home.id)
}

@Test func futureMonthsNeverHaveRewindHighlights() {
    var library = MemoryLibrary()
    library.trips = [Trip(title: "Long trip", start: date(2026, 3, 1), end: date(2026, 6, 1))]
    library.memories = [PlaceMemory(date: date(2026, 5, 1), photoIDs: ["future"])]
    let result = MonthlyRewind(month: date(2026, 5, 1), items: [], places: [], library: library, now: date(2026, 4, 1), calendar: rewindCalendar)
    #expect(!result.hasHighlights)
    #expect(result.photoIDs.isEmpty)
}
