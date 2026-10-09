import XCTest
import PlacesCore
import TraccarClientSDK
@testable import Places

@MainActor final class TraccarOutputTests: XCTestCase {
    func testSDKCallbackCommitsBeforeAcknowledgingAndDrainsBeforeDeletion() async throws {
        let store = try PlacesStore()
        var failed = false
        let output = TraccarLocalOutput(store: store, onPoint: { _ in }, onPause: { _ in }, onFailure: { failed = true })
        let position = Position(latitude: KotlinDouble(double: 52.36), longitude: KotlinDouble(double: 4.88),
            accuracy: KotlinDouble(double: 15), time: 1_780_000_000_000, altitude: nil, speed: nil, bearing: nil,
            battery: nil, charging: nil, alarm: nil)
        let acknowledged = await withCheckedContinuation { continuation in
            output.save(position: position) { success in continuation.resume(returning: success.boolValue) }
        }
        XCTAssertTrue(acknowledged)
        let count = try await store.traccarPointCount()
        XCTAssertEqual(count, 1)
        let points = try await store.observations(limit: 10)
        XCTAssertTrue(points.isEmpty)
        output.accepting = false
        await output.drain()
        try await store.eraseHistory()
        var rejected = false
        output.save(position: position) { rejected = !$0.boolValue }
        await output.drain()
        let after = try await store.traccarPointCount()
        XCTAssertTrue(rejected)
        XCTAssertEqual(after, 0)
        XCTAssertFalse(failed)
    }

    func testStopDrainsAlreadyAcceptedWritesAndPersistsStationaryState() async throws {
        let store = try PlacesStore()
        var acknowledgements = 0
        let output = TraccarLocalOutput(store: store, onPoint: { _ in }, onPause: { _ in },
                                       onFailure: { XCTFail("Valid local writes should succeed") })
        for index in 0..<5 {
            output.save(position: Position(latitude: KotlinDouble(double: 52.36), longitude: KotlinDouble(double: 4.88),
                accuracy: nil, time: 1_780_000_000_000 + Int64(index * 1_000), altitude: nil, speed: nil,
                bearing: nil, battery: nil, charging: nil, alarm: nil)) { success in
                if success.boolValue { acknowledgements += 1 }
            }
        }
        output.stateChanged(paused: true)
        output.accepting = false
        await output.drain()
        let count = try await store.traccarPointCount()
        let paused = try await store.setting("traccarPaused")
        XCTAssertEqual(count, 5)
        XCTAssertEqual(acknowledgements, 5)
        XCTAssertEqual(paused, "true")
        XCTAssertTrue(output.writes.isEmpty)
    }

    func testRejectedLocalWriteReturnsFailureWithoutSavingAPoint() async throws {
        let store = try PlacesStore()
        var failed = false
        let output = TraccarLocalOutput(store: store, onPoint: { _ in XCTFail("Must not report an unsaved point") },
                                       onPause: { _ in }, onFailure: { failed = true })
        let acknowledged = await withCheckedContinuation { continuation in
            output.save(position: Position(latitude: KotlinDouble(double: 100), longitude: KotlinDouble(double: 4.88),
                accuracy: nil, time: 1_780_000_000_000, altitude: nil, speed: nil,
                bearing: nil, battery: nil, charging: nil, alarm: nil)) { continuation.resume(returning: $0.boolValue) }
        }
        await output.drain()
        let count = try await store.traccarPointCount()
        XCTAssertFalse(acknowledged)
        XCTAssertTrue(failed)
        XCTAssertEqual(count, 0)
    }
}
