import Foundation
import Testing
@testable import PlacesCore

private let importDay = Date(timeIntervalSince1970: 1_700_000_000)
private let importNow = importDay.addingTimeInterval(86_400)
private func draft(_ id: String = "visit", start: TimeInterval = 0, end: TimeInterval = 3600) -> PastVisitDraft {
    var draft = PastVisitDraft(candidate: PastVisitCandidate(id: id, name: "Fixture Garden",
        coordinate: Coordinate(latitude: 1, longitude: 1), date: importDay.addingTimeInterval(start)), places: [])
    draft.departure = importDay.addingTimeInterval(end)
    return draft
}
private func existing(_ kind: TimelineKind = .stay, start: TimeInterval = 600, end: TimeInterval = 1200,
                      edited: Bool = false) -> TimelineItem {
    TimelineItem(id: "existing", kind: kind, start: importDay.addingTimeInterval(start), end: importDay.addingTimeInterval(end),
                 isUserEdited: edited, lastEvidenceAt: importDay.addingTimeInterval(end))
}

@Test func pastVisitsFillEmptyHistoryWithoutFabricatingSensorEvidence() async throws {
    let store = try PlacesStore()
    let drafts = [draft()]
    let plan = PastVisitPlan.make(drafts: drafts, context: try await store.pastVisitContext(), now: importNow)
    try await store.importPastVisits(drafts, reviewed: plan, now: importNow)
    let items = try await store.timeline(in: DateInterval(start: importDay, duration: 3600))
    #expect(items.count == 1)
    #expect(items[0].start == importDay && items[0].end == importDay.addingTimeInterval(3600))
    #expect(items[0].isUserEdited && items[0].evidenceIDs.isEmpty)
    #expect(items[0].reasons.joined().contains("Journaling Suggestions"))
    #expect(try await store.observations(limit: 100).isEmpty)
    #expect(try await store.routePoints(from: importDay, to: importNow).isEmpty)
    #expect(try await store.historyDays(now: importNow).count == 1)
    #expect(try await store.search("Fixture").count == 1)
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let archive = try decoder.decode(HistoryArchive.self, from: await store.exportHistory())
    #expect(archive.corrections.first?.importedVisitID == "visit")
    try await store.eraseHistory()
    #expect(try await store.pastVisitContext().importedIDs.isEmpty)
    #expect(try await store.historyDays().isEmpty)
}

@Test func ordinaryCorrectionsStillCannotInventUnrecordedHistory() {
    let edit = UserOverride(start: importDay, end: importNow, kind: .stay)
    #expect(InferenceEngine.applying([edit], to: []).isEmpty)
}

@Test func pastVisitsPreserveKnownEntriesAndExplicitGapsByDefault() {
    for item in [existing(), existing(.journey), existing(.gap, edited: true)] {
        let plan = PastVisitPlan.make(drafts: [draft()], context: PastVisitContext(places: [], items: [item]), now: importNow)
        #expect(plan.canImport && plan.count == 2)
        #expect(plan.visits[0].intervals.map(\.duration) == [600, 2400])
    }
    let inferredGap = PastVisitPlan.make(drafts: [draft()], context: PastVisitContext(places: [], items: [existing(.gap)]), now: importNow)
    #expect(inferredGap.count == 1 && inferredGap.visits[0].intervals[0].duration == 3600)
}

@Test func replacingOverlapIsExplicitAndKeepsOutsideIntervals() {
    var visit = draft(start: 600, end: 1200); visit.replaceExisting = true
    let prior = existing(start: 0, end: 3600, edited: true)
    let plan = PastVisitPlan.make(drafts: [visit], context: PastVisitContext(places: [], items: [prior]), now: importNow)
    #expect(plan.count == 1 && plan.visits[0].conflicts.count == 1)
    let edit = UserOverride(start: importDay.addingTimeInterval(600), end: importDay.addingTimeInterval(1200),
                            kind: .stay, placeID: "new", importedVisitID: "visit")
    let items = InferenceEngine.applying([edit], to: [prior])
    #expect(items.count == 3)
    #expect(items.map { $0.duration() } == [600, 600, 2400])
    #expect(items[1].placeID == "new" && items[1].evidenceIDs.isEmpty)
}

