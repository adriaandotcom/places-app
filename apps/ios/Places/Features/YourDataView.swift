import SwiftUI

struct YourDataView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var period = ExportPeriodSelection()
    @State private var includePhotos = true
    @State private var confirmExport = false
    @State private var confirmGPXExport = false
    @State private var confirmTestExport = false
    @State private var confirmDelete = false
    @State private var preparing = false
    @State private var deleting = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                NavigationLink { BackupTransferView() } label: {
                    DataActionLabel(title: "Backup and restore", detail: "One complete ZIP for another iPhone", symbol: "externaldrive")
                }.accessibilityIdentifier("backup-and-restore")
            }
            Section {
                ExportPeriodPicker(selection: $period)
                Toggle("Include saved photos", isOn: $includePhotos).tint(Palette.controlGreen)
                    .accessibilityIdentifier("export-photos")
            } header: { Text("Export options") } footer: {
                Text("Choose fewer days or turn off photos for a smaller history file. Includes related places, people and overlapping trips. Photos are never included in GPX or test cases.")
            }
            Section {
                Button { confirmExport = true } label: {
                    DataActionLabel(title: "Export history…", detail: "JSON · visits, memories and recorded evidence", symbol: "square.and.arrow.up")
                }.accessibilityIdentifier("export-history")
                Button { confirmGPXExport = true } label: {
                    DataActionLabel(title: "Export GPX…", detail: "Locations for your own maps and tools", symbol: "square.and.arrow.up")
                }.accessibilityIdentifier("export-gpx")
            } header: { Text("Save a copy") } footer: {
                Text("Exports stay with you until you choose to share them. Saving to a cloud folder may sync the file there.")
            }
            Section {
                NavigationLink { SupportReportView(period: period, includePhotos: includePhotos) } label: {
                    DataActionLabel(title: "Report a problem", detail: "Private technical report or selected history", symbol: "lifepreserver")
                }.accessibilityIdentifier("support-report")
                Button { confirmTestExport = true } label: {
                    DataActionLabel(title: "Export a test case…", detail: "Reproduce a timeline issue with disguised data", symbol: "square.and.arrow.up")
                }.accessibilityIdentifier("export-test-case")
            } header: { Text("Help improve Places") }
            if preparing { Section { ProgressView("Preparing export…") } }
            Section {
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label(deleting ? "Starting again…" : "Delete all data and start again…", systemImage: "trash")
                }.foregroundStyle(.red).accessibilityIdentifier("reset-all-data")
            }
        }.disabled(preparing || deleting).scrollContentBackground(.hidden).background(Palette.background)
            .navigationTitle("Your data").navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Export your private history?", isPresented: $confirmExport, titleVisibility: .visible) {
                Button("Export history") { export(.history) }
            } message: {
                Text("Includes the selected period’s exact locations, Wi-Fi identifiers, observations, corrections and memories, plus related places, trips and people. Saved images are included only when enabled. Anyone with the file can read it.")
            }
            .confirmationDialog("Export locations as GPX?", isPresented: $confirmGPXExport, titleVisibility: .visible) {
                Button("Export GPX") { export(.gpx) }
            } message: {
                Text("Includes recorded coordinates, timestamps and saved place names for the selected period. Photos, notes, people and Wi-Fi details are excluded. Anyone with the file can read your locations.")
            }
            .confirmationDialog("Export a test case?", isPresented: $confirmTestExport, titleVisibility: .visible) {
                Button("Export test case") { export(.testCase) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your corrected timeline becomes the expected result alongside the selected evidence. Names, Wi-Fi identifiers, dates and locations are replaced. Route shapes and durations remain; review before sharing. Limited periods exclude earlier tracking context. Nothing is uploaded automatically.")
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
            } message: {
                Text("Permanently delete all history, places, trips, notes, photos, people, Wi-Fi, corrections, diagnostics, downloaded maps and app settings, then return to setup. This deletes every date, regardless of the export period. iOS permissions and files already exported are not removed. This cannot be undone.")
            }
            .fileExporter(isPresented: $model.showExporter, document: model.exportDocument,
                contentType: model.exportDocument?.contentType ?? .json, defaultFilename: model.exportFilename) { result in
                model.exportDocument = nil
                if case .failure = result { model.errorMessage = "The export could not be saved. Your history has not changed." }
            }
    }
    private func export(_ format: HistoryExportFormat) {
        preparing = true
        Task {
            await model.export(format, period: period.interval(), includePhotos: includePhotos)
            preparing = false
        }
    }
}

struct DataActionLabel: View {
    let title: String
    let detail: String
    let symbol: String
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: Layout.compact) {
                Text(title).foregroundStyle(Palette.ink)
                Text(detail).font(.footnote).foregroundStyle(Palette.muted)
            }.padding(.vertical, Layout.compact)
        } icon: { Image(systemName: symbol).foregroundStyle(Palette.green) }
    }
}
