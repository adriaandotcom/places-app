import XCTest
import ImageIO
import UniformTypeIdentifiers
import UIKit
import PlacesCore
@preconcurrency import Photos
@testable import Places

@MainActor final class PhotoEvidenceTests: XCTestCase {
    #if targetEnvironment(simulator)
    /// Runs against the dedicated QA simulator's Photos library after a Photos
    /// grant. Synthetic pictures only; never requests access on a real device.
    func testPhotoKitScanReviewAndMemoryImport() async throws {
        if ProcessInfo.processInfo.environment["PLACES_PHOTO_INTEGRATION"] == "1" {
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        try XCTSkipUnless(PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized,
                          "Grant Photos on the QA simulator for the PhotoKit integration check (status: \(PHPhotoLibrary.authorizationStatus(for: .readWrite).rawValue))")
        let date = Date().addingTimeInterval(-3600)
        let location = CLLocation(latitude: 12, longitude: 34)
        func add(model: String, offset: Double) async throws -> PHAsset {
            let pixels = UIGraphicsImageRenderer(size: CGSize(width: 30, height: 30)).image { context in
                UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 30, height: 30))
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
            defer { try? FileManager.default.removeItem(at: url) }
            let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(writer, try XCTUnwrap(pixels.cgImage), [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: model]] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(writer))
            let createdAt = date.addingTimeInterval(offset)
            try await PHPhotoLibrary.shared().performChanges { @Sendable in
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: url, options: nil)
                request.creationDate = createdAt; request.location = location
            }
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate <= %@", createdAt.addingTimeInterval(-0.01) as NSDate, createdAt.addingTimeInterval(0.01) as NSDate)
            return try XCTUnwrap(PHAsset.fetchAssets(with: options).firstObject)
        }
        let accepted = try await add(model: "iPhone 16 Pro", offset: 0)
        let wrongModel = try await add(model: "iPhone 16 Pro Max", offset: 1)
        let tooOld = try await add(model: "iPhone 16 Pro", offset: -31 * 86400)
        let store = try PlacesStore(), library = PhotoLibraryEvidence(currentModel: "iPhone 16 Pro")
        await library.start(store: store)
        await library.setEnabled(true)
        await library.finishBackgroundScan()
        let value = try XCTUnwrap(library.evidence.first { $0.assetID == accepted.localIdentifier })
        XCTAssertFalse(library.evidence.contains { $0.assetID == wrongModel.localIdentifier || $0.assetID == tooOld.localIdentifier })
        await library.sync()
        let all = try await store.photoEvidence(includeHistory: true)
        XCTAssertEqual(all.filter { $0.assetID == accepted.localIdentifier }.count, 1)
        let imported = try await library.importPhoto(value)
        XCTAssertEqual(imported.details?.coordinate, value.coordinate)
        XCTAssertEqual(imported.details?.createdAt, value.capturedAt)
        let place = Place(name: "Synthetic photo park", coordinate: value.coordinate)
        try await store.savePlace(place)
        let memory = PlaceMemory(date: value.capturedAt, placeID: place.id, photoIDs: [imported.id])
        try await store.saveMemory(memory, adding: [imported])
        await library.dismiss([value])
        XCTAssertFalse(library.evidence.contains { $0.assetID == value.assetID })
        await library.erase()
        XCTAssertFalse(library.canRead)
        let saved = try await store.memoryLibrary()
        XCTAssertEqual(saved.memories.first?.id, memory.id, "Opting out must preserve confirmed memories")
    }
    #endif
    func testOriginalCameraMetadataMatchesExactModel() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
            UIColor.systemGreen.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, try XCTUnwrap(image.cgImage), [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 16 Pro"]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        let camera = PhotoLibraryEvidence.cameraMetadata(url)
        XCTAssertEqual(camera.model, "iPhone 16 Pro")
        XCTAssertTrue(PhotoEvidence.matches(cameraMake: camera.make, cameraModel: camera.model, currentModel: PhotoCameraModel.name(for: "iPhone17,1")))
        XCTAssertFalse(PhotoEvidence.matches(cameraMake: camera.make, cameraModel: camera.model, currentModel: PhotoCameraModel.name(for: "iPhone17,2")))
        XCTAssertNil(PhotoCameraModel.name(for: "unknown-future-iPhone"))
    }
    func testPhotoCollectionDefaultsOffWithoutRequestingAccessAndCanErase() async throws {
        let store = try PlacesStore()
        let library = PhotoLibraryEvidence()
        await library.start(store: store)
        XCTAssertFalse(library.enabled)
        XCTAssertFalse(library.canRead)
        XCTAssertFalse(library.scanning)
        XCTAssertTrue(library.suggestions.isEmpty)
        await library.sync()
        XCTAssertFalse(library.scanning)
        await library.erase()
        let enabled = try await store.setting("photoEvidenceEnabled")
        XCTAssertEqual(enabled, "false")
        XCTAssertTrue(library.evidence.isEmpty)
    }
}
