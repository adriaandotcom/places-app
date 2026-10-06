import XCTest
import CoreLocation
import UIKit
import PlacesCore
@testable import Places

@MainActor final class WiFiTrackingControllerTests: XCTestCase {
    private let home = Place(id: "fixture-home", name: "Fixture Home", coordinate: .init(latitude: 1, longitude: 1))
    private var network: WiFiNetwork {
        WiFiNetwork(id: "fixture-network", ssid: "Fixture Wi-Fi", firstSeen: Date(), lastSeen: Date())
    }
    private var points: [WiFiAccessPoint] {
        ["02:00:00:00:00:01", "02:00:00:00:00:02"].map {
            WiFiAccessPoint(id: $0, networkID: network.id, bssid: $0, placeID: home.id, lastSeen: Date())
        }
    }
    private var connection: ConnectedWiFi { ConnectedWiFi(ssid: network.ssid, bssid: points[0].bssid) }

    private func makeTracker(timeout: Duration = .seconds(3), recoveryTimeout: Duration = .seconds(90),
                             settlingDelay: Duration = .seconds(TrackingPolicy.stationaryDuration),
                             device: UIDevice = DeviceSpy(), clock: TrackingClock = TrackingClock()) -> (TrackingController, LocationSpy, LocationSpy, WiFiReaderSpy) {
        let live = LocationSpy(), passive = LocationSpy(), reader = WiFiReaderSpy()
        let tracker = TrackingController(live: live, passive: passive, device: device, wifiTimeout: timeout, recoveryTimeout: recoveryTimeout, settlingDelay: settlingDelay, monitorSystemChanges: false, now: { clock.time },
                                         wifiReader: { reader.callbacks.append($0) })
        tracker.updateWiFiKnowledge(places: [home], networks: [network], accessPoints: points)
        tracker.configure(places: [home], enabled: true)
        return (tracker, live, passive, reader)
    }

    func testSavedPlaceRequiresThreeMinutesBeforeStoppingGPS() {
        let clock = TrackingClock()
        let (tracker, live, _, reader) = makeTracker(clock: clock)
        reader.complete(0, nil)
        func fix() { tracker.locationManager(live, didUpdateLocations: [CLLocation(
            coordinate: .init(latitude: 1, longitude: 1), altitude: 0,
            horizontalAccuracy: 10, verticalAccuracy: 10, timestamp: clock.time)]) }
        fix()
        XCTAssertEqual(tracker.state, .stationaryCandidate)
        XCTAssertTrue(live.updating)
        clock.time.addTimeInterval(179); fix()
        XCTAssertTrue(live.updating)
        clock.time.addTimeInterval(1); fix()
        XCTAssertEqual(tracker.state, .knownPlace)
        XCTAssertFalse(live.updating)
        tracker.configure(places: [], enabled: false)
    }

    func testFreshWiFiConfirmsDwellAndPersistsTheConfirmationForReplay() {
        let clock = TrackingClock()
        let (tracker, live, _, reader) = makeTracker(clock: clock)
        var observations: [SensorObservation] = []
        tracker.onObservations = { observations += $0 }
        reader.complete(0, connection)
        XCTAssertFalse(live.updating)
        XCTAssertFalse(InferenceEngine.infer(observations: observations, places: [home], networks: [network], accessPoints: points).contains { $0.kind == .stay }, "Pausing GPS must not prematurely create a visit")
        clock.time.addTimeInterval(180)
        tracker.refreshCurrentWiFi(); reader.complete(1, connection)
        XCTAssertEqual(tracker.state, .knownWiFi)
        XCTAssertFalse(live.updating)
        XCTAssertEqual(observations.filter { $0.source == .wifi }.count, 2)
        let items = InferenceEngine.infer(observations: observations, places: [home], networks: [network], accessPoints: points)
        XCTAssertEqual(items.first?.kind, .stay)
        tracker.configure(places: [], enabled: false)
    }

