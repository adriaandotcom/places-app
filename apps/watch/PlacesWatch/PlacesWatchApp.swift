import SwiftUI
import WatchKit

@main struct PlacesWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = WatchCompanionModel.shared
    var body: some Scene {
        WindowGroup {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        PlacesMarker().fill(.primary, style: FillStyle(eoFill: true)).frame(width: 17, height: 24)
                        Text("Places").font(.headline)
                    }
                    Toggle("Collect locations", isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) }))
                    Text(model.status).font(.footnote).foregroundStyle(.secondary)
                    if model.enabled {
                        Toggle("More frequent", isOn: Binding(get: { model.frequent }, set: { model.setFrequent($0) }))
                        Text(model.frequent ? "Continues after you lower your wrist, with automatic stationary pauses. Uses more battery; may need reopening after a restart."
                            : "Collects when watchOS allows. Add Places to your watch face for more opportunities.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if let date = model.lastRecorded { Text("Last recorded \(date.formatted(date: .omitted, time: .shortened))").font(.caption2) }
                    if model.queued > 0 { Text("\(model.queued) waiting for iPhone").font(.caption2) }
                    Button("Send to iPhone") { Task { await model.flush() } }.disabled(!model.enabled)
                }.padding(.horizontal, 4)
            }.task { model.start(); await model.foreground() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await model.foreground() } }
                }
        }
    }
}

@MainActor final class WatchDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() { WatchCompanionModel.shared.start() }
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let connectivity = task as? WKWatchConnectivityRefreshBackgroundTask {
                WatchCompanionModel.shared.connectivityTask(connectivity)
            } else if task is WKApplicationRefreshBackgroundTask {
                Task { @MainActor in
                    await WatchCompanionModel.shared.backgroundOpportunity()
                    task.setTaskCompletedWithSnapshot(false)
                }
            } else if let snapshot = task as? WKSnapshotRefreshBackgroundTask {
                snapshot.setTaskCompleted(restoredDefaultState: true, estimatedSnapshotExpiration: .distantFuture, userInfo: nil)
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}
