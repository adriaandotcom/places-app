import Foundation
import Testing
import GRDB
@testable import PlacesCore

private let home = Place(id: "home", name: "Fixture home", coordinate: .init(latitude: 52, longitude: 4), tripRole: .home)
private let hotel = Place(id: "hotel", name: "Fixture hotel", coordinate: .init(latitude: 36, longitude: 27), tripRole: .lodging)
private func date(_ day: Int, _ hour: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))!
}
private func visit(_ id: String, _ place: String?, _ day: Int, _ hour: Int, _ endDay: Int, _ endHour: Int, kind: TimelineKind = .stay) -> TimelineItem {
    TimelineItem(id: id, kind: kind, start: date(day, hour), end: date(endDay, endHour), placeID: place, lastEvidenceAt: date(endDay, endHour))
}
private func detect(_ items: [TimelineItem], places: [Place] = [home, hotel], now: Date = date(8, 12)) -> [Trip] {
    TripDetection.detect(items: items, places: places, timeZones: Dictionary(uniqueKeysWithValues: items.map { ($0.id, "UTC") }), now: now)
}

@Test func automaticTripIncludesOutingsAndDifferentHotelsUntilHome() throws {
    let other = Place(id: "other", name: "Fixture next hotel", coordinate: hotel.coordinate, tripRole: .lodging)
    let items = [visit("home", "home", 1, 0, 1, 8), visit("night1", "hotel", 1, 19, 2, 9),
                 visit("outing", nil, 2, 10, 2, 18, kind: .journey), visit("night2", "hotel", 2, 19, 3, 9),
                 visit("night3", "other", 3, 19, 4, 9), visit("return", "home", 4, 17, 5, 8)]
    let trip = try #require(detect(items, places: [home, hotel, other]).first)
    #expect(detect(items, places: [home, hotel, other]).count == 1)
    #expect(trip.start == date(1, 8)); #expect(trip.end == date(4, 17))
    #expect(trip.contains(date(2, 12)))
}
@Test func overnightGapCanSuggestTripButBriefStopsAndRegularPlacesCannot() {
    let items = [visit("evening", "hotel", 1, 21, 1, 23), visit("gap", nil, 1, 23, 2, 7, kind: .gap), visit("morning", "hotel", 2, 7, 2, 8)]
    #expect(detect(items, now: date(2, 10)).count == 1)
    #expect(detect([visit("short", "hotel", 1, 23, 2, 0)]).isEmpty)
    var regular = hotel; regular.tripRole = .regular
    #expect(detect(items, places: [home, regular]).isEmpty)
    #expect(detect([visit("homeNight", "home", 1, 18, 2, 9)]).isEmpty)
    var blocked = items; blocked[1].kind = .journey
    #expect(detect(blocked).isEmpty)
}
@Test func homeSeparatesTripsAndUnobservedTimeDoesNotInventAnOvernight() {
    let items = [visit("night1", "hotel", 1, 19, 2, 8), visit("home", "home", 2, 15, 3, 8), visit("night2", "hotel", 3, 19, 4, 8)]
    #expect(detect(items).count == 2)
    var stale = visit("stale", "hotel", 1, 19, 1, 20); stale.end = nil
    #expect(detect([stale]).isEmpty)
}
@Test func overnightUsesRecordedTimeZoneAndAwayFromHomeDistance() {
    let far = Place(id: "far", name: "Fixture", coordinate: hotel.coordinate)
    let near = Place(id: "near", name: "Fixture", coordinate: .init(latitude: 52.01, longitude: 4))
    let item = visit("far-night", "far", 1, 18, 1, 22)
    #expect(TripDetection.detect(items: [item], places: [home, far], timeZones: [item.id: "Asia/Tokyo"], now: date(2, 12)).count == 1)
    #expect(detect([visit("near-night", "near", 1, 20, 2, 8)], places: [home, near]).isEmpty)
    #expect(detect([visit("far-night", "far", 1, 20, 2, 8)], places: [far]).isEmpty)
}
@Test func automaticUpdatesPreserveNamesDatesCompanionsAndHiddenTrips() throws {
    var original = Trip(title: "My holiday", start: date(1, 8), end: date(4, 18), personIDs: ["friend"], automaticAnchor: date(1, 19), datesEdited: true, titleEdited: true, hidden: true, photoJPEG: Data([1, 2, 3]))
    let inferred = Trip(title: "Hotel", start: date(1, 9), end: nil, automaticAnchor: date(1, 19))
    #expect(TripDetection.reconcile([inferred], existing: [original]) == [original])
    original.datesEdited = false
    let updated = try #require(TripDetection.reconcile([inferred], existing: [original]).first)
    #expect(updated.photoJPEG == original.photoJPEG)
    #expect(updated.id == original.id); #expect(updated.end == nil); #expect(updated.personIDs == ["friend"])
    let manual = Trip(title: "Manual", start: date(1, 0), end: date(5, 0))
    #expect(TripDetection.reconcile([inferred], existing: [manual]) == [manual])
}
@Test func tripMemoriesOnlyIncludeThisVisitNotEveryStayAtSamePlace() {
    let trip = Trip(title: "Holiday", start: date(2, 0), end: date(5, 0))
    #expect(PlaceMemory(text: "General place note", placeID: hotel.id).belongs(to: trip) == false)
    #expect(PlaceMemory(text: "Earlier visit", placeID: hotel.id, visitStart: date(1, 10)).belongs(to: trip) == false)
    #expect(PlaceMemory(text: "This visit", placeID: hotel.id, visitStart: date(3, 10)).belongs(to: trip))
    #expect(PlaceMemory(text: "Trip note", tripID: trip.id).belongs(to: trip))
}
@Test func memoriesPhotosAndPeoplePersistExportPrivatelyAndEraseCompletely() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try PlacesStore(path: path)
    try await store.savePlace(hotel)
    let trip = Trip(title: "Private trip", start: date(1, 0), end: date(5, 0))
    let person = MemoryPerson(name: "Private person")
    try await store.saveTrip(trip); try await store.savePerson(person)
    let photo = MemoryPhoto(jpeg: Data([1, 2, 3]), thumbnail: Data([4, 5]))
    let memory = PlaceMemory(text: "Private note", tripID: trip.id, personIDs: [person.id], photoIDs: [photo.id])
    try await store.saveMemory(memory, adding: [photo])
    let reopened = try PlacesStore(path: path)
    #expect(try await reopened.memoryLibrary().memories == [memory])
    #expect(try await reopened.photoData(id: photo.id) == photo.jpeg)
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let archive = try decoder.decode(HistoryArchive.self, from: await store.exportHistory())
    #expect(archive.memories?.photos.first?.jpeg == photo.jpeg)
    for export in [try await store.exportDiagnostics(), try await store.exportTestCase()] {
        let text = String(decoding: export, as: UTF8.self)
        #expect(!text.contains("Private person")); #expect(!text.contains("Private note")); #expect(!text.contains("Private trip"))
    }
    try await reopened.deletePerson(id: person.id)
    #expect(try await reopened.memoryLibrary().memories.first?.personIDs == [])
    try await reopened.deleteMemory(id: memory.id)
    #expect(try await reopened.photoData(id: photo.id) == nil)
    try await reopened.saveMemory(memoryWithoutPeople(memory), adding: [photo])
    try await reopened.eraseHistory(resetSettings: true)
    let empty = try await reopened.memoryLibrary()
    #expect(empty.trips.isEmpty && empty.people.isEmpty && empty.memories.isEmpty)
    #expect(try await reopened.photoData(id: photo.id) == nil)
}
private func memoryWithoutPeople(_ memory: PlaceMemory) -> PlaceMemory { var memory = memory; memory.personIDs = []; return memory }
@Test func photoOwnershipAndInvalidWritesRollbackAtomically() async throws {
    let store = try PlacesStore(); try await store.savePlace(hotel)
    let photo = MemoryPhoto(jpeg: Data([1]), thumbnail: Data([2]))
    let owner = PlaceMemory(text: "Owner", placeID: hotel.id, photoIDs: [photo.id])
    try await store.saveMemory(owner, adding: [photo])
    let thief = PlaceMemory(text: "Other", placeID: hotel.id, photoIDs: [photo.id])
    await #expect(throws: (any Error).self) { try await store.saveMemory(thief, adding: [photo]) }
    #expect(try await store.memoryLibrary().memories == [owner])
    var missing = owner; missing.photoIDs = ["missing"]
    await #expect(throws: MemoryError.self) { try await store.saveMemory(missing) }
    #expect(try await store.photoData(id: photo.id) == photo.jpeg)
    var removed = owner; removed.photoIDs = []
    try await store.saveMemory(removed)
    #expect(try await store.photoData(id: photo.id) == nil)
}
@Test func oldPlaceAndArchiveRemainDecodableWithoutMemoryFields() throws {
    var encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(hotel)) as? [String: Any])
    encoded.removeValue(forKey: "tripRole")
    #expect(try JSONDecoder().decode(Place.self, from: JSONSerialization.data(withJSONObject: encoded)).tripRole == nil)
}

