import Foundation
import Testing
@testable import PlacesCore

private func photo(_ id: String, seconds: Double = 0, latitude: Double = 12) -> PhotoLocationEvidence {
    PhotoLocationEvidence(id: id, assetID: "asset-" + id, capturedAt: Date(timeIntervalSince1970: 1_000_000 + seconds),
                          coordinate: Coordinate(latitude: latitude, longitude: 34), cameraModel: "iPhone 16 Pro")
}

@Test func cameraModelRequiresExactAppleModelAndFailsClosed() {
    #expect(PhotoEvidence.matches(cameraMake: "Apple", cameraModel: "iPhone 16 Pro", currentModel: "iPhone 16 Pro"))
    #expect(!PhotoEvidence.matches(cameraMake: "Apple", cameraModel: "iPhone 16 Pro Max", currentModel: "iPhone 16 Pro"))
    #expect(!PhotoEvidence.matches(cameraMake: nil, cameraModel: "iPhone 16 Pro", currentModel: "iPhone 16 Pro"))
    #expect(!PhotoEvidence.matches(cameraMake: "Apple", cameraModel: "iPhone 16 Pro", currentModel: nil))
}

@Test func photoClusteringDoesNotChainIntoTravelOrInventTimes() {
    let photos = [photo("a"), photo("b", seconds: 60, latitude: 12.0009), photo("c", seconds: 120, latitude: 12.0018), photo("d", seconds: 8000)]
    let groups = PhotoEvidence.suggestions(photos, calendar: Calendar(identifier: .gregorian))
    #expect(groups.count == 3)
    let first = groups.first { $0.id == "asset-a" }!
    #expect(first.photos.count == 2)
    #expect(first.start == photos[0].capturedAt && first.end == photos[1].capturedAt)
    #expect(groups[0].start == groups[0].end)
}

@Test func photoEvidenceConsentRevisionsDeletionAndReviewStaySeparateFromGPS() async throws {
    let store = try PlacesStore()
    let initial = photo("a")
    try await store.indexPhoto(assetID: initial.assetID, fingerprint: "one", evidence: initial)
    #expect(try await store.photoEvidence().isEmpty)
    try await store.setSetting("photoEvidenceEnabled", value: "true")
    try await store.indexPhoto(assetID: initial.assetID, fingerprint: "one", evidence: initial)
    try await store.indexPhoto(assetID: initial.assetID, fingerprint: "one", evidence: initial)
    #expect(try await store.photoEvidence().count == 1)
    var edited = initial; edited.id = "revision-two"; edited.coordinate.latitude = 15
    try await store.indexPhoto(assetID: initial.assetID, fingerprint: "two", evidence: edited)
    #expect(try await store.photoEvidence() == [edited])
    #expect(try await store.photoEvidence(includeHistory: true).count == 2)
    #expect(try await store.observations().isEmpty)
    #expect(try await store.timeline(on: initial.capturedAt).isEmpty)
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let archive = try decoder.decode(HistoryArchive.self, from: await store.exportHistory())
    #expect(archive.photoEvidence?.count == 2)
    try await store.dismissPhotoSuggestions(assetIDs: [initial.assetID])
    #expect(try await store.photoEvidence().isEmpty)
    #expect(try await store.photoEvidence(includeHistory: true).count == 2)
    try await store.setSetting("photoEvidenceEnabled", value: "false")
    try await store.indexPhoto(assetID: "asset-other", fingerprint: "three", evidence: photo("other"))
    #expect(try await store.photoEvidence(includeHistory: true).count == 2)
    try await store.eraseHistory(resetSettings: true)
    #expect(try await store.photoEvidence(includeHistory: true).isEmpty)
    #expect(try await store.photoScanFingerprints().isEmpty)
}

@Test func inaccessiblePhotoMetadataIsRetainedButNoLongerSuggested() async throws {
    let store = try PlacesStore(), value = photo("a")
    try await store.setSetting("photoEvidenceEnabled", value: "true")
    try await store.indexPhoto(assetID: value.assetID, fingerprint: "one", evidence: value)
    try await store.reconcilePhotoAccess(accessibleIDs: [], since: .distantPast)
    #expect(try await store.photoEvidence().isEmpty)
    #expect(try await store.photoEvidence(includeHistory: true).count == 1)
    #expect(try await store.photoScanFingerprints().isEmpty)
    try await store.erasePhotoEvidence()
    #expect(try await store.photoEvidence(includeHistory: true).isEmpty)
}
