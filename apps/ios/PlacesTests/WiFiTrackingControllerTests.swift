import XCTest
import CoreLocation
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

    private func makeTracker(timeout: Duration = .seconds(3)) -> (TrackingController, LocationSpy, LocationSpy, WiFiReaderSpy) {
        let live = LocationSpy(), passive = LocationSpy(), reader = WiFiReaderSpy()
        let tracker = TrackingController(live: live, passive: passive, wifiTimeout: timeout, monitorSystemChanges: false,
                                         wifiReader: { reader.callbacks.append($0) })
        tracker.updateWiFiKnowledge(places: [home], networks: [network], accessPoints: points)
        tracker.configure(places: [home], enabled: true)
        return (tracker, live, passive, reader)
    }

    func testLiveKnownWiFiStopsLocationAndMotionDoesNotRestartIt() {
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
        XCTAssertEqual(observations.filter { $0.source == .wifi }.count, 2)
        XCTAssertTrue(observations.filter { $0.source == .wifi }.allSatisfy { $0.coordinate == nil })
        tracker.configure(places: [], enabled: false)
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
        XCTAssertEqual(tracker.state, .knownPlace); XCTAssertFalse(live.updating)
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
}

@MainActor private final class WiFiReaderSpy {
    var callbacks: [@MainActor @Sendable (ConnectedWiFi?) -> Void] = []
    func complete(_ index: Int, _ value: ConnectedWiFi?) { callbacks[index](value) }
}

private final class LocationSpy: CLLocationManager {
    var starts = 0
    var updating = false
    var visits = false
    var significantChanges = false
    var regions: Set<CLRegion> = []
    var mockAuthorization: CLAuthorizationStatus = .authorizedAlways
    var mockAccuracy: CLAccuracyAuthorization = .fullAccuracy
    override var authorizationStatus: CLAuthorizationStatus { mockAuthorization }
    override var accuracyAuthorization: CLAccuracyAuthorization { mockAccuracy }
    override var monitoredRegions: Set<CLRegion> { regions }
    override var maximumRegionMonitoringDistance: CLLocationDistance { 100_000 }
    override func startUpdatingLocation() { starts += 1; updating = true }
    override func stopUpdatingLocation() { updating = false }
    override func requestLocation() {}
    override func startMonitoringVisits() { visits = true }
    override func stopMonitoringVisits() { visits = false }
    override func startMonitoringSignificantLocationChanges() { significantChanges = true }
    override func stopMonitoringSignificantLocationChanges() { significantChanges = false }
    override func startMonitoring(for region: CLRegion) { regions.insert(region) }
    override func stopMonitoring(for region: CLRegion) { regions.remove(region) }
}
