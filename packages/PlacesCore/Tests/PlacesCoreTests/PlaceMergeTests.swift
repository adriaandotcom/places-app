import Foundation
import Testing
@testable import PlacesCore

@Test func placeMergePrefersRecentUserEditsAndFallsBackToInvestment() {
    let point = Coordinate(latitude: 1, longitude: 1)
    let older = Place(id: "personal", name: "My garden", coordinate: point, symbol: "tree.fill", colorIndex: 3,
        customColorHex: "123456", userEditedAt: Date(timeIntervalSince1970: 100))
    var recent = Place(id: "journaling-place-import", name: "Garden", coordinate: point, userEditedAt: Date(timeIntervalSince1970: 200))
    #expect(PlaceMergePlan(older, recent).kept.id == recent.id)
    recent.userEditedAt = nil
    #expect(PlaceMergePlan(recent, older).kept == older)
    var legacy = older; legacy.userEditedAt = nil
    #expect(PlaceMergePlan(recent, legacy).kept == legacy)
    #expect(PlaceMergePlan(legacy, recent).kept == legacy)
}

@Test func mergePreservesVisitsPhotosWiFiCorrectionsAndRawEvidenceAcrossReopen() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("merge-\(UUID()).sqlite")
    defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path.path + suffix) } }
    let store = try PlacesStore(path: path.path)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let old = Place(id: "old", name: "Imported garden", coordinate: .init(latitude: 1, longitude: 1), expectedSSIDs: ["Fixture WiFi"])
    let kept = Place(id: "kept", name: "My garden", coordinate: .init(latitude: 2, longitude: 2), symbol: "tree.fill",
        expectedSSIDs: ["Fixture second network"], customColorHex: "7A1234", userEditedAt: date, photoJPEG: Data([5, 6, 7]))
    try await store.savePlace(old); try await store.savePlace(kept)
    try await store.append([
        SensorObservation(id: "arrival", timestamp: date, source: .wifi, coordinate: old.coordinate,
            horizontalAccuracy: 5, ssid: "Fixture WiFi", bssid: "02:00:00:00:00:01"),
        SensorObservation(id: "confirmation", timestamp: date.addingTimeInterval(180), source: .wifi,
            ssid: "Fixture WiFi", bssid: "02:00:00:00:00:01"),
        SensorObservation(id: "exit", timestamp: date.addingTimeInterval(600), source: .regionExit, monitoredPlaceID: old.id)
    ])
    let correction = UserOverride(id: "imported-visit", start: date.addingTimeInterval(3600), end: date.addingTimeInterval(4200),
        kind: .stay, placeID: old.id, importedVisitID: "apple-fixture")
    try await store.correct(correction)
    let photo = MemoryPhoto(id: "photo", jpeg: Data([1,2]), thumbnail: Data([3]))
    let person = MemoryPerson(id: "person", name: "Alex")
    try await store.savePerson(person)
    try await store.saveMemory(PlaceMemory(id: "memory", text: "A day together", date: correction.start,
        placeID: old.id, visitStart: correction.start, personIDs: [person.id], photoIDs: [photo.id]), adding: [photo])
    let before = try await store.observations()
    let result = try await store.mergePlaces(edited: old, with: kept.id, keeping: kept.id, now: date.addingTimeInterval(5000))
    #expect(result.photoJPEG == kept.photoJPEG)
    #expect(result.customColorHex == kept.customColorHex && result.symbol == kept.symbol && result.coordinate == kept.coordinate)
    #expect(Set(result.expectedSSIDs) == Set(old.expectedSSIDs + kept.expectedSSIDs))
    #expect(result.mergedPlaceIDs == [old.id])
    #expect(try await store.observations() == before)
    let reopened = try PlacesStore(path: path.path)
    #expect(try await reopened.places() == [result])
    let context = try await reopened.pastVisitContext()
    #expect(context.importedIDs == ["apple-fixture"])
    #expect(context.items.contains { $0.placeID == kept.id && $0.start == date && $0.end == date.addingTimeInterval(600) })
    #expect(context.items.contains { $0.placeID == kept.id && $0.start == correction.start && $0.end == correction.end })
    let library = try await reopened.memoryLibrary(now: date.addingTimeInterval(5000))
    #expect(library.memories.first?.placeID == kept.id && library.memories.first?.personIDs == [person.id])
    #expect(try await reopened.photoData(id: photo.id) == photo.jpeg)
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let archive = try decoder.decode(HistoryArchive.self, from: await reopened.exportHistory())
    #expect(archive.accessPoints.allSatisfy { $0.placeID == kept.id })
    #expect(archive.observations.first(where: { $0.id == "exit" })?.monitoredPlaceID == old.id)
}

@Test func mergeRejectsAStaleSelectionWithoutLosingEitherPlace() async throws {
    let store = try PlacesStore()
    let a = Place(id: "a", name: "A", coordinate: .init(latitude: 1, longitude: 1), userEditedAt: Date(timeIntervalSince1970: 1))
    let b = Place(id: "b", name: "B", coordinate: a.coordinate, userEditedAt: Date(timeIntervalSince1970: 2))
    try await store.savePlace(a); try await store.savePlace(b)
    await #expect(throws: PlacesError.self) { try await store.mergePlaces(edited: a, with: b.id, keeping: a.id) }
    var invalid = b; invalid.coordinate.latitude = 100
    await #expect(throws: PlacesError.self) { try await store.mergePlaces(edited: invalid, with: a.id, keeping: b.id) }
    #expect(try await store.places().count == 2)
}

@Test func mergedRegionCallbacksResolveWithoutChangingTheirEvidence() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let place = Place(id: "kept", name: "Garden", coordinate: .init(latitude: 1, longitude: 1), mergedPlaceIDs: ["old"])
    let observations = [SensorObservation(timestamp: date, source: .location, coordinate: place.coordinate, horizontalAccuracy: 5),
        SensorObservation(timestamp: date.addingTimeInterval(600), source: .regionExit, monitoredPlaceID: "old")]
    let items = InferenceEngine.infer(observations: observations, places: [place])
    #expect(items.first?.end == date.addingTimeInterval(600))
    #expect(items.last?.kind == .journey)
    #expect(observations.last?.monitoredPlaceID == "old")
}


@Test func placeMergePreservesTheChosenPhotoIncludingExplicitRemoval() {
    let original = Place(id: "original", name: "Garden", coordinate: .init(latitude: 1, longitude: 1))
    var personalized = original; personalized.id = "personalized"; personalized.photoJPEG = Data([1, 2, 3])
    #expect(PlaceMergePlan(original, personalized).combined.photoJPEG == personalized.photoJPEG)
    var edited = original; edited.userEditedAt = Date(timeIntervalSince1970: 100)
    #expect(PlaceMergePlan(personalized, edited).combined.photoJPEG == nil)
}
