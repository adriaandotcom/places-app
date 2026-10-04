import Foundation
import Observation
import PlacesCore
import PlacesCompanion
import WatchConnectivity
import UIKit

@MainActor @Observable final class PhoneCompanions: NSObject, WCSessionDelegate {
    private(set) var macEnabled = UserDefaults.standard.bool(forKey: "macCompanionEnabled")
    private(set) var watchEnabled = UserDefaults.standard.bool(forKey: "watchCompanionEnabled")
    private(set) var status = "Companions are optional. Your iPhone remains the main recorder."
    private(set) var lastReceived: Date?
    private(set) var lastWatchReceived = UserDefaults.standard.object(forKey: "lastWatchReceived") as? Date
    private(set) var syncing = false
    private(set) var configuring = false
    private var cloud: CloudInbox?
    private var receiverID: UUID?
    private var watchLink: WatchLink?
    private var importBatch: (@MainActor (CompanionBatch) async throws -> Void)?
    private let keys = CompanionKeychain()
    private var generation = 0
    private var deliveryTask: Task<Void, Never>?

    func start(importBatch: @escaping @MainActor (CompanionBatch) async throws -> Void) {
        self.importBatch = importBatch
        do {
            receiverID = try CompanionIdentity.deviceID()
            if let data = try keys.read("watch-link") { watchLink = try JSONDecoder().decode(WatchLink.self, from: data) }
            if watchEnabled { activateWatch() }
            if macEnabled {
                prepareCloud(); UIApplication.shared.registerForRemoteNotifications()
                Task { await sync() }
            }
        } catch { status = "Companion storage is unavailable. Unlock your iPhone and try again." }
    }
    func setMacEnabled(_ value: Bool) async {
        guard !configuring else { return }
        configuring = true; defer { configuring = false }
        generation += 1
        if !value {
            macEnabled = false; UserDefaults.standard.set(false, forKey: "macCompanionEnabled")
            UIApplication.shared.unregisterForRemoteNotifications()
            do {
                if let cloud, let receiverID { try await cloud.setReceiverEnabled(false, receiverID: receiverID) }
                status = "Mac collection is paused."
            } catch { status = "Reception is paused here. Reconnect and turn Mac collection off again to also pause remote uploads." }
            return
        }
        macEnabled = true; UserDefaults.standard.set(true, forKey: "macCompanionEnabled")
        prepareCloud()
        do {
            guard let cloud, let receiverID else { throw CompanionError.notLinked }
            // Setup can reach CloudKit before a subscription/network failure. Remember
            // the attempted inbox so reset also cleans up partially completed setup.
            UserDefaults.standard.set(true, forKey: "macCompanionConfigured")
            _ = try await cloud.enableReceiver(receiverID)
            UIApplication.shared.registerForRemoteNotifications()
            status = "Ready for your Mac. Enable collection in the Mac menu bar."
            await sync()
        } catch { status = CompanionIdentity.message(for: error) }
    }
    private func prepareCloud() {
        guard macEnabled else { return }
        do {
            guard let group = Bundle.main.object(forInfoDictionaryKey: "CompanionKeychainGroup") as? String,
                  !group.contains("$(") else { throw CompanionError.notLinked }
            cloud = try CloudInbox(consented: true, keychainGroup: group)
        } catch { status = CompanionIdentity.message(for: error) }
    }
    func setWatchEnabled(_ value: Bool) {
        generation += 1
        do {
            if value, watchLink == nil {
                let bytes = try keys.createIfMissing("watch-link", value: JSONEncoder().encode(WatchLink()))
                watchLink = try JSONDecoder().decode(WatchLink.self, from: bytes)
            }
            watchEnabled = value; UserDefaults.standard.set(value, forKey: "watchCompanionEnabled")
            activateWatch(); requestWatchSync()
            status = value ? "Open Places on your Watch once to allow location access." : "Watch reception is paused."
        } catch { status = "Could not prepare the Watch connection. Please try again." }
    }
    func sync() async {
        // Foreground refresh also requests the Watch outbox, independently of Mac / iCloud.
        requestWatchSync()
        // A silent-push handler must await an in-flight import too, so returning
        // from the handler cannot suspend the app before its durable commit.
        if let deliveryTask { await deliveryTask.value; return }
        guard macEnabled else { return }
        let task = Task { await self.syncInbox() }
        deliveryTask = task
        await task.value
        deliveryTask = nil
    }
    private func syncInbox() async {
        guard macEnabled, !syncing, let cloud, let receiverID, let importBatch else { return }
        syncing = true; defer { syncing = false }
        let epoch = generation
        do {
            let batches = try await cloud.pending(receiverID: receiverID)
            for batch in batches {
                guard macEnabled, generation == epoch else { return }
                try await importBatch(batch)
                guard macEnabled, generation == epoch else { return }
                try await cloud.acknowledge(batch, receiverID: receiverID)
                lastReceived = Date()
            }
            if !batches.isEmpty { status = "Your Mac observations are saved on this iPhone." }
        } catch { if generation == epoch { LocalDiagnostics.shared.record(.companionFailed, error: error); status = CompanionIdentity.message(for: error) } }
    }
    /// Pause locally without deleting the previous phone's cloud inbox or keys.
    /// Pairing secrets never travel in an ordinary, human-readable backup.
    func pauseAfterRestore() {
        generation += 1; deliveryTask?.cancel()
        macEnabled = false; watchEnabled = false; lastReceived = nil
        lastWatchReceived = nil; UserDefaults.standard.removeObject(forKey: "lastWatchReceived")
        UserDefaults.standard.set(false, forKey: "macCompanionEnabled")
        UserDefaults.standard.set(false, forKey: "watchCompanionEnabled")
        UIApplication.shared.unregisterForRemoteNotifications()
        if WCSession.isSupported(), WCSession.default.activationState == .activated { sendWatchConfiguration() }
        status = "Companions are paused after restoring. Enable them again when you’re ready."
    }

