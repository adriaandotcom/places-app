import Foundation
import Testing
import GRDB
import ZIPFoundation
@testable import PlacesCore

private let backupDate = Date(timeIntervalSince1970: 1_780_000_000.123456)
private func backupWorkspace() throws -> URL {
    try PlacesBackup.createWorkspace(in: FileManager.default.temporaryDirectory.appendingPathComponent("PlacesBackupTests"))
}
private func populatedBackupStore() async throws -> PlacesStore {
    let store = try PlacesStore()
    let point = Coordinate(latitude: 52.36, longitude: 4.88)
    var place = Place(id: "park", name: "Picnic <script>alert('x')</script> & friends", address: "Amsterdam", coordinate: point, expectedSSIDs: ["Fixture Wi-Fi"])
    place.photoJPEG = Data([1, 2, 3]); place.customColorHex = "#123456"
    try await store.savePlace(place)
    let person = MemoryPerson(id: "person", name: "Fixture Friend", detail: "Only demo data", avatarJPEG: Data([3, 4]))
    try await store.savePerson(person)
    try await store.saveTrip(Trip(id: "trip", title: "Fixture trip", start: backupDate, end: backupDate.addingTimeInterval(86400), personIDs: [person.id], titleEdited: true, photoJPEG: Data([4, 5])))
    let observations = [
        SensorObservation(id: "arrival", timestamp: backupDate, source: .visitArrival, coordinate: point, horizontalAccuracy: 10),
        SensorObservation(id: "wifi", timestamp: backupDate.addingTimeInterval(10), source: .wifi, coordinate: point, horizontalAccuracy: 10, ssid: "Fixture Wi-Fi", bssid: "02:00:00:00:00:01"),
        SensorObservation(id: "end", timestamp: backupDate.addingTimeInterval(3600), source: .location, coordinate: point, horizontalAccuracy: 10)
    ]
    _ = try await store.append(observations)
    var memory = PlaceMemory(id: "memory", text: "Picnic & sunshine", date: backupDate.addingTimeInterval(100), tripID: "trip", placeID: "park", personIDs: ["person"], photoIDs: ["photo"])
    memory.photoDetails = ["photo": .init(createdAt: backupDate, utcOffsetSeconds: 7200, coordinate: point, caption: "<img src=x onerror=alert(1)>")]
    memory.photosManuallyOrdered = true
    memory.coverPhotoID = "photo"
    try await store.saveMemory(memory, adding: [MemoryPhoto(id: "photo", jpeg: Data([7, 8, 9]), thumbnail: Data([7]))])
    try await store.setSetting("favoritePlaceColors", value: "[\"#123456\"]")
    for key in ["photoEvidenceEnabled", "trackingEnabled", "placeLookupEnabled", "mapsEnabled", "weeklyReviewReminders"] { try await store.setSetting(key, value: "true") }
    try await store.setSetting("mapProvider", value: "apple")
    try await store.setSetting("nerdMode", value: "true")
    let evidence = PhotoLocationEvidence(id: "evidence", assetID: "fixture-asset", capturedAt: backupDate, coordinate: point, cameraModel: "Fixture Phone", faceCount: 2)
    try await store.indexPhoto(assetID: evidence.assetID, fingerprint: "fingerprint", evidence: evidence)
    try await store.dismissPhotoSuggestions(assetIDs: [evidence.assetID])
    try await store.record(TrackingEvent(timestamp: backupDate, state: .knownPlace, reason: "fixture", previousStateDuration: 2, standardLocationActive: false, build: "test"))
    try await store.addBackupTestRows()
    return store
}

extension PlacesStore {
    fileprivate func addBackupTestRows() throws {
        try queue.write { db in
            try db.execute(sql: "INSERT INTO timelineSeparations(timestamp) VALUES (?)", arguments: [backupDate.timeIntervalSince1970])
            let edit = UserOverride(id: "correction", start: backupDate, end: backupDate.addingTimeInterval(900), kind: .stay, placeID: "park", createdAt: backupDate)
            try StoreSQL.saveCorrection(edit, db: db)
        }
    }
    fileprivate func canonicalRows() throws -> [String: [String]] {
        try queue.read { db in
            try BackupTable.checkSchema(db)
            var result: [String: [String]] = [:]
            for table in BackupTable.all {
                let cursor = try Row.fetchCursor(db, sql: table.select)
                var records: [String] = []
                while let row = try cursor.next() {
                    let data = try table.export(row) { "photos/" + BackupIO.hex(SHA256.hash(data: $0)) + ".jpg" }
                    records.append(String(decoding: data, as: UTF8.self))
                }
                result[table.name] = records.sorted()
            }
            return result
        }
    }
}
import CryptoKit

