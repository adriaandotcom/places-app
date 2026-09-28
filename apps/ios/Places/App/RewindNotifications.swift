import Foundation
import UserNotifications
import PlacesCore

struct RewindRequest: Identifiable, Sendable {
    let id = UUID()
    var month: Date
    var reviewWeek = false
    static func notification(kind: String, period: Double) -> Self? {
        guard let kind = RewindReminder.Kind(rawValue: kind) else { return nil }
        let start = Date(timeIntervalSince1970: period)
        // A monthly notification can be opened after travelling west. An anchor
        // inside the month keeps local midnight from becoming the prior month.
        let anchor = kind == .monthly ? start.addingTimeInterval(14 * 24 * 3600) : start
        return Self(month: anchor, reviewWeek: kind == .weekly)
    }
}

@MainActor final class RewindNotifications: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((RewindRequest) -> Void)?
    private var pending: Task<Void, Never>?
    static let identifiers = ["places-rewind-monthly", "places-rewind-weekly"]

    func update(_ plans: [RewindReminder]) {
        // Serialize replacements with reset/disable so an in-flight add cannot
        // put a notification back after the user's opt-out.
        let previous = pending
        pending = Task {
            await previous?.value
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            let allowed = [.authorized, .provisional].contains(settings.authorizationStatus)
            let active = allowed ? plans : []
            let wanted = Set(active.map { "places-rewind-\($0.kind.rawValue)" })
            let removed = Self.identifiers.filter { !wanted.contains($0) }
            center.removePendingNotificationRequests(withIdentifiers: removed)
            center.removeDeliveredNotifications(withIdentifiers: removed)
            let existing = await center.pendingNotificationRequests()
            for plan in active {
                let id = "places-rewind-\(plan.kind.rawValue)"
                let components = Calendar.current.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute], from: plan.fireAt)
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                if let old = existing.first(where: { $0.identifier == id }),
                   (old.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() == trigger.nextTriggerDate(),
                   old.content.userInfo["period"] as? Double == plan.periodStart.timeIntervalSince1970 { continue }
                let content = UNMutableNotificationContent()
                content.title = plan.kind == .monthly ? "Your monthly rewind is ready" : "A little timeline catch-up?"
                content.body = plan.kind == .monthly ? "Revisit your month, fill in a few details, and see your highlights." : "There are unnamed places in your recent timeline. Add the names while they’re fresh."
                // No place names, people, coordinates or counts on the lock screen.
                content.userInfo = ["kind": plan.kind.rawValue, "period": plan.periodStart.timeIntervalSince1970]
                content.sound = .default
                do { try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger)) }
                catch { /* A reminder must never interrupt recording or editing. */ }
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let kind = info["kind"] as? String, let seconds = info["period"] as? Double,
           let request = RewindRequest.notification(kind: kind, period: seconds) {
            Task { @MainActor [weak self] in self?.onOpen?(request) }
        }
        completionHandler()
    }
}
