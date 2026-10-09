import SwiftUI

struct LocationCollectorsView: View {
    @Environment(AppModel.self) private var model
    @State private var changing = false
    var body: some View {
        Form {
            Section {
                Toggle("Traccar comparison", isOn: Binding(get: { model.traccarEnabled }, set: { value in
                    changing = true
                    Task { await model.setTraccarEnabled(value); changing = false }
                })).disabled(changing).accessibilityIdentifier("traccar-recording-toggle")
                if model.traccarEnabled {
                    LabeledContent("Status", value: status)
                    LabeledContent("Saved points", value: model.traccar.count.formatted())
                    if let date = model.traccar.lastRecorded {
                        LabeledContent("Last recorded", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                    if model.tracking.authorization != .authorizedAlways {
                        Button("Allow background location") { model.tracking.requestLocation() }
                    }
                    if model.traccar.storageFailed {
                        Button("Retry recording") { Task { await model.traccar.stop(); await model.reconcileTraccar() } }
                    }
                }
            } footer: {
                Text("Runs alongside Places to compare location recording. Points stay in this iPhone’s local history and are included in your backups. They are never uploaded or used for your timeline. Running both collectors may use more battery.")
            }
            Section {
                Toggle("Nerd mode", isOn: Binding(get: { model.nerdMode }, set: { value in
                    Task { await model.setNerdMode(value) }
                })).accessibilityIdentifier("collector-nerd-mode")
                Toggle(isOn: Binding(get: { model.showPlacesPoints }, set: { value in
                    Task { await model.setComparisonLayer(traccar: false, visible: value) }
                })) {
                    Label { Text("Places points") } icon: {
                        Image(systemName: "circle.fill").foregroundStyle(Palette.accent(0))
                    }
                }
                    .accessibilityIdentifier("show-places-points")
                Toggle(isOn: Binding(get: { model.showTraccarPoints }, set: { value in
                    Task { await model.setComparisonLayer(traccar: true, visible: value) }
                })) {
                    Label { Text("Traccar points") } icon: {
                        Image(systemName: "circle.fill").foregroundStyle(Palette.accent(2))
                    }
                }
                    .accessibilityIdentifier("show-traccar-points")
            } header: { Text("Map layers") } footer: {
                Text("Nerd mode shows each collector’s points for the selected date or period. Dashed lines connect points from the same collector in time order. Hiding a layer does not stop recording.")
            }
        }.scrollContentBackground(.hidden).background(Palette.background).foregroundStyle(Palette.ink)
            .tint(Palette.controlGreen).navigationTitle("Location collectors").navigationBarTitleDisplayMode(.inline)
    }
    private var status: String {
        if model.traccar.storageFailed { return "Could not save; recording stopped" }
        if !model.trackingEnabled { return "Recording paused" }
        if model.tracking.authorization != .authorizedAlways { return "Needs Always location access" }
        if model.traccar.running { return model.traccar.paused ? "Stationary · GPS paused" : "Recording" }
        return "Starting"
    }
}
