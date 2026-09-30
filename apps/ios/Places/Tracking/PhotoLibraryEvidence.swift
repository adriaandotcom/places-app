import Foundation
import Observation
@preconcurrency import Photos
import UIKit
import ImageIO
import CryptoKit
import BackgroundTasks
import Vision
import PlacesCore

@MainActor @Observable final class PhotoLibraryEvidence: NSObject, PHPhotoLibraryChangeObserver {
    static let taskID = "com.adriaan.places.photo-evidence"
    private(set) var enabled = false
    private(set) var authorization = PHAuthorizationStatus.notDetermined
    private(set) var scanning = false
    private(set) var lastScan: Date?
    private(set) var status = "Off"
    private(set) var evidence: [PhotoLocationEvidence] = []
    let currentModel: String?
    private var store: PlacesStore?
    private var revision = 0
    private var registered = false
    private var scanTask: Task<Void, Never>?
    init(currentModel: String? = PhotoCameraModel.current) {
        self.currentModel = currentModel
        super.init()
    }
    #if DEBUG
    private var previewPhotos: [String: MemoryPhoto] = [:]
    #endif
    var canRead: Bool { enabled && authorization == .authorized }
    var suggestions: [PhotoVisitSuggestion] { canRead ? PhotoEvidence.suggestions(evidence) : [] }
    private var permitted: Bool { enabled && PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized }

