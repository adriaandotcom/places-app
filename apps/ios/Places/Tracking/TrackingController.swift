import Foundation
import CoreLocation
import CoreMotion
import NetworkExtension
import Observation
import UIKit
import UserNotifications
import PlacesCore

@MainActor @Observable
final class TrackingController: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let live = CLLocationManager()
    private let passive = CLLocationManager()
    private let activity = CMMotionActivityManager()
    private var settlingTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var places: [Place] = []
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

    override init() {
        super.init()
        live.delegate = self; passive.delegate = self
        live.allowsBackgroundLocationUpdates = true
        live.showsBackgroundLocationIndicator = true
        live.pausesLocationUpdatesAutomatically = true
        live.activityType = .other
        UIDevice.current.isBatteryMonitoringEnabled = true
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, UIDevice.batteryLevelDidChangeNotification,
                     UIDevice.batteryStateDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.powerChanged() }
            })
        }
        refreshAuthorization()
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
        if isForeground { readWiFi(); Task { await refreshNotifications() } }
    }
    func clearSensitiveState() {
        sensorGeneration += 1
        currentLocation = nil; currentSSID = nil; currentBSSID = nil; candidate = nil; places = []
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
            transition(.recovery, reason: "Restoring authorized location services.")
            beginRecoveryDeadline()
        }
    }
    private func stopAll() {
        let wasStarted = hasStarted
        sensorGeneration += 1
        settlingTask?.cancel(); recoveryTask?.cancel()
        live.stopUpdatingLocation(); standardActive = false
        passive.stopMonitoringSignificantLocationChanges(); passive.stopMonitoringVisits()
        for region in passive.monitoredRegions { passive.stopMonitoring(for: region) }
        monitoredRegionCount = 0
        activity.stopActivityUpdates(); motionActive = false
        candidate = nil
        if wasStarted { onObservations?([SensorObservation(timestamp: Date(), source: .paused)]) }
        transition(.paused, reason: "Tracking is paused or location access is unavailable.")
        hasStarted = false
    }
    private func reconcileMotion() {
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
    private func receivedMotion(_ kind: MotionKind, at time: Date) {
        guard hasStarted else { return }
        onObservations?([SensorObservation(timestamp: time, source: .motion, motion: kind)])
        guard abs(Date().timeIntervalSince(time)) <= 300, time >= motionTime else { return }
        motion = kind; motionTime = time
        if kind != .stationary && kind != .unknown {
            candidate = nil; settlingTask?.cancel()
            transition(.moving, reason: "Movement was detected.")
            beginRecoveryDeadline()
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
        if state == .lowPowerFallback { transition(.recovery, reason: "Re-evaluating the power policy."); beginRecoveryDeadline() }
        else { transition(state, reason: "The power policy changed.") }
    }
    private func beginRecoveryDeadline() {
        recoveryTask?.cancel()
        recoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(90))
            guard !Task.isCancelled, let self, self.hasStarted,
                  [.recovery, .unknown, .moving, .stationaryCandidate].contains(self.state),
                  self.currentLocation.map({ Date().timeIntervalSince($0.timestamp) > 90 }) ?? true else { return }
            self.transition(.lowPowerFallback, reason: "No recent fix; waiting for a low-power location event.")
        }
    }
    private func configureRegions() {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self), authorization == .authorizedAlways else { return }
        let sorted = places.sorted {
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
        if TrackingPolicy.matchingPlace(for: observation, places: places) != nil {
            candidate = nil; settlingTask?.cancel(); recoveryTask?.cancel()
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
    private func readWiFi(force: Bool = false) {
        guard canLocate, accuracy == .fullAccuracy, force || Date().timeIntervalSince(lastWiFiRead) >= 60 else { return }
        lastWiFiRead = Date()
        let expectedGeneration = sensorGeneration
        NEHotspotNetwork.fetchCurrent { [weak self] network in
            let ssid = network?.ssid, bssid = network?.bssid
            Task { @MainActor in
                guard let self, self.canLocate, self.accuracy == .fullAccuracy,
                      self.sensorGeneration == expectedGeneration else { return }
                self.currentSSID = ssid; self.currentBSSID = bssid
                guard self.hasStarted, let ssid else { return }
                let location = self.currentLocation
                self.onObservations?([SensorObservation(timestamp: Date(), source: .wifi,
                    coordinate: location.map { Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) },
                    coordinateTimestamp: location?.timestamp, horizontalAccuracy: location?.horizontalAccuracy,
                    ssid: ssid, bssid: bssid)])
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let old = authorization, oldAccuracy = accuracy
        refreshAuthorization()
        if accuracy != .fullAccuracy { currentSSID = nil; currentBSSID = nil }
        // Upgrading access does not interrupt recording and must not fabricate a
        // pause/recovery gap. Revocation and background foreground-only access
        // still go through stopAll via reconcile.
        if hasStarted, canLocate, oldAccuracy != accuracy {
            candidate = nil; settlingTask?.cancel()
            transition(.recovery, reason: "Location precision changed; checking a fresh fix.")
            beginRecoveryDeadline()
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
        currentLocation = latest; evaluate(latest)
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
        transition(.recovery, reason: "A visit event arrived; checking the current location."); beginRecoveryDeadline(); readWiFi()
    }
    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) { regionChanged(region, entering: true) }
    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) { regionChanged(region, entering: false) }
    private func regionChanged(_ region: CLRegion, entering: Bool) {
        guard hasStarted else { return }
        onObservations?([SensorObservation(timestamp: Date(), source: entering ? .regionEnter : .regionExit,
                                    monitoredPlaceID: region.identifier == "temporary-stop" ? nil : region.identifier)])
        candidate = nil; settlingTask?.cancel()
        transition(entering ? .recovery : .moving, reason: "A monitored region boundary was crossed.")
        beginRecoveryDeadline(); readWiFi()
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if (error as? CLError)?.code == .denied { refreshAuthorization(); reconcile() }
        // Transient failures are represented by gaps and a bounded recovery window, not raw OS error logs.
    }
    func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        guard hasStarted, state != .knownPlace, let location = currentLocation else { return }
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
