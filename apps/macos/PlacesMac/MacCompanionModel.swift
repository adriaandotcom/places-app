import AppKit
import CoreLocation
import CloudKit
import Observation
import PlacesCompanion
import Network

@MainActor @Observable final class MacCompanionModel: NSObject, @preconcurrency CLLocationManagerDelegate {
    private(set) var enabled = UserDefaults.standard.bool(forKey: "companionEnabled")
    private(set) var status = "Paused. Enable collection when you’re ready."
    private(set) var syncing = false
    private(set) var queued = 0
    private(set) var lastUploaded: Date?
    private let location = CLLocationManager()
    private var cloud: CloudInbox?
    private var outbox: CompanionOutbox?
    private var deviceID: UUID?
    private var link: CompanionLink?
    private var timer: Timer?
    private var awake = true
    private var sessionActive = true
    private var collecting = false
    private var started = false
    private var generation = 0
    private var network: NWPathMonitor?
    private var lastActive = false
    private var resting = false
    private var anchor: CLLocation?
    private var recordingStarted: Date?
    private var saving: Task<Void, Never>?
    private var storageFailed = false
    private var syncFailure: String?
    private var deletingQueue = false
    private let keys = CompanionKeychain()

    override init() {
        super.init(); start()
        if enabled { Task { await sync() } }
    }