    func start(store: PlacesStore) async {
        self.store = store
        enabled = (try? await store.setting("photoEvidenceEnabled")) == "true"
        lastScan = (try? await store.setting("photoEvidenceLastScan")).flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        updateAuthorization()
        if permitted { schedule(); requestScan() }
    }
    func setEnabled(_ value: Bool) async {
        guard let store else { return }
        revision += 1; scanTask?.cancel()
        enabled = value; evidence = []
        do { try await store.setSetting("photoEvidenceEnabled", value: value ? "true" : "false") }
        catch { enabled = false; status = "Couldn’t save this setting. Try again."; return }
        if value && PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined {
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        updateAuthorization()
        if permitted { schedule(); await sync() }
        else { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskID) }
    }
    func updateAuthorization() {
        #if DEBUG
        if !previewPhotos.isEmpty { return }
        #endif
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if permitted {
            if !registered { PHPhotoLibrary.shared().register(self); registered = true }
        } else {
            revision += 1; scanTask?.cancel(); evidence = []
            if registered { PHPhotoLibrary.shared().unregisterChangeObserver(self); registered = false }
            status = !enabled ? "Off" : "Full Photos access is needed for automatic suggestions."
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskID)
        }
    }
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in self?.updateAuthorization(); self?.requestScan() }
    }
    func requestScan() {
        guard permitted, scanTask == nil else { return }
        scanTask = Task { [weak self] in
            await self?.sync()
            self?.scanTask = nil
        }
    }
    func finishBackgroundScan() async {
        if let scanTask { await withTaskCancellationHandler { await scanTask.value } onCancel: { scanTask.cancel() } }
        else { await sync() }
    }
    func schedule() {
        guard permitted else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.taskID)
        request.earliestBeginDate = Date().addingTimeInterval(60 * 60)
        // iOS decides when to run; this is a preference, never a promised interval.
        try? BGTaskScheduler.shared.submit(request)
    }
    func sync() async {
        updateAuthorization()
        guard permitted, !scanning, let store else { return }
        guard let currentModel else { status = "This iPhone model isn’t recognized yet. Automatic photo import is paused."; return }
        scanning = true
        let epoch = revision
        defer { scanning = false; schedule() }
        let now = Date(), cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        do {
            let fingerprints = try await store.photoScanFingerprints()
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "mediaType == %d AND creationDate >= %@ AND creationDate <= %@", PHAssetMediaType.image.rawValue, cutoff as NSDate, now as NSDate)
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.includeAssetSourceTypes = [.typeUserLibrary]
            options.includeHiddenAssets = false
            let fetched = PHAsset.fetchAssets(with: options)
            var assets: [PHAsset] = []
            fetched.enumerateObjects { asset, _, _ in assets.append(asset) }
            try await store.reconcilePhotoAccess(accessibleIDs: Set(assets.map(\.localIdentifier)), since: cutoff)
            // Continue after the previous bounded pass so unavailable recent originals
            // cannot starve older photos in a large library.
            if let cursor = try await store.setting("photoEvidenceCursor"), let index = assets.firstIndex(where: { $0.localIdentifier == cursor }), index + 1 < assets.count {
                assets = Array(assets[(index + 1)...]) + Array(assets[...index])
            }
            var completed = true
            var lastChecked: String?
            for asset in assets {
                try Task.checkCancellation()
                guard permitted, epoch == revision else { throw CancellationError() }
                let fingerprint = Self.fingerprint(asset, model: currentModel)
                guard fingerprints[asset.localIdentifier] != fingerprint else { continue }
                if Date().timeIntervalSince(now) > 20 { completed = false; break }
                lastChecked = asset.localIdentifier
                guard let date = asset.creationDate, let location = asset.location,
                      !asset.mediaSubtypes.contains(.photoScreenshot) else {
                    try await store.indexPhoto(assetID: asset.localIdentifier, fingerprint: fingerprint, evidence: nil)
                    continue
                }
                // Do not fetch originals from iCloud in the background. Missing local
                // originals are retried next time; no unsupported device identifiers.
                guard let url = await Self.originalURL(asset, network: false) else { completed = false; continue }
                let camera = await Task.detached(priority: .utility) { Self.cameraMetadata(url) }.value
                try Task.checkCancellation()
                guard permitted, epoch == revision else { throw CancellationError() }
                let matches = PhotoEvidence.matches(cameraMake: camera.make, cameraModel: camera.model, currentModel: currentModel)
                let faces = matches ? await Task.detached(priority: .utility) { Self.faceCount(url) }.value : nil
                try Task.checkCancellation()
                guard permitted, epoch == revision else { throw CancellationError() }
                let point = Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
                let value = matches && point.isValid ? PhotoLocationEvidence(id: Self.digest(asset.localIdentifier + fingerprint),
                    assetID: asset.localIdentifier, capturedAt: date, coordinate: point, cameraModel: currentModel, faceCount: faces) : nil
                try await store.indexPhoto(assetID: asset.localIdentifier, fingerprint: fingerprint, evidence: value)
            }
            guard permitted, epoch == revision else { throw CancellationError() }
            if let lastChecked { try await store.setSetting("photoEvidenceCursor", value: lastChecked) }
            let loaded = try await store.photoEvidence(since: cutoff)
            guard permitted, epoch == revision else { throw CancellationError() }
            evidence = loaded.filter { $0.cameraModel == currentModel }
            if completed {
                lastScan = Date()
                try await store.setSetting("photoEvidenceLastScan", value: String(lastScan!.timeIntervalSince1970))
            }
            status = completed ? "Up to date for the last 30 days" : "More photos will be checked on the next scan. Originals stored only in iCloud are skipped until available on this iPhone."
        } catch is CancellationError { }
        catch { status = "Couldn’t finish checking photos. Try again when this iPhone is unlocked." }
    }
    func dismiss(_ photos: [PhotoLocationEvidence]) async {
        do {
            try await store?.dismissPhotoSuggestions(assetIDs: photos.map(\.assetID))
            let ids = Set(photos.map(\.assetID)); evidence.removeAll { ids.contains($0.assetID) }
        } catch { status = "Couldn’t save your review. Please try again." }
    }
    func deleteSuggestion(_ photos: [PhotoLocationEvidence], undo: DeleteUndo) async {
        guard let store, canRead else { return }
        let epoch = revision
        let ids = photos.map(\.assetID)
        do {
            try await store.dismissPhotoSuggestions(assetIDs: ids)
            guard epoch == revision else { return }
            evidence.removeAll { ids.contains($0.assetID) }
            undo.register("Suggestion deleted") { [weak self] in
                guard let self, epoch == self.revision else { throw CancellationError() }
                try await store.restorePhotoSuggestions(assetIDs: ids)
                let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
                let restored = try await store.photoEvidence(since: cutoff)
                if self.canRead, epoch == self.revision { self.evidence = restored.filter { $0.cameraModel == self.currentModel } }
            }
        } catch { status = "Couldn’t delete this suggestion. Please try again." }
    }
    func erase() async {
        await setEnabled(false)
        do {
            try await store?.erasePhotoEvidence()
            try await store?.setSetting("photoEvidenceLastScan", value: "")
            try await store?.setSetting("photoEvidenceCursor", value: "")
            lastScan = nil
        }
        catch { status = "Couldn’t remove imported photo evidence. Please try again." }
    }
    func reset() {
        revision += 1; enabled = false; scanTask?.cancel(); evidence = []; lastScan = nil
        updateAuthorization()
    }
    func thumbnail(_ id: String) async -> UIImage? {
        #if DEBUG
        if canRead, let photo = previewPhotos[id] { return UIImage(data: photo.thumbnail) }
        #endif
        guard permitted, let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions(); options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = false
        let image: UIImage? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 240, height: 240), contentMode: .aspectFill, options: options) { @Sendable image, _ in
                continuation.resume(returning: image)
            }
        }
        return permitted ? image : nil
    }
    func importPhoto(_ value: PhotoLocationEvidence) async throws -> MemoryPhoto {
        #if DEBUG
        if canRead, let photo = previewPhotos[value.assetID] { return photo }
        #endif
        guard permitted, let currentModel,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [value.assetID], options: nil).firstObject,
              Self.digest(value.assetID + Self.fingerprint(asset, model: currentModel)) == value.id,
              let url = await Self.originalURL(asset, network: true) else { throw MemoryError.invalidPhoto }
        var photo = try await Task.detached(priority: .userInitiated) { try MemoryPhotoImport.make(url: url, date: value.capturedAt) }.value
        try Task.checkCancellation()
        guard permitted,
              let refreshed = PHAsset.fetchAssets(withLocalIdentifiers: [value.assetID], options: nil).firstObject,
              Self.digest(value.assetID + Self.fingerprint(refreshed, model: currentModel)) == value.id else { throw CancellationError() }
        // Photos lets users correct capture time and location independently of EXIF.
        photo.details = MemoryPhotoDetails(createdAt: value.capturedAt, coordinate: value.coordinate)
        return photo
    }
    #if DEBUG
    func loadPreviewForTesting(_ values: [PhotoLocationEvidence], photos: [String: MemoryPhoto]) async throws {
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing"), let store else { return }
        try await store.setSetting("photoEvidenceEnabled", value: "true")
        for value in values { try await store.indexPhoto(assetID: value.assetID, fingerprint: value.id, evidence: value) }
        previewPhotos = photos; enabled = true; authorization = .authorized; evidence = values
    }
    #endif
    private static func originalURL(_ asset: PHAsset, network: Bool) async -> URL? {
        let request = PhotoInputRequest(asset: asset)
        return await withTaskCancellationHandler { await request.load(network: network) }
            onCancel: { Task { @MainActor in request.cancel() } }
    }
    nonisolated static func cameraMetadata(_ url: URL) -> (make: String?, model: String?) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] else { return (nil, nil) }
        return (tiff[kCGImagePropertyTIFFMake] as? String, tiff[kCGImagePropertyTIFFModel] as? String)
    }
    nonisolated private static func faceCount(_ url: URL) -> Int? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 640] as CFDictionary) else { return nil }
        let request = VNDetectFaceRectanglesRequest()
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
            return request.results?.count ?? 0
        } catch { return nil }
    }
    private static func fingerprint(_ asset: PHAsset, model: String) -> String {
        digest(["faces-v1", model, String(describing: asset.creationDate), String(describing: asset.modificationDate),
                String(describing: asset.location?.coordinate.latitude), String(describing: asset.location?.coordinate.longitude)].joined(separator: "|"))
    }
    private static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
}

