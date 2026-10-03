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
    private(set) var lastSynced = WatchStorage.lastSynced
    private(set) var lastRecorded = WatchStorage.lastRecorded
    private let location = CLLocationManager()
    private let connection = WatchConnectionMonitor()
    private var started = false
    private var recording = false
    private var locationTask: Task<Void, Never>?
    private var serviceSession: CLServiceSession?
    private var backgroundSession: CLBackgroundActivitySession?
    private var collectionGeneration = 0
    private var connectivityTasks: [WKWatchConnectivityRefreshBackgroundTask] = []
    private var lastSavedFix: CLLocation?
    private var capturing = false
    private var snapshot: WatchLocationSnapshot?
    private var pendingObservation: NSKeyValueObservation?
    private var flushTask: Task<Void, Never>?
    private var flushRequested = false
    private nonisolated let connectivityWork = ConnectivityWork()

    func start() {
        guard !started else { return }; started = true
        location.delegate = self; location.desiredAccuracy = kCLLocationAccuracyHundredMeters
        location.distanceFilter = 100
        connection.onChange = { [weak self] in self?.connectionChanged() }
        connection.start()
        let session = WCSession.default; session.delegate = self; session.activate()
        pendingObservation = session.observe(\.hasContentPending, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.finishConnectivityIfReady() }
        }
        // Rejoin a previously user-enabled session after an OS-granted launch.
        // This does not promise watchOS will relaunch a terminated app.
        reconcileCollection()
    }
    func setEnabled(_ value: Bool) {
        enabled = value; WatchStorage.enabled = value
        if value { location.requestWhenInUseAuthorization(); Task { await foreground() } }
        else { stop(); status = "Collection paused. Saved locations sync automatically."; Task { await flush() } }
        WidgetCenter.shared.reloadAllTimelines()
    }
    func setFrequent(_ value: Bool) {
        frequent = value; WatchStorage.frequent = value
        if !value { stop() }
        Task { await foreground() }
    }
    func foreground() async {
        noteReachablePhone()
        reconcileCollection()
        if !frequent { await captureOne() }
        await flush()
        scheduleDelivery()
    }
    func backgroundOpportunity() async {
        // An OS-granted refresh, not a repeating GPS timer or a fabricated workout.
        noteReachablePhone()
        reconcileCollection()
        if !recording { await captureOne() }
        await flush()
        scheduleDelivery()
    }
    private func scheduleDelivery() {
        guard WatchStorage.deliveryEnabled else { return }
        // Preferred delivery time only: watchOS budgets these opportunities and may defer them.
        WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: Date().addingTimeInterval(1_800), userInfo: nil) { _ in }
    }
    private func beginFrequentIfAllowed() {
        guard collectionDecision == .collect, frequent, !recording else { return }
        guard WKApplication.shared().applicationState == .active
                || WatchStorage.defaults.bool(forKey: "frequentSessionActive") else {
            status = "Collects when watchOS allows. Open Places for more frequent updates away from your iPhone and Wi-Fi."
            return
        }
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
                    guard !Task.isCancelled, epoch == collectionGeneration, collectionDecision == .collect else { break }
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
        snapshot?.cancel(); snapshot = nil
        WatchStorage.defaults.set(false, forKey: "frequentSessionActive")
        recording = false
    }
    private func captureOne() async {
        guard collectionDecision == .collect, !capturing else { return }
        capturing = true; defer { capturing = false }
        guard authorized else { status = "Allow location access in Watch Settings → Privacy → Location Services."; return }
        let request = WatchLocationSnapshot()
        snapshot = request
        if let fix = await request.capture(), collectionDecision == .collect { await save([fix]) }
        if snapshot === request { snapshot = nil }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if !authorized { stop() }
        else if enabled { Task { await foreground() } }
    }
    private func save(_ locations: [CLLocation]) async {
        do {
            for fix in locations {
                guard collectionDecision == .collect else { return }
                try await WatchStorage.record(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude,
                    accuracy: fix.horizontalAccuracy, speed: fix.speed >= 0 ? fix.speed : nil, date: fix.timestamp)
            }
            lastRecorded = WatchStorage.lastRecorded
            WidgetCenter.shared.reloadAllTimelines()
        } catch { stop(); status = "Could not save locations. Free storage and try again." }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) { status = "Waiting for a location." }

    private var collectionDecision: WatchCollectionPolicy.Decision {
        guard WatchStorage.enabled else { return .disabled }
        guard WCSession.default.activationState == .activated else { return .checkingConnection }
        return connection.decision(phoneReachable: WCSession.default.isReachable)
    }
    private func noteReachablePhone() {
        if WCSession.default.activationState == .activated, WCSession.default.isReachable {
            WatchStorage.defaults.set(Date(), forKey: "lastPhoneContact")
        }
    }
    private func connectionChanged() {
        noteReachablePhone()
        reconcileCollection()
        if collectionDecision == .collect, !frequent, WKApplication.shared().applicationState == .active {
            Task { await captureOne(); await flush() }
        }
    }
    private func reconcileCollection() {
        switch collectionDecision {
        case .disabled:
            stop()
            status = enabled ? "Enable Watch companions in Places on your iPhone." : "Collection paused. Saved locations sync automatically."
        case .checkingConnection:
            // No GPS starts while the initial route / session state is unknown.
            if recording || capturing { stop() }
            status = "Checking the iPhone and Wi-Fi connection…"
        case .phoneAvailable:
            stop()
            status = WCSession.default.isReachable ? "Resting while your iPhone is available."
                : "Resting after a recent iPhone connection."
        case .wifiAvailable:
            stop(); status = "Resting on Wi-Fi. No location updates."
        case .collect:
            if frequent { beginFrequentIfAllowed() }
            else { status = "Collects when watchOS allows, away from your iPhone and Wi-Fi." }
        }
    }

    func flush() async {
        guard WatchStorage.deliveryEnabled, WCSession.default.activationState == .activated else { return }
        if let flushTask { flushRequested = true; await flushTask.value; return }
        flushRequested = false
        let task = Task { await self.flushOutbox() }
        flushTask = task
        await task.value
        flushTask = nil
        // An OS-granted caller must join existing delivery before completing its
        // background task. Also catch a new request arriving as that task finishes.
        if flushRequested { await flush() }
        finishConnectivityIfReady()
    }
    private func flushOutbox() async {
        do {
            guard let link = try WatchStorage.link() else { return }
            let outbox = try WatchStorage.outbox()
            repeat {
                flushRequested = false
                var pending = try await outbox.pending().filter { $0.linkID == link.id }
                // Retry outstanding background packets too. A lost/delayed receipt
                // must not strand already imported data; the phone deduplicates IDs.
                while !pending.isEmpty, WCSession.default.isReachable, deliveryAllowed(link) {
                    let payloads = try WatchDelivery.payloads(from: pending, link: link)
                    guard !payloads.isEmpty else { break }
                    guard let receipt = await sendLive(payloads), deliveryAllowed(link),
                          receipt.linkID == link.id,
                          receipt.batchIDs == Array(pending.prefix(payloads.count)).map(\.id) else { break }
                    WatchStorage.defaults.set(Date(), forKey: "lastPhoneContact")
                    reconcileCollection()
                    try await acknowledge(receipt)
                    pending.removeFirst(payloads.count)
                }
                guard deliveryAllowed(link) else { return }
                let outstanding = Set(WCSession.default.outstandingUserInfoTransfers.compactMap { $0.userInfo["id"] as? String })
                for batch in pending.filter({ !outstanding.contains($0.id.uuidString) }).prefix(max(0, 50 - outstanding.count)) {
                    WCSession.default.transferUserInfo(["id": batch.id.uuidString,
                        "batch": try CompanionCipher.seal(batch, key: link.key)])
                }
            } while flushRequested && deliveryAllowed(link)
        } catch { status = "Waiting to send encrypted locations. They are kept on this Watch." }
    }
    private func deliveryAllowed(_ link: WatchLink) -> Bool {
        WatchStorage.deliveryEnabled && (try? WatchStorage.link()?.id) == link.id
    }
    private func sendLive(_ payloads: [Data]) async -> WatchDelivery.Receipt? {
        await withCheckedContinuation { continuation in
            WCSession.default.sendMessage(["batches": payloads], replyHandler: { reply in
                let receipt = (reply["receipt"] as? Data).flatMap { try? JSONDecoder().decode(WatchDelivery.Receipt.self, from: $0) }
                continuation.resume(returning: receipt)
            }, errorHandler: { _ in continuation.resume(returning: nil) })
        }
    }
    private func acknowledge(_ receipt: WatchDelivery.Receipt) async throws {
        guard let link = try WatchStorage.link() else { return }
        try await WatchDelivery.acknowledge(receipt, linkID: link.id, outbox: WatchStorage.outbox())
        guard try WatchStorage.link()?.id == receipt.linkID else { return }
        let ids = Set(receipt.batchIDs.map(\.uuidString))
        for transfer in WCSession.default.outstandingUserInfoTransfers {
            if let id = transfer.userInfo["id"] as? String, ids.contains(id) { transfer.cancel() }
        }
        lastSynced = Date(); WatchStorage.defaults.set(lastSynced, forKey: "lastSynced")
    }
    func connectivityTask(_ task: WKWatchConnectivityRefreshBackgroundTask) {
        connectivityTasks.append(task); finishConnectivityIfReady()
    }
    private func finishConnectivityIfReady() {
        guard connectivityWork.isEmpty, flushTask == nil, !WCSession.default.hasContentPending,
              WCSession.default.activationState == .activated else { return }
        let tasks = connectivityTasks; connectivityTasks = []
        for task in tasks { task.setTaskCompletedWithSnapshot(false) }
    }
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        let data = session.receivedApplicationContext["link"] as? Data
        let enabled = session.receivedApplicationContext["enabled"] as? Bool ?? false
        let reset = session.receivedApplicationContext["reset"] as? Bool ?? false
        handleConnectivity { await self.configure(data: data, enabled: enabled, reset: reset) }
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
                clearConnectionHistory()
            } else if let data {
                let link = try JSONDecoder().decode(WatchLink.self, from: data)
                guard link.key.count == 32 else { throw CompanionError.invalidPayload }
                if try WatchStorage.link()?.id != link.id {
                    let pendingLocation = locationTask
                    WatchStorage.defaults.set(false, forKey: "phoneEnabled"); stop()
                    await pendingLocation?.value
                    try await WatchStorage.outbox().erase(); try keys.remove("watch-link")
                    clearConnectionHistory()
                    _ = try keys.createIfMissing("watch-link", value: data)
                }
                WatchStorage.defaults.set(enabled, forKey: "phoneEnabled")
                if !enabled { stop() }
            }
            WidgetCenter.shared.reloadAllTimelines()
            noteReachablePhone(); reconcileCollection()
            await flush()
        } catch { status = "Could not update the iPhone connection." }
    }
    private func clearConnectionHistory() {
        for key in ["lastSynced", "lastPhoneContact", "lastRecorded"] { WatchStorage.defaults.removeObject(forKey: key) }
        lastSynced = nil; lastRecorded = nil
    }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let ack = userInfo["ack"] as? String, let id = UUID(uuidString: ack), let link = userInfo["linkID"] as? String else { return }
        handleConnectivity {
            do {
                guard let linkID = UUID(uuidString: link) else { return }
                try await self.acknowledge(.init(linkID: linkID, batchIDs: [id]))
                await self.flush()
            } catch { self.status = "Could not save the delivery receipt. Locations remain queued." }
        }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        handleConnectivity { self.noteReachablePhone(); self.reconcileCollection(); await self.flush() }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let syncLink = message["syncLink"] as? String
        let receiptData = message["receipt"] as? Data
        let reply = WatchMessageReply(replyHandler)
        handleConnectivity {
            WatchStorage.defaults.set(Date(), forKey: "lastPhoneContact")
            self.reconcileCollection()
            if let receiptData, let receipt = try? JSONDecoder().decode(WatchDelivery.Receipt.self, from: receiptData) {
                try? await self.acknowledge(receipt)
            }
            let valid = (try? WatchStorage.link()?.id.uuidString) == syncLink && syncLink != nil
            if valid || receiptData != nil { await self.flush() }
            // Finish the request only after delivery; replying early can surrender
            // its background execution opportunity before the outbox is drained.
            reply.send()
        }
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