    func erase() async throws {
        generation += 1
        if cloud == nil, UserDefaults.standard.bool(forKey: "macCompanionConfigured") {
            // Erase is an explicit request to remove the previously enabled delivery inbox too.
            guard let group = Bundle.main.object(forInfoDictionaryKey: "CompanionKeychainGroup") as? String else { throw CompanionError.notLinked }
            cloud = try CloudInbox(consented: true, keychainGroup: group)
        }
        // Cloud delivery is revoked before erasing history, preventing delayed re-import.
        if let cloud, let receiverID { try await cloud.erase(receiverID: receiverID) }
        else if macEnabled { throw CompanionError.notLinked }
        macEnabled = false; watchEnabled = false
        lastWatchReceived = nil; UserDefaults.standard.removeObject(forKey: "lastWatchReceived")
        UIApplication.shared.unregisterForRemoteNotifications()
        UserDefaults.standard.removeObject(forKey: "macCompanionEnabled")
        UserDefaults.standard.removeObject(forKey: "watchCompanionEnabled")
        UserDefaults.standard.removeObject(forKey: "macCompanionConfigured")
        if WCSession.isSupported() {
            activateWatch()
            if WCSession.default.activationState == .activated {
                try WCSession.default.updateApplicationContext(["enabled": false, "reset": true])
            }
        }
        try keys.remove("watch-link"); watchLink = nil; cloud = nil; lastReceived = nil
    }
    private func activateWatch() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default; session.delegate = self; session.activate()
    }
    private func sendWatchConfiguration(requestSync: Bool = false) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        do {
            var context: [String: Any] = ["enabled": watchEnabled, "reset": watchLink == nil]
            if let watchLink { context["link"] = try JSONEncoder().encode(watchLink) }
            // Latest intent may replace an older request; observations never travel
            // in applicationContext, where replacement would lose undelivered data.
            if requestSync { context["syncRequest"] = UUID().uuidString }
            try WCSession.default.updateApplicationContext(context)
        } catch { status = "Waiting to deliver settings to your Watch." }
    }
    private func requestWatchSync() {
        guard WCSession.isSupported() else { return }
        guard WCSession.default.activationState == .activated else {
            if watchEnabled { activateWatch() }
            return
        }
        sendWatchConfiguration(requestSync: watchEnabled)
        guard watchEnabled, let watchLink, WCSession.default.isReachable else { return }
        // The persisted context still requests delivery if the live hint fails.
        WCSession.default.sendMessage(["syncLink": watchLink.id.uuidString],
            replyHandler: WatchMessageCallbacks.ignored.reply, errorHandler: WatchMessageCallbacks.ignored.error)
    }
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        Task { @MainActor in self.requestWatchSync() }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in if reachable { self.requestWatchSync() } }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) { }
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let payload = userInfo["batch"] as? Data else { return }
        Task { @MainActor in
            await self.receiveWatch([payload]) { receipt in
                guard let receipt else { return }
                // Preserve background delivery and compatibility with older Watch builds.
                for id in receipt.batchIDs {
                    WCSession.default.transferUserInfo(["ack": id.uuidString, "linkID": receipt.linkID.uuidString])
                }
                if WCSession.default.isReachable, let data = try? JSONEncoder().encode(receipt) {
                    WCSession.default.sendMessage(["receipt": data],
                        replyHandler: WatchMessageCallbacks.ignored.reply, errorHandler: WatchMessageCallbacks.ignored.error)
                }
            }
        }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard let payloads = message["batches"] as? [Data] else { replyHandler([:]); return }
        let reply = WatchMessageReply(replyHandler)
        Task { @MainActor in
            await self.receiveWatch(payloads) { receipt in
                reply.send(receipt: receipt.flatMap { try? JSONEncoder().encode($0) })
            }
        }
    }
    private func receiveWatch(_ payloads: [Data], deliverReceipt: (WatchDelivery.Receipt?) -> Void) async {
        guard watchEnabled, let link = watchLink, let importBatch else { deliverReceipt(nil); return }
        let background = UIApplication.shared.beginBackgroundTask(withName: "Save companion observations")
        // Keep the background allowance through the receipt, not just the database write.
        defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
        let epoch = generation
        do {
            let receipt = try await WatchDelivery.receive(payloads, link: link, isEnabled: {
                self.watchEnabled && self.generation == epoch && self.watchLink?.id == link.id
            }, persist: importBatch)
            lastReceived = Date(); lastWatchReceived = lastReceived
            UserDefaults.standard.set(lastWatchReceived, forKey: "lastWatchReceived")
            status = "Your Watch observations are saved on this iPhone."
            deliverReceipt(receipt)
            return
        } catch { LocalDiagnostics.shared.record(.watchDeliveryFailed, error: error); status = "Watch observations could not be saved yet. They remain queued on your Watch." }
        deliverReceipt(nil)
    }
}