    func testWalkingVisitKeepsGPSAndCyclingCannotSettleInThePark() {
        let clock = TrackingClock()
        let (tracker, live, _, reader) = makeTracker(clock: clock)
        var park = home; park.countsWalksAsVisits = true; park.radius = 500
        tracker.configure(places: [park], enabled: true)
        reader.complete(0, nil)
        tracker.receivedMotion(.walking, at: clock.time); reader.complete(1, nil)
        for step in 0...3 {
            if step > 0 { clock.time.addTimeInterval(60) }
            tracker.locationManager(live, didUpdateLocations: [CLLocation(
                coordinate: .init(latitude: 1, longitude: 1 + Double(step) * 0.0005), altitude: 0,
                horizontalAccuracy: 10, verticalAccuracy: 10, course: 90, speed: 1, timestamp: clock.time)])
        }
        XCTAssertEqual(tracker.state, .moving)
        XCTAssertTrue(live.updating)
        tracker.receivedMotion(.automotive, at: clock.time)
        reader.complete(reader.callbacks.count - 1, nil)
        clock.time.addTimeInterval(180)
        tracker.locationManager(live, didUpdateLocations: [CLLocation(
            coordinate: .init(latitude: 1, longitude: 1), altitude: 0,
            horizontalAccuracy: 10, verticalAccuracy: 10, timestamp: clock.time)])
        XCTAssertTrue(live.updating)
        XCTAssertNotEqual(tracker.state, .knownPlace)
        tracker.configure(places: [], enabled: false)
    }

    func testKnownWiFiPausesGPSWhileWalkingStillDoesNotConfirmAStop() {
        let (tracker, live, passive, reader) = makeTracker()
        var observations: [SensorObservation] = []
        tracker.onObservations = { observations += $0 }
        XCTAssertEqual(live.starts, 0, "Check Wi-Fi before requesting location at launch")
        reader.complete(0, connection)
        XCTAssertEqual(tracker.state, .knownWiFi)
        XCTAssertEqual(live.starts, 0)
        XCTAssertTrue(passive.visits && passive.significantChanges)
        XCTAssertTrue(passive.regions.contains { $0.identifier == home.id })
        tracker.receivedMotion(.walking, at: Date())
        XCTAssertEqual(reader.callbacks.count, 2, "Movement requires a live read, not a cached BSSID")
        reader.complete(1, connection)
        XCTAssertEqual(tracker.state, .knownWiFi)
        XCTAssertEqual(live.starts, 0)
        let energy = tracker.energySnapshot()
        XCTAssertEqual(energy.wifiReads, 2)
        XCTAssertEqual(energy.motionCallbacks, 1)
        XCTAssertEqual(energy.locationStarts, 0)
        XCTAssertFalse(live.updating)
        XCTAssertEqual(observations.filter { $0.source == .wifi }.count, 1)
        XCTAssertTrue(observations.filter { $0.source == .wifi }.allSatisfy { $0.coordinate == nil })
        XCTAssertFalse(InferenceEngine.infer(observations: observations, places: [home], networks: [network], accessPoints: points).contains { $0.kind == .stay })
        tracker.configure(places: [], enabled: false)
    }

    func testUnavailableWiFiAndRepeatedCallbacksDoNotProlongGPSRecovery() async throws {
        let (tracker, live, _, reader) = makeTracker(recoveryTimeout: .milliseconds(120))
        reader.complete(0, nil)
        XCTAssertTrue(live.updating)
        try await Task.sleep(for: .milliseconds(80))
        tracker.wifiPathChanged(); reader.complete(1, nil)
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertEqual(tracker.state, .lowPowerFallback)
        XCTAssertFalse(live.updating)
        tracker.configure(places: [], enabled: false)
    }

    func testImpreciseStationaryFixesDoNotKeepDetailedGPSRunning() async throws {
        let (tracker, live, _, reader) = makeTracker(recoveryTimeout: .milliseconds(160))
        reader.complete(0, nil)
        for _ in 0..<3 {
            tracker.locationManager(live, didUpdateLocations: [CLLocation(coordinate: .init(latitude: 1, longitude: 1),
                altitude: 0, horizontalAccuracy: 100, verticalAccuracy: 100, timestamp: Date())])
            try await Task.sleep(for: .milliseconds(60))
        }
        XCTAssertEqual(tracker.state, .lowPowerFallback)
        XCTAssertFalse(live.updating)
        tracker.configure(places: [], enabled: false)
    }

