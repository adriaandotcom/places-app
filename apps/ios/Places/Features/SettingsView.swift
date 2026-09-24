import SwiftUI
import CoreMotion
import UserNotifications
import PlacesCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmMaps = false
    @State private var confirmExport = false
    @State private var confirmTestExport = false
    @State private var confirmDelete = false
    @State private var deleting = false
    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                InfoRow(symbol: "iphone", title: "Your history stays here", subtitle: "Stored on this iPhone. No account, analytics, or automatic cloud backup.")
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            }
            Section("Recording") {
                Toggle("Record my history", isOn: Binding(get: { model.trackingEnabled }, set: { value in Task { await model.setTrackingEnabled(value) } })).tint(Palette.controlGreen)
                    .accessibilityIdentifier("tracking-toggle")
                LabeledContent("Status", value: model.tracking.state.title)
                Button("Retry storage", systemImage: "arrow.clockwise") { Task { await model.retryStorage() } }
            }
            Section("Permissions") {
                Button { model.tracking.requestLocation() } label: { LabeledContent("Location", value: model.tracking.locationStatus) }
                Button { model.tracking.requestMotion() } label: {
                    LabeledContent("Motion & Fitness", value: model.tracking.motionAuthorization == .authorized ? "Enabled" : "Not enabled")
                }
                Button { Task { await model.tracking.requestNotifications() } } label: {
                    LabeledContent("Notifications", value: model.tracking.notificationAuthorization == .authorized ? "Enabled" : "Not enabled")
                }
                Button("Open system settings") { model.tracking.openSettings() }
            }
            Section {
                Toggle("Apple Maps", isOn: Binding(get: { model.mapsEnabled }, set: { value in
                    if value { confirmMaps = true } else { Task { await model.setMapsEnabled(false) } }
                })).tint(Palette.controlGreen).accessibilityIdentifier("maps-toggle")
            } header: { Text("Optional Apple service") } footer: {
                Text("Enabling maps sends requests to Apple for the areas you view. Turn this off to remove maps immediately. Places, history, and local search keep working.")
            }
            Section {
                NavigationLink("Saved Wi-Fi networks") {
                    ScrollView {
                        VStack(spacing: 16) {
                            if model.networks.isEmpty { EmptyHistory(symbol: "wifi", title: "No networks yet", message: "Connected networks appear when precise location access and Wi-Fi information are available.") }
                            ForEach(model.networks) { network in WiFiClassificationPicker(network: network) }
                        }.padding(20)
                    }.background(Palette.background).navigationTitle("Wi-Fi networks")
                }
                Toggle("Nerd mode", isOn: Binding(get: { model.nerdMode }, set: { value in Task { await model.setNerdMode(value) } })).tint(Palette.controlGreen)
                    .accessibilityIdentifier("nerd-toggle")
                if model.nerdMode { NavigationLink("Local diagnostics") { DiagnosticsView() } }
            } header: { Text("A little more detail") } footer: {
                Text("Nerd mode reveals observations, tracking policy, and local counters. Nothing is uploaded.")
            }
            Section("Your data") {
                Button("Export full history…", systemImage: "square.and.arrow.up") { confirmExport = true }
                Button("Export redacted diagnostics…", systemImage: "doc.text") { Task { await model.export(fullHistory: false) } }
                Button("Export a test case…", systemImage: "checkmark.rectangle.stack") { confirmTestExport = true }
                    .accessibilityIdentifier("export-test-case")
                Button(deleting ? "Starting again…" : "Delete all data and start again…", role: .destructive) { confirmDelete = true }
                    .accessibilityIdentifier("reset-all-data")
            }
            Section("About Places") {
                Text("Built independently by Adriaan, founder of Simple Analytics. This is a separate personal project.").font(.footnote)
                Text("Public source code · PolyForm Noncommercial 1.0.0").font(.footnote)
                Text("Version 0.1 · iOS 26 or newer").font(.footnote).foregroundStyle(.secondary)
                NavigationLink("Offline place data") { OfflinePlaceDataView() }
                NavigationLink("Third-party licenses") { LicensesView() }
            }
            Section {
                Text("Background recording depends on iOS permissions and delivery. Force-quitting Places can stop recording until you reopen it. This foundation still needs physical-device battery and lifecycle validation.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.disabled(deleting).scrollContentBackground(.hidden).background(Palette.background).navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Enable Apple Maps?", isPresented: $confirmMaps, titleVisibility: .visible) {
                Button("Enable Apple Maps") { Task { await model.setMapsEnabled(true) } }
            } message: { Text("Map data requests go to Apple and can reveal the area you’re viewing. You can turn this off at any time.") }
            .confirmationDialog("Export your private history?", isPresented: $confirmExport, titleVisibility: .visible) {
                Button("Export full history") { Task { await model.export(fullHistory: true) } }
            } message: { Text("This file includes exact locations, Wi-Fi identifiers, raw observations, and corrections. Anyone with the file can read them. Where you save it may synchronize it to a cloud service.") }
            .confirmationDialog("Export a test case?", isPresented: $confirmTestExport, titleVisibility: .visible) {
                Button("Export test case") { Task { await model.exportTestCase() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Correct your timeline first: it becomes the expected result alongside the recorded evidence. Names, Wi-Fi identifiers, dates, and locations are replaced. Route shapes and durations remain, so review the JSON before sharing it. Nothing is uploaded automatically.")
            }
            .alert("Delete everything and start again?", isPresented: $confirmDelete) {
                Button("Delete all data and restart", role: .destructive) {
                    deleting = true
                    Task {
                        let reset = await model.deleteAllDataAndRestart()
                        deleting = false
                        if reset { dismiss() }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Permanently delete all history, places, Wi-Fi, corrections, diagnostics, and app settings, then return to setup. Recording stays paused until you finish setup. iOS permissions and files you already exported are not removed. This cannot be undone.") }
            .fileExporter(isPresented: $model.showExporter, document: model.exportDocument, contentType: .json, defaultFilename: model.exportFilename) { result in
                model.exportDocument = nil
                if case .failure = result { model.errorMessage = "The export could not be saved. Your history has not changed." }
            }
    }
}

struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        List {
            Section("Tracking") {
                LabeledContent("State", value: model.tracking.state.rawValue)
                LabeledContent("Policy", value: TrackingPolicy.version)
                LabeledContent("Monitored regions", value: String(model.tracking.monitoredRegionCount))
                LabeledContent("Low Power Mode", value: model.tracking.lowPower ? "On" : "Off")
            }
            if let diagnostics = model.diagnostics {
                Section("Local counters") {
                    LabeledContent("Raw observations", value: String(diagnostics.observationCount))
                    LabeledContent("Location fixes", value: String(diagnostics.locationFixCount))
                    LabeledContent("Standard location requested", value: Display.duration(diagnostics.standardLocationSeconds))
                    ForEach(diagnostics.stateDurations.keys.sorted(), id: \.self) { key in LabeledContent(key, value: Display.duration(diagnostics.stateDurations[key] ?? 0)) }
                    Text("These are recorded policy durations, not app-specific battery drain. The current interval is added on the next transition.").font(.caption)
                }
            }
            Section("Recent tracking events") {
                ForEach(model.events) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.state.rawValue).font(.subheadline.monospaced())
                        Text(event.reason).font(.caption)
                        Text(event.timestamp.formatted()).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Recent raw observations · on device only") {
                ForEach(model.recentObservations) { observation in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(observation.source.rawValue).font(.subheadline.monospaced())
                        Text(observation.timestamp.formatted()).font(.caption)
                        if let coordinate = observation.coordinate {
                            Text("\(coordinate.latitude, specifier: "%.5f"), \(coordinate.longitude, specifier: "%.5f") · ±\(Int(observation.horizontalAccuracy ?? 0)) m").font(.caption.monospaced())
                        }
                        if let ssid = observation.ssid { Text(ssid).font(.caption) }
                        if let bssid = observation.bssid { Text(bssid).font(.caption.monospaced()) }
                    }.textSelection(.enabled)
                }
            }
        }.navigationTitle("Nerd mode").refreshable { await model.refresh() }
    }
}

private struct LicensesView: View {
    var body: some View {
        List {
            ForEach(["OFL", "GRDB-LICENSE"], id: \.self) { name in
                Section(name == "OFL" ? "Bricolage Grotesque" : "GRDB.swift") {
                    Text(license(name)).font(.caption).textSelection(.enabled)
                }
            }
        }.navigationTitle("Licenses")
    }
    private func license(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "License included in the source distribution." }
        return text
    }
}
