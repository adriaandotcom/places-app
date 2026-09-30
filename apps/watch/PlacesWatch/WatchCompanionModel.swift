import CoreLocation
import Observation
import PlacesCompanion
import WatchConnectivity
import WatchKit
import WidgetKit
import Foundation

@MainActor @Observable final class WatchCompanionModel: NSObject, @preconcurrency CLLocationManagerDelegate, WCSessionDelegate {
    static let shared = WatchCompanionModel()
    private(set) var enabled = WatchStorage.defaults.bool(forKey: "enabled")
    private(set) var frequent = WatchStorage.frequent
    private(set) var status = "Enable Watch companions in Places on your iPhone."
    private(set) var queued = 0
    private(set) var lastRecorded = WatchStorage.lastRecorded
    private let location = CLLocationManager()
    private var started = false
    private var recording = false
    private var locationTask: Task<Void, Never>?
    private var serviceSession: CLServiceSession?
    private var backgroundSession: CLBackgroundActivitySession?
    private var collectionGeneration = 0
    private var connectivityTasks: [WKWatchConnectivityRefreshBackgroundTask] = []
    private var lastSavedFix: CLLocation?
    private var capturing = false
    private var pendingObservation: NSKeyValueObservation?
    private var flushing = false
    private nonisolated let connectivityWork = ConnectivityWork()