@Test func completeBackupRestoresEveryTableAndPhotoWithoutGrantingConsent() async throws {
    let root = try backupWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let source = try await populatedBackupStore()
    let before = try await source.canonicalRows()
    let zip = try await source.makeBackup(in: root)
    let prepared = try PlacesBackup.prepare(zip: zip, in: root)
    #expect(prepared.manifest.counts["memoryPhotos"] == 1)
    let path = root.appendingPathComponent("new-phone.sqlite").path
    let destination = try PlacesStore(path: path)
    try await destination.savePlace(Place(id: "replace", name: "Old data", coordinate: .init(latitude: 1, longitude: 2)))
    try await destination.restoreBackup(prepared)
    let after = try await destination.canonicalRows()
    for table in BackupTable.all where table.name != "settings" { #expect(before[table.name] == after[table.name], "Lost data in \(table.name)") }
    #expect(try await destination.photoData(id: "photo") == Data([7, 8, 9]))
    #expect(try await destination.setting("favoritePlaceColors") == "[\"#123456\"]")
    #expect(try await destination.setting("nerdMode") == "true")
    #expect(try await destination.setting("photoEvidenceEnabled") == "false")
    #expect(try await destination.setting("trackingEnabled") == "false")
    #expect(try await destination.setting("placeLookupEnabled") == "false")
    #expect(try await destination.setting("mapProvider") == "off")
    #expect(try await destination.search("Picnic").map(\.id) == ["park"])
    let reopened = try PlacesStore(path: path)
    #expect(try await reopened.photoData(id: "photo") == Data([7, 8, 9]))
    #expect(try await reopened.canonicalRows() == after)
    // Importing again replaces the same IDs, never duplicates history or photos.
    try await reopened.restoreBackup(prepared)
    #expect(try await reopened.canonicalRows() == after)
}

@Test func readableBackupEscapesNotesAndContainsImagesAndCorrectedHistory() async throws {
    let root = try backupWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let source = try await populatedBackupStore()
    _ = try await source.makeBackup(in: root)
    let contents = root.appendingPathComponent("contents")
    let memories = try String(contentsOf: contents.appendingPathComponent("memories.html"), encoding: .utf8)
    let places = try String(contentsOf: contents.appendingPathComponent("places.html"), encoding: .utf8)
    #expect(memories.contains("&lt;img src=x onerror=alert(1)&gt;"))
    #expect(!memories.contains("<img src=x"))
    #expect(places.contains("&lt;script&gt;")); #expect(!places.contains("<script>"))
    #expect(memories.contains("photos/")); #expect(memories.contains("Fixture Friend"))
    let index = try String(contentsOf: contents.appendingPathComponent("index.html"), encoding: .utf8)
    #expect(index.contains("timeline-")); #expect(index.contains("Restore on another iPhone"))
    #expect(index.contains("default-src 'none'")); #expect(!index.contains("https://"))
    let data = try String(contentsOf: contents.appendingPathComponent("data/observations.jsonl"), encoding: .utf8)
    #expect(data.contains("\"payload\":{")); #expect(data.contains("Fixture Wi-Fi"))
}

private func repack(_ root: URL, change: (URL) throws -> Void, updateChecksums: Bool = false) throws -> URL {
    let contents = root.appendingPathComponent("contents")
    try change(contents)
    if updateChecksums {
        let manifestURL = contents.appendingPathComponent("manifest.json")
        var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        var files = try #require(manifest["files"] as? [[String: Any]])
        for i in files.indices {
            let path = try #require(files[i]["path"] as? String)
            let (size, hash) = try BackupIO.digest(contents.appendingPathComponent(path))
            files[i]["bytes"] = size; files[i]["sha256"] = hash
        }
        manifest["files"] = files
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
    }
    let url = root.appendingPathComponent(UUID().uuidString + ".zip")
    let archive = try Archive(url: url, accessMode: .create)
    let files = FileManager.default.enumerator(atPath: contents.path)!
    for case let path as String in files {
        let file = contents.appendingPathComponent(path)
        guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
        try archive.addEntry(with: path, relativeTo: contents, compressionMethod: .deflate)
    }
    return url
}

@Test func damagedOrMissingPhotosAreRejectedBeforeRestore() async throws {
    let root = try backupWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try await populatedBackupStore()
    let before = try await store.canonicalRows()
    _ = try await store.makeBackup(in: root)
    let bad = try repack(root) { contents in
        let photo = try FileManager.default.contentsOfDirectory(at: contents.appendingPathComponent("photos"), includingPropertiesForKeys: nil).first!
        try Data([0]).write(to: photo)
    }
    #expect(throws: BackupError.self) { try PlacesBackup.prepare(zip: bad, in: root) }
    #expect(try await store.canonicalRows() == before)
}

@Test func validChecksumsCannotHideBrokenPhotoRelationships() async throws {
    let root = try backupWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try await populatedBackupStore()
    _ = try await store.makeBackup(in: root)
    let bad = try repack(root, change: { contents in
        let file = contents.appendingPathComponent("data/memoryPhotos.jsonl")
        let text = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "\"memoryID\":\"memory\"", with: "\"memoryID\":\"missing\"")
        try Data(text.utf8).write(to: file)
    }, updateChecksums: true)
    #expect(throws: BackupError.self) { try PlacesBackup.prepare(zip: bad, in: root) }
}

