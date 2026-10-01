import SwiftUI

struct SupportReportView: View {
    @Environment(AppModel.self) private var model
    @State var period = ExportPeriodSelection()
    @State var includePhotos = true
    @State private var snapshot = SupportSnapshot()
    @State private var preparing = false
    @State private var confirmFull = false
    @State private var document: HistoryDocument?
    @State private var filename = "Places-support"
    @State private var showExporter = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Text("Help us understand a problem without sharing where you’ve been.")
                Text("Reports stay on this iPhone until you choose to save or share a file. Nothing is sent automatically.")
                    .foregroundStyle(Palette.muted)
            }
            Section {
                Label("App and iOS versions", systemImage: "app.badge")
                Label("Error codes and recent app activity", systemImage: "list.bullet.rectangle")
                Label("Crash stacks and background exit counts", systemImage: "waveform.path.ecg")
                Label("Permission settings and recording counters", systemImage: "switch.2")
                Button { prepare(full: false) } label: {
                    Label("Export technical report", systemImage: "square.and.arrow.up")
                }.accessibilityIdentifier("support-technical-export")
            } header: { Text("Technical report · recommended") } footer: {
                Text("No locations, place names, photos, notes, Wi-Fi details, IP addresses, device identifiers, or exact activity dates. Error messages and file paths are excluded too.")
            }
            Section {
                LabeledContent("Crash & performance reports", value: "\(snapshot.incidents.count)")
                LabeledContent("Background exit reports", value: "\(snapshot.exitReports.count)")
                if !snapshot.storageAvailable {
                    Text("Saved diagnostics are unavailable. Unlock this iPhone or free some storage, then try again.").foregroundStyle(Palette.muted)
                }
            } footer: {
                Text("iOS supplies these reports when available, sometimes after you reopen Places. No reports does not mean no crashes. Recent technical details are kept locally with a size limit.")
            }
            Section {
                ExportPeriodPicker(selection: $period)
                Toggle("Include saved photos", isOn: $includePhotos).tint(Palette.controlGreen)
            } header: { Text("History options") } footer: {
                Text("These options apply only when you include history. The technical report never includes your history or photos.")
            }
            Section {
                Button("Export with history…", systemImage: "doc.badge.plus") { confirmFull = true }
                    .disabled(model.store == nil).accessibilityIdentifier("support-full-export")
            } header: { Text("Include private history") } footer: {
                Text("Adds the selected period’s exact locations and times, Wi-Fi and companion identifiers, observations, corrections and memories, plus related places, trips and people. Saved photos are included only when enabled. Includes only app data, not your entire photo library. Passwords and encryption keys are never included.")
            }
            Section {
                Text("You choose who receives the file. Your sharing service may reveal your identity, and saving to a cloud folder may sync the file there.")
                    .foregroundStyle(Palette.muted)
            }
            if preparing { Section { ProgressView("Preparing report…") } }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .disabled(preparing)
        .scrollContentBackground(.hidden).background(Palette.background)
        .navigationTitle("Report a problem").navigationBarTitleDisplayMode(.inline)
        .task { snapshot = await LocalDiagnostics.shared.log.snapshot() }
        .confirmationDialog("Include your private history?", isPresented: $confirmFull, titleVisibility: .visible) {
            Button("Export private support report") { prepare(full: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Anyone with this file can read your locations, photos, people and other private history. Only share it with someone you trust. Nothing is sent until you choose where to save or share it.")
        }
        .fileExporter(isPresented: $showExporter, document: document, contentType: .json, defaultFilename: filename) { result in
            document = nil
            if case .failure = result { error = "The report could not be saved. Please try again." }
        }
    }
    private func prepare(full: Bool) {
        preparing = true; error = nil
        Task {
            defer { preparing = false }
            do {
                let data = try await model.supportReport(includeHistory: full, period: period.interval(), includePhotos: includePhotos)
                document = HistoryDocument(data: data, contentType: .json)
                filename = full ? "Places-support-FULL-PRIVATE" : "Places-support"
                showExporter = true
            } catch { self.error = "Could not prepare this report. Your data has not changed. You can try the technical report without history." }
        }
    }
}