    func testQuietStopRequestsFreshEvidenceBeforeRecoveryExpires() async throws {
        let (tracker, live, _, reader) = makeTracker(recoveryTimeout: .milliseconds(80), settlingDelay: .milliseconds(180))
        reader.complete(0, nil)
        let fix = CLLocation(coordinate: .init(latitude: 2, longitude: 2), altitude: 0,
                             horizontalAccuracy: 10, verticalAccuracy: 10, timestamp: Date())
        tracker.locationManager(live, didUpdateLocations: [fix])
        tracker.receivedMotion(.walking, at: Date()); reader.complete(1, nil)
        XCTAssertEqual(tracker.state, .moving)
        tracker.receivedMotion(.stationary, at: Date())
        tracker.locationManager(live, didUpdateLocations: [CLLocation(coordinate: fix.coordinate, altitude: 0,
            horizontalAccuracy: 10, verticalAccuracy: 10, timestamp: Date())])
        XCTAssertEqual(tracker.state, .stationaryCandidate)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(tracker.state, .stationaryCandidate, "The shorter recovery timeout must not cancel stop confirmation")
        XCTAssertEqual(live.requests, 0)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(live.requests, 1)
        XCTAssertNotEqual(tracker.state, .stationaryUnknown, "Silence is not evidence of a stay")
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(tracker.state, .lowPowerFallback)
        XCTAssertEqual(live.requests, 1, "No periodic GPS polling when confirmation fails")
        XCTAssertFalse(live.requestPending, "The recovery deadline must cancel the one-off request too")
        tracker.configure(places: [], enabled: false)
    }

    func testMovementCancelsPendingStopConfirmation() async throws {
        let (tracker, live, _, reader) = makeTracker(recoveryTimeout: .milliseconds(80), settlingDelay: .milliseconds(180))
        reader.complete(0, nil)
        tracker.locationManager(live, didUpdateLocations: [CLLocation(coordinate: .init(latitude: 2, longitude: 2), altitude: 0,
            horizontalAccuracy: 10, verticalAccuracy: 10, timestamp: Date())])
        tracker.receivedMotion(.walking, at: Date()); reader.complete(1, nil)
        try await Task.sleep(for: .milliseconds(240))
        XCTAssertEqual(tracker.state, .lowPowerFallback)
        XCTAssertEqual(live.requests, 0)
        tracker.configure(places: [], enabled: false)
    }

    func testDuplicateWiFiCallbackCannotCreateDuplicateEvidence() {
        let (tracker, _, _, reader) = makeTracker()
        var values: [SensorObservation] = []
        tracker.onObservations = { values += $0 }
        reader.complete(0, connection); reader.complete(0, connection)
        XCTAssertEqual(tracker.currentWiFiObservation?.ssid, connection.ssid)
        XCTAssertEqual(values.filter { $0.source == .wifi }.count, 1)
        tracker.wifiPathChanged(); reader.complete(1, nil)
        XCTAssertNil(tracker.currentWiFiObservation)
        XCTAssertEqual(values.filter { $0.source == .wifi }.count, 2)
        tracker.configure(places: [], enabled: false)
    }

    func testWiFiPairsWithAnAlreadyDeliveredFixAndDoesNotStartAnotherRead() {
        let (tracker, live, _, reader) = makeTracker()
        var values: [SensorObservation] = []
        tracker.onObservations = { values += $0 }
        let fix = CLLocation(coordinate: .init(latitude: 1.01, longitude: 1.01), altitude: 0,
                             horizontalAccuracy: 10, verticalAccuracy: 10, timestamp: Date())
        tracker.locationManager(live, didUpdateLocations: [fix])
        XCTAssertEqual(reader.callbacks.count, 1, "Reuse the pending connected-network request")
        reader.complete(0, connection)
        XCTAssertEqual(values.first(where: { $0.source == .wifi })?.usableCoordinate,
                       Coordinate(latitude: 1.01, longitude: 1.01))
        XCTAssertEqual(tracker.currentWiFiObservation?.coordinateTimestamp, fix.timestamp)
        tracker.configure(places: [], enabled: false)
        XCTAssertNil(tracker.currentWiFiObservation)
    }

    func testRoamingAndInternetOutageKeepKnownWiFiButDisconnectionChecksLocation() {
        let (tracker, live, _, reader) = makeTracker()
        reader.complete(0, connection)
        tracker.wifiPathChanged()
        reader.complete(1, ConnectedWiFi(ssid: network.ssid, bssid: points[1].bssid))
        XCTAssertEqual(tracker.state, .knownWiFi); XCTAssertEqual(live.starts, 0)
        // A path change can be loss of internet while association remains intact.
        tracker.wifiPathChanged(); reader.complete(2, connection)
        XCTAssertEqual(live.starts, 0)
        tracker.wifiPathChanged(); reader.complete(3, nil)
        XCTAssertEqual(tracker.state, .recovery)
        XCTAssertEqual(live.starts, 1)
        XCTAssertNil(tracker.currentSSID)
        tracker.wifiPathChanged(); reader.complete(4, connection)
        XCTAssertEqual(tracker.state, .knownWiFi)
        XCTAssertFalse(live.updating)
        tracker.configure(places: [], enabled: false)
    }

