import XCTest
import UIKit
import PlacesCore
@testable import Places

@MainActor final class BackupTransferTests: XCTestCase {
    func testSavedImagesAndPrivateStagingSurviveTransfer() async throws {
        let root = try PlacesBackup.createWorkspace(in: FileManager.default.temporaryDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { context in
            UIColor.systemGreen.setFill(); context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        let jpeg = try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
        let store = try PlacesStore()
        let point = Coordinate(latitude: 52.36, longitude: 4.88)
        let place = Place(id: "demo-park", name: "Picnic in Amsterdam", address: "Synthetic example", coordinate: point, photoJPEG: jpeg)
        try await store.savePlace(place)
        let now = Date()
        _ = try await store.append([
            SensorObservation(timestamp: now.addingTimeInterval(-3600), source: .visitArrival, coordinate: point, horizontalAccuracy: 5),
            SensorObservation(timestamp: now, source: .visitDeparture, coordinate: point, horizontalAccuracy: 5)
        ])
        let photo = MemoryPhoto(id: "demo-photo", jpeg: jpeg, thumbnail: jpeg)
        var memory = PlaceMemory(text: "A sunny afternoon with friends.", date: now, placeID: place.id, photoIDs: [photo.id])
        memory.photoDetails = [photo.id: MemoryPhotoDetails(createdAt: now, caption: "A synthetic green square")]
        try await store.saveMemory(memory, adding: [photo])
        let zip = try await store.makeBackup(in: root)
        let attachment = XCTAttachment(contentsOfFile: zip)
        attachment.name = "Synthetic readable Places backup"; attachment.lifetime = .keepAlways; add(attachment)
        let prepared = try await Task.detached { try PlacesBackup.prepare(zip: zip, in: root) }.value
        let destination = try PlacesStore(path: root.appendingPathComponent("phone.sqlite").path)
        try await destination.restoreBackup(prepared)
        let restored = try await destination.photoData(id: photo.id)
        XCTAssertEqual(restored, jpeg)
        XCTAssertNotNil(UIImage(data: try XCTUnwrap(restored)))
        let library = try await destination.memoryLibrary()
        XCTAssertEqual(library.memories.first?.photoDetails?[photo.id]?.caption, "A synthetic green square")
        // Simulator files live on macOS without iOS Data Protection classes.
        #if !targetEnvironment(simulator)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!.allObjects
        for case let file as URL in files where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.protectionKey] as? FileProtectionType,
                           .completeUntilFirstUserAuthentication)
        }
        #endif
    }
}
