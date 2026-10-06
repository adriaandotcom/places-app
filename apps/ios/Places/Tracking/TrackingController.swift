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
    private let device: UIDevice
    private let now: @MainActor () -> Date
    private var externallyPowered: Bool { device.batteryState == .charging || device.batteryState == .full }
    private var appliedExternalPower = false
    private let wifiReader: WiFiReader
    private let recoveryTimeout: Duration
    private let settlingDelay: Duration
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
    private var confirmation = VisitConfirmation()
    private var enteredState = Date()
    private var lastWiFiRead = Date.distantPast
    private var hasStarted = false
    private var enabled = false
    private var foreground = true
    private var energy = EnergyCounters()
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
    private(set) var currentWiFiObservation: SensorObservation?
    private(set) var motion: MotionKind = .unknown
    private var recentMotion: MotionKind { now().timeIntervalSince(motionTime) <= 300 ? motion : .unknown }
    private(set) var lowPower = false
    private(set) var monitoredRegionCount = 0
    var onObservations: (([SensorObservation]) -> Void)?
    var onEvent: ((TrackingEvent) -> Void)?

    init(live: CLLocationManager = CLLocationManager(), passive: CLLocationManager = CLLocationManager(), device: UIDevice = .current,
         wifiTimeout: Duration = .seconds(3), recoveryTimeout: Duration = .seconds(90),
         settlingDelay: Duration = .seconds(TrackingPolicy.stationaryDuration), monitorSystemChanges: Bool = true,
         now: @escaping @MainActor () -> Date = Date.init,
         wifiReader: @escaping WiFiReader = TrackingController.fetchWiFi) {
        self.live = live; self.passive = passive; self.device = device; self.wifiReader = wifiReader
        self.recoveryTimeout = recoveryTimeout; self.wifiTimeout = wifiTimeout; self.monitorSystemChanges = monitorSystemChanges
        self.settlingDelay = settlingDelay; self.now = now
        super.init()
        live.delegate = self; passive.delegate = self
        live.allowsBackgroundLocationUpdates = true
        live.showsBackgroundLocationIndicator = true
        live.pausesLocationUpdatesAutomatically = true
        live.activityType = .other
        if monitorSystemChanges {
            device.isBatteryMonitoringEnabled = true
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
            let connection = SensorObservation(timestamp: now(), source: .wifi, ssid: currentSSID, bssid: currentBSSID)
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
        activity.queryActivityStarting(from: now().addingTimeInterval(-60), to: now(), to: .main) { [weak self] _, _ in
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
        recordEnergyCheckpoint(reason: isForeground ? "App entered foreground." : "App entered background.")
        refreshAuthorization()
        reconcile()
        if isForeground {
            readWiFi(force: true, fallback: wifiPlaceID == nil ? nil : .recovery)
            Task { await refreshNotifications() }
        }
    }
    func clearSensitiveState() {
        sensorGeneration += 1
        energy = EnergyCounters()
        invalidateWiFi()
        currentLocation = nil; currentSSID = nil; currentBSSID = nil; currentWiFiObservation = nil; candidate = nil; confirmation.reset(); places = []
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
            enteredState = now()
            hasStarted = true
            onObservations?([SensorObservation(timestamp: now(), source: .recovery)])
            if externallyPowered { checkLocation(.recovery, reason: "External power enables detailed location recording.") }
            readWiFi(force: true, fallback: .recovery)
        } else if appliedExternalPower != externallyPowered {
            // Reapply after suspension, when a charging notification may have been missed.
            powerChanged()
        }
        startWiFiMonitoring()
    }
    private func stopAll() {
        let wasStarted = hasStarted
        sensorGeneration += 1
        currentWiFiObservation = nil; currentSSID = nil; currentBSSID = nil
        invalidateWiFi(); departureNeedsFixAfter = nil
        wifiPathMonitor?.cancel(); wifiPathMonitor = nil
        settlingTask?.cancel(); settlingTask = nil; endRecovery()
        live.stopUpdatingLocation(); standardActive = false
        energy.setStandardLocation(active: false, uptime: ProcessInfo.processInfo.systemUptime)
        passive.stopMonitoringSignificantLocationChanges(); passive.stopMonitoringVisits()
        for region in passive.monitoredRegions { passive.stopMonitoring(for: region) }
        monitoredRegionCount = 0
        activity.stopActivityUpdates(); motionActive = false
        candidate = nil; confirmation.reset()
        if wasStarted { onObservations?([SensorObservation(timestamp: now(), source: .paused)]) }
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
            let kind = VisitConfirmation.motion(stationary: value.stationary, walking: value.walking,
                running: value.running, cycling: value.cycling, automotive: value.automotive)
            let time = value.startDate
            Task { @MainActor in self?.receivedMotion(kind, at: time) }
        }
    }
    func receivedMotion(_ kind: MotionKind, at time: Date) {
        guard hasStarted else { return }
        energy.motionCallbacks += 1
        onObservations?([SensorObservation(timestamp: time, source: .motion, motion: kind)])
        guard abs(now().timeIntervalSince(time)) <= 300, time >= motionTime else { return }
        motion = kind; motionTime = time
        confirmation.motionChanged(kind)
        if kind == .stationary, candidate == nil,
           [.recovery, .unknown, .moving].contains(state), let location = currentLocation,
           (0...120).contains(time.timeIntervalSince(location.timestamp)),
           makeObservation(location, source: .location).usableCoordinate != nil {
            checkLocation(.recovery, reason: "A change to stationary activity needs a fresh location check.")
        }
        if kind != .stationary && kind != .unknown {
            candidate = nil; settlingTask?.cancel(); settlingTask = nil
            readWiFi(force: true, fallback: .moving)
        }
    }
    private func transition(_ next: TrackingState, reason: String) {
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let level = device.batteryLevel
        let externalPower = externallyPowered
        let critical = level >= 0 && level <= 0.05 && !externalPower
        let resolved: TrackingState = critical && next != .paused ? .lowPowerFallback : next
        let policy = TrackingPolicy.sensors(state: resolved, motion: recentMotion, lowPower: lowPower, externalPower: externalPower)
        if externalPower { endRecovery() }
        live.desiredAccuracy = policy.desiredAccuracy
        live.distanceFilter = policy.distanceFilter
        live.pausesLocationUpdatesAutomatically = policy.pausesAutomatically
        let changed = resolved != state || policy.standardUpdates != standardActive || appliedExternalPower != externalPower
        appliedExternalPower = externalPower
        if policy.standardUpdates && !standardActive { live.startUpdatingLocation() }
        if !policy.standardUpdates && standardActive { live.stopUpdatingLocation() }
        standardActive = policy.standardUpdates
        energy.setStandardLocation(active: standardActive, uptime: ProcessInfo.processInfo.systemUptime)
        if changed {
            state = resolved
            recordEnergyCheckpoint(reason: reason)
        }
    }
    func energySnapshot() -> EnergySnapshot {
        var snapshot = energy.snapshot(uptime: ProcessInfo.processInfo.systemUptime)
        let level = device.batteryLevel
        snapshot.batteryLevel = level >= 0 ? Double(level) : nil
        switch device.batteryState {
        case .charging: snapshot.batteryState = "Charging"
        case .full: snapshot.batteryState = "Full"
        case .unplugged: snapshot.batteryState = "On battery"
        default: snapshot.batteryState = "Unavailable"
        }
        snapshot.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: snapshot.thermalState = "Normal"
        case .fair: snapshot.thermalState = "Warm"
        case .serious: snapshot.thermalState = "Hot"
        case .critical: snapshot.thermalState = "Critical"
        @unknown default: snapshot.thermalState = "Unknown"
        }
        snapshot.foreground = foreground
        return snapshot
    }
    func recordEnergyCheckpoint(reason: String = "Activity snapshot requested.") {
        var event = TrackingEvent(timestamp: now(), state: state, reason: reason,
            previousStateDuration: hasStarted ? now().timeIntervalSince(enteredState) : 0,
            standardLocationActive: standardActive,
            build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "development")
        event.energy = energySnapshot()
        enteredState = event.timestamp
        onEvent?(event)
    }

    func powerChanged() {
        recordEnergyCheckpoint(reason: "Battery or power state changed.")
        guard hasStarted else { return }
        if state == .lowPowerFallback {
            if externallyPowered { checkLocation(.recovery, reason: "External power enables detailed location recording.") }
            readWiFi(force: true, fallback: .recovery)
        } else {
            transition(state, reason: "The power policy changed.")
            if standardActive { beginRecoveryDeadline() }
        }
    }
    private func endRecovery() {
        recoveryTask?.cancel(); recoveryTask = nil
    }
    private func beginRecoveryDeadline() {
        // Repeated motion/Wi-Fi callbacks must not keep an unsuccessful search alive.
        guard !externallyPowered, recoveryTask == nil, settlingTask == nil else { return }
        recoveryTask = Task { [weak self, recoveryTimeout] in
            try? await Task.sleep(for: recoveryTimeout)
            guard !Task.isCancelled, let self else { return }
            self.recoveryTask = nil
            guard self.hasStarted, !self.externallyPowered,
                  [.recovery, .unknown, .moving, .stationaryCandidate].contains(self.state) else { return }
            self.transition(.lowPowerFallback, reason: "No recent usable fix; waiting for a low-power location event.")
        }
    }
    private func configureRegions() {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self), authorization == .authorizedAlways else { return }
        let sorted = places.filter { $0.area == nil }.sorted {
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
           !place.contains(coordinate, tolerance: min(100, location.horizontalAccuracy)) {
            invalidateWiFi()
        }
        evaluateEvidence(observation)
        readWiFi()
    }
    private func evaluateEvidence(_ observation: SensorObservation, connectedPlace: Place? = nil) {
        let place = connectedPlace ?? TrackingPolicy.matchingPlace(for: observation, places: places)
        let previousStart = confirmation.candidate?.first.timestamp
        let confirmed = confirmation.observe(observation, place: place, connectedPlace: connectedPlace, motion: recentMotion)
        if let confirmed, !confirmed.walking {
            candidate = nil; settlingTask?.cancel(); settlingTask = nil; endRecovery()
            transition(connectedPlace != nil ? .knownWiFi : place != nil ? .knownPlace : .stationaryUnknown,
                       reason: "Fresh evidence confirms at least three minutes with little movement.")
            if let location = currentLocation { monitorStop(location) }
            configureRegions()
        } else if let pending = confirmation.candidate, !pending.walking {
            if previousStart != pending.first.timestamp || state != .stationaryCandidate {
                beginStationaryCheck(at: currentLocation)
            }
        } else {
            candidate = nil; settlingTask?.cancel(); settlingTask = nil
            if VisitConfirmation.isMoving(recentMotion) || (observation.speed ?? -1) >= 0.8 {
                endRecovery()
            }
            transition(.moving, reason: confirmed?.walking == true
                ? "Recording the route while walking through a visited place."
                : "Movement or uncertain evidence does not establish a stop.")
            beginRecoveryDeadline()
        }
    }
    private func beginStationaryCheck(at location: CLLocation?) {
        candidate = location
        endRecovery()
        transition(.stationaryCandidate, reason: "Checking whether this is a meaningful stop.")
        settlingTask?.cancel()
        settlingTask = Task { [weak self, settlingDelay] in
            try? await Task.sleep(for: settlingDelay)
            guard !Task.isCancelled, let self else { return }
            self.settlingTask = nil
            guard self.hasStarted, self.state == .stationaryCandidate, !self.externallyPowered else { return }
            // Distance filtering can make a stationary sensor quiet. Request one
            // fresh fix before the bounded recovery timeout, never infer a stay from silence.
            self.live.stopUpdatingLocation(); self.standardActive = false
            self.energy.setStandardLocation(active: false, uptime: ProcessInfo.processInfo.systemUptime)
            self.energy.singleLocationRequests += 1
            self.live.requestLocation()
            self.readWiFi(force: true)
            self.beginRecoveryDeadline()
        }
    }
    private func makeObservation(_ location: CLLocation, source: ObservationSource) -> SensorObservation {
        SensorObservation(timestamp: location.timestamp, source: source,
            coordinate: Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude),
            horizontalAccuracy: location.horizontalAccuracy, speed: location.speed)
    }
    private func invalidateWiFi() {
        if confirmation.candidate?.first.source == .wifi { confirmation.reset() }
        wifiCheckID += 1; wifiCheckTask?.cancel(); wifiCheckTask = nil
        wifiFallback = nil; wifiPlaceID = nil
    }

    private func checkLocation(_ next: TrackingState, reason: String) {
        guard hasStarted else { return }
        candidate = nil; settlingTask?.cancel(); settlingTask = nil
        transition(next, reason: reason)
        beginRecoveryDeadline()
    }

    private func wifiUnavailable(fallback: TrackingState?) {
        let next = fallback ?? (wifiPlaceID == nil ? nil : .recovery)
        invalidateWiFi(); currentSSID = nil; currentBSSID = nil; currentWiFiObservation = nil
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
            invalidateWiFi(); currentSSID = nil; currentBSSID = nil; currentWiFiObservation = nil
            if let next = fallback ?? (wasTrusted ? .recovery : nil) {
                checkLocation(next, reason: "Wi-Fi information is unavailable; checking location.")
            }
            return
        }
        // Passive UI reads must not cancel a pending departure check.
        if wifiCheckTask != nil && fallback == nil { return }
        guard force || now().timeIntervalSince(lastWiFiRead) >= 60 else { return }
        let next = fallback ?? wifiFallback
        wifiCheckID += 1; wifiCheckTask?.cancel(); wifiFallback = next
        let request = wifiCheckID
        let started = ContinuousClock.now
        lastWiFiRead = now()
        let expectedGeneration = sensorGeneration
        wifiCheckTask = Task { [weak self, wifiTimeout] in
            try? await Task.sleep(for: wifiTimeout)
            guard !Task.isCancelled, let self, self.wifiCheckID == request,
                  self.sensorGeneration == expectedGeneration else { return }
            self.wifiUnavailable(fallback: next)
        }
        energy.wifiReads += 1
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
            let location = network == nil ? nil : self.currentLocation
            let observation = SensorObservation(timestamp: self.now(), source: .wifi,
                coordinate: location.map { Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) },
                coordinateTimestamp: location?.timestamp, horizontalAccuracy: location?.horizontalAccuracy,
                ssid: network?.ssid, bssid: network?.bssid)
            self.currentWiFiObservation = network == nil ? nil : observation
            guard self.hasStarted else { return }
            let place = self.departureNeedsFixAfter == nil ? TrackingPolicy.connectedPlace(for: observation,
                places: self.places, networks: self.networks, accessPoints: self.accessPoints) : nil
            let shouldRecord = self.wifiEvidence.shouldRecord(observation, placeID: place?.id)
            let confirmsPending = place != nil && self.confirmation.candidate?.confirmed == false
                && observation.timestamp.timeIntervalSince(self.confirmation.candidate!.first.timestamp) >= TrackingPolicy.stationaryDuration
            if shouldRecord || confirmsPending { self.onObservations?([observation]) }
            let wasTrusted = self.wifiPlaceID != nil
            self.wifiPlaceID = place?.id
            if let place {
                self.configureRegions()
                self.evaluateEvidence(observation, connectedPlace: place)
            } else if let next = next ?? (wasTrusted ? .recovery : nil) {
                self.checkLocation(next, reason: "Wi-Fi does not confirm this place; checking location.")
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let old = authorization, oldAccuracy = accuracy
        refreshAuthorization()
        if accuracy != .fullAccuracy || !canLocate { invalidateWiFi(); currentSSID = nil; currentBSSID = nil; currentWiFiObservation = nil }
        // Upgrading access does not interrupt recording and must not fabricate a
        // pause/recovery gap. Revocation and background foreground-only access
        // still go through stopAll via reconcile.
        if hasStarted, canLocate, oldAccuracy != accuracy {
            candidate = nil; confirmation.reset(); settlingTask?.cancel(); settlingTask = nil
            readWiFi(force: true, fallback: .recovery)
        }
        reconcile()
        if old == .authorizedAlways && authorization != .authorizedAlways && enabled {
            Task { await notifyPermissionProblem() }
        }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard hasStarted else { return }
        energy.locationCallbacks += 1
        let accepted = locations.filter { $0.horizontalAccuracy >= 0 && $0.timestamp <= now().addingTimeInterval(60) }
        energy.locationSamples += accepted.count
        onObservations?(accepted.map { makeObservation($0, source: manager === passive ? .significantChange : .location) })
        guard let latest = accepted.max(by: { $0.timestamp < $1.timestamp }), now().timeIntervalSince(latest.timestamp) <= 120 else { return }
        currentLocation = latest
        if makeObservation(latest, source: .location).usableCoordinate != nil, abs(now().timeIntervalSince(latest.timestamp)) <= 30,
           latest.horizontalAccuracy <= 50 || VisitConfirmation.isMoving(recentMotion) || latest.speed >= 0.8 {
            endRecovery()
        }
        evaluate(latest)
        // Pair already-delivered fixes with connected Wi-Fi, including unnamed areas.
        // This read is throttled and never asks for an additional GPS fix.
        readWiFi()
        if standardActive { beginRecoveryDeadline() }
    }
    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        guard hasStarted else { return }
        let coordinate = Coordinate(latitude: visit.coordinate.latitude, longitude: visit.coordinate.longitude)
        var observations: [SensorObservation] = []
        if visit.arrivalDate != .distantPast {
            var arrival = SensorObservation(timestamp: visit.arrivalDate, source: .visitArrival, coordinate: coordinate,
                horizontalAccuracy: visit.horizontalAccuracy, speed: 0)
            arrival.systemVisitDuration = max(0, (visit.departureDate == .distantFuture ? now() : visit.departureDate)
                .timeIntervalSince(visit.arrivalDate))
            observations.append(arrival)
        }
        if visit.departureDate != .distantFuture {
            observations.append(SensorObservation(timestamp: visit.departureDate, source: .visitDeparture, coordinate: coordinate,
                horizontalAccuracy: visit.horizontalAccuracy))
        }
        onObservations?(observations)
        if visit.departureDate != .distantFuture {
            invalidateWiFi(); confirmation.reset(); departureNeedsFixAfter = now()
            checkLocation(.recovery, reason: "A visit departure needs a fresh location check.")
        } else { readWiFi(force: true, fallback: .recovery) }
    }
    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) { regionChanged(region, entering: true) }
    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) { regionChanged(region, entering: false) }
    private func regionChanged(_ region: CLRegion, entering: Bool) {
        guard hasStarted else { return }
        // A queued circular callback can arrive after a place changes to an area.
        guard !places.contains(where: { $0.id == region.identifier && $0.area != nil }) else { return }
        onObservations?([SensorObservation(timestamp: now(), source: entering ? .regionEnter : .regionExit,
                                    monitoredPlaceID: region.identifier == "temporary-stop" ? nil : region.identifier)])
        if !entering {
            if let wifiPlaceID, region.identifier != wifiPlaceID { return }
            invalidateWiFi(); confirmation.reset(); departureNeedsFixAfter = now()
            checkLocation(.recovery, reason: "A monitored departure needs a fresh location check.")
        } else { readWiFi(force: true, fallback: .recovery) }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        LocalDiagnostics.shared.record(.locationFailed, error: error)
        if (error as? CLError)?.code == .denied { refreshAuthorization(); reconcile() }
        // Transient failures are represented by gaps and a bounded recovery window, not raw OS error logs.
    }
    func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        if hasStarted, externallyPowered {
            // An automatic pause from the previous battery policy may arrive after plugging in.
            standardActive = false
            energy.setStandardLocation(active: false, uptime: ProcessInfo.processInfo.systemUptime)
            transition(state, reason: "Resuming detailed location recording on external power.")
            return
        }
        guard hasStarted, state != .knownPlace, state != .knownWiFi, let location = currentLocation else { return }
        transition(.lowPowerFallback, reason: "iOS paused updates; waiting for fresh evidence of a stop."); monitorStop(location)
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