@Test func unnamedOvernightFarFromHomeStartsATripWithoutNamingThePlace() {
    var item = visit("unnamed", nil, 1, 20, 2, 8)
    item.coordinate = hotel.coordinate
    let result = detect([item])
    #expect(result.count == 1); #expect(result.first?.title == "Time away")
}
@Test func tripsSeparatedByLongMissingHistoryDoNotOverlapAtLaterHomecoming() {
    let items = [visit("night1", "hotel", 1, 20, 2, 8), visit("night2", "hotel", 6, 20, 7, 8), visit("home", "home", 7, 15, 8, 8)]
    let trips = detect(items)
    #expect(trips.count == 2)
    #expect(trips[0].end == date(2, 8))
    #expect(trips[1].end == date(7, 15))
}
@Test func visitMemoryFollowsPlaceCorrectionWhileTripIdentitySurvivesReopening() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try PlacesStore(path: path)
    try await store.savePlace(home); try await store.savePlace(hotel)
    try await store.append([SensorObservation(timestamp: date(1, 18), source: .visitArrival, coordinate: hotel.coordinate, horizontalAccuracy: 5, timezoneIdentifier: "UTC"),
                            SensorObservation(timestamp: date(2, 9), source: .visitDeparture, coordinate: hotel.coordinate, horizontalAccuracy: 5, timezoneIdentifier: "UTC")])
    try await store.correct(UserOverride(start: date(1, 18), end: date(2, 9), kind: .stay, placeID: hotel.id))
    let original = try #require(await store.memoryLibrary(now: date(2, 10)).trips.first)
    let memory = PlaceMemory(text: "Keep this", placeID: hotel.id, visitStart: date(1, 20))
    try await store.saveMemory(memory)
    let reopened = try PlacesStore(path: path)
    #expect(try await reopened.memoryLibrary(now: date(2, 11)).trips.first?.id == original.id)
    try await reopened.correct(UserOverride(start: date(1, 18), end: date(2, 9), kind: .stay, placeID: home.id, createdAt: Date().addingTimeInterval(1)))
    #expect(try await reopened.memoryLibrary(now: date(2, 11)).memories.first?.placeID == home.id)
    #expect(try await reopened.memoryLibrary(now: date(2, 11)).memories.first?.text == "Keep this")
}

