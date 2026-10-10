import SwiftUI
import PlacesCore
import UniformTypeIdentifiers

struct LocationCollectorsView: View {
    @Environment(AppModel.self) private var model
    @State private var changing = false
    @State private var importingPack = false
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
            Section {
                Toggle("Valhalla routes", isOn: Binding(get: { model.valhallaEnabled }, set: { enabled in
                    Task { await model.setValhalla(enabled: enabled, mode: model.valhallaMode) }
                })).disabled(model.installingRoutingPack || (model.routingPack == nil && !model.valhallaEnabled))
                    .accessibilityIdentifier("valhalla-toggle")
                Picker("Match as", selection: Binding(get: { model.valhallaMode }, set: { mode in
                    Task { await model.setValhalla(enabled: model.valhallaEnabled, mode: mode) }
                })) {
                    ForEach(TraccarMatchingMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }.disabled(model.installingRoutingPack).accessibilityIdentifier("valhalla-mode")
                if let pack = model.routingPack {
                    LabeledContent("Routing data", value: pack.name)
                    LabeledContent("Storage", value: ByteCountFormatter.string(fromByteCount: Int64(pack.bytes), countStyle: .file))
                }
                Button("Import routing pack", systemImage: "square.and.arrow.down") { importingPack = true }
                    .disabled(model.installingRoutingPack).accessibilityIdentifier("import-routing-pack")
                if model.routingPack != nil {
                    Button("Delete routing pack", systemImage: "trash", role: .destructive) {
                        Task { await model.deleteRoutingPack() }
                    }.foregroundStyle(.red).disabled(model.installingRoutingPack)
                }
                if model.installingRoutingPack { ProgressView("Installing routing data…") }
                if let result = model.routeComparison, !result.matches.isEmpty {
                    LabeledContent("Matched points", value: "\(result.matchedPointCount) of \(result.pointCount)")
                    LabeledContent("Estimated distance", value: Measurement(value: result.distanceMeters, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated)))
                    LabeledContent("Observed span", value: Duration.seconds(result.observedSeconds).formatted(.time(pattern: .hourMinuteSecond)))
                }
                if let status = model.routeComparisonStatus { Text(status).foregroundStyle(.secondary) }
            } header: { Text("Route experiment") } footer: {
                Text("Matches only orange Traccar points using local routing data. Enabling this turns on Nerd mode and leaves recording unchanged. Solid orange lines are estimates; dashed sections remain unmatched. Gaps and poor fixes break the trace. Time comes from recorded points, including stops. Import the Places Valhalla ZIP through Files. Matching happens on this iPhone; routing packs are excluded from backups.")
            }
        }.scrollContentBackground(.hidden).background(Palette.background).foregroundStyle(Palette.ink)
            .tint(Palette.controlGreen).navigationTitle("Location collectors").navigationBarTitleDisplayMode(.inline)
            .fileImporter(isPresented: $importingPack, allowedContentTypes: [.zip]) { result in
                if case .success(let url) = result { Task { await model.importRoutingPack(url) } }
            }
    }
    private var status: String {
        if model.traccar.storageFailed { return "Could not save; recording stopped" }
        if !model.trackingEnabled { return "Recording paused" }
        if model.tracking.authorization != .authorizedAlways { return "Needs Always location access" }
        if model.traccar.running { return model.traccar.paused ? "Stationary · GPS paused" : "Recording" }
        return "Starting"
    }
}