/// Bounded, cancellable PhotoKit work; in particular a locked library cannot hold
/// a BGAppRefreshTask alive beyond the system's expiration callback.
@MainActor private final class PhotoInputRequest {
    let asset: PHAsset
    private var id: PHContentEditingInputRequestID?
    private var continuation: CheckedContinuation<URL?, Never>?
    private var timeout: Task<Void, Never>?
    private var cancelled = false
    init(asset: PHAsset) { self.asset = asset }
    func load(network: Bool) async -> URL? {
        guard !cancelled, !Task.isCancelled else { return nil }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let options = PHContentEditingInputRequestOptions()
            options.isNetworkAccessAllowed = network; options.canHandleAdjustmentData = { @Sendable _ in true }
            id = asset.requestContentEditingInput(with: options) { @Sendable [weak self] input, _ in
                let url = input?.fullSizeImageURL
                Task { @MainActor in self?.finish(url) }
            }
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(network ? 60 : 5)); self?.cancel() } catch { }
            }
        }
    }
    func cancel() {
        cancelled = true
        if let id { asset.cancelContentEditingInputRequest(id) }
        finish(nil)
    }
    private func finish(_ url: URL?) {
        timeout?.cancel(); timeout = nil; id = nil
        let pending = continuation; continuation = nil; pending?.resume(returning: url)
    }
}

enum PhotoCameraModel {
    static var current: String? {
        var system = utsname(); uname(&system)
        let identifier = withUnsafeBytes(of: &system.machine) { bytes in String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self) }
        return name(for: identifier)
    }
    // Hardware-to-product facts verified against DeviceKit's device inventory.
    // Unknown future devices fail closed instead of admitting every iPhone model.
    static func name(for identifier: String) -> String? {
        let names = [
            "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max", "iPhone12,8": "iPhone SE (2nd generation)",
            "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
            "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13", "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max", "iPhone14,6": "iPhone SE (3rd generation)",
            "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus", "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus", "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus", "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max", "iPhone17,5": "iPhone 16e",
            "iPhone18,3": "iPhone 17", "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max", "iPhone18,4": "iPhone Air", "iPhone18,5": "iPhone 17e",
            "iPhone19,2": "iPhone 18 Pro", "iPhone19,3": "iPhone 18 Pro Max", "iPhone19,7": "iPhone 18 Pro Max"
        ]
        return names[identifier]
    }
}