    func testConnectedPlaceGetsDepartureRegionEvenWithManySavedPlaces() {
        let (tracker, _, passive, reader) = makeTracker()
        let places = (0..<25).map { Place(name: "A Fixture \($0)", coordinate: .init(latitude: 2, longitude: 2)) } + [home]
        tracker.updateWiFiKnowledge(places: places, networks: [network], accessPoints: points)
        tracker.configure(places: places, enabled: true)
        XCTAssertFalse(passive.regions.contains { $0.identifier == home.id })
        reader.complete(0, connection)
        XCTAssertTrue(passive.regions.contains { $0.identifier == home.id })
        XCTAssertEqual(passive.regions.count, 19)
        tracker.configure(places: [], enabled: false)
    }

    func testUnknownBSSIDAndPortableReclassificationCannotSuppressLocation() {
        let (tracker, live, _, reader) = makeTracker()
        reader.complete(0, ConnectedWiFi(ssid: network.ssid, bssid: "02:00:00:00:00:99"))
        XCTAssertEqual(tracker.state, .recovery); XCTAssertTrue(live.updating)
        tracker.wifiPathChanged(); reader.complete(1, connection)
        XCTAssertFalse(live.updating)
        var portable = network; portable.classification = .portable
        tracker.updateWiFiKnowledge(places: [home], networks: [portable], accessPoints: points)
        XCTAssertEqual(tracker.state, .recovery); XCTAssertTrue(live.updating)
        tracker.receivedMotion(.walking, at: Date()); reader.complete(2, connection)
        XCTAssertEqual(tracker.state, .moving); XCTAssertTrue(live.updating)
        tracker.configure(places: [], enabled: false)
    }

    func testRegionDepartureRequiresFreshFixEvenIfWiFiStillMatches() {
        let (tracker, live, passive, reader) = makeTracker()
        reader.complete(0, connection)
        let region = CLCircularRegion(center: .init(latitude: 1, longitude: 1), radius: 100, identifier: home.id)
        tracker.locationManager(passive, didExitRegion: region)
        XCTAssertEqual(tracker.state, .recovery); XCTAssertTrue(live.updating)
        tracker.wifiPathChanged(); reader.complete(1, connection)
        XCTAssertTrue(live.updating, "An exit must be verified before Wi-Fi can suppress requests again")
        let cached = CLLocation(coordinate: .init(latitude: 1, longitude: 1), altitude: 0,
                                horizontalAccuracy: 10, verticalAccuracy: 10, timestamp: Date().addingTimeInterval(-30))
        tracker.locationManager(live, didUpdateLocations: [cached])
        XCTAssertTrue(live.updating, "A fix taken before departure cannot settle the departure check")
        let location = CLLocation(coordinate: .init(latitude: 1, longitude: 1), altitude: 0,
                                  horizontalAccuracy: 10, verticalAccuracy: 10, timestamp: Date())
        tracker.locationManager(live, didUpdateLocations: [location])
        XCTAssertEqual(tracker.state, .stationaryCandidate); XCTAssertTrue(live.updating)
        tracker.receivedMotion(.walking, at: Date()); reader.complete(reader.callbacks.count - 1, connection)
        XCTAssertEqual(tracker.state, .knownWiFi); XCTAssertFalse(live.updating)
        tracker.configure(places: [], enabled: false)
    }

    func testPermissionRevocationAndLateCallbacksCannotResumeTracking() {
        let (tracker, live, _, reader) = makeTracker()
        reader.complete(0, connection)
        tracker.receivedMotion(.walking, at: Date())
        live.mockAuthorization = .denied
        tracker.locationManagerDidChangeAuthorization(live)
        reader.complete(1, connection)
        XCTAssertEqual(tracker.state, .paused); XCTAssertFalse(live.updating)
        XCTAssertNil(tracker.currentSSID)
    }

    func testContradictoryPassiveLocationCannotBeOverriddenByKnownBSSID() {
        let (tracker, live, passive, reader) = makeTracker()
        reader.complete(0, connection)
        let outside = CLLocation(coordinate: .init(latitude: 1, longitude: 1.01), altitude: 0,
                                 horizontalAccuracy: 10, verticalAccuracy: 10, timestamp: Date())
        tracker.locationManager(passive, didUpdateLocations: [outside])
        XCTAssertTrue(live.updating)
        tracker.receivedMotion(.walking, at: Date()); reader.complete(1, connection)
        XCTAssertTrue(live.updating); XCTAssertNotEqual(tracker.state, .knownWiFi)
        tracker.configure(places: [], enabled: false)
    }

