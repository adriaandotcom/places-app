import SwiftUI
import UIKit
import UserNotifications
import BackgroundTasks

@MainActor final class AppDelegate: NSObject, UIApplicationDelegate {
    // BGTaskScheduler's nil queue is a background queue. The launch handler is
    // MainActor-isolated, while expiration must be callable from any queue.
    nonisolated static func photoTaskExpirationHandler(_ work: Task<Void, Never>) -> @Sendable () -> Void {
        { LocalDiagnostics.shared.record(.photoTaskExpired); work.cancel() }
    }
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        LocalDiagnostics.shared.record(.companionDeliveryStarted)
        let received = await AppModel.shared.receiveCompanionDelivery()
        LocalDiagnostics.shared.record(.companionDeliveryFinished)
        return received ? .newData : .noData
    }
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier.hasPrefix(MapDownloads.sessionID) else { completionHandler(); return }
        AppModel.shared.mapDownloads.start()
        AppModel.shared.mapDownloads.handleBackgroundEvents(identifier: identifier, completion: completionHandler)
    }
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if !AppModel.shared.uiTesting { LocalDiagnostics.shared.start() }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: PhotoLibraryEvidence.taskID, using: .main) { task in
            let work = Task { @MainActor in
                LocalDiagnostics.shared.record(.photoTaskStarted)
                let model = AppModel.shared
                await model.preparePhotoBackgroundScan()
                LocalDiagnostics.shared.record(.photoTaskFinished)
                task.setTaskCompleted(success: !Task.isCancelled)
            }
            task.expirationHandler = Self.photoTaskExpirationHandler(work)
        }
        // Start from the lifecycle entry point too, including location-triggered background launches.
        UNUserNotificationCenter.current().delegate = AppModel.shared.rewindNotifications
        AppModel.shared.start()
        return true
    }
}

@main struct PlacesApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel.shared
    @State private var showingSupport = false
    var body: some Scene {
        WindowGroup {
            Group {
                if !model.ready {
                    VStack(spacing: 20) {
                        Image(systemName: "location.circle.fill").font(.system(size: 54)).foregroundStyle(Palette.green)
                        Text(model.waitingForUnlock ? "Unlock to open your history" : "Opening Places").font(BrandFont.heading)
                        if model.waitingForUnlock { Text("Recording will resume after your first unlock.").foregroundStyle(.secondary) }
                        else { ProgressView() }
                    }.padding().frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.background)
                } else if !model.onboardingComplete || model.replayingOnboarding { OnboardingView() }
                else { MainView() }
            }
            .environment(model)
            .tint(Palette.green)
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in model.start() }
            .onChange(of: model.tracking.authorization) { _, _ in
                Task { await model.reconcileTraccar() }
            }
            .onChange(of: scenePhase) { _, phase in
                model.matchingSceneChanged(active: phase == .active)
                if !model.uiTesting {
                    model.tracking.sceneChanged(isForeground: phase != .background)
                    if phase == .active { LocalDiagnostics.shared.record(.foreground) }
                    else if phase == .background { LocalDiagnostics.shared.record(.background) }
                }
                if phase == .active { Task { await model.reconcileTraccar(); await model.refresh(); if !model.uiTesting { model.photoLibrary.updateAuthorization(); model.photoLibrary.requestScan(); await model.companions.sync() } } }
            }
            .alert("Places needs your attention", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                if !model.ready { Button("Retry") { model.errorMessage = nil; model.start() } }
                else if model.storageNeedsRetry { Button("Try again") { Task { await model.retryStorage() } } }
                Button("Report a problem") { model.errorMessage = nil; showingSupport = true }
                Button("OK") { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
            .sheet(isPresented: $showingSupport) {
                NavigationStack { SupportReportView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingSupport = false } } } }
                    .environment(model)
            }
        }
    }
}