@Test func memoryMigrationPreservesExistingPlacesEvidenceAndCorrections() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try PlacesStore(path: path)
    try await store.savePlace(home)
    let observation = SensorObservation(timestamp: date(1, 12), source: .location, coordinate: home.coordinate, horizontalAccuracy: 10)
    try await store.append([observation])
    try await store.correct(UserOverride(id: "keep-correction", start: date(1, 12), end: date(1, 13), kind: .stay, placeID: home.id))
    let queue = try DatabaseQueue(path: path)
    try await queue.write { db in
        try db.execute(sql: "DROP TABLE memoryPhotos; DROP TABLE memories; DROP TABLE people; DROP TABLE trips; DELETE FROM grdb_migrations WHERE identifier = 'v6-private-memories'")
    }
    let upgraded = try PlacesStore(path: path)
    #expect(try await upgraded.places() == [home])
    #expect(try await upgraded.observations().map(\.id) == [observation.id])
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let archive = try decoder.decode(HistoryArchive.self, from: await upgraded.exportHistory())
    #expect(archive.corrections.map(\.id) == ["keep-correction"])
    #expect(archive.memories?.photos.isEmpty == true)
    try await upgraded.savePerson(MemoryPerson(name: "New person"))
    #expect(try await upgraded.memoryLibrary().people.count == 1)
}

@Test func longGapAfterLastOvernightDoesNotExtendTripToMuchLaterHomeArrival() {
    let items = [visit("night", "hotel", 1, 20, 2, 8), visit("late", nil, 20, 12, 20, 14, kind: .journey), visit("home", "home", 21, 0, 22, 0)]
    #expect(detect(items, now: date(23, 0)).first?.end == date(2, 8))
}

