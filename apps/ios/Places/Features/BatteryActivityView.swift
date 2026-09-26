import SwiftUI
import PlacesCore

struct BatteryActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var snapshots: [EnergySnapshot] = []
    @State private var summary: EnergySummary?
    @State private var failed = false
    var body: some View {
        List {
            Section {
                Text("See how often Places asks for location and checks Wi-Fi. These counters stay on this iPhone and are included in redacted diagnostics.")
            }
            if let current = snapshots.first {
                Section("Device now") {
                    LabeledContent("Battery", value: current.batteryLevel.map { "\(Int(($0 * 100).rounded()))%" } ?? "Unavailable")
                    LabeledContent("Power", value: current.batteryState ?? "Unavailable")
                    LabeledContent("Low Power Mode", value: current.lowPower == true ? "On" : "Off")
                    LabeledContent("Temperature state", value: current.thermalState ?? "Unavailable")
                }
            }
            if let summary {
                Section {
                    LabeledContent("Location updates requested", value: Duration.seconds(summary.standardLocationSeconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)))
                    LabeledContent("Location sessions started", value: String(summary.locationStarts))
                    LabeledContent("Single location requests", value: String(summary.singleLocationRequests))
                    LabeledContent("Location callbacks", value: String(summary.locationCallbacks))
                    LabeledContent("Location readings delivered", value: String(summary.locationSamples))
                    LabeledContent("Wi-Fi checks", value: String(summary.wifiReads))
                    LabeledContent("Motion callbacks", value: String(summary.motionCallbacks))
                } header: { Text("Since activity recording began") } footer: {
                    Text("Counts begin with this app update. Location time is how long updates were requested, not measured GPS hardware time. Unobserved time after the app stops is not counted.")
                }
            }
            Section("Recent battery snapshots") {
                ForEach(Array(snapshots.prefix(20).enumerated()), id: \.offset) { _, snapshot in
                    VStack(alignment: .leading, spacing: Layout.compact) {
                        HStack {
                            Text(snapshot.timestamp.formatted(date: .abbreviated, time: .shortened))
                            Spacer()
                            Text(snapshot.batteryLevel.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                        }
                        Text([snapshot.foreground == true ? "Foreground" : "Background", snapshot.batteryState ?? "", snapshot.lowPower == true ? "Low Power Mode" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(Palette.muted)
                    }
                }
                if failed { Text("Activity couldn’t be loaded. Try refreshing.") }
            }
            Section {
                Text("Battery percentages describe the whole iPhone. For battery use attributed to Places, open iOS Settings → Battery. Snapshots are taken on existing app and power events; there is no battery polling timer.")
                    .font(.footnote).foregroundStyle(Palette.muted)
                Button("Export redacted diagnostics…") { Task { await model.export(fullHistory: false) } }
            }
        }.scrollContentBackground(.hidden).background(Palette.background)
            .navigationTitle("Battery & activity").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } } } }
            .task { await load() }.refreshable { await load() }
    }
    private func load() async {
        let current = model.tracking.energySnapshot()
        model.tracking.recordEnergyCheckpoint()
        do {
            let events = try await model.store?.trackingEvents(limit: 200) ?? []
            snapshots = [current] + events.compactMap(\.energy).filter { $0.timestamp < current.timestamp }
            // Include each session's last cumulative checkpoint, including older sessions.
            let allEvents = try await model.store?.trackingEvents(limit: Int.max) ?? []
            summary = EnergySummary(snapshots: allEvents.compactMap(\.energy) + [current])
            failed = false
        } catch { failed = true }
    }
}
