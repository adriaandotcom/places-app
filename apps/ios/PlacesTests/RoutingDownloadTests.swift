import XCTest
import CryptoKit
import PlacesCore
@testable import PlacesRouting
@testable import Places

@MainActor final class RoutingDownloadTests: XCTestCase {
    private func fixture() -> (RoutingPackDownload, Data) {
        let data = Data("Synthetic transfer bytes; the installer is stubbed, never native parsing.".utf8)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let pack = RoutingPack(name: "Synthetic", version: "1.0", engine: "3.9.1", bytes: 100,
            sha256: hash, south: 0, west: 0, north: 1, east: 1)
        return (RoutingPackDownload(country: "synthetic", pack: pack, bytes: Int64(data.count), sha256: hash), data)
    }
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func wait(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Transfer did not finish its expected state transition")
    }
    func testBundledRoutingDownloadPinsSizeGraphAndPublicURL() throws {
        let source = try XCTUnwrap(RoutingPackDownload.catalog().first)
        XCTAssertEqual(source.url.absoluteString, "https://places-app.b-cdn.net/maps/routing/netherlands/2026.10.08/valhalla.zip")
        XCTAssertNil(source.url.query)
        XCTAssertEqual(source.bytes, 347_647_021)
        XCTAssertTrue(try RoutingPack.catalog().contains(source.pack))
        XCTAssertTrue(source.isValid)
        XCTAssertGreaterThan(source.requiredStorageBytes, source.bytes + Int64(source.pack.bytes))
    }
    func testMeteredConnectionCannotStartWithoutApproval() async throws {
        let (source, _) = fixture(), root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = RoutingPackDownloads(testing: true, storage: root, manifest: [source]) { _ in
            XCTFail("A blocked request must not install"); return source.pack
        }
        defer { downloads.stopForTesting() }
        downloads.start(); try await wait { downloads.ready }
        downloads.networkChanged(.needsApproval); downloads.download(source)
        XCTAssertNil(downloads.transfer)
        XCTAssertTrue(downloads.issue?.contains("Confirm") == true)
    }
    func testVerifiedDeliveryInstallsOnceAndIgnoresStaleCallbacks() async throws {
        let (source, data) = fixture(), root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        var installed = 0
        let downloads = RoutingPackDownloads(testing: true, storage: root, manifest: [source]) { file in
            XCTAssertEqual(try Data(contentsOf: file), data); installed += 1; return source.pack
        }
        let token = UUID().uuidString
        downloads.prepareDeliveryForTesting(source, token: token)
        let stale = root.appendingPathComponent("stale.partial")
        try data.write(to: stale)
        downloads.receive(stale, token: UUID().uuidString, responseURL: source.url, status: 200, session: "test")
        XCTAssertEqual(installed, 0); XCTAssertEqual(downloads.transfer?.phase, .downloading)
        let valid = root.appendingPathComponent("valid.partial")
        try data.write(to: valid)
        downloads.receive(valid, token: token, responseURL: source.url, status: 200, session: "test")
        try await wait { downloads.transfer?.phase == .installed }
        XCTAssertEqual(installed, 1)
        XCTAssertEqual(downloads.transfer?.received, source.bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: valid.path))
        try data.write(to: stale)
        downloads.receive(stale, token: token, responseURL: source.url, status: 200, session: "test")
        XCTAssertEqual(downloads.transfer?.phase, .installed); XCTAssertEqual(installed, 1)
    }
    func testCorruptedOrRedirectedDeliveryNeverReachesInstaller() async throws {
        let (source, data) = fixture(), root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        var installed = 0
        let downloads = RoutingPackDownloads(testing: true, storage: root, manifest: [source]) { _ in
            installed += 1; return source.pack
        }
        let token = UUID().uuidString
        downloads.prepareDeliveryForTesting(source, token: token)
        let file = root.appendingPathComponent("corrupt.partial")
        var corrupted = data; corrupted[0] ^= 1
        try corrupted.write(to: file)
        downloads.receive(file, token: token, responseURL: source.url, status: 200, session: "test")
        try await wait { downloads.transfer?.phase == .failed }
        XCTAssertEqual(installed, 0)
        downloads.prepareDeliveryForTesting(source, token: token)
        try data.write(to: file)
        downloads.receive(file, token: token, responseURL: URL(string: "https://example.invalid/valhalla.zip"), status: 200, session: "test")
        XCTAssertEqual(downloads.transfer?.phase, .failed); XCTAssertEqual(installed, 0)
    }
    func testInterruptedVerificationCanBeRetriedAfterRelaunch() async throws {
        let (source, _) = fixture(), root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let transfer = RoutingPackTransfer(token: UUID().uuidString, source: source, phase: .verifying)
        try JSONEncoder().encode(transfer).write(to: root.appendingPathComponent("transfer.json"))
        let downloads = RoutingPackDownloads(testing: true, storage: root, manifest: [source]) { _ in
            XCTFail("A missing temporary file must not install"); return source.pack
        }
        defer { downloads.stopForTesting() }
        downloads.start(); try await wait { downloads.ready }
        XCTAssertEqual(downloads.transfer?.phase, .paused)
        XCTAssertFalse(downloads.pending)
    }
}
