import SwiftUI
import PlacesCore

struct MapsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmApple = false
    @State private var confirmWorld = false
    @State private var deletingPack: MapPack?
    @State private var switching = false
    @State private var detailPack: MapPack?
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
                Text("Apple Maps loads the areas you view from Apple servers. On-device Maps uses downloaded maps and works without internet. Your places and history stay on this iPhone.")
            }
            if !downloads.packs.isEmpty {
                Section {
                    ForEach(countryPacks) { pack in
                        VStack(alignment: .leading, spacing: Layout.compact) {
                            if pack.id != .world, !downloads.choices(pack.id).isEmpty {
                                Button { detailPack = pack } label: { packLabel(pack, opensDetail: true) }
                                    .buttonStyle(.plain).accessibilityIdentifier("map-pack-" + pack.id.rawValue)
                                    .accessibilityHint("Change map detail")
                            } else { packLabel(pack, opensDetail: false) }
                            packState(pack)
                        }.padding(.vertical, Layout.compact).buttonStyle(.borderless)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if let installed = downloads.installedPacks[pack.id] {
                                    Button(role: .destructive) { deletingPack = installed } label: { Label("Delete", systemImage: "trash") }
                                        .tint(.red)
                                }
                            }
                    }
                } header: { Text("On-device maps") } footer: {
                    Text("World gives an overview everywhere. Choose a detail level for each country. Country downloads come from Bunny and World comes from GitHub. They receive your IP address and the file you choose. Map browsing stays on this iPhone.")
                }
                Section {
                    Button { Task { await downloads.refreshCatalog(force: true) } } label: {
                        HStack { Text("Check for map updates"); Spacer(); if downloads.checkingCatalog { ProgressView() } }
                    }.disabled(downloads.checkingCatalog)
                    if let message = downloads.catalogIssue { Text(message).font(.footnote).foregroundStyle(Palette.muted) }
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
            .task(id: model.mapProvider) { if model.mapProvider == .onDevice { await downloads.refreshCatalog() } }
            .sheet(item: $detailPack) { pack in NavigationStack { MapDetailPicker(countryID: pack.id) } }
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
    private var countryPacks: [MapPack] {
        Set(downloads.packs.map(\.id)).compactMap { downloads.pack($0) }.sorted {
            if $0.id == .world || $1.id == .world { return $0.id == .world }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    private func packLabel(_ pack: MapPack, opensDetail: Bool) -> some View {
        let installed = downloads.installedPacks[pack.id]
        let displayed = installed ?? pack
        return HStack(spacing: Layout.spacing) {
            VStack(alignment: .leading, spacing: Layout.compact) {
                Text(pack.name).font(.body.weight(.semibold))
                HStack(spacing: Layout.compact) {
                    Text(displayed.sizeLabel)
                    if let detail = displayed.detail { MapDetailIndicator(detail: detail) }
                    if let date = installed?.updatedDate { Text("· Updated " + date.formatted(.relative(presentation: .named))) }
                }.font(.footnote).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 0)
            if opensDetail { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Palette.muted) }
        }.foregroundStyle(Palette.ink).frame(minHeight: Layout.touchTarget).contentShape(Rectangle())
            .accessibilityElement(children: .combine)
    }
    @ViewBuilder private func packState(_ pack: MapPack) -> some View {
        let transfer = downloads.transfers[pack.id]
        let target = transfer?.pack ?? pack
        let installed = downloads.installedPacks[pack.id]
        if transfer?.phase == .downloading {
            ProgressView(value: Double(transfer?.received ?? 0), total: Double(target.bytes))
                .accessibilityLabel("Downloading \(pack.name)")
            HStack {
                Text("\(ByteCountFormatter.string(fromByteCount: transfer?.received ?? 0, countStyle: .file)) of \(target.sizeLabel)")
                    .font(.footnote).foregroundStyle(Palette.muted)
                Spacer()
                Button("Pause") { downloads.pause(pack.id) }
            }.frame(minHeight: Layout.touchTarget)
        } else if transfer?.phase == .verifying || transfer?.phase == .pausing {
            ProgressView(transfer?.phase == .pausing ? "Pausing…" : "Checking download…").frame(minHeight: Layout.touchTarget)
        } else if let transfer, transfer.phase != .installed {
            if let message = transfer.message { Text(message).font(.footnote).foregroundStyle(Palette.muted) }
            HStack {
                MapPackDownloadButton(pack: target, title: transfer.phase == .failed ? "Retry" : "Resume", chooseDetail: false)
                Spacer()
                Button("Cancel") { downloads.cancel(pack.id) }
            }.frame(minHeight: Layout.touchTarget)
        } else if installed != nil {
            if let update = downloads.update(pack.id) {
                HStack {
                    if let date = update.updatedDate { Text("New map · " + date.formatted(.relative(presentation: .named))).font(.footnote).foregroundStyle(Palette.muted) }
                    Spacer()
                    MapPackDownloadButton(pack: update, title: "Update", chooseDetail: false)
                }.frame(minHeight: Layout.touchTarget)
            }
        } else {
            MapPackDownloadButton(pack: pack).frame(minHeight: Layout.touchTarget)
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
    var chooseDetail = true
    var accessibilityID: String?
    @State private var picker = false
    @State private var confirm = false
    @State private var loadingChoices = false
    @State private var unavailable = false
    var body: some View {
        Button(loadingChoices ? "Loading maps…" : title, systemImage: "arrow.down.circle") {
            if chooseDetail && pack.id != .world {
                loadingChoices = true
                Task {
                    if model.mapDownloads.choices(pack.id).isEmpty { await model.mapDownloads.refreshCatalog(force: true) }
                    loadingChoices = false
                    if model.mapDownloads.choices(pack.id).isEmpty { unavailable = true } else { picker = true }
                }
            }
            else if model.mapDownloads.network == .needsApproval { confirm = true }
            else { model.mapDownloads.download(pack) }
        }.accessibilityIdentifier(accessibilityID ?? ("download-map-" + pack.id.rawValue))
            .disabled(!model.mapDownloads.ready || loadingChoices)
            .sheet(isPresented: $picker) { NavigationStack { MapDetailPicker(countryID: pack.id) } }
            .alert("Country maps unavailable", isPresented: $unavailable) {
                Button("OK") {}
            } message: { Text(model.mapDownloads.catalogIssue ?? "The country maps haven’t been published yet. Your downloaded maps still work.") }
            .alert("Download \(pack.name)?", isPresented: $confirm) {
                Button("Cancel", role: .cancel) {}
                Button("Download") { model.mapDownloads.download(pack, approvedMetered: true) }
            } message: {
                Text("This connection may use mobile data or Low Data Mode. The download is \(ByteCountFormatter.string(fromByteCount: model.mapDownloads.remaining(pack), countStyle: .file)).")
            }
    }
}

/// Three dots keep storage and detail together without another line of controls.
struct MapDetailIndicator: View {
    let detail: MapDetail
    private var level: Int { switch detail { case .tiny: 1; case .normal: 2; case .extensive: 3 } }
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3) { index in
                Image(systemName: index < level ? "circle.fill" : "circle")
                    .font(.system(size: 6, weight: .semibold))
                    .foregroundStyle(index < level ? Palette.green : Palette.muted)
            }
        }.accessibilityElement(children: .ignore).accessibilityLabel(detail.title + " detail")
    }
}