@Test func moreThanTwelvePhotosCanCommitFromFilesAndOversizedCopiesRollback() async throws {
    let store = try PlacesStore(); try await store.savePlace(hotel)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var files: [MemoryPhotoFile] = []
    for index in 0..<25 {
        let jpeg = directory.appendingPathComponent("\(index).jpg"), thumb = directory.appendingPathComponent("\(index)-thumb.jpg")
        try Data(repeating: UInt8(index), count: 400_000).write(to: jpeg)
        try Data([1, 2]).write(to: thumb)
        files.append(MemoryPhotoFile(id: "photo-\(index)", jpegURL: jpeg, thumbnailURL: thumb))
    }
    let memory = PlaceMemory(placeID: hotel.id, photoIDs: files.map(\.id))
    try await store.saveMemory(memory, importing: files)
    #expect(try await store.memoryLibrary().memories.first?.photoIDs.count == 25)
    #expect(try await store.photoData(id: "photo-24")?.count == 400_000)
    let oversized = MemoryPhoto(jpeg: Data(repeating: 0, count: 450_001), thumbnail: Data([1]))
    let rejected = PlaceMemory(placeID: hotel.id, photoIDs: [oversized.id])
    await #expect(throws: MemoryError.self) { try await store.saveMemory(rejected, adding: [oversized]) }
    #expect(try await store.memoryLibrary().memories.count == 1)
}

@Test func mentionsKeepIdentityAcrossUnicodeEditsAndDuplicateNames() throws {
    let a = MemoryPerson(id: "person-a", name: "Renée Smith")
    let b = MemoryPerson(id: "person-b", name: "Renée Smith")
    let text = "🌴 With @Ren"
    let query = try #require(PersonMentions.query(in: text, selection: NSRange(location: text.utf16.count, length: 0), mentions: []))
    let tagged = PersonMentions.inserting(a, in: text, mentions: [], replacing: query.range)
    #expect(tagged.text == "🌴 With @Renée ")
    #expect(a.name == "Renée Smith")
    #expect(MemoryPerson(name: "  Anne-Marie  van Dijk ").firstName == "Anne-Marie")
    #expect(tagged.mentions.first?.personID == a.id)
    #expect(tagged.mentions.first?.personID != b.id)
    let shifted = PersonMentions.adjusted(tagged.mentions, replacing: NSRange(location: 0, length: 0), with: "Hello ")
    #expect(PersonMentions.valid(shifted, in: "Hello " + tagged.text).count == 1)
    let mention = try #require(tagged.mentions.first)
    #expect(PersonMentions.adjusted(tagged.mentions, replacing: NSRange(location: mention.location + 2, length: 1), with: "x").isEmpty)
    #expect(PersonMentions.query(in: "mail@example.com", selection: NSRange(location: 16, length: 0), mentions: []) == nil)
    #expect(PersonMentions.query(in: tagged.text, selection: NSRange(location: mention.location + 4, length: 0), mentions: tagged.mentions) == nil)
    #expect(PersonMentions.query(in: tagged.text, selection: NSRange(location: tagged.caret, length: 0), mentions: tagged.mentions) == nil)
    let continued = tagged.text + "at the beach "
    #expect(PersonMentions.query(in: continued, selection: NSRange(location: continued.utf16.count, length: 0), mentions: tagged.mentions) == nil)
    let another = continued + "@Al"
    #expect(PersonMentions.query(in: another, selection: NSRange(location: another.utf16.count, length: 0), mentions: tagged.mentions)?.name == "Al")
    #expect(PersonMentions.matchingPerson(named: "  RENEE SMITH ", in: [a])?.id == a.id)
}

