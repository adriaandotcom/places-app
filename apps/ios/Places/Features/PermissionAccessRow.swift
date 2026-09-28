import SwiftUI
import CoreMotion
import UserNotifications

struct PermissionAccessRow: View {
    enum Permission { case location, motion, notifications }
    @Environment(AppModel.self) private var model
    let permission: Permission
    var style: PermissionRow.Style = .inline
    private var title: String {
        switch permission {
        case .location: "Location"
        case .motion: "Motion & Fitness"
        case .notifications: "Notifications"
        }
    }
    private var enabled: Bool {
        switch permission {
        case .location: model.tracking.locationSetupReady
        case .motion: model.tracking.motionAuthorization == .authorized
        case .notifications: [.authorized, .provisional, .ephemeral].contains(model.tracking.notificationAuthorization)
        }
    }
    private var status: String {
        switch permission {
        case .location: model.tracking.locationStatus
        case .motion:
            if !CMMotionActivityManager.isActivityAvailable() { "Unavailable on this device" }
            else { enabled ? "Enabled" : "Not enabled" }
        case .notifications: enabled ? "Enabled" : "Not enabled"
        }
    }
    var body: some View {
        PermissionRow(title: title, status: status, enabled: enabled, style: style, action: action)
    }
    private var action: (() -> Void)? {
        guard permission != .motion || CMMotionActivityManager.isActivityAvailable() else { return nil }
        return { request() }
    }
    private func request() {
        switch permission {
        case .location:
            if model.tracking.authorization == .authorizedAlways { model.tracking.openSettings() }
            else { model.tracking.requestLocation() }
        case .motion:
            if enabled { model.tracking.openSettings() }
            else { model.tracking.requestMotion() }
        case .notifications:
            if enabled { model.tracking.openSettings() }
            else { Task { await model.tracking.requestNotifications() } }
        }
    }
}
