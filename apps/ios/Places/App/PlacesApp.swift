import SwiftUI
import UIKit

@MainActor final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Start from the lifecycle entry point too, including location-triggered background launches.
        AppModel.shared.start()
        return true
    }
}

@main struct PlacesApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel.shared
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
                } else if !model.onboardingComplete { OnboardingView() }
                else { MainView() }
            }
            .environment(model)
            .tint(Palette.ink)
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in model.start() }
            .onChange(of: scenePhase) { _, phase in
                if !model.uiTesting { model.tracking.sceneChanged(isForeground: phase != .background) }
                if phase == .active { Task { await model.refresh() } }
            }
            .alert("Places needs your attention", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                if !model.ready { Button("Retry") { model.errorMessage = nil; model.start() } }
                Button("OK") { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
            .fileExporter(isPresented: $model.showExporter, document: model.exportDocument, contentType: .json, defaultFilename: model.exportFilename) { result in
                model.exportDocument = nil
                if case .failure = result { model.errorMessage = "The export could not be saved. Your history has not changed." }
            }
        }
    }
}