    func testForegroundRechecksWiFiAndForegroundOnlyPermissionStopsInBackground() {
        let (tracker, live, passive, reader) = makeTracker()
        reader.complete(0, connection)
        tracker.sceneChanged(isForeground: false)
        tracker.sceneChanged(isForeground: true)
        XCTAssertEqual(reader.callbacks.count, 2)
        reader.complete(1, nil)
        XCTAssertTrue(live.updating)
        tracker.wifiPathChanged(); reader.complete(2, connection)
        live.mockAuthorization = .authorizedWhenInUse
        tracker.locationManagerDidChangeAuthorization(live)
        tracker.sceneChanged(isForeground: false)
        XCTAssertEqual(tracker.state, .paused); XCTAssertFalse(live.updating)
        XCTAssertFalse(passive.visits); XCTAssertFalse(passive.significantChanges)
    }

    func testApproximateAccessSkipsWiFiAndChecksLocation() {
        let (tracker, live, _, reader) = makeTracker()
        reader.complete(0, connection)
        live.mockAccuracy = .reducedAccuracy
        tracker.locationManagerDidChangeAuthorization(live)
        XCTAssertEqual(tracker.state, .recovery); XCTAssertTrue(live.updating)
        XCTAssertNil(tracker.currentBSSID)
        XCTAssertEqual(reader.callbacks.count, 1)
        tracker.configure(places: [], enabled: false)
    }

    func testOverlappingReadsAndPauseDiscardOldWiFiResults() {
        let (tracker, live, _, reader) = makeTracker()
        tracker.wifiPathChanged()
        reader.complete(0, connection)
        XCTAssertNotEqual(tracker.state, .knownWiFi)
        reader.complete(1, nil)
        XCTAssertTrue(live.updating)
        tracker.receivedMotion(.walking, at: Date())
        tracker.configure(places: [], enabled: false)
        reader.complete(2, connection)
        XCTAssertEqual(tracker.state, .paused); XCTAssertFalse(live.updating)
        tracker.clearSensitiveState()
        XCTAssertNil(tracker.currentSSID)
    }

    func testWiFiTimeoutFallsBackAndLateResultCannotStopLocation() async throws {
        let (tracker, live, _, reader) = makeTracker(timeout: .milliseconds(20))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(tracker.state, .recovery); XCTAssertTrue(live.updating)
        reader.complete(0, connection)
        XCTAssertTrue(live.updating); XCTAssertNotEqual(tracker.state, .knownWiFi)
        tracker.configure(places: [], enabled: false)
    }

    func testExpiredWiFiResultIsRejectedEvenBeforeWatchdogRuns() {
        let (tracker, live, _, reader) = makeTracker(timeout: .milliseconds(20))
        // Model queued main-actor work after suspension: deliver the old Wi-Fi
        // callback before the timeout task gets its turn.
        Thread.sleep(forTimeInterval: 0.05)
        reader.complete(0, connection)
        XCTAssertEqual(tracker.state, .recovery); XCTAssertTrue(live.updating)
        XCTAssertNil(tracker.currentBSSID)
        tracker.configure(places: [], enabled: false)
    }

    func testKnownWiFiStaysQuietThroughPowerChangesAndLateLocationCallbacks() {
        let device = DeviceSpy(), clock = TrackingClock()
        let (tracker, live, _, reader) = makeTracker(device: device, clock: clock)
        reader.complete(0, connection)
        var observations: [SensorObservation] = []
        tracker.onObservations = { observations += $0 }
        for power in [UIDevice.BatteryState.charging, .full, .unplugged] {
            device.mockState = power
            tracker.powerChanged()
            let fix = CLLocation(coordinate: .init(latitude: 1, longitude: 1), altitude: 0,
                                 horizontalAccuracy: 3, verticalAccuracy: 3, timestamp: clock.time)
            tracker.locationManager(live, didUpdateLocations: [fix])
            tracker.locationManagerDidPauseLocationUpdates(live)
            XCTAssertEqual(tracker.state, .knownWiFi)
            XCTAssertFalse(live.updating)
        }
        XCTAssertEqual(live.starts, 0)
        XCTAssertEqual(live.requests, 0)
        XCTAssertEqual(observations.filter { $0.source == .location }.count, 3, "Late samples are retained without restarting GPS")
        XCTAssertEqual(reader.callbacks.count, 1)
        tracker.configure(places: [], enabled: false)
    }

