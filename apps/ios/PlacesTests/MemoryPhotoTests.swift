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
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 1.0, kCGImagePropertyGPSLongitude: 2.0],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Private fixture metadata"]
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let photo = try MemoryPhotoImport.make(source as Data)
        XCTAssertLessThanOrEqual(photo.jpeg.count + photo.thumbnail.count, 500_000)
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
    func testUnreadablePhotoIsRejected() {
        XCTAssertThrowsError(try MemoryPhotoImport.make(Data("not a photo".utf8)))
    }
}