@Test func staleReviewCannotOverwriteNewHistoryOrPartiallyCreatePlaces() async throws {
    let store = try PlacesStore()
    let drafts = [draft()]
    let plan = PastVisitPlan.make(drafts: drafts, context: try await store.pastVisitContext(), now: importNow)
    try await store.append([
        SensorObservation(timestamp: importDay.addingTimeInterval(600), source: .visitArrival,
                          coordinate: Coordinate(latitude: 2, longitude: 2), horizontalAccuracy: 10),
        SensorObservation(timestamp: importDay.addingTimeInterval(1200), source: .visitDeparture,
                          coordinate: Coordinate(latitude: 2, longitude: 2), horizontalAccuracy: 10)
    ])
    await #expect(throws: PastVisitImportError.timelineChanged) {
        try await store.importPastVisits(drafts, reviewed: plan, now: importNow)
    }
    #expect(try await store.places().isEmpty)
    #expect(try await store.pastVisitContext().importedIDs.isEmpty)
}

@Test func repeatedSuggestionsAndOverlappingSelectionsCannotDuplicateVisits() async throws {
    let store = try PlacesStore()
    let drafts = [draft(), draft()]
    let context = try await store.pastVisitContext()
    let plan = PastVisitPlan.make(drafts: drafts, context: context, now: importNow)
    #expect(plan.count == 1)
    try await store.importPastVisits(drafts, reviewed: plan, now: importNow)
    let repeated = PastVisitPlan.make(drafts: drafts, context: try await store.pastVisitContext(), now: importNow)
    #expect(repeated.count == 0 && repeated.visits[0].alreadyAdded)
    var second = draft("second", start: 500, end: 1500); second.replaceExisting = true
    let overlap = PastVisitPlan.make(drafts: [draft(), second], context: context, now: importNow)
    #expect(!overlap.canImport && overlap.visits[1].issue != nil)
}

@Test func pastVisitsReuseSavedPlacesAndRequireMissingData() {
    let place = Place(id: "saved", name: "My garden", coordinate: Coordinate(latitude: 1, longitude: 1))
    var visit = PastVisitDraft(candidate: draft().candidate, places: [place])
    #expect(visit.placeID == "saved")
    #expect(visit.departure == importDay.addingTimeInterval(3600), "Missing departure starts with an editable one-hour review default")
    let context = PastVisitContext(places: [place], items: [])
    #expect(PastVisitPlan.make(drafts: [visit], context: context, now: importNow).canImport)
    visit.departure = importDay.addingTimeInterval(600)
    #expect(PastVisitPlan.make(drafts: [visit], context: context, now: importNow).visits[0].place?.name == "My garden")
    visit.candidate.coordinate = nil; visit.placeID = nil
    #expect(!PastVisitPlan.make(drafts: [visit], context: context, now: importNow).canImport)
    visit.placeID = place.id
    #expect(PastVisitPlan.make(drafts: [visit], context: context, now: importNow).canImport)
    visit.departure = importNow.addingTimeInterval(60)
    #expect(!PastVisitPlan.make(drafts: [visit], context: context, now: importNow).canImport)
}

@Test func importedVisitsSurviveReinferenceAndLaterCorrectionsWin() async throws {
    let store = try PlacesStore()
    let drafts = [draft()]
    let plan = PastVisitPlan.make(drafts: drafts, context: try await store.pastVisitContext(), now: importNow)
    try await store.importPastVisits(drafts, reviewed: plan, now: importNow)
    try await store.append([SensorObservation(timestamp: importDay, source: .location,
        coordinate: Coordinate(latitude: 2, longitude: 2), horizontalAccuracy: 10)])
    try await store.correct(UserOverride(start: importDay.addingTimeInterval(1200), end: importDay.addingTimeInterval(1800), kind: .gap))
    let items = try await store.timeline(in: DateInterval(start: importDay, duration: 3600))
    #expect(items.map(\.kind) == [.stay, .gap, .stay])
    #expect(items.allSatisfy { $0.isUserEdited })
}

