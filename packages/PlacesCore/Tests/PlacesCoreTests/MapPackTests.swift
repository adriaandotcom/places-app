import XCTest
@testable import PlacesCore

final class MapPackTests: XCTestCase {
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
