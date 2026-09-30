import SwiftUI
import AppKit

@main struct PlacesMacApp: App {
    @State private var model = MacCompanionModel()
    var body: some Scene {
        MenuBarExtra {
            MacCompanionView(model: model)
        } label: {
            Image(nsImage: Self.marker).accessibilityLabel("Places")
        }.menuBarExtraStyle(.window)
    }
    private static var marker: NSImage {
        let renderer = ImageRenderer(content: PlacesMarker().fill(.black, style: FillStyle(eoFill: true))
            .frame(width: 16, height: 20))
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: 16, height: 20))
        image.isTemplate = true
        return image
    }
}

private struct MacCompanionView: View {
    @Bindable var model: MacCompanionModel
    @State private var confirmDelete = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                PlacesMarker().fill(.primary, style: FillStyle(eoFill: true)).frame(width: 20, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Places").font(.headline)
                    Text("A little more of your day").font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("Contribute Mac locations", isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) }))
            Text(model.status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let uploaded = model.lastUploaded {
                LabeledContent("Last secure upload") { Text(uploaded, style: .relative).font(.caption) }
            }
            if model.queued > 0 {
                LabeledContent("Waiting to send", value: String(model.queued))
                Button("Delete queued locations…", role: .destructive) { confirmDelete = true }
            }
            if model.enabled {
                Button("Sync now", systemImage: "arrow.triangle.2.circlepath") { Task { await model.sync() } }
                    .disabled(model.syncing)
            }
            Divider()
            Text("Enable Mac companions in Places on your iPhone first. Use the same iCloud account with iCloud Keychain turned on.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Locations are collected only while you actively use this Mac. Records are encrypted before delivery through your private iCloud. Your iPhone keeps the timeline.")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Quit Places") { NSApplication.shared.terminate(nil) } }
        }.padding(20).frame(width: 320)
            .task { model.start(); if model.enabled { await model.sync() } }
            .confirmationDialog("Delete locations still waiting on this Mac?", isPresented: $confirmDelete) {
                Button("Delete queued locations", role: .destructive) { Task { await model.deleteQueued() } }
            }
    }
}
