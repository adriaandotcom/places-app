import XCTest
import ImageIO
import UniformTypeIdentifiers
import UIKit
import PlacesCore
@testable import Places

@MainActor final class MemoryPhotoTests: XCTestCase {
    func testPhotoCopiesAreBoundedAndRemoveEmbeddedLocationMetadata() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 2000)).image { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 3000, height: 2000))
        }
        let source = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(source, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 1.0, kCGImagePropertyGPSLongitude: 2.0,
                kCGImagePropertyGPSLatitudeRef: "S", kCGImagePropertyGPSLongitudeRef: "W"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Private fixture metadata",
                kCGImagePropertyExifDateTimeOriginal: "2026:09:24 10:15:30", kCGImagePropertyExifOffsetTimeOriginal: "+03:00"]
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let photo = try MemoryPhotoImport.make(source as Data)
        XCTAssertLessThanOrEqual(photo.jpeg.count + photo.thumbnail.count, 500_000)
        XCTAssertEqual(photo.details?.coordinate, Coordinate(latitude: -1, longitude: -2))
        XCTAssertEqual(photo.details?.utcOffsetSeconds, 10800)
        XCTAssertEqual(photo.details?.createdAt, ISO8601DateFormatter().date(from: "2026-09-24T07:15:30Z"))
        for (data, maximum) in [(photo.jpeg, 1600), (photo.thumbnail, 320)] {
            let result = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(result, 0, nil) as? [CFString: Any])
            XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
            XCTAssertNil(exif?[kCGImagePropertyExifUserComment])
            XCTAssertLessThanOrEqual(try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int), maximum)
            XCTAssertLessThanOrEqual(try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int), maximum)
        }
    }
    func testDetailedPhotosAlwaysFitTheHalfMegabyteBudget() throws {
        let width = 2400, height = 1800
        var state: UInt64 = 123
        let pixels = Data((0..<(width * height * 4)).map { index -> UInt8 in
            if index % 4 == 3 { return 255 }
            state = state &* 6364136223846793005 &+ 1
            return UInt8(truncatingIfNeeded: state >> 32)
        })
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let output = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, image, nil); XCTAssertTrue(CGImageDestinationFinalize(output))
        let photo = try MemoryPhotoImport.make(data as Data)
        XCTAssertLessThanOrEqual(photo.jpeg.count, 450_000)
        XCTAssertLessThanOrEqual(photo.thumbnail.count, 50_000)
        XCTAssertLessThanOrEqual(photo.jpeg.count + photo.thumbnail.count, 500_000)
    }
    func testImportedDraftsAreProtectedExcludedFromBackupAndDiscarded() throws {
        let draft = MemoryPhotoDraft()
        let file = try draft.append(MemoryPhoto(jpeg: Data([1, 2, 3]), thumbnail: Data([4, 5])))
        // Simulator files live on the Mac and have no iOS Data Protection class.
        #if !targetEnvironment(simulator)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.jpegURL.path)
        XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .completeUntilFirstUserAuthentication)
        #endif
        XCTAssertEqual(try file.jpegURL.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        draft.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.jpegURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.thumbnailURL.path))
    }
    func testAvatarCropIsSquareBoundedAndStripsMetadata() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 800), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 400))
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 400, width: 1200, height: 400))
        }
        let source = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(source, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 1.0],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Private fixture"]
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let data = try AvatarImage.cropped(source as Data, rect: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertLessThanOrEqual(data.count, 200_000)
        let result = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(result, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 512)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 512)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertNil((properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment])
        // Crop coordinates are measured from the top, matching the preview and Vision conversion.
        for (y, expectedChannel) in [(0.0, 0), (0.5, 2)] {
            let crop = try AvatarImage.cropped(source as Data, rect: CGRect(x: 0, y: y, width: 0.2, height: 0.25))
            let decoded = try XCTUnwrap(CGImageSourceCreateWithData(crop as CFData, nil))
            let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
            var pixel = [UInt8](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes { bytes in
                let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
                context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            XCTAssertGreaterThan(pixel[expectedChannel], 220)
            XCTAssertLessThan(pixel[expectedChannel == 0 ? 2 : 0], 30)
        }
        XCTAssertThrowsError(try AvatarImage.cropped(source as Data, rect: CGRect(x: 2, y: 2, width: 1, height: 1)))
        XCTAssertThrowsError(try AvatarImage.cropped(Data(), rect: .zero))
    }

    func testFaceSuggestionSquaresStayInsidePortraitAndLandscapeImages() {
        for (width, height) in [(1600.0, 900.0), (900.0, 1600.0)] {
            for face in [CGRect(x: 0.02, y: 0.02, width: 0.15, height: 0.2), CGRect(x: 0.8, y: 0.8, width: 0.2, height: 0.2)] {
                let square = AvatarImage.square(around: face, width: width, height: height)
                XCTAssertEqual(square.width * width, square.height * height, accuracy: 0.001)
                XCTAssertGreaterThanOrEqual(square.minX, 0); XCTAssertGreaterThanOrEqual(square.minY, 0)
                XCTAssertLessThanOrEqual(square.maxX, 1.001); XCTAssertLessThanOrEqual(square.maxY, 1.001)
                XCTAssertTrue(square.contains(CGPoint(x: face.midX, y: face.midY)))
            }
        }
    }

    func testSuggestionPhotoURLReusesBoundedImportAndSuppliedDate() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2400, height: 1600)).image { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2400, height: 1600))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try XCTUnwrap(image.jpegData(compressionQuality: 1)).write(to: url)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let photo = try MemoryPhotoImport.make(url: url, date: date)
        XCTAssertLessThanOrEqual(photo.jpeg.count, 450_000)
        XCTAssertLessThanOrEqual(photo.thumbnail.count, 50_000)
        XCTAssertEqual(photo.details?.createdAt, date)
        XCTAssertThrowsError(try MemoryPhotoImport.make(url: URL(string: "https://example.com/photo.jpg")!))
    }

    func testUnreadablePhotoIsRejected() {
        XCTAssertThrowsError(try MemoryPhotoImport.make(Data("not a photo".utf8)))
    }
}
