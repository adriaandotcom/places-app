import Foundation
import CoreLocation
import CoreMotion
import Network
import NetworkExtension
import Observation
import UIKit
import UserNotifications
import PlacesCore

struct ConnectedWiFi: Sendable {
    let ssid: String
    let bssid: String
}

@MainActor @Observable
final class TrackingController: NSObject, @preconcurrency CLLocationManagerDelegate {
    typealias WiFiReader = @MainActor (@escaping @MainActor @Sendable (ConnectedWiFi?) -> Void) -> Void
    private let live: CLLocationManager
    private let passive: CLLocationManager
    private let wifiReader: WiFiReader
    private let recoveryTimeout: Duration
    private var wifiEvidence = WiFiEvidenceGate()
    private let wifiTimeout: Duration
    private let monitorSystemChanges: Bool
    private let activity = CMMotionActivityManager()
    private var settlingTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var places: [Place] = []
    private var networks: [WiFiNetwork] = []
    private var accessPoints: [WiFiAccessPoint] = []
    private var wifiPlaceID: String?
    private var wifiCheckID = 0
    private var wifiCheckTask: Task<Void, Never>?
    private var wifiFallback: TrackingState?
    private var wifiPathMonitor: NWPathMonitor?
    private var departureNeedsFixAfter: Date?
    private var candidate: CLLocation?
    private var enteredState = Date()
    private var lastWiFiRead = Date.distantPast
    private var hasStarted = false
    private var enabled = false
    private var foreground = true
    private var standardActive = false
    private var motionActive = false
    private var motionTime = Date.distantPast
    private var sensorGeneration = 0
    private var observers: [NSObjectProtocol] = []

    private(set) var state: TrackingState = .paused
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    private(set) var accuracy: CLAccuracyAuthorization = .reducedAccuracy
    private(set) var motionAuthorization = CMMotionActivityManager.authorizationStatus()
    private(set) var notificationAuthorization: UNAuthorizationStatus = .notDetermined
    private(set) var currentLocation: CLLocation?
    private(set) var currentSSID: String?
    private(set) var currentBSSID: String?
    private(set) var motion: MotionKind = .unknown
    private var recentMotion: MotionKind { Date().timeIntervalSince(motionTime) <= 300 ? motion : .unknown }
    private(set) var lowPower = false
    private(set) var monitoredRegionCount = 0
    var onObservations: (([SensorObservation]) -> Void)?
    var onEvent: ((TrackingEvent) -> Void)?