@Test func photoDetailsPersistWithStableDateAndManualOrderAndDeletion() async throws {
    let store = try PlacesStore(); try await store.savePlace(hotel)
    let first = MemoryPhoto(id: "earlier", jpeg: Data([1]), thumbnail: Data([2]), details: MemoryPhotoDetails(createdAt: date(2, 8), coordinate: hotel.coordinate))
    let second = MemoryPhoto(id: "later", jpeg: Data([3]), thumbnail: Data([4]), details: MemoryPhotoDetails(createdAt: date(3, 8), utcOffsetSeconds: 7200))
    let unknown = MemoryPhoto(id: "undated", jpeg: Data([5]), thumbnail: Data([6]))
    let draft = PlaceMemory(placeID: hotel.id, photoIDs: [second.id, unknown.id, first.id])
    try await store.saveMemory(draft, adding: [first, second, unknown])
    var memory = try #require(try await store.memoryLibrary().memories.first)
    #expect(memory.orderedPhotoIDs == [first.id, second.id, unknown.id])
    #expect(memory.photoDetails?[first.id]?.coordinate == hotel.coordinate)
    memory.photoIDs = [second.id, first.id, unknown.id]; memory.photosManuallyOrdered = true
    try await store.saveMemory(memory)
    try await store.updatePhotoCaption(memoryID: memory.id, photoID: first.id, caption: "Morning walk")
    memory = try #require(try await store.memoryLibrary().memories.first)
    #expect(memory.photoDetails?[first.id]?.caption == "Morning walk")
    #expect(memory.orderedPhotoIDs == [second.id, first.id, unknown.id])
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let archive = try decoder.decode(HistoryArchive.self, from: await store.exportHistory())
    #expect(archive.memories?.memories.first?.photoDetails?[first.id]?.coordinate == hotel.coordinate)
    #expect(archive.memories?.memories.first?.photoDetails?[first.id]?.caption == "Morning walk")
    let diagnostics = String(decoding: try await store.exportDiagnostics(), as: UTF8.self)
    #expect(!diagnostics.contains("Morning walk") && !diagnostics.contains("photoDetails"))
    memory.photosManuallyOrdered = false
    #expect(memory.orderedPhotoIDs == [first.id, second.id, unknown.id])
    memory.photoIDs.removeAll { $0 == first.id }
    try await store.saveMemory(memory)
    #expect(try await store.photoData(id: first.id) == nil)
    #expect(try await store.memoryLibrary().memories.first?.photoDetails?[first.id] == nil)
    await #expect(throws: MemoryError.self) { try await store.updatePhotoCaption(memoryID: memory.id, photoID: first.id, caption: "Deleted") }
    let legacy = PlaceMemory(placeID: hotel.id, photoIDs: ["a", "b"])
    let decoded = try JSONDecoder().decode(PlaceMemory.self, from: JSONEncoder().encode(legacy))
    #expect(decoded.photoDetails == nil && decoded.photosManuallyOrdered == nil && decoded.orderedPhotoIDs == ["a", "b"])
}

@Test func avatarsMentionsAndDescriptionsPersistAndDeletionOnlyUnlinksNames() async throws {
    let store = try PlacesStore(); try await store.savePlace(hotel)
    let parent = MemoryPerson(id: "parent", name: "Henk", avatarJPEG: Data([7, 8, 9]))
    try await store.savePerson(parent)
    let note = "Kid of @Henk"
    let tag = PersonMention(personID: parent.id, location: 7, length: 5)
    let child = MemoryPerson(id: "child", name: "Lou", detail: note, mentions: [tag])
    try await store.savePerson(child)
    let memory = PlaceMemory(text: note, placeID: hotel.id, mentions: [tag])
    try await store.saveMemory(memory)
    #expect(try await store.memoryLibrary().people.first { $0.id == parent.id }?.avatarJPEG == parent.avatarJPEG)
    #expect(try await store.memoryLibrary().memories.first?.linkedPersonIDs == [parent.id])
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let archive = try decoder.decode(HistoryArchive.self, from: await store.exportHistory())
    #expect(archive.memories?.people.first { $0.id == child.id }?.mentions == [tag])
    var tooLarge = parent; tooLarge.avatarJPEG = Data(repeating: 1, count: 200_001)
    await #expect(throws: MemoryError.self) { try await store.savePerson(tooLarge) }
    try await store.deletePerson(id: parent.id)
    let library = try await store.memoryLibrary()
    #expect(library.memories.first?.text == note)
    #expect(library.memories.first?.mentions == [])
    #expect(library.people.first?.detail == note)
    #expect(library.people.first?.mentions == [])
    try await store.eraseHistory(resetSettings: true)
    #expect(try await store.memoryLibrary().people.isEmpty)
}