    func testLaunchingOnExternalPowerChecksWiFiFirstAndStopsAfterGPSDwell() {
        let clock = TrackingClock()
        let device = DeviceSpy(); device.mockState = .full
        let (tracker, live, _, reader) = makeTracker(device: device, clock: clock)
        XCTAssertFalse(live.updating, "Check Wi-Fi before starting GPS even while charging")
        reader.complete(0, nil)
        XCTAssertTrue(live.updating)
        let fix = CLLocation(coordinate: .init(latitude: 1, longitude: 1), altitude: 0,
                             horizontalAccuracy: 3, verticalAccuracy: 3, timestamp: clock.time)
        tracker.locationManager(live, didUpdateLocations: [fix])
        XCTAssertEqual(tracker.state, .stationaryCandidate)
        clock.time.addTimeInterval(180)
        tracker.locationManager(live, didUpdateLocations: [CLLocation(coordinate: fix.coordinate, altitude: 0,
            horizontalAccuracy: 3, verticalAccuracy: 3, timestamp: clock.time)])
        XCTAssertEqual(tracker.state, .knownPlace)
        XCTAssertFalse(live.updating)
        XCTAssertEqual(live.desiredAccuracy, kCLLocationAccuracyNearestTenMeters)
        XCTAssertTrue(live.pausesLocationUpdatesAutomatically)
        XCTAssertEqual(tracker.energySnapshot().batteryState, "Full")
        device.mockState = .unplugged
        tracker.powerChanged()
        XCTAssertFalse(live.updating)
        tracker.configure(places: [], enabled: false)
    }

    func testChargingAndBatteryCallbacksCannotProlongFailedGPSRecovery() async throws {
        let device = DeviceSpy()
        let (tracker, live, _, reader) = makeTracker(recoveryTimeout: .milliseconds(80), device: device)
        reader.complete(0, nil)
        device.mockState = .charging
        tracker.powerChanged()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(tracker.state, .lowPowerFallback)
        XCTAssertFalse(live.updating)
        device.mockLevel = 0.6
        tracker.powerChanged()
        device.mockState = .unplugged
        tracker.powerChanged()
        XCTAssertFalse(live.updating)
        XCTAssertEqual(live.starts, 1)
        XCTAssertEqual(reader.callbacks.count, 1, "Battery updates must not initiate more searches")
        tracker.configure(places: [], enabled: false)
    }

    func testChargingCanRetryCriticalBatteryFallbackAfterCheckingWiFi() {
        let device = DeviceSpy(); device.mockLevel = 0.03
        let (tracker, live, _, reader) = makeTracker(device: device)
        reader.complete(0, nil)
        XCTAssertEqual(tracker.state, .lowPowerFallback)
        XCTAssertFalse(live.updating)
        device.mockState = .charging
        tracker.powerChanged()
        XCTAssertFalse(live.updating)
        reader.complete(1, nil)
        XCTAssertEqual(tracker.state, .recovery)
        XCTAssertTrue(live.updating)
        XCTAssertEqual(live.desiredAccuracy, kCLLocationAccuracyNearestTenMeters)
        device.mockState = .unplugged
        tracker.powerChanged()
        XCTAssertEqual(tracker.state, .lowPowerFallback)
        XCTAssertFalse(live.updating)
        tracker.configure(places: [], enabled: false)
    }

    func testChargingCannotOverrideDisabledRecordingOrRevokedPermission() {
        let device = DeviceSpy(); device.mockState = .charging
        let (tracker, live, _, reader) = makeTracker(device: device)
        tracker.configure(places: [], enabled: false)
        tracker.powerChanged()
        reader.complete(0, connection)
        tracker.locationManagerDidPauseLocationUpdates(live)
        XCTAssertFalse(live.updating)
        XCTAssertEqual(tracker.state, .paused)
        tracker.configure(places: [home], enabled: true)
        XCTAssertFalse(live.updating)
        reader.complete(1, nil)
        XCTAssertTrue(live.updating)
        tracker.refreshCurrentWiFi()
        live.mockAuthorization = .denied
        tracker.locationManagerDidChangeAuthorization(live)
        tracker.powerChanged()
        reader.complete(2, connection)
        XCTAssertFalse(live.updating)
        XCTAssertEqual(tracker.state, .paused)
    }

