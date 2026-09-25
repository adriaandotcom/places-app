import XCTest
import PlacesCore
@testable import Places

@MainActor final class PlaceRegionLookupTests: XCTestCase {
    func testNoRequestBeforeConsentAndLateResultDiscardedAfterRevocation() async {
        let request = RegionRequestSpy()
        var constructions = 0
        let lookup = ApplePlaceLookup { _ in constructions += 1; return request }
        let point = Coordinate(latitude: 1, longitude: 1)
        let disabled = await lookup.lookup(point)
        XCTAssertNil(disabled); XCTAssertEqual(constructions, 0)
        lookup.setEnabled(true)
        let task = Task { await lookup.lookup(point) }
        while request.continuation == nil { await Task.yield() }
        XCTAssertEqual(constructions, 1)
        lookup.setEnabled(false)
        XCTAssertTrue(request.cancelled)
        lookup.setEnabled(true)
        request.continuation?.resume(returning: PlaceLocality(city: "Fixture city", source: .apple))
        let late = await task.value
        XCTAssertNil(late, "An old consent generation cannot save a result after revoke/re-enable")
        lookup.setEnabled(false)
        let revoked = await lookup.lookup(point)
        XCTAssertNil(revoked); XCTAssertEqual(constructions, 1)
    }
}

@MainActor private final class RegionRequestSpy: PlaceRegionRequest {
    var cancelled = false
    var continuation: CheckedContinuation<PlaceLocality?, Never>?
    func result() async throws -> PlaceLocality? {
        await withCheckedContinuation { continuation = $0 }
    }
    func cancel() { cancelled = true }
}