    func start() {
        guard !started else { return }; started = true
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyHundredMeters
        location.distanceFilter = 100
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            center.addObserver(self, selector: #selector(sleep), name: name, object: nil)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            center.addObserver(self, selector: #selector(wake), name: name, object: nil)
        }
        center.addObserver(self, selector: #selector(resignSession), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(activateSession), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(accountChanged), name: .CKAccountChanged, object: nil)
        // This checks aggregate idle time, never input contents, and does not poll GPS.
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateCollection() }
        }
        if enabled { prepare() }
    }
    func setEnabled(_ value: Bool) {
        syncFailure = nil
        generation += 1; enabled = value; UserDefaults.standard.set(value, forKey: "companionEnabled")
        if value { storageFailed = false; prepare(); location.requestWhenInUseAuthorization(); Task { await sync() } }
        else { cloud = nil; link = nil; network?.cancel(); network = nil; updateCollection(); status = "Paused. Queued records stay encrypted on this Mac." }
    }
    private func prepare() {
        do {
            deviceID = try CompanionIdentity.deviceID()
            outbox = try CompanionIdentity.outbox()
            if let data = try keys.read("mac-link") { link = try JSONDecoder().decode(CompanionLink.self, from: data) }
            guard let group = Bundle.main.object(forInfoDictionaryKey: "CompanionKeychainGroup") as? String,
                  !group.contains("$(") else { throw CompanionError.notLinked }
            cloud = try CloudInbox(consented: enabled, keychainGroup: group)
            if network == nil {
                let monitor = NWPathMonitor(); network = monitor
                monitor.pathUpdateHandler = { [weak self] path in
                    if path.status == .satisfied { Task { @MainActor in await self?.sync() } }
                }
                monitor.start(queue: DispatchQueue(label: "Places.connection-availability"))
            }
        } catch { status = CompanionIdentity.message(for: error) }
        updateCollection()
    }
    func sync() async {
        guard enabled, !syncing else { return }
        if cloud == nil { prepare() }
        guard let cloud, let outbox else { return }
        syncing = true; defer { syncing = false; updateCollection() }
        let epoch = generation
        do {
            queued = try await outbox.pending().count
            let currentLink = try await cloud.link()
            guard enabled, epoch == generation else { return }
            link = currentLink
            try keys.storeState("mac-link", value: JSONEncoder().encode(currentLink))
            let pending = try await outbox.pending(); queued = pending.count
            for batch in pending {
                guard enabled, epoch == generation else { return }
                // A reset/re-pair must never import records from the previous connection.
                guard batch.linkID == currentLink.id else {
                    status = "Your iPhone connection changed. Old queued locations remain on this Mac."
                    continue
                }
                try await cloud.upload(batch)
                try await outbox.acknowledge(batch.id)
                lastUploaded = Date()
            }
            queued = try await outbox.pending().count
            syncFailure = nil
        } catch {
            let remaining = try? await outbox.pending().count
            guard epoch == generation else { return }
            if let remaining { queued = remaining }
            if error is CompanionError || (error as? CKError)?.code == .zoneNotFound || (error as? CKError)?.code == .unknownItem {
                link = nil; try? keys.remove("mac-link")
            }
            let message = CompanionIdentity.message(for: error)
            syncFailure = message; status = message
        }
    }
    private func updateCollection() {
        guard enabled else {
            location.stopUpdatingLocation(); location.stopMonitoringSignificantLocationChanges()
            collecting = false; return
        }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                           eventType: CGEventType(rawValue: ~UInt32(0))!)
        let authorized = location.authorizationStatus == .authorizedAlways
        let active = awake && sessionActive && idle < 120
            && NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.loginwindow"
        if active != lastActive { resting = false; anchor = nil; recordingStarted = nil; lastActive = active }
        // A distance filter can suppress stationary callbacks. End the burst even if
        // no new fix arrives; significant changes or renewed use can resume it.
        if let lastMovement = anchor?.timestamp ?? recordingStarted,
           Date().timeIntervalSince(lastMovement) >= 300 { resting = true }
        let shouldCollect = authorized && active && link != nil && !resting && !storageFailed && !deletingQueue
        if shouldCollect != collecting {
            collecting = shouldCollect
            if shouldCollect { recordingStarted = Date(); location.startUpdatingLocation() }
            else { recordingStarted = nil; location.stopUpdatingLocation() }
        }
        if active && authorized && link != nil && !storageFailed && !deletingQueue {
            if CLLocationManager.significantLocationChangeMonitoringAvailable() { location.startMonitoringSignificantLocationChanges() }
        } else {
            location.stopMonitoringSignificantLocationChanges()
        }
        if storageFailed { status = "Collection paused: queued locations could not be saved. Free storage, then re-enable collection." }
        else if let syncFailure { status = syncFailure }
        else if enabled, authorized, link != nil {
            status = active ? (resting ? "Resting at this location. Movement can resume collection." : "Collecting while you use this Mac.") : "Paused while this Mac is idle or asleep."
        } else if enabled && !authorized { status = "Allow location access in System Settings → Privacy & Security → Location Services." }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { updateCollection() }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        updateCollection()
        guard enabled, lastActive, !storageFailed, !deletingQueue, let deviceID, let link, let outbox else { return }
        if let fix = locations.last, fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= 100 {
            if let anchor, fix.distance(from: anchor) < 100 {
                if fix.timestamp.timeIntervalSince(anchor.timestamp) >= 300 { resting = true; updateCollection() }
            } else { anchor = fix; resting = false; updateCollection() }
        }
        let values = locations.filter { abs($0.timestamp.timeIntervalSinceNow) <= 120 }.map {
            CompanionSample(deviceID: deviceID, kind: .mac, timestamp: $0.timestamp,
                latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude,
                accuracy: $0.horizontalAccuracy, speed: $0.speed >= 0 ? $0.speed : nil)
        }.filter { $0.isValid() }
        guard !values.isEmpty else { return }
        let previous = saving, epoch = generation
        saving = Task {
            await previous?.value
            guard enabled, epoch == generation, !deletingQueue else { return }
            do {
                for value in values { try await outbox.append(CompanionBatch(linkID: link.id, samples: [value])) }
                queued = try await outbox.pending().count
                await sync()
            } catch { storageFailed = true; updateCollection() }
        }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        status = "Location is unavailable. Check Location Services and Wi-Fi."
    }
    @objc private func sleep() { awake = false; updateCollection() }
    @objc private func wake() { awake = true; updateCollection(); if enabled { Task { await sync() } } }
    @objc private func resignSession() { sessionActive = false; updateCollection() }
    @objc private func activateSession() { sessionActive = true; wake() }
    @objc private func accountChanged() {
        generation += 1; link = nil; try? keys.remove("mac-link"); updateCollection()
        if enabled { Task { await sync() } }
    }
    func deleteQueued() async {
        guard let outbox else { return }
        generation += 1; deletingQueue = true; updateCollection()
        await saving?.value
        defer { deletingQueue = false; updateCollection() }
        do { try await outbox.erase(); queued = 0 }
        catch { status = "Queued locations could not be deleted. Please try again." }
    }
}