    init(live: CLLocationManager = CLLocationManager(), passive: CLLocationManager = CLLocationManager(),
         wifiTimeout: Duration = .seconds(3), recoveryTimeout: Duration = .seconds(90), monitorSystemChanges: Bool = true,
         wifiReader: @escaping WiFiReader = TrackingController.fetchWiFi) {
        self.live = live; self.passive = passive; self.wifiReader = wifiReader
        self.recoveryTimeout = recoveryTimeout; self.wifiTimeout = wifiTimeout; self.monitorSystemChanges = monitorSystemChanges
        super.init()
        live.delegate = self; passive.delegate = self
        live.allowsBackgroundLocationUpdates = true
        live.showsBackgroundLocationIndicator = true
        live.pausesLocationUpdatesAutomatically = true
        live.activityType = .other
        if monitorSystemChanges {
            UIDevice.current.isBatteryMonitoringEnabled = true
            for name in [Notification.Name.NSProcessInfoPowerStateDidChange, UIDevice.batteryLevelDidChangeNotification,
                     UIDevice.batteryStateDidChangeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.powerChanged() }
                })
            }
        }
        refreshAuthorization()
    }

    private static func fetchWiFi(completion: @escaping @MainActor @Sendable (ConnectedWiFi?) -> Void) {
        NEHotspotNetwork.fetchCurrent { network in
            let value = network.map { ConnectedWiFi(ssid: $0.ssid, bssid: $0.bssid) }
            Task { @MainActor in completion(value) }
        }
    }

    func updateWiFiKnowledge(places: [Place], networks: [WiFiNetwork], accessPoints: [WiFiAccessPoint]) {
        self.places = places; self.networks = networks; self.accessPoints = accessPoints
        // Reclassification/deletion revokes suppression immediately. Metadata updates
        // never turn a cached connection into a fresh Wi-Fi observation.
        if let wifiPlaceID {
            let connection = SensorObservation(timestamp: Date(), source: .wifi, ssid: currentSSID, bssid: currentBSSID)
            if TrackingPolicy.connectedPlace(for: connection, places: places, networks: networks, accessPoints: accessPoints)?.id != wifiPlaceID {
                invalidateWiFi()
                if hasStarted { checkLocation(.recovery, reason: "Saved Wi-Fi no longer confirms this place.") }
            }
        }
    }

    var locationStatus: String {
        switch authorization {
        case .authorizedAlways: accuracy == .fullAccuracy ? "Always · Precise" : "Always · Approximate"
        case .authorizedWhenInUse: accuracy == .fullAccuracy ? "While using · Precise" : "While using · Approximate"
        case .denied: "Not allowed"
        case .restricted: "Restricted"
        case .notDetermined: "Not enabled"
        @unknown default: "Unavailable"
        }
    }
    var canLocate: Bool { authorization == .authorizedAlways || authorization == .authorizedWhenInUse }

    var locationSetupReady: Bool { authorization == .authorizedAlways && accuracy == .fullAccuracy }
    var locationSetupMessage: String {
        if !canLocate { return "Allow location access to record your history." }
        if authorization != .authorizedAlways && accuracy != .fullAccuracy { return "Choose Always and turn on Precise Location in Settings." }
        if authorization != .authorizedAlways { return "Choose Always to record while Places is closed." }
        return "Turn on Precise Location to tell nearby places apart."
    }

    func configure(places: [Place], enabled: Bool) {
        self.places = places; self.enabled = enabled
        reconcile()
    }
    func requestLocation() {
        if authorization == .notDetermined { live.requestWhenInUseAuthorization() }
        else if authorization == .authorizedWhenInUse { live.requestAlwaysAuthorization() }
        else if authorization == .denied || authorization == .restricted { openSettings() }
    }
    func requestMotion() {
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        if motionAuthorization == .denied || motionAuthorization == .restricted { openSettings(); return }
        activity.queryActivityStarting(from: Date().addingTimeInterval(-60), to: Date(), to: .main) { [weak self] _, _ in
            Task { @MainActor in self?.refreshAuthorization(); self?.reconcileMotion() }
        }
    }
    func requestNotifications() async {
        if notificationAuthorization == .denied { openSettings(); return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        await refreshNotifications()
    }
    func refreshNotifications() async {
        notificationAuthorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
    func sceneChanged(isForeground: Bool) {
        foreground = isForeground
        refreshAuthorization()
        reconcile()
        if isForeground {
            readWiFi(force: true, fallback: wifiPlaceID == nil ? nil : .recovery)
            Task { await refreshNotifications() }
        }
    }
    func clearSensitiveState() {
        sensorGeneration += 1
        invalidateWiFi()
        currentLocation = nil; currentSSID = nil; currentBSSID = nil; candidate = nil; places = []
        networks = []; accessPoints = []; departureNeedsFixAfter = nil
        motion = .unknown; motionTime = .distantPast; lastWiFiRead = .distantPast
    }
    func refreshCurrentWiFi() { readWiFi(force: true) }

    private func refreshAuthorization() {
        authorization = live.authorizationStatus; accuracy = live.accuracyAuthorization
        motionAuthorization = CMMotionActivityManager.authorizationStatus()
    }
    private func reconcile() {
        guard enabled, canLocate, foreground || authorization == .authorizedAlways else {
            stopAll()
            return
        }
        if authorization == .authorizedAlways {
            if CLLocationManager.significantLocationChangeMonitoringAvailable() { passive.startMonitoringSignificantLocationChanges() }
            passive.startMonitoringVisits()
            configureRegions()
        } else {
            passive.stopMonitoringSignificantLocationChanges(); passive.stopMonitoringVisits()
            for region in passive.monitoredRegions { passive.stopMonitoring(for: region) }
            monitoredRegionCount = 0
        }
        reconcileMotion()
        if !hasStarted {
            enteredState = Date()
            hasStarted = true
            onObservations?([SensorObservation(timestamp: Date(), source: .recovery)])
            readWiFi(force: true, fallback: .recovery)
        }
        startWiFiMonitoring()
    }
    private func stopAll() {
        let wasStarted = hasStarted
        sensorGeneration += 1
        invalidateWiFi(); departureNeedsFixAfter = nil
        wifiPathMonitor?.cancel(); wifiPathMonitor = nil
        settlingTask?.cancel(); endRecovery()
        live.stopUpdatingLocation(); standardActive = false
        passive.stopMonitoringSignificantLocationChanges(); passive.stopMonitoringVisits()
        for region in passive.monitoredRegions { passive.stopMonitoring(for: region) }
        monitoredRegionCount = 0
        activity.stopActivityUpdates(); motionActive = false
        candidate = nil
        if wasStarted { onObservations?([SensorObservation(timestamp: Date(), source: .paused)]) }
        transition(.paused, reason: "Tracking is paused or location access is unavailable.")
        hasStarted = false; wifiEvidence = WiFiEvidenceGate()
    }
    private func reconcileMotion() {
        guard monitorSystemChanges else { return }
        guard enabled, canLocate, motionAuthorization == .authorized else {
            activity.stopActivityUpdates(); motionActive = false; return
        }
        guard !motionActive else { return }
        motionActive = true
        activity.startActivityUpdates(to: .main) { [weak self] value in
            guard let value, value.confidence != .low else { return }
            let kind: MotionKind = value.stationary ? .stationary : value.cycling ? .cycling
                : value.running ? .running : value.walking ? .walking : value.automotive ? .automotive : .unknown
            let time = value.startDate
            Task { @MainActor in self?.receivedMotion(kind, at: time) }
        }
    }
    func receivedMotion(_ kind: MotionKind, at time: Date) {
        guard hasStarted else { return }
        onObservations?([SensorObservation(timestamp: time, source: .motion, motion: kind)])
        guard abs(Date().timeIntervalSince(time)) <= 300, time >= motionTime else { return }
        motion = kind; motionTime = time
        if kind != .stationary && kind != .unknown {
            candidate = nil; settlingTask?.cancel()
            readWiFi(force: true, fallback: .moving)
        }
    }
    private func transition(_ next: TrackingState, reason: String) {
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let level = UIDevice.current.batteryLevel
        let critical = level >= 0 && level <= 0.05 && UIDevice.current.batteryState != .charging && UIDevice.current.batteryState != .full
        let resolved: TrackingState = critical && next != .paused ? .lowPowerFallback : next
        let policy = TrackingPolicy.sensors(state: resolved, motion: recentMotion, lowPower: lowPower)
        live.desiredAccuracy = policy.desiredAccuracy
        live.distanceFilter = policy.distanceFilter
        let changed = resolved != state || policy.standardUpdates != standardActive
        if policy.standardUpdates && !standardActive { live.startUpdatingLocation() }
        if !policy.standardUpdates && standardActive { live.stopUpdatingLocation() }
        standardActive = policy.standardUpdates
        if changed {
            onEvent?(TrackingEvent(timestamp: Date(), state: resolved, reason: reason,
                previousStateDuration: hasStarted ? Date().timeIntervalSince(enteredState) : 0,
                standardLocationActive: standardActive,
                build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "development"))
            enteredState = Date(); state = resolved
        }
    }
    private func powerChanged() {
        guard hasStarted else { return }
        if state == .lowPowerFallback { readWiFi(force: true, fallback: .recovery) }
        else { transition(state, reason: "The power policy changed.") }
    }
    private func endRecovery() {
        recoveryTask?.cancel(); recoveryTask = nil
    }
    private func beginRecoveryDeadline() {
        // Repeated motion/Wi-Fi callbacks must not keep an unsuccessful search alive.
        guard recoveryTask == nil else { return }
        recoveryTask = Task { [weak self, recoveryTimeout] in
            try? await Task.sleep(for: recoveryTimeout)
            guard !Task.isCancelled, let self else { return }
            self.recoveryTask = nil
            guard self.hasStarted, [.recovery, .unknown, .moving, .stationaryCandidate].contains(self.state) else { return }
            self.transition(.lowPowerFallback, reason: "No recent usable fix; waiting for a low-power location event.")
        }
    }
    private func configureRegions() {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self), authorization == .authorizedAlways else { return }
        let sorted = places.sorted {
            if $0.id == wifiPlaceID { return $1.id != wifiPlaceID }
            if $1.id == wifiPlaceID { return false }
            guard let currentLocation else { return $0.name < $1.name }
            let current = Coordinate(latitude: currentLocation.coordinate.latitude, longitude: currentLocation.coordinate.longitude)
            return current.distance(to: $0.coordinate) < current.distance(to: $1.coordinate)
        }
        let wanted = Array(sorted.prefix(19))
        for region in passive.monitoredRegions where region.identifier != "temporary-stop" {
            if let place = wanted.first(where: { $0.id == region.identifier }), let circle = region as? CLCircularRegion,
               circle.center.latitude == place.coordinate.latitude, circle.center.longitude == place.coordinate.longitude,
               abs(circle.radius - place.radius) < 1 { continue }
            passive.stopMonitoring(for: region)
        }
        for place in wanted where !passive.monitoredRegions.contains(where: { $0.identifier == place.id }) {
            let region = CLCircularRegion(center: CLLocationCoordinate2D(latitude: place.coordinate.latitude, longitude: place.coordinate.longitude),
                radius: min(place.radius, passive.maximumRegionMonitoringDistance), identifier: place.id)
            region.notifyOnEntry = true; region.notifyOnExit = true
            passive.startMonitoring(for: region)
        }
        monitoredRegionCount = passive.monitoredRegions.count
    }
    private func monitorStop(_ location: CLLocation) {
        guard authorization == .authorizedAlways, CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        for region in passive.monitoredRegions where region.identifier == "temporary-stop" { passive.stopMonitoring(for: region) }
        let region = CLCircularRegion(center: location.coordinate, radius: 100, identifier: "temporary-stop")
        region.notifyOnEntry = false; region.notifyOnExit = true
        passive.startMonitoring(for: region)
        monitoredRegionCount = passive.monitoredRegions.count
    }
    private func evaluate(_ location: CLLocation) {
        let observation = makeObservation(location, source: .location)
        if let boundary = departureNeedsFixAfter {
            guard location.timestamp >= boundary, observation.usableCoordinate != nil else { return }
            departureNeedsFixAfter = nil
        }
        if let id = wifiPlaceID, let place = places.first(where: { $0.id == id }),
           let coordinate = observation.usableCoordinate,
           coordinate.distance(to: place.coordinate) > place.radius + min(100, location.horizontalAccuracy) {
            invalidateWiFi()
        }
        if wifiPlaceID != nil && departureNeedsFixAfter == nil {
            // Recheck the actual connection on this event; a cached BSSID cannot
            // indefinitely override passive location or departure signals.
            readWiFi(force: true, fallback: .recovery)
            return
        }
        if TrackingPolicy.matchingPlace(for: observation, places: places) != nil {
            candidate = nil; settlingTask?.cancel(); endRecovery()
            transition(.knownPlace, reason: "A recent fix matches a saved place.")
            configureRegions(); readWiFi()
        } else if candidate.map({ TrackingPolicy.sameStationaryArea(makeObservation($0, source: .location), observation) }) ?? true {

            if let candidate, TrackingPolicy.sameStationaryArea(makeObservation(candidate, source: .location), observation) {
                if location.timestamp.timeIntervalSince(candidate.timestamp) >= TrackingPolicy.stationaryDuration {
                    settlingTask?.cancel(); transition(.stationaryUnknown, reason: "Location observations indicate a stop.")
                    monitorStop(location); readWiFi()
                }
            } else {
                candidate = location
                transition(.stationaryCandidate, reason: "Checking whether this is a meaningful stop.")
                settlingTask?.cancel()
                settlingTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(TrackingPolicy.stationaryDuration))
                    guard !Task.isCancelled, let self, self.state == .stationaryCandidate,
                          let latest = self.currentLocation, let anchor = self.candidate,
                          TrackingPolicy.sameStationaryArea(self.makeObservation(anchor, source: .location), self.makeObservation(latest, source: .location)) else { return }
                    // Obtain a fresh sample before treating a quiet sensor as proof of a stop.
                    self.live.stopUpdatingLocation(); self.standardActive = false
                    self.live.requestLocation()
                    self.beginRecoveryDeadline()
                }
            }
        } else {
            candidate = nil; settlingTask?.cancel()
            transition(.moving, reason: "Recent fixes indicate movement.")
            beginRecoveryDeadline()
        }
    }
    private func makeObservation(_ location: CLLocation, source: ObservationSource) -> SensorObservation {
        SensorObservation(timestamp: location.timestamp, source: source,
            coordinate: Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude),
            horizontalAccuracy: location.horizontalAccuracy, speed: location.speed)
    }
    private func invalidateWiFi() {
        wifiCheckID += 1; wifiCheckTask?.cancel(); wifiCheckTask = nil
        wifiFallback = nil; wifiPlaceID = nil
    }

    private func checkLocation(_ next: TrackingState, reason: String) {
        guard hasStarted else { return }
        candidate = nil; settlingTask?.cancel()
        transition(next, reason: reason)
        beginRecoveryDeadline()
    }

    private func wifiUnavailable(fallback: TrackingState?) {
        let next = fallback ?? (wifiPlaceID == nil ? nil : .recovery)
        invalidateWiFi(); currentSSID = nil; currentBSSID = nil
        if let next { checkLocation(next, reason: "Wi-Fi did not respond in time; checking location.") }
    }

    private func startWiFiMonitoring() {
        guard monitorSystemChanges, wifiPathMonitor == nil else { return }
        let generation = sensorGeneration
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.hasStarted, self.sensorGeneration == generation else { return }
                self.wifiPathChanged()
            }
        }
        wifiPathMonitor = monitor
        monitor.start(queue: DispatchQueue(label: "Places.WiFiChanges"))
    }

    func wifiPathChanged() {
        guard hasStarted else { return }
        // Path reachability isn't the same as Wi-Fi association. Read the BSSID
        // even on an unsatisfied path; a router may simply have lost internet.
        readWiFi(force: true, fallback: .recovery)
    }

    private func readWiFi(force: Bool = false, fallback: TrackingState? = nil) {
        guard canLocate, accuracy == .fullAccuracy else {
            let wasTrusted = wifiPlaceID != nil
            invalidateWiFi(); currentSSID = nil; currentBSSID = nil
            if let next = fallback ?? (wasTrusted ? .recovery : nil) {
                checkLocation(next, reason: "Wi-Fi information is unavailable; checking location.")
            }
            return
        }
        // Passive UI reads must not cancel a pending departure check.
        if wifiCheckTask != nil && fallback == nil { return }
        guard force || Date().timeIntervalSince(lastWiFiRead) >= 60 else { return }
        let next = fallback ?? wifiFallback
        wifiCheckID += 1; wifiCheckTask?.cancel(); wifiFallback = next
        let request = wifiCheckID
        let started = ContinuousClock.now
        lastWiFiRead = Date()
        let expectedGeneration = sensorGeneration
        wifiCheckTask = Task { [weak self, wifiTimeout] in
            try? await Task.sleep(for: wifiTimeout)
            guard !Task.isCancelled, let self, self.wifiCheckID == request,
                  self.sensorGeneration == expectedGeneration else { return }
            self.wifiUnavailable(fallback: next)
        }
        wifiReader { [weak self] network in
            guard let self, self.wifiCheckID == request, self.sensorGeneration == expectedGeneration,
                  self.canLocate, self.accuracy == .fullAccuracy else { return }
            // Check age as well as the watchdog: both callbacks may be queued
            // while iOS suspends the app, and delivery order isn't guaranteed.
            guard started.duration(to: .now) < self.wifiTimeout else {
                self.wifiUnavailable(fallback: next); return
            }
            self.wifiCheckID += 1
            self.wifiCheckTask?.cancel(); self.wifiCheckTask = nil; self.wifiFallback = nil
            self.currentSSID = network?.ssid; self.currentBSSID = network?.bssid.lowercased()
            guard self.hasStarted else { return }
            let location = network == nil ? nil : self.currentLocation
            let observation = SensorObservation(timestamp: Date(), source: .wifi,
                coordinate: location.map { Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) },
                coordinateTimestamp: location?.timestamp, horizontalAccuracy: location?.horizontalAccuracy,
                ssid: network?.ssid, bssid: network?.bssid)
            let place = self.departureNeedsFixAfter == nil ? TrackingPolicy.connectedPlace(for: observation,
                places: self.places, networks: self.networks, accessPoints: self.accessPoints) : nil
            if self.wifiEvidence.shouldRecord(observation, placeID: place?.id) { self.onObservations?([observation]) }
            let wasTrusted = self.wifiPlaceID != nil
            self.wifiPlaceID = place?.id
            if place != nil {
                self.candidate = nil; self.settlingTask?.cancel(); self.endRecovery()
                self.transition(.knownWiFi, reason: "A live connection matches a learned fixed-place access point.")
                self.configureRegions()
            } else if let next = next ?? (wasTrusted ? .recovery : nil) {
                self.checkLocation(next, reason: "Wi-Fi does not confirm this place; checking location.")
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let old = authorization, oldAccuracy = accuracy
        refreshAuthorization()
        if accuracy != .fullAccuracy || !canLocate { invalidateWiFi(); currentSSID = nil; currentBSSID = nil }
        // Upgrading access does not interrupt recording and must not fabricate a
        // pause/recovery gap. Revocation and background foreground-only access
        // still go through stopAll via reconcile.
        if hasStarted, canLocate, oldAccuracy != accuracy {
            candidate = nil; settlingTask?.cancel()
            readWiFi(force: true, fallback: .recovery)
        }
        reconcile()
        if old == .authorizedAlways && authorization != .authorizedAlways && enabled {
            Task { await notifyPermissionProblem() }
        }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard hasStarted else { return }
        let accepted = locations.filter { $0.horizontalAccuracy >= 0 && $0.timestamp <= Date().addingTimeInterval(60) }
        onObservations?(accepted.map { makeObservation($0, source: manager === passive ? .significantChange : .location) })
        guard let latest = accepted.max(by: { $0.timestamp < $1.timestamp }), Date().timeIntervalSince(latest.timestamp) <= 120 else { return }
        currentLocation = latest
        if makeObservation(latest, source: .location).usableCoordinate != nil, abs(Date().timeIntervalSince(latest.timestamp)) <= 30 {
            endRecovery()
        }
        evaluate(latest)
        if standardActive { beginRecoveryDeadline() }
    }
    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        guard hasStarted else { return }
        let coordinate = Coordinate(latitude: visit.coordinate.latitude, longitude: visit.coordinate.longitude)
        var observations: [SensorObservation] = []
        if visit.arrivalDate != .distantPast {
            observations.append(SensorObservation(timestamp: visit.arrivalDate, source: .visitArrival, coordinate: coordinate,
                horizontalAccuracy: visit.horizontalAccuracy, speed: 0))
        }
        if visit.departureDate != .distantFuture {
            observations.append(SensorObservation(timestamp: visit.departureDate, source: .visitDeparture, coordinate: coordinate,
                horizontalAccuracy: visit.horizontalAccuracy))
        }
        onObservations?(observations)
        if visit.departureDate != .distantFuture {
            invalidateWiFi(); departureNeedsFixAfter = Date()
            checkLocation(.recovery, reason: "A visit departure needs a fresh location check.")
        } else { readWiFi(force: true, fallback: .recovery) }
    }
    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) { regionChanged(region, entering: true) }
    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) { regionChanged(region, entering: false) }
    private func regionChanged(_ region: CLRegion, entering: Bool) {
        guard hasStarted else { return }
        onObservations?([SensorObservation(timestamp: Date(), source: entering ? .regionEnter : .regionExit,
                                    monitoredPlaceID: region.identifier == "temporary-stop" ? nil : region.identifier)])
        if !entering {
            if let wifiPlaceID, region.identifier != wifiPlaceID { return }
            invalidateWiFi(); departureNeedsFixAfter = Date()
            checkLocation(.recovery, reason: "A monitored departure needs a fresh location check.")
        } else { readWiFi(force: true, fallback: .recovery) }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if (error as? CLError)?.code == .denied { refreshAuthorization(); reconcile() }
        // Transient failures are represented by gaps and a bounded recovery window, not raw OS error logs.
    }
    func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        guard hasStarted, state != .knownPlace, state != .knownWiFi, let location = currentLocation else { return }
        transition(.stationaryUnknown, reason: "iOS paused location updates while stationary."); monitorStop(location)
    }
    private func notifyPermissionProblem() async {
        let expectedGeneration = sensorGeneration
        await refreshNotifications()
        guard enabled, sensorGeneration == expectedGeneration, notificationAuthorization == .authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "Your history may have gaps"
        content.body = "Background location is no longer enabled. You can review access in Places."
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "location-access", content: content, trigger: nil))
    }
}