    func testForegroundAndMissedPowerChangesKeepWiFiQuietAndHonorPermission() {
        let device = DeviceSpy(), clock = TrackingClock()
        let (tracker, live, _, reader) = makeTracker(device: device, clock: clock)
        reader.complete(0, connection)
        tracker.sceneChanged(isForeground: false)
        device.mockState = .charging
        tracker.sceneChanged(isForeground: true)
        XCTAssertFalse(live.updating)
        reader.complete(1, connection)
        clock.time.addTimeInterval(180)
        device.mockState = .unplugged
        tracker.sceneChanged(isForeground: true)
        reader.complete(2, connection)
        XCTAssertFalse(live.updating)
        XCTAssertEqual(live.starts, 0)
        device.mockState = .charging
        tracker.powerChanged()
        live.mockAuthorization = .authorizedWhenInUse
        tracker.locationManagerDidChangeAuthorization(live)
        tracker.sceneChanged(isForeground: false)
        tracker.powerChanged()
        XCTAssertFalse(live.updating)
        XCTAssertEqual(tracker.state, .paused)
        tracker.configure(places: [], enabled: false)
    }

    func testAutomaticPauseIsHonoredOnExternalPower() {
        let device = DeviceSpy(); device.mockState = .charging
        let (tracker, live, _, reader) = makeTracker(device: device)
        reader.complete(0, nil)
        XCTAssertTrue(live.updating)
        tracker.locationManagerDidPauseLocationUpdates(live)
        XCTAssertEqual(live.starts, 1)
        XCTAssertFalse(live.updating)
        XCTAssertTrue(live.pausesLocationUpdatesAutomatically)
        XCTAssertEqual(tracker.state, .lowPowerFallback)
        tracker.configure(places: [], enabled: false)
    }

    func testQuietWiFiConfirmsVisitWithOneConnectionReadAndNoGPSRequests() async throws {
        for power in [UIDevice.BatteryState.unplugged, .charging] {
            let clock = TrackingClock(), device = DeviceSpy(); device.mockState = power
            let (tracker, live, _, reader) = makeTracker(settlingDelay: .milliseconds(100), device: device, clock: clock)
            var observations: [SensorObservation] = []
            tracker.onObservations = { observations += $0 }
            reader.complete(0, connection)
            // A passive fix inside the place must not discard Wi-Fi-only dwell.
            clock.time.addTimeInterval(60)
            tracker.locationManager(live, didUpdateLocations: [CLLocation(coordinate: .init(latitude: 1, longitude: 1),
                altitude: 0, horizontalAccuracy: 100, verticalAccuracy: 100, timestamp: clock.time)])
            reader.complete(1, connection)
            clock.time.addTimeInterval(120)
            try await Task.sleep(for: .milliseconds(160))
            XCTAssertEqual(reader.callbacks.count, 3)
            reader.complete(2, connection)
            XCTAssertEqual(live.starts, 0)
            XCTAssertEqual(live.requests, 0)
            XCTAssertEqual(tracker.state, .knownWiFi)
            let items = InferenceEngine.infer(observations: observations, places: [home], networks: [network], accessPoints: points)
            XCTAssertTrue(items.contains { $0.kind == .stay })
            try await Task.sleep(for: .milliseconds(160))
            XCTAssertEqual(reader.callbacks.count, 3, "No periodic network polling after confirmation")
            tracker.configure(places: [], enabled: false)
        }
    }

    func testIndoorMovementResetsDwellWithoutWakingGPS() async throws {
        let clock = TrackingClock()
        let (tracker, live, _, reader) = makeTracker(settlingDelay: .milliseconds(100), clock: clock)
        var observations: [SensorObservation] = []
        tracker.onObservations = { observations += $0 }
        reader.complete(0, connection)
        clock.time.addTimeInterval(30)
        tracker.receivedMotion(.walking, at: clock.time); reader.complete(1, connection)
        clock.time.addTimeInterval(30)
        tracker.receivedMotion(.stationary, at: clock.time)
        clock.time.addTimeInterval(0.01); reader.complete(2, connection)
        XCTAssertFalse(live.updating)
        XCTAssertFalse(InferenceEngine.infer(observations: observations, places: [home], networks: [network], accessPoints: points).contains { $0.kind == .stay })
        clock.time.addTimeInterval(180)
        try await Task.sleep(for: .milliseconds(160))
        reader.complete(3, connection)
        let items = InferenceEngine.infer(observations: observations, places: [home], networks: [network], accessPoints: points)
        XCTAssertEqual(items.last?.kind, .stay)
        XCTAssertEqual(items.last?.start, clock.time.addingTimeInterval(-180), "The indoor walk must not count toward stationary dwell")
        XCTAssertEqual(live.starts, 0)
        XCTAssertEqual(live.requests, 0)
        tracker.configure(places: [], enabled: false)
    }

