import XCTest
@testable import PlacesCore

final class MapPackTests: XCTestCase {
    func testRemoteCatalogRequiresCompleteVariantsAndFixedImmutableURLs() throws {
        func variant(_ detail: MapDetail) -> [String: Any] {
            ["id": "greece", "name": "Greece", "version": "123.1", "bytes": 12345,
             "sha256": String(repeating: "a", count: 64), "minZoom": 7, "maxZoom": detail.maxZoom,
             "url": "https://places-app.b-cdn.net/maps/greece/123.1/" + detail.rawValue + ".pmtiles",
             "attribution": "OSM", "detail": detail.rawValue, "bounds": [20, 35, 28, 42],
             "sourceDate": "20260925", "updatedAt": "2026-09-28T10:00:00Z"]
        }
        let variants = MapDetail.allCases.map(variant)
        func catalog(_ variants: [[String: Any]]) throws -> MapCatalog {
            let object: [String: Any] = ["schemaVersion": 1, "countries": [["id": "greece", "name": "Greece", "bounds": [20, 35, 28, 42], "variants": variants]]]
            return try JSONDecoder().decode(MapCatalog.self, from: JSONSerialization.data(withJSONObject: object))
        }
        XCTAssertTrue(try catalog(variants).isValid)
        XCTAssertFalse(try catalog(Array(variants.prefix(2))).isValid)
        XCTAssertFalse(try catalog(variants + [variants[0]]).isValid)
        for url in ["https://example.invalid/maps", variants[0]["url"] as! String + "?position=1", "http://places-app.b-cdn.net/maps/greece/123.1/tiny.pmtiles"] {
            var altered = variants; altered[0]["url"] = url
            XCTAssertFalse(try catalog(altered).isValid)
        }
        XCTAssertNil(MapPack.ID(rawValue: "../secret"))
        XCTAssertFalse(MapCatalog.validBounds([0, 0, 1, Double.nan]))
        XCTAssertFalse(MapCatalog.validBounds([2, 0, 1, 1]))
        XCTAssertEqual(try JSONDecoder().decode(MapPack.ID.self, from: Data("\"greece\"".utf8)), .greece)
    }
    func testLegacyBootstrapDescriptorsOnlyDownloadFromBunny() throws {
        let old: [String: Any] = ["id": "world", "name": "World", "version": "20260925.1", "bytes": 12345,
            "sha256": String(repeating: "a", count: 64), "minZoom": 0, "maxZoom": 6, "attribution": "OSM",
            "url": "https://github.com/adriaandotcom/places-app/releases/download/maps-20260925.1/world.pmtiles"]
        let pack = try JSONDecoder().decode(MapPack.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertTrue(pack.isValid)
        XCTAssertEqual(pack.downloadURL.absoluteString, "https://places-app.b-cdn.net/maps/bootstrap/20260925.1/world.pmtiles")
        var mirrored = old; mirrored["url"] = pack.downloadURL.absoluteString
        let updated = try JSONDecoder().decode(MapPack.self, from: JSONSerialization.data(withJSONObject: mirrored))
        XCTAssertTrue(updated.isValid)
        XCTAssertEqual(pack.downloadDescriptor, updated)
        XCTAssertEqual(updated.filename, pack.filename)
        XCTAssertEqual(updated.sha256, pack.sha256)
    }
    func testMigrationPreservesAppleConsentWithoutStartingDownloads() {
        XCTAssertEqual(MapProvider.migrated(stored: nil, appleEnabled: true), .apple)
        XCTAssertEqual(MapProvider.migrated(stored: nil, appleEnabled: false), .off)
        XCTAssertEqual(MapProvider.migrated(stored: "onDevice", appleEnabled: true), .onDevice)
        XCTAssertEqual(MapProvider.migrated(stored: "off", appleEnabled: true), .off)
    }
    func testCellularLowDataAndUnknownConnectionsRequireApproval() {
        XCTAssertEqual(MapDownloadNetwork.classify(connected: false, wifiOrEthernet: true, expensive: false, constrained: false), .unavailable)
        for (wifi, expensive, constrained) in [(false, false, false), (true, true, false), (true, false, true)] {
            let network = MapDownloadNetwork.classify(connected: true, wifiOrEthernet: wifi, expensive: expensive, constrained: constrained)
            XCTAssertEqual(network, .needsApproval)
            XCTAssertFalse(MapDownloadPolicy.canStart(network: network, approvedMetered: false))
            XCTAssertTrue(MapDownloadPolicy.canStart(network: network, approvedMetered: true))
        }
        XCTAssertFalse(MapDownloadPolicy.canStart(network: .unavailable, approvedMetered: true))
        XCTAssertTrue(MapDownloadPolicy.canStart(network: .unmetered, approvedMetered: false))
    }
    func testSpaceAndRemainingBytes() {
        XCTAssertEqual(MapDownloadPolicy.remaining(total: 100, received: 40), 60)
        XCTAssertEqual(MapDownloadPolicy.remaining(total: 100, received: 200), 0)
        XCTAssertEqual(MapDownloadPolicy.remaining(total: 100, received: -10), 100)
        XCTAssertFalse(MapDownloadPolicy.hasSpace(available: 80_000_000, packBytes: 30_000_000))
        XCTAssertTrue(MapDownloadPolicy.hasSpace(available: 110_000_000, packBytes: 30_000_000))
    }
    func testPromptSuppressionWhileDownloadingAfterDismissalAndWithinSession() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func suggests(zoom: Double = 9, installed: Set<MapPack.ID> = [], pending: Set<MapPack.ID> = [], dismissed: Date? = nil, offered: Bool = false) -> Bool {
            MapDownloadPolicy.canSuggest(id: .greece, zoom: zoom, installed: installed, pending: pending, dismissedAt: dismissed, now: now, offeredThisSession: offered ? [.greece] : [])
        }
        XCTAssertTrue(suggests())
        XCTAssertFalse(suggests(zoom: 7))
        XCTAssertFalse(suggests(installed: [.greece]))
        XCTAssertFalse(suggests(pending: [.greece]))
        XCTAssertFalse(suggests(dismissed: now.addingTimeInterval(-6 * 86400)))
        XCTAssertTrue(suggests(dismissed: now.addingTimeInterval(-7 * 86400)))
        XCTAssertFalse(suggests(offered: true))
    }
}