@Test func legacyPeopleAndMemoriesDecodeWithoutAvatarOrMentionFields() throws {
    let person = try JSONDecoder().decode(MemoryPerson.self, from: Data(#"{"id":"legacy","name":"Alex","detail":"A friend"}"#.utf8))
    #expect(person.avatarJPEG == nil && person.mentions == nil)
    #expect(person.initials == "A")
    #expect(person.resolvedColorIndex == 5)
    var value = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(PlaceMemory(text: "Old note", placeID: hotel.id))) as? [String: Any])
    value.removeValue(forKey: "mentions")
    #expect(try JSONDecoder().decode(PlaceMemory.self, from: JSONSerialization.data(withJSONObject: value)).mentions == nil)
}

@Test func avatarSuggestionsOnlyUsePhotosFromThatPersonsTripsOrLinkedMemories() {
    let person = MemoryPerson(id: "friend", name: "Friend")
    let trip = Trip(title: "Shared", start: date(2, 0), end: date(5, 0), personIDs: [person.id])
    var library = MemoryLibrary(); library.people = [person]; library.trips = [trip]
    library.memories = [PlaceMemory(date: date(3, 0), tripID: trip.id, photoIDs: ["trip-photo"]),
        PlaceMemory(date: date(4, 0), placeID: hotel.id, visitStart: date(4, 0), photoIDs: ["visit-photo"]),
        PlaceMemory(date: date(4, 0), placeID: hotel.id, photoIDs: ["unrelated-place-photo"]),
        PlaceMemory(date: date(1, 0), placeID: hotel.id, personIDs: [person.id], photoIDs: ["tagged-photo"])]
    #expect(library.avatarPhotoIDs(for: person.id, now: date(6, 0)) == ["visit-photo", "trip-photo", "tagged-photo"])
    #expect(library.avatarPhotoIDs(for: "someone-else", now: date(6, 0)).isEmpty)
}


@Test func placeAndTripPhotosPersistExportPrivatelyAndCanBeRemoved() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("cover-\(UUID()).sqlite")
    defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path.path + suffix) } }
    let store = try PlacesStore(path: path.path)
    let photo = Data("Synthetic cover photo payload".utf8)
    var place = hotel; place.photoJPEG = photo
    var trip = Trip(title: "Private trip", start: date(1, 0), end: date(5, 0), photoJPEG: photo)
    try await store.savePlace(place); try await store.saveTrip(trip)
    let reopened = try PlacesStore(path: path.path)
    #expect(try await reopened.places().first?.photoJPEG == photo)
    #expect(try await reopened.memoryLibrary().trips.first?.photoJPEG == photo)
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let archive = try decoder.decode(HistoryArchive.self, from: await reopened.exportHistory())
    #expect(archive.places.first?.photoJPEG == photo)
    #expect(archive.memories?.trips.first?.photoJPEG == photo)
    for export in [try await reopened.exportDiagnostics(), try await reopened.exportTestCase()] {
        let text = String(decoding: export, as: UTF8.self)
        #expect(!text.contains("photoJPEG") && !text.contains(photo.base64EncodedString()))
    }
    for invalid in [Data(), Data(repeating: 1, count: 200_001)] {
        var invalidPlace = place; invalidPlace.photoJPEG = invalid
        var invalidTrip = trip; invalidTrip.photoJPEG = invalid
        await #expect(throws: MemoryError.invalidPhoto) { try await reopened.savePlace(invalidPlace) }
        await #expect(throws: MemoryError.invalidPhoto) { try await reopened.saveTrip(invalidTrip) }
    }
    #expect(try await reopened.places().first?.photoJPEG == photo)
    #expect(try await reopened.memoryLibrary().trips.first?.photoJPEG == photo)
    place.photoJPEG = nil; trip.photoJPEG = nil
    try await reopened.savePlace(place); try await reopened.saveTrip(trip)
    #expect(try await store.places().first?.photoJPEG == nil)
    #expect(try await store.memoryLibrary().trips.first?.photoJPEG == nil)
    #expect(try await store.places().first?.symbol == hotel.symbol)
}

@Test func oldPlacesAndTripsDecodeWithoutPhotoFields() throws {
    let trip = Trip(title: "Existing trip", start: date(1, 0))
    for data in [try JSONEncoder().encode(hotel), try JSONEncoder().encode(trip)] {
        #expect(!String(decoding: data, as: UTF8.self).contains("photoJPEG"))
    }
    #expect(try JSONDecoder().decode(Place.self, from: JSONEncoder().encode(hotel)).photoJPEG == nil)
    #expect(try JSONDecoder().decode(Trip.self, from: JSONEncoder().encode(trip)).photoJPEG == nil)
}
