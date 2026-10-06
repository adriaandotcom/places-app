import Foundation
import Testing
@testable import PlacesCore

private let exportStart = Date(timeIntervalSince1970: 1_700_000_000)
private let exportArea = Coordinate(latitude: 0, longitude: 0)

@Test func limitedHistoryExportsOnlySelectedEvidenceAndRelatedImages() async throws {
    let store = try PlacesStore()
    var home = Place(id: "home", name: "Fixture Home", coordinate: exportArea)
    home.photoJPEG = Data([1, 2, 3])
    try await store.savePlace(home)
    try await store.savePlace(Place(id: "elsewhere", name: "Unrelated", coordinate: .init(latitude: 1, longitude: 1)))
    let person = MemoryPerson(id: "friend", name: "Fixture Friend", avatarJPEG: Data([4, 5, 6]))
    try await store.savePerson(person)
    try await store.savePerson(MemoryPerson(id: "unrelated", name: "Unrelated Person"))
    let period = DateInterval(start: exportStart, duration: 3600)
    let observations = [-600.0, 0, 600, 3599, 3600, 7200].map { second in
        SensorObservation(id: "sample-\(second)", timestamp: exportStart.addingTimeInterval(second), source: .location,
            coordinate: exportArea, horizontalAccuracy: 5)
    }
    try await store.append(observations)
    for (id, seconds) in [("before", -1.0), ("inside", 0.0), ("end", 3600.0)] {
        let photo = MemoryPhoto(id: "photo-\(id)", jpeg: Data([10]), thumbnail: Data([11]))
        try await store.saveMemory(PlaceMemory(id: id, text: id, date: exportStart.addingTimeInterval(seconds),
            placeID: home.id, personIDs: [person.id], photoIDs: [photo.id]), adding: [photo])
    }
    let archive = try await store.fullHistoryArchive(in: period)
    #expect(archive.period == period)
    #expect(archive.observations.map(\.id) == ["sample-0.0", "sample-600.0", "sample-3599.0"])
    #expect(archive.timeline.first?.start == period.start && archive.timeline.last?.end == period.end)
    #expect(archive.places.map(\.id) == [home.id])
    #expect(archive.memories?.memories.map(\.id) == ["inside"])
    #expect(archive.memories?.photos.map(\.id) == ["photo-inside"])
    #expect(archive.memories?.people.map(\.id) == [person.id])
    let small = try await store.fullHistoryArchive(in: period, includePhotos: false)
    #expect(small.memories?.photos.isEmpty == true)
    #expect(small.places.first?.photoJPEG == nil && small.memories?.people.first?.avatarJPEG == nil)
    #expect(small.memories?.memories.first?.photoIDs == ["photo-inside"])
    let gpx = String(decoding: try await store.exportGPX(in: period), as: UTF8.self)
    #expect(gpx.components(separatedBy: "<trkpt ").count - 1 == 3)
    #expect(!gpx.contains("Unrelated"))
    let testCase = try InferenceTestCase.decode(await store.exportTestCase(in: period))
    #expect(testCase.input.observations.count == 3)
    #expect(testCase.input.period?.duration == period.duration)
    #expect(testCase.expectedTimeline.allSatisfy { $0.start >= testCase.input.period!.start && $0.end! <= testCase.input.period!.end })
    #expect(testCase.replay() == testCase.expectedTimeline)
    #expect(try await store.observations().count == observations.count)
    #expect(try await store.fullHistoryArchive().memories?.photos.count == 3)
}

@Test func exportClipsNestedGapsAndCorrectionsAndKeepsEmptyPeriodsEmpty() async throws {
    let store = try PlacesStore()
    try await store.savePlace(Place(id: "home", name: "Fixture Home", coordinate: exportArea))
    try await store.append([SensorObservation(timestamp: exportStart, source: .location, coordinate: exportArea, horizontalAccuracy: 5),
        SensorObservation(timestamp: exportStart.addingTimeInterval(180), source: .location, coordinate: exportArea, horizontalAccuracy: 5),
        SensorObservation(timestamp: exportStart.addingTimeInterval(600), source: .recovery),
        SensorObservation(timestamp: exportStart.addingTimeInterval(700), source: .location, coordinate: exportArea, horizontalAccuracy: 5),
        SensorObservation(timestamp: exportStart.addingTimeInterval(880), source: .location, coordinate: exportArea, horizontalAccuracy: 5)])
    let period = DateInterval(start: exportStart.addingTimeInterval(200), duration: 600)
    let archive = try await store.fullHistoryArchive(in: period)
    #expect(archive.timeline.count == 1)
    let originals = try #require(archive.timeline.first?.originalItems)
    #expect(originals.allSatisfy { $0.start >= period.start && $0.end! <= period.end })
    try await store.correct(UserOverride(start: exportStart, end: exportStart.addingTimeInterval(7200), kind: .stay, placeID: "home"))
    let corrected = try await store.fullHistoryArchive(in: period)
    #expect(corrected.corrections.first?.start == period.start && corrected.corrections.first?.end == period.end)
    let empty = try await store.fullHistoryArchive(in: DateInterval(start: exportStart.addingTimeInterval(-7200), duration: 3600))
    #expect(empty.observations.isEmpty && empty.timeline.isEmpty && empty.places.isEmpty)
}

@Test func currentPeriodDoesNotInventAnOngoingVisitsDeparture() async throws {
    let now = Date(), store = try PlacesStore()
    try await store.savePlace(Place(id: "home", name: "Fixture Home", coordinate: exportArea))
    try await store.append([SensorObservation(timestamp: now.addingTimeInterval(-100), source: .location,
        coordinate: exportArea, horizontalAccuracy: 5)])
    let period = DateInterval(start: now.addingTimeInterval(-200), end: now.addingTimeInterval(3600))
    let archive = try await store.fullHistoryArchive(in: period)
    #expect(archive.timeline.count == 1 && archive.timeline[0].end == nil)
    let testCase = try InferenceTestCase.decode(await store.exportTestCase(in: period))
    #expect(testCase.expectedTimeline.first?.end == nil)
    #expect(testCase.input.referenceDate != nil)
    #expect(testCase.replay() == testCase.expectedTimeline)
}