@Test func validChecksumsCannotHideInvalidCoordinatesOrMissingFiles() async throws {
    let root = try backupWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try await populatedBackupStore()
    _ = try await store.makeBackup(in: root)
    let badCoordinate = try repack(root, change: { contents in
        let file = contents.appendingPathComponent("data/places.jsonl")
        let original = try Data(contentsOf: file)
        var row = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var payload = try #require(row["payload"] as? [String: Any])
        payload["coordinate"] = ["latitude": 999, "longitude": 4.88]; row["payload"] = payload
        var data = try JSONSerialization.data(withJSONObject: row); data.append(10)
        try data.write(to: file)
    }, updateChecksums: true)
    #expect(throws: BackupError.self) { try PlacesBackup.prepare(zip: badCoordinate, in: root) }
    let missingFile = try repack(root) { contents in
        try FileManager.default.removeItem(at: contents.appendingPathComponent("data/memoryPhotos.jsonl"))
    }
    #expect(throws: BackupError.self) { try PlacesBackup.prepare(zip: missingFile, in: root) }
}

@Test func failureDuringReplacementRollsBackAllExistingTables() async throws {
    let root = try backupWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let source = try await populatedBackupStore()
    let zip = try await source.makeBackup(in: root)
    let prepared = try PlacesBackup.prepare(zip: zip, in: root)
    let target = try await populatedBackupStore()
    try await target.savePlace(Place(id: "keep", name: "Keep me", coordinate: .init(latitude: 1, longitude: 2)))
    let before = try await target.canonicalRows()
    let damaged = try DatabaseQueue(path: prepared.databaseURL.path)
    try await damaged.write { try $0.execute(sql: "DELETE FROM timelineSeparations") }
    try damaged.close()
    await #expect(throws: BackupError.self) { try await target.restoreBackup(prepared) }
    #expect(try await target.canonicalRows() == before)
}

@Test func zipPathsLinksAndFutureFormatsAreRejected() async throws {
    let root = try backupWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    for (path, type) in [("../escape", Entry.EntryType.file), ("/absolute", .file), ("link", .symlink)] {
        let zip = root.appendingPathComponent(UUID().uuidString + ".zip")
        let archive = try Archive(url: zip, accessMode: .create)
        try archive.addEntry(with: path, type: type, uncompressedSize: Int64(1)) { _, _ in Data([65]) }
        #expect(throws: BackupError.self) { try PlacesBackup.prepare(zip: zip, in: root) }
    }
    let store = try PlacesStore()
    _ = try await store.makeBackup(in: root)
    let future = try repack(root) { contents in
        let url = contents.appendingPathComponent("manifest.json")
        var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        manifest["version"] = 999
        try JSONSerialization.data(withJSONObject: manifest).write(to: url)
    }
    #expect(throws: BackupError.newerVersion) { try PlacesBackup.prepare(zip: future, in: root) }
}

@Test func emptyBackupCanRestoreAndUnknownTablesCannotSilentlyDisappear() async throws {
    let root = try backupWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let source = try PlacesStore()
    let zip = try await source.makeBackup(in: root)
    let prepared = try PlacesBackup.prepare(zip: zip, in: root)
    let target = try await populatedBackupStore()
    try await target.restoreBackup(prepared)
    #expect(try await target.places().isEmpty)
    #expect(try await target.memoryLibrary().memories.isEmpty)
    #expect(try await target.photoData(id: "photo") == nil)
    let fresh = try PlacesBackup.createWorkspace(in: root)
    try await source.addFutureTableForBackupTest()
    await #expect(throws: BackupError.newerVersion) { try await source.makeBackup(in: fresh) }
}
extension PlacesStore {
    fileprivate func addFutureTableForBackupTest() throws { try queue.write { try $0.execute(sql: "CREATE TABLE futureData(id TEXT)") } }
}

@Test func legacyBackupWithoutTraccarTableStillRestores() async throws {
    let root = try backupWorkspace(); defer { try? FileManager.default.removeItem(at: root) }
    let source = try await populatedBackupStore()
    _ = try await source.makeBackup(in: root)
    let legacy = try repack(root) { contents in
        let url = contents.appendingPathComponent("manifest.json")
        var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        manifest["version"] = 1
        var counts = try #require(manifest["counts"] as? [String: Int]); counts["traccarPoints"] = nil
        manifest["counts"] = counts
        let files = try #require(manifest["files"] as? [[String: Any]])
        manifest["files"] = files.filter { $0["path"] as? String != "data/traccarPoints.jsonl" }
        try JSONSerialization.data(withJSONObject: manifest).write(to: url)
        try FileManager.default.removeItem(at: contents.appendingPathComponent("data/traccarPoints.jsonl"))
    }
    let prepared = try PlacesBackup.prepare(zip: legacy, in: root)
    let target = try PlacesStore()
    try await target.restoreBackup(prepared)
    #expect(try await target.memoryLibrary().memories.count == 1)
    #expect(try await target.traccarPointCount() == 0)
}