@Test func pastVisitTimeDefaultsAreImmediatelyReviewable() {
    let candidate = draft().candidate
    let event = DateInterval(start: importDay.addingTimeInterval(-600), end: importDay.addingTimeInterval(1800))
    let suppliedEnd = PastVisitDraft(candidate: candidate, places: [], eventDate: event, now: importNow)
    #expect(suppliedEnd.arrival == importDay && suppliedEnd.departure == event.end)
    let earlierEvent = DateInterval(start: importDay.addingTimeInterval(-3600), duration: 1800)
    #expect(PastVisitDraft(candidate: candidate, places: [], eventDate: earlierEvent, now: importNow).departure == importDay.addingTimeInterval(3600))
    let recent = PastVisitDraft(candidate: candidate, places: [], now: importDay.addingTimeInterval(600))
    #expect(recent.departure == importDay.addingTimeInterval(600))
    let undated = PastVisitCandidate(id: "undated", name: "Garden", coordinate: candidate.coordinate)
    let fallback = PastVisitDraft(candidate: undated, places: [], fallbackDate: importDay, now: importNow)
    #expect(fallback.arrival == importDay && fallback.departure == importDay.addingTimeInterval(3600))
}

@Test func pastVisitAndPhotoMemoryCommitTogetherAndSurviveExport() async throws {
    let store = try PlacesStore()
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let jpeg = folder.appendingPathComponent("photo.jpg"), thumbnail = folder.appendingPathComponent("thumbnail.jpg")
    try Data([1, 2, 3]).write(to: jpeg); try Data([4, 5]).write(to: thumbnail)
    let file = MemoryPhotoFile(id: "selected-photo", jpegURL: jpeg, thumbnailURL: thumbnail, details: MemoryPhotoDetails(createdAt: importDay))
    let memory = PastVisitMemory(visitID: "visit", suggestionID: "selected-event", photos: [file])
    let drafts = [draft()]
    let plan = PastVisitPlan.make(drafts: drafts, context: try await store.pastVisitContext(), now: importNow)
    try await store.importPastVisits(drafts, reviewed: plan, now: importNow, memory: memory)
    let saved = try #require(try await store.memoryLibrary(now: importNow).memories.first)
    #expect(saved.placeID == plan.visits[0].place?.id && saved.visitStart == importDay)
    #expect(saved.photoIDs == [file.id] && saved.photoDetails?[file.id]?.createdAt == importDay)
    #expect(try await store.photoData(id: file.id) == Data([1, 2, 3]))
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let archive = try decoder.decode(HistoryArchive.self, from: await store.exportHistory())
    #expect(archive.memories?.memories.count == 1 && archive.memories?.photos.count == 1)
    await #expect(throws: PastVisitImportError.timelineChanged) {
        try await store.importPastVisits(drafts, reviewed: plan, now: importNow, memory: memory)
    }
    #expect(try await store.memoryLibrary(now: importNow).memories.count == 1)
    try await store.eraseHistory()
    #expect(try await store.memoryLibrary().memories.isEmpty)
    #expect(try await store.photoData(id: file.id) == nil)
}

@Test func invalidSuggestionPhotoRollsBackVisitPlaceAndMemory() async throws {
    let store = try PlacesStore()
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let file = MemoryPhotoFile(id: "unreadable", jpegURL: missing, thumbnailURL: missing)
    let drafts = [draft()]
    let plan = PastVisitPlan.make(drafts: drafts, context: try await store.pastVisitContext(), now: importNow)
    do {
        try await store.importPastVisits(drafts, reviewed: plan, now: importNow,
            memory: PastVisitMemory(visitID: "visit", suggestionID: "event", photos: [file]))
        Issue.record("An unreadable photo must fail the whole import")
    } catch { }
    #expect(try await store.pastVisitContext().importedIDs.isEmpty)
    #expect(try await store.places().isEmpty)
    #expect(try await store.memoryLibrary().memories.isEmpty)
}