    func start() {
        guard !started else { return }; started = true
        location.delegate = self; location.desiredAccuracy = kCLLocationAccuracyHundredMeters
        location.distanceFilter = 100
        let session = WCSession.default; session.delegate = self; session.activate()
        pendingObservation = session.observe(\.hasContentPending, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.finishConnectivityIfReady() }
        }
        // Rejoin a previously user-enabled session after an OS-granted launch.
        // This does not promise watchOS will relaunch a terminated app.
        beginFrequentIfAllowed()
    }
    func setEnabled(_ value: Bool) {
        enabled = value; WatchStorage.enabled = value
        if value { location.requestWhenInUseAuthorization(); Task { await foreground() } }
        else { stop(); status = "Paused. Queued locations remain encrypted." }
        WidgetCenter.shared.reloadAllTimelines()
    }
    func setFrequent(_ value: Bool) {
        frequent = value; WatchStorage.frequent = value
        if !value { stop() }
        Task { await foreground() }
    }
    func foreground() async {
        guard enabled else { return }
        guard WatchStorage.enabled else { status = "Enable Watch companions in Places on your iPhone."; return }
        if frequent { beginFrequentIfAllowed() }
        else { await captureOne() }
        await flush()
        scheduleDelivery()
    }
    func backgroundOpportunity() async {
        // An OS-granted refresh, not a repeating GPS timer or a fabricated workout.
        if !recording { await captureOne() }
        await flush()
        scheduleDelivery()
    }
    private func scheduleDelivery() {
        guard WatchStorage.enabled else { return }
        // Preferred delivery time only: watchOS budgets these opportunities and may defer them.
        WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: Date().addingTimeInterval(1_800), userInfo: nil) { _ in }
    }
    private func beginFrequentIfAllowed() {
        guard enabled, WatchStorage.enabled, frequent, !recording else { return }
        guard WKApplication.shared().applicationState == .active
                || WatchStorage.defaults.bool(forKey: "frequentSessionActive") else { return }
        guard authorized else { status = "Allow location access in Watch Settings → Privacy → Location Services."; return }
        serviceSession = CLServiceSession(authorization: .whenInUse)
        backgroundSession = CLBackgroundActivitySession()
        WatchStorage.defaults.set(true, forKey: "frequentSessionActive")
        recording = true; lastSavedFix = nil; collectionGeneration += 1
        let epoch = collectionGeneration
        status = "Collecting in the background."
        locationTask = Task {
            do {
                // Core Location manages stationary pause and movement resume. The
                // default configuration does not pretend this is a workout.
                for try await update in CLLocationUpdate.liveUpdates() {
                    guard !Task.isCancelled, epoch == collectionGeneration, WatchStorage.enabled else { break }
                    if update.authorizationDenied || update.authorizationDeniedGlobally || update.authorizationRestricted {
                        status = "Allow location access in Watch Settings → Privacy → Location Services."
                        break
                    }
                    status = update.stationary ? "Resting while stationary. Collection resumes with movement."
                        : (update.insufficientlyInUse ? "Open Places to resume background collection." : "Collecting in the background.")
                    if let fix = update.location, fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= 250,
                       abs(fix.timestamp.timeIntervalSinceNow) <= 120,
                       shouldSave(fix, stationary: update.stationary) {
                        await save([fix])
                        guard epoch == collectionGeneration else { return }
                        lastSavedFix = fix
                        await flush()
                    }
                }
            } catch {
                if epoch == collectionGeneration { status = "Location is unavailable. Open Places to resume." }
            }
            if epoch == collectionGeneration { stop() }
        }
    }
    private func shouldSave(_ fix: CLLocation, stationary: Bool) -> Bool {
        guard let lastSavedFix else { return true }
        guard fix.timestamp > lastSavedFix.timestamp else { return false }
        return stationary || fix.distance(from: lastSavedFix) >= 100
            || fix.timestamp.timeIntervalSince(lastSavedFix.timestamp) >= 300
    }
    private var authorized: Bool {
        location.authorizationStatus == .authorizedAlways || location.authorizationStatus == .authorizedWhenInUse
    }
    private func stop() {
        collectionGeneration += 1
        locationTask?.cancel(); locationTask = nil
        backgroundSession?.invalidate(); backgroundSession = nil
        serviceSession?.invalidate(); serviceSession = nil
        WatchStorage.defaults.set(false, forKey: "frequentSessionActive")
        recording = false
    }
    private func captureOne() async {
        guard WatchStorage.enabled, !capturing else { return }
        capturing = true; defer { capturing = false }
        guard authorized else { status = "Allow location access in Watch Settings → Privacy → Location Services."; return }
        let request = WatchLocationSnapshot()
        if let fix = await request.capture() { await save([fix]) }
        status = "Automatic collection · watchOS controls availability."
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if !authorized { stop() }
        else if enabled { Task { await foreground() } }
    }
    private func save(_ locations: [CLLocation]) async {
        do {
            for fix in locations {
                try await WatchStorage.record(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude,
                    accuracy: fix.horizontalAccuracy, speed: fix.speed >= 0 ? fix.speed : nil, date: fix.timestamp)
            }
            lastRecorded = WatchStorage.lastRecorded
            WidgetCenter.shared.reloadAllTimelines()
        } catch { stop(); status = "Could not save locations. Free storage and try again." }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) { status = "Waiting for a location." }
    func flush() async {
        guard WatchStorage.enabled, !flushing, WCSession.default.activationState == .activated else { return }
        flushing = true; defer { flushing = false }
        do {
            guard let link = try WatchStorage.link() else { status = "Waiting for your iPhone connection."; return }
            let pending = try await WatchStorage.outbox().pending(); queued = pending.count
            let outstanding = Set(WCSession.default.outstandingUserInfoTransfers.compactMap { $0.userInfo["id"] as? String })
            let ready = pending.filter { $0.linkID == link.id && !outstanding.contains($0.id.uuidString) }
                .prefix(max(0, 50 - outstanding.count))
            for batch in ready {
                WCSession.default.transferUserInfo(["id": batch.id.uuidString,
                    "batch": try CompanionCipher.seal(batch, key: link.key)])
            }
        } catch { status = "Waiting to send encrypted locations. They are kept on this Watch." }
    }
    func connectivityTask(_ task: WKWatchConnectivityRefreshBackgroundTask) {
        connectivityTasks.append(task); finishConnectivityIfReady()
    }
    private func finishConnectivityIfReady() {
        guard connectivityWork.isEmpty, !WCSession.default.hasContentPending,
              WCSession.default.activationState == .activated else { return }
        let tasks = connectivityTasks; connectivityTasks = []
        for task in tasks { task.setTaskCompletedWithSnapshot(false) }
    }
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        let data = session.receivedApplicationContext["link"] as? Data
        let enabled = session.receivedApplicationContext["enabled"] as? Bool ?? false
        let reset = session.receivedApplicationContext["reset"] as? Bool ?? false
        handleConnectivity { await self.configure(data: data, enabled: enabled, reset: reset); await self.flush() }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        let data = context["link"] as? Data, enabled = context["enabled"] as? Bool ?? false, reset = context["reset"] as? Bool ?? false
        handleConnectivity { await self.configure(data: data, enabled: enabled, reset: reset) }
    }
    private func configure(data: Data?, enabled: Bool, reset: Bool) async {
        do {
            let keys = try WatchStorage.keys()
            if reset {
                let pendingLocation = locationTask
                WatchStorage.defaults.set(false, forKey: "phoneEnabled"); stop()
                await pendingLocation?.value
                try await WatchStorage.outbox().erase(); try keys.remove("watch-link")
            } else if let data {
                let link = try JSONDecoder().decode(WatchLink.self, from: data)
                guard link.key.count == 32 else { throw CompanionError.invalidPayload }
                if try WatchStorage.link()?.id != link.id {
                    let pendingLocation = locationTask
                    WatchStorage.defaults.set(false, forKey: "phoneEnabled"); stop()
                    await pendingLocation?.value
                    try await WatchStorage.outbox().erase(); try keys.remove("watch-link")
                    _ = try keys.createIfMissing("watch-link", value: data)
                }
                WatchStorage.defaults.set(enabled, forKey: "phoneEnabled")
                if !enabled { stop() }
            }
            WidgetCenter.shared.reloadAllTimelines()
            if enabled, WKApplication.shared().applicationState == .active { await foreground() }
        } catch { status = "Could not update the iPhone connection." }
    }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let ack = userInfo["ack"] as? String, let id = UUID(uuidString: ack), let link = userInfo["linkID"] as? String else { return }
        handleConnectivity {
            do {
                guard try WatchStorage.link()?.id.uuidString == link else { return }
                let outbox = try WatchStorage.outbox(); try await outbox.acknowledge(id)
                self.queued = try await outbox.pending().count
                await self.flush()
            } catch { self.status = "Could not save the delivery receipt. Locations remain queued." }
        }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        handleConnectivity { await self.flush() }
    }
    private nonisolated func handleConnectivity(_ action: @escaping @MainActor @Sendable () async -> Void) {
        connectivityWork.begin()
        Task { @MainActor in
            await action()
            self.connectivityWork.end()
            self.finishConnectivityIfReady()
        }
    }
}

// WCSession invokes delegates off the main actor. Count work before hopping so
// watchOS cannot suspend the app before a settings/receipt write has finished.
private final class ConnectivityWork: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var isEmpty: Bool { lock.withLock { count == 0 } }
    func begin() { lock.withLock { count += 1 } }
    func end() { lock.withLock { count -= 1 } }
}
