import SwiftUI
import UniformTypeIdentifiers
import PlacesCore

struct BackupTransferView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var restoreOnly = false
    @State private var busy = false
    @State private var operation = ""
    @State private var confirmExport = false
    @State private var confirmRestore = false
    @State private var showImporter = false
    @State private var export: BackupExportFile?
    @State private var preview: PreparedBackup?
    @State private var workspace: URL?
    @State private var error: String?
    @State private var restored = false
    @State private var saved = false

    var body: some View {
        Form {
            if preview == nil {
                if !restoreOnly {
                    Section {
                        Button { confirmExport = true } label: {
                            DataActionLabel(title: "Export complete backup…", detail: "All dates, saved photos and app data", symbol: "square.and.arrow.up")
                        }.accessibilityIdentifier("backup-export")
                    } header: { Text("Move to another iPhone") } footer: {
                        Text("Creates one ZIP. Save it in Files or transfer it to your new phone. The export period in Your data doesn’t limit a complete backup.")
                    }
                }
                Section {
                    Button { showImporter = true } label: {
                        DataActionLabel(title: "Restore a backup…", detail: "Choose a Places ZIP from Files", symbol: "square.and.arrow.down")
                    }.accessibilityIdentifier("backup-import")
                } footer: { Text("Review the backup before restoring. Restore replaces the Places data currently on this iPhone.") }
            }
            if let preview {
                Section("Ready to restore") {
                    LabeledContent("Created", value: preview.manifest.createdAt.formatted(date: .abbreviated, time: .shortened))
                    ForEach([("places", "Places"), ("memories", "Memories"), ("memoryPhotos", "Saved photos"), ("trips", "Trips"), ("people", "People"), ("observations", "Observations")], id: \.0) { key, title in
                        LabeledContent(title, value: (preview.manifest.counts[key] ?? 0).formatted())
                    }
                    Button { confirmRestore = true } label: { Label("Restore this backup", systemImage: "square.and.arrow.down") }
                        .accessibilityIdentifier("backup-restore-confirm")
                    Button { cleanup() } label: { Label("Cancel restore", systemImage: "xmark") }
                }
            }
            if busy { Section { ProgressView(operation).accessibilityIdentifier("backup-progress") } }
            Section("Also readable without Places") {
                Text("Unzip the file on a computer and open index.html to browse your timeline, places, trips, people and memories. Photos are ordinary JPEG files, and the original records are included as readable JSON.")
            }
            Section("What transfers") {
                Text("All history, recorded evidence, corrections, Wi-Fi knowledge, saved places and areas, memories, photos, people, trips and preferences.")
                Text("Download maps again and set up permissions and companions on the new phone. Recording, photo scanning, Apple Maps and online lookups remain off after restore. Photos only in your system library and temporary diagnostics aren’t included.")
                    .foregroundStyle(Palette.muted)
            }
            Section {
                Label("Keep your backup private", systemImage: "lock.shield")
                Text("The ZIP is not encrypted. Anyone with it can read your exact locations, Wi-Fi details, notes and photos. Nothing is uploaded automatically; a cloud folder may sync files you save there.")
                    .font(.footnote).foregroundStyle(Palette.muted)
            }
        }
        .disabled(busy).scrollContentBackground(.hidden).background(Palette.background)
        .navigationTitle(restoreOnly ? "Restore a backup" : "Backup and restore").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(busy).interactiveDismissDisabled(busy)
        .confirmationDialog("Export all your private data?", isPresented: $confirmExport, titleVisibility: .visible) {
            Button("Create ZIP backup") { createBackup() }
        } message: { Text("This includes every date and saved photo, plus exact locations, Wi-Fi details, notes and people. Anyone with the ZIP can read it.") }
        .alert("Replace the data on this iPhone?", isPresented: $confirmRestore) {
            Button("Replace and restore", role: .destructive) { restore() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your current Places history, places, memories, photos and preferences will be replaced with this backup. Export them first if you want to keep them. A damaged backup leaves your current data unchanged.")
        }
        .alert("Backup restored", isPresented: $restored) {
            Button("Done") { model.finishBackupRestore(); dismiss() }
        } message: { Text("Your history and saved photos are here. Recording and connected services are paused. Open Settings when you’re ready to enable them and choose your maps.") }
        .alert("Backup saved", isPresented: $saved) { Button("Done", role: .cancel) {} }
            message: { Text("On your new iPhone, install Places and choose Restore a backup. Keep this ZIP somewhere private.") }
        .alert("Couldn’t finish", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.zip]) { result in
            switch result {
            case .success(let url): review(url)
            case .failure: error = "The backup couldn’t be opened. Try choosing it again in Files."
            }
        }
        .sheet(item: $export, onDismiss: { cleanup() }) { file in
            BackupSavePicker(url: file.url) { completed in export = nil; saved = completed }
        }
        .onDisappear { if !busy && export == nil { cleanup() } }
    }

    private static var temporaryRoot: URL { FileManager.default.temporaryDirectory.appendingPathComponent("PlacesBackups", isDirectory: true) }
    static func clearAbandonedTransfers() throws {
        if FileManager.default.fileExists(atPath: temporaryRoot.path) { try FileManager.default.removeItem(at: temporaryRoot) }
    }
    private func newWorkspace() throws -> URL {
        cleanup()
        let root = try PlacesBackup.createWorkspace(in: Self.temporaryRoot)
        workspace = root
        return root
    }
    private func cleanup() {
        preview = nil
        if let workspace { try? FileManager.default.removeItem(at: workspace) }
        workspace = nil
    }
    private func createBackup() {
        busy = true; operation = "Preparing your complete backup…"
        Task {
            defer { busy = false }
            do {
                let root = try newWorkspace()
                export = try BackupExportFile(url: await model.makeBackup(in: root))
            } catch { cleanup(); self.error = "The backup couldn’t be created. Check free storage and try again. Your data hasn’t changed." }
        }
    }
    private func review(_ url: URL) {
        busy = true; operation = "Checking the backup…"
        Task {
            defer { busy = false }
            do {
                let root = try newWorkspace()
                preview = try await Task.detached(priority: .userInitiated) {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    var coordinationError: NSError?
                    var result: Result<PreparedBackup, Error>?
                    NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinated in
                        result = Result { try PlacesBackup.prepare(zip: coordinated, in: root) }
                    }
                    if let coordinationError { throw coordinationError }
                    guard let result else { throw BackupError.invalid }
                    return try result.get()
                }.value
            } catch { cleanup(); self.error = (error as? BackupError)?.errorDescription ?? "The backup couldn’t be read. Check free storage and try again. Your data hasn’t changed." }
        }
    }
    private func restore() {
        guard let preview else { return }
        busy = true; operation = "Restoring your history…"
        Task {
            defer { busy = false }
            do { try await model.restoreBackup(preview); cleanup(); restored = true }
            catch { self.error = "Restore couldn’t finish. Your existing history is unchanged. Check free storage and try again." }
        }
    }
}

private struct BackupExportFile: Identifiable { let id = UUID(); let url: URL }

/// Export a file URL instead of loading a multi-gigabyte ZIP into FileDocument.
private struct BackupSavePicker: UIViewControllerRepresentable {
    let url: URL
    let completion: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (Bool) -> Void
        init(completion: @escaping (Bool) -> Void) { self.completion = completion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { completion(!urls.isEmpty) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completion(false) }
    }
}
