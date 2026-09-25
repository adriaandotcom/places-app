import XCTest
import PlacesCore
@testable import Places

@MainActor final class PlaceRegionLookupTests: XCTestCase {
    func testFailedLookupCanRetryAndPersistResolvedNames() async throws {
        let expected = PlaceLocality(city: "Fixture city", country: "Fixture country", source: .apple)
        var attempts = 0
        let lookup = ApplePlaceLookup { _ in
            attempts += 1
            return ImmediateRegionRequest(value: attempts == 1 ? .failure(URLError(.notConnectedToInternet)) : .success(expected))
        }
        let point = Coordinate(latitude: 1, longitude: 1)
        lookup.setEnabled(true)
        do {
            _ = try await lookup.lookup(point)
            XCTFail("Lookup failures must reach the UI instead of being silently discarded")
        } catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
        let result = try await lookup.lookup(point)
        let locality = try XCTUnwrap(result)
        XCTAssertEqual(attempts, 2)
        let store = try PlacesStore()
        let place = Place(name: "Fixture place", coordinate: point)
        try await store.savePlace(place)
        try await store.saveLocality(locality, for: place.id, at: point)
        let saved = try await store.places().first { $0.id == place.id }
        XCTAssertEqual(saved?.locality, expected)
    }

    func testNoRequestBeforeConsentAndLateResultDiscardedAfterRevocation() async throws {
        let request = RegionRequestSpy()
        var constructions = 0
        let lookup = ApplePlaceLookup { _ in constructions += 1; return request }
        let point = Coordinate(latitude: 1, longitude: 1)
        let disabled = try await lookup.lookup(point)
        XCTAssertNil(disabled); XCTAssertEqual(constructions, 0)
        lookup.setEnabled(true)
        let task = Task { try await lookup.lookup(point) }
        while request.continuation == nil { await Task.yield() }
        XCTAssertEqual(constructions, 1)
        lookup.setEnabled(false)
        XCTAssertTrue(request.cancelled)
        lookup.setEnabled(true)
        request.continuation?.resume(returning: PlaceLocality(city: "Fixture city", source: .apple))
        let late = try await task.value
        XCTAssertNil(late, "An old consent generation cannot save a result after revoke/re-enable")
        lookup.setEnabled(false)
        let revoked = try await lookup.lookup(point)
        XCTAssertNil(revoked); XCTAssertEqual(constructions, 1)
    }
}

@MainActor private final class ImmediateRegionRequest: PlaceRegionRequest {
    let value: Result<PlaceLocality?, Error>
    init(value: Result<PlaceLocality?, Error>) { self.value = value }
    func result() async throws -> PlaceLocality? { try value.get() }
    func cancel() { }
}

@MainActor private final class RegionRequestSpy: PlaceRegionRequest {
    var cancelled = false
    var continuation: CheckedContinuation<PlaceLocality?, Never>?
    func result() async throws -> PlaceLocality? {
        await withCheckedContinuation { continuation = $0 }
    }
    func cancel() { cancelled = true }
}
