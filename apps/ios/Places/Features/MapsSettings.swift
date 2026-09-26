import SwiftUI
import PlacesCore

struct MapsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmApple = false
    @State private var confirmWorld = false
    @State private var deletingPack: MapPack?
    @State private var switching = false
    private var downloads: MapDownloads { model.mapDownloads }
    var body: some View {
        Form {
            Section {
                ForEach(MapProvider.allCases, id: \.self) { provider in
                    Button { choose(provider) } label: {
                        HStack {
                            Text(provider.title).foregroundStyle(Palette.ink)
                            Spacer()
                            if model.mapProvider == provider { Image(systemName: "checkmark").fontWeight(.semibold) }
                        }.frame(minHeight: 28)
                    }.accessibilityIdentifier("map-provider-" + provider.rawValue)
                        .accessibilityAddTraits(model.mapProvider == provider ? .isSelected : [])
                        .disabled(switching || (provider == .onDevice && !downloads.ready))
                }
            } header: { Text("Map provider") } footer: {
                Text("Apple Maps loads the areas you view from Apple. On-device Maps uses downloaded maps and works without a connection. Your places and history stay on this iPhone.")
            }
            if !downloads.packs.isEmpty {
                Section {
                    ForEach(downloads.packs) { pack in
                        VStack(alignment: .leading, spacing: Layout.compact) {
                            HStack {
                                Text(pack.name).font(.body.weight(.semibold))
                                Spacer()
                                Text(pack.sizeLabel).foregroundStyle(Palette.muted)
                            }
                            packState(pack)
                        }.padding(.vertical, 4).buttonStyle(.borderless)
                    }
                } header: { Text("On-device maps") } footer: {
                    Text("World gives an overview everywhere. Country maps add roads, towns and landscapes. Downloads come from GitHub, which sees your IP address and the pack you choose. Map browsing stays on this iPhone.")
                }
                if downloads.totalInstalledBytes > 0 {
                    Section {
                        LabeledContent("Storage used", value: ByteCountFormatter.string(fromByteCount: downloads.totalInstalledBytes, countStyle: .file))
                    }
                }
                Section {
                    Text("© OpenStreetMap contributors · Natural Earth · Protomaps").font(.footnote)
                }.listRowBackground(Color.clear)
            } else { Text("Map downloads are unavailable in this build.").foregroundStyle(Palette.muted) }
        }.scrollContentBackground(.hidden).background(Palette.background)
            .navigationTitle("Maps").navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Use Apple Maps?", isPresented: $confirmApple, titleVisibility: .visible) {
                if downloads.totalInstalledBytes > 0 || !downloads.transfers.isEmpty {
                    Button("Keep downloaded maps") { switchToApple(deleteDownloads: false) }
                    Button("Delete downloaded maps", role: .destructive) { switchToApple(deleteDownloads: true) }
                } else { Button("Enable Apple Maps") { switchToApple(deleteDownloads: false) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(downloads.transfers.isEmpty
                     ? "Apple receives requests for the areas you view. Location Details has its own setting."
                     : "Apple receives requests for the areas you view. Keep your on-device maps for later, or delete them to free storage. Your places and history are kept.")
            }
            .alert("Download World map?", isPresented: $confirmWorld) {
                Button("Cancel", role: .cancel) {}
                Button("Download") { activateOffline(approved: true) }
            } message: {
                if let world = downloads.pack(.world) {
                    Text("This connection may use mobile data or Low Data Mode. Download \(ByteCountFormatter.string(fromByteCount: downloads.remaining(world), countStyle: .file)) from GitHub to use On-device Maps?")
                }
            }
            .confirmationDialog("Delete downloaded map?", isPresented: Binding(get: { deletingPack != nil }, set: { if !$0 { deletingPack = nil } }), titleVisibility: .visible) {
                if let pack = deletingPack {
                    Button("Delete \(pack.name)", role: .destructive) { downloads.delete(pack); deletingPack = nil }
                }
                Button("Cancel", role: .cancel) { deletingPack = nil }
            } message: { Text("You can download it again later. Your places and history are kept.") }
            .alert("Map download", isPresented: Binding(get: { downloads.issue != nil }, set: { if !$0 { downloads.clearIssue() } })) {
                Button("OK") { downloads.clearIssue() }
            } message: { Text(downloads.issue ?? "") }
    }
    @ViewBuilder private func packState(_ pack: MapPack) -> some View {
        let transfer = downloads.transfers[pack.id]
        if downloads.installed[pack.id] != nil {
            HStack {
                Label("Downloaded", systemImage: "checkmark.circle").foregroundStyle(Palette.muted)
                Spacer()
                Button("Delete", role: .destructive) { deletingPack = pack }
            }.font(.subheadline).frame(minHeight: Layout.touchTarget)
        } else if transfer?.phase == .downloading {
            ProgressView(value: Double(transfer?.received ?? 0), total: Double(pack.bytes))
                .accessibilityLabel("Downloading \(pack.name)")
            HStack {
                Text("\(ByteCountFormatter.string(fromByteCount: transfer?.received ?? 0, countStyle: .file)) of \(pack.sizeLabel)")
                    .font(.footnote).foregroundStyle(Palette.muted)
                Spacer()
                Button("Pause") { downloads.pause(pack.id) }
            }.frame(minHeight: Layout.touchTarget)
        } else if transfer?.phase == .verifying || transfer?.phase == .pausing {
            ProgressView(transfer?.phase == .pausing ? "Pausing…" : "Checking download…").frame(minHeight: Layout.touchTarget)
        } else {
            if let message = transfer?.message { Text(message).font(.footnote).foregroundStyle(Palette.muted) }
            HStack {
                MapPackDownloadButton(pack: pack, title: transfer == nil ? "Download" : (transfer?.phase == .failed ? "Retry" : "Resume"))
                Spacer()
                if transfer != nil { Button("Cancel", role: .destructive) { downloads.delete(pack) } }
            }.frame(minHeight: Layout.touchTarget)
        }
    }
    private func choose(_ provider: MapProvider) {
        guard provider != model.mapProvider else { return }
        switch provider {
        case .off: Task { await model.setMapProvider(.off) }
        case .apple: confirmApple = true
        case .onDevice:
            if downloads.installed[.world] != nil || downloads.pending.contains(.world) { Task { await model.setMapProvider(.onDevice) } }
            else if downloads.network == .needsApproval { confirmWorld = true }
            else if downloads.network == .unmetered { activateOffline(approved: false) }
            else { downloads.showConnectionIssue() }
        }
    }
    private func activateOffline(approved: Bool) {
        guard let world = downloads.pack(.world) else { return }
        switching = true
        Task {
            await model.setMapProvider(.onDevice)
            if model.mapProvider == .onDevice { downloads.download(world, approvedMetered: approved) }
            switching = false
        }
    }
    private func switchToApple(deleteDownloads: Bool) {
        switching = true
        Task {
            await model.setMapProvider(.apple)
            if model.mapProvider == .apple && deleteDownloads {
                do { try downloads.deleteAll() } catch { model.errorMessage = "Some map files could not be deleted. Try again in Maps settings." }
            }
            switching = false
        }
    }
}

struct MapPackDownloadButton: View {
    @Environment(AppModel.self) private var model
    let pack: MapPack
    var title = "Download"
    @State private var confirm = false
    var body: some View {
        Button(title, systemImage: "arrow.down.circle") {
            if model.mapDownloads.network == .needsApproval { confirm = true }
            else { model.mapDownloads.download(pack) }
        }.accessibilityIdentifier("download-map-" + pack.id.rawValue)
            .disabled(!model.mapDownloads.ready)
            .alert("Download \(pack.name)?", isPresented: $confirm) {
                Button("Cancel", role: .cancel) {}
                Button("Download") { model.mapDownloads.download(pack, approvedMetered: true) }
            } message: {
                Text("This connection may use mobile data or Low Data Mode. The download from GitHub is \(ByteCountFormatter.string(fromByteCount: model.mapDownloads.remaining(pack), countStyle: .file)).")
            }
    }
}
