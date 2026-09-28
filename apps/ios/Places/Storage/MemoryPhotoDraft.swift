import Foundation
import PlacesCore

/// Draft photos are never stored in the photo library or a cloud container.
/// A cancelled editor releases its files; startup also removes abandoned imports.
final class MemoryPhotoDraft {
    private let directory = MemoryPhotoDraft.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    private static var root: URL { FileManager.default.temporaryDirectory.appendingPathComponent("PlacesPhotoDrafts", isDirectory: true) }

    func append(_ photo: MemoryPhoto) throws -> MemoryPhotoFile {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication, .posixPermissions: 0o700])
        var folder = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        let jpeg = directory.appendingPathComponent(photo.id + ".jpg")
        let thumbnail = directory.appendingPathComponent(photo.id + "-thumbnail.jpg")
        try photo.jpeg.write(to: jpeg, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try photo.thumbnail.write(to: thumbnail, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return MemoryPhotoFile(id: photo.id, jpegURL: jpeg, thumbnailURL: thumbnail, details: photo.details)
    }
    func remove(_ photo: MemoryPhotoFile) {
        try? FileManager.default.removeItem(at: photo.jpegURL)
        try? FileManager.default.removeItem(at: photo.thumbnailURL)
    }
    func discard() { try? FileManager.default.removeItem(at: directory) }
    static func clearAbandonedImports() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}
