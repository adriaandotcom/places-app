import SwiftUI
import CoreMotion
import UserNotifications
import PlacesCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
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
                if model.storageNeedsRetry {
                    Text("Recording is paused until your history can be saved.").foregroundStyle(Palette.muted)
                    Button("Try again", systemImage: "arrow.clockwise") { Task { await model.retryStorage() } }
                }
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
                NavigationLink { MapsSettings() } label: {
                    LabeledContent("Maps", value: model.mapProvider.title)
                }.accessibilityIdentifier("map-settings")
            }
            Section {
                AppleLocationDetailsToggle()
            } header: { Text("Apple Services") } footer: {
                Text("Add city and country names to group your trips.")
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
            Section {
                NavigationLink("About Places") { AboutPlacesView() }
                    .font(.footnote).frame(minHeight: Layout.touchTarget)
                    .listRowBackground(Color.clear).accessibilityIdentifier("about-places")
            }
        }.disabled(deleting).scrollContentBackground(.hidden).background(Palette.background).navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
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
            } message: { Text("Permanently delete all history, places, Wi-Fi, corrections, diagnostics, downloaded maps, and app settings, then return to setup. Recording stays paused until you finish setup. iOS permissions and files you already exported are not removed. This cannot be undone.") }
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
            ForEach(["OFL", "GRDB-LICENSE", "MapLibre-LICENSE", "Map-data", "Map-fonts"], id: \.self) { name in
                Section(["OFL": "Bricolage Grotesque", "GRDB-LICENSE": "GRDB.swift", "MapLibre-LICENSE": "MapLibre", "Map-data": "On-device map data", "Map-fonts": "Noto Sans map labels"][name] ?? name) {
                    Text(license(name)).font(.caption).textSelection(.enabled)
                }
            }
        }.navigationTitle("Licenses")
    }
    private func license(_ name: String) -> String {
        let filename = name == "Map-fonts" ? "OFL" : name
        let folder = name == "Map-fonts" ? "OfflineMaps/fonts" : "OfflineMaps"
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt") ?? Bundle.main.url(forResource: filename, withExtension: "txt", subdirectory: folder),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "License included in the source distribution." }
        return text
    }
}

struct AppleLocationDetailsToggle: View {
    @Environment(AppModel.self) private var model
    @State private var confirm = false
    var body: some View {
        Toggle("Apple Location Details", isOn: Binding(get: { model.placeLookupEnabled }, set: { value in
            if !value { Task { await model.setPlaceLookupEnabled(false) } }
            else if model.placeLookupExplained { enableLookup() }
            else { confirm = true }
        })).tint(Palette.controlGreen).accessibilityIdentifier("city-lookup-toggle")
            .alert("Find city & country with Apple?", isPresented: $confirm) {
                Button("Not now", role: .cancel) { }
                Button("Enable lookup", action: enableLookup)
            } message: {
                Text("Places sends saved place coordinates to Apple to find city and country names. Results stay on this iPhone. Your map choice is separate. Turning this off stops lookups and keeps names already saved.")
            }
    }
    private func enableLookup() { Task { await model.setPlaceLookupEnabled(true) } }
}

struct CityLookupSettings: View {
    var body: some View {
        Form {
            Section {
                AppleLocationDetailsToggle()
            } footer: {
                Text("Add city and country names to group your trips. Saved names remain with each place when you turn this off.")
            }
        }.scrollContentBackground(.hidden).background(Palette.background)
            .navigationTitle("Apple Location Details").navigationBarTitleDisplayMode(.inline)
    }
}

private struct AboutPlacesView: View {
    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }
    private var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "" }
    var body: some View {
        List {
            Section {
                Text("Built independently by Adriaan, founder of Simple Analytics. This is a separate personal project.")
                Text("Public source code · PolyForm Noncommercial 1.0.0")
                LabeledContent("Version", value: "\(version) (\(build))")
            }
            Section {
                NavigationLink("Offline place data") { OfflinePlaceDataView() }
                NavigationLink("Third-party licenses") { LicensesView() }
            }
        }.scrollContentBackground(.hidden).background(Palette.background)
            .navigationTitle("About Places").navigationBarTitleDisplayMode(.inline)
    }
}