    func testRecognizingWiFiCancelsAnOutstandingSingleLocationRequest() async throws {
        let clock = TrackingClock()
        let (tracker, live, _, reader) = makeTracker(settlingDelay: .milliseconds(100), clock: clock)
        reader.complete(0, nil)
        tracker.locationManager(live, didUpdateLocations: [CLLocation(coordinate: .init(latitude: 1, longitude: 1),
            altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10, timestamp: clock.time)])
        clock.time.addTimeInterval(180)
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertTrue(live.requestPending)
        reader.complete(1, connection)
        XCTAssertEqual(tracker.state, .knownWiFi)
        XCTAssertFalse(live.updating)
        XCTAssertFalse(live.requestPending)
        tracker.configure(places: [], enabled: false)
    }

    func testWiFiLossDuringDwellResumesGPSAndCannotConfirmAcrossTheDisconnection() {
        let clock = TrackingClock()
        let (tracker, live, _, reader) = makeTracker(clock: clock)
        var observations: [SensorObservation] = []
        tracker.onObservations = { observations += $0 }
        reader.complete(0, connection)
        clock.time.addTimeInterval(100)
        tracker.wifiPathChanged(); reader.complete(1, nil)
        XCTAssertTrue(live.updating)
        clock.time.addTimeInterval(80)
        tracker.wifiPathChanged(); reader.complete(2, connection)
        XCTAssertFalse(live.updating)
        XCTAssertFalse(InferenceEngine.infer(observations: observations, places: [home], networks: [network], accessPoints: points).contains { $0.kind == .stay })
        tracker.configure(places: [], enabled: false)
    }

    func testUnresponsiveWiFiAfterIndoorMovementFallsBackToBoundedGPS() async throws {
        let device = DeviceSpy(); device.mockState = .charging
        let (tracker, live, _, reader) = makeTracker(timeout: .milliseconds(30), recoveryTimeout: .milliseconds(80), device: device)
        reader.complete(0, connection)
        tracker.receivedMotion(.walking, at: Date())
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(live.updating)
        reader.complete(1, connection)
        XCTAssertTrue(live.updating, "A late Wi-Fi reply cannot suppress recovery")
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(live.updating)
        XCTAssertEqual(tracker.state, .lowPowerFallback)
        tracker.configure(places: [], enabled: false)
    }

}

@MainActor private final class DeviceSpy: UIDevice {
    var mockState: UIDevice.BatteryState = .unplugged
    var mockLevel: Float = 0.5
    override var batteryState: UIDevice.BatteryState { mockState }
    override var batteryLevel: Float { mockLevel }
}

@MainActor private final class WiFiReaderSpy {
    var callbacks: [@MainActor @Sendable (ConnectedWiFi?) -> Void] = []
    func complete(_ index: Int, _ value: ConnectedWiFi?) { callbacks[index](value) }
}

private final class LocationSpy: CLLocationManager {
    var starts = 0
    var requests = 0
    var requestPending = false
    var updating = false
    var visits = false
    var significantChanges = false
    var regions: Set<CLRegion> = []
    var mockAuthorization: CLAuthorizationStatus = .authorizedAlways
    var mockAccuracy: CLAccuracyAuthorization = .fullAccuracy
    // The simulator may force automatic pausing off; record the adapter's requested value.
    override var pausesLocationUpdatesAutomatically: Bool { get { requestedPausing } set { requestedPausing = newValue } }
    private var requestedPausing = true
    override var authorizationStatus: CLAuthorizationStatus { mockAuthorization }
    override var accuracyAuthorization: CLAccuracyAuthorization { mockAccuracy }
    override var monitoredRegions: Set<CLRegion> { regions }
    override var maximumRegionMonitoringDistance: CLLocationDistance { 100_000 }
    override func startUpdatingLocation() { starts += 1; updating = true; requestPending = false }
    override func stopUpdatingLocation() { updating = false; requestPending = false }
    override func requestLocation() { requests += 1; requestPending = true }
    override func startMonitoringVisits() { visits = true }
    override func stopMonitoringVisits() { visits = false }
    override func startMonitoringSignificantLocationChanges() { significantChanges = true }
    override func stopMonitoringSignificantLocationChanges() { significantChanges = false }
    override func startMonitoring(for region: CLRegion) { regions.insert(region) }
    override func stopMonitoring(for region: CLRegion) { regions.remove(region) }
}

@MainActor private final class TrackingClock { var time = Date() }
