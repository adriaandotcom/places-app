import Foundation
import Testing
@testable import PlacesCore

@Test func traccarHistoryIsPermanentDeduplicatedAndSeparateFromTimeline() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let path = folder.appendingPathComponent("history.sqlite").path
    let date = Date(timeIntervalSince1970: 1_780_000_000)
    let point = TraccarPoint(timestamp: date, coordinate: .init(latitude: 52.36, longitude: 4.88), accuracy: 200)
    let store = try PlacesStore(path: path)
    try await store.appendTraccar(point)
    try await store.appendTraccar(point)
    #expect(try await store.traccarPointCount() == 1)
    #expect(try await store.timeline(on: date).isEmpty)
    #expect(try await store.observations(from: date, to: date.addingTimeInterval(1)).isEmpty)
    let reopened = try PlacesStore(path: path)
    #expect(try await reopened.lastTraccarPoint() == point)
    #expect(try await reopened.traccarPoints(from: date, to: date.addingTimeInterval(1)) == [point])
    #expect(try await reopened.traccarPoints(from: date.addingTimeInterval(-1), to: date).isEmpty)
    #expect(try await reopened.fullHistoryArchive().traccarPoints == [point])
    let diagnostics = try await reopened.exportDiagnostics()
    #expect(!String(decoding: diagnostics, as: UTF8.self).contains("52.36"))
    try await reopened.eraseHistory(resetSettings: true)
    #expect(try await reopened.traccarPointCount() == 0)
}

@Test func traccarBackupRestoresPointsWithoutStartingCollector() async throws {
    let store = try PlacesStore()
    let point = TraccarPoint(timestamp: Date(), coordinate: .init(latitude: 52.36, longitude: 4.88), accuracy: 10, speed: 2)
    try await store.appendTraccar(point)
    try await store.setSetting("traccarEnabled", value: "true")
    let workspace = try PlacesBackup.createWorkspace(in: FileManager.default.temporaryDirectory)
    defer { try? FileManager.default.removeItem(at: workspace) }
    let zip = try await store.makeBackup(in: workspace)
    let restoreWorkspace = try PlacesBackup.createWorkspace(in: workspace)
    let prepared = try PlacesBackup.prepare(zip: zip, in: restoreWorkspace)
    let destination = try PlacesStore()
    try await destination.restoreBackup(prepared)
    #expect(try await destination.lastTraccarPoint() == point)
    #expect(try await destination.setting("traccarEnabled") == "false")
    #expect(try await destination.timeline(on: point.timestamp).isEmpty)
}

@Test func traccarRejectsInvalidCoordinatesAndMetadata() async throws {
    let store = try PlacesStore()
    for point in [TraccarPoint(timestamp: Date(), coordinate: .init(latitude: 95, longitude: 1)),
                  TraccarPoint(timestamp: Date(), coordinate: .init(latitude: 1, longitude: 1), accuracy: -.infinity)] {
        await #expect(throws: PlacesError.self) { try await store.appendTraccar(point) }
    }
    #expect(try await store.traccarPointCount() == 0)
}
