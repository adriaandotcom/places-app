import SwiftUI
import PlacesCore

struct MapDetailPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let countryID: MapPack.ID
    @State private var selection = MapDetail.normal
    private var choices: [MapPack] { model.mapDownloads.choices(countryID) }
    private var selected: MapPack? { choices.first { $0.detail == selection } }

    var body: some View {
        ScrollView {
            VStack(spacing: Layout.spacing) {
                ForEach(choices, id: \.detail) { pack in
                    if let detail = pack.detail {
                        Button { selection = detail } label: {
                            VStack(alignment: .leading, spacing: 0) {
                                MapDetailPreview(detail: detail).frame(height: 112).allowsHitTesting(false).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: Layout.compact) {
                                    HStack {
                                        Text(detail.title).font(BrandFont.title)
                                        Spacer()
                                        MapDetailIndicator(detail: detail)
                                        Text(pack.sizeLabel).font(.subheadline)
                                        Image(systemName: selection == detail ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(selection == detail ? Palette.green : Palette.muted)
                                    }
                                    Text(detail.summary).font(.subheadline).foregroundStyle(Palette.muted)
                                }.padding(Layout.spacing)
                            }.foregroundStyle(Palette.ink).background(Palette.paper)
                                .clipShape(RoundedRectangle(cornerRadius: Layout.cardRadius))
                                .overlay(RoundedRectangle(cornerRadius: Layout.cardRadius).stroke(selection == detail ? Palette.green : Palette.line, lineWidth: selection == detail ? 2 : 1))
                        }.buttonStyle(.plain).accessibilityIdentifier("map-detail-" + detail.rawValue)
                            .accessibilityAddTraits(selection == detail ? .isSelected : [])
                    }
                }
                Text("Amsterdam previews · © OpenStreetMap contributors · Natural Earth · Protomaps")
                    .font(.caption).foregroundStyle(Palette.muted)
            }.padding(Layout.gutter)
        }.background(Palette.background)
            .navigationTitle(choices.first?.name ?? "Map detail").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                if let selected {
                    if model.mapDownloads.installedPacks[countryID] == selected {
                        Button("Done") { dismiss() }.buttonStyle(PrimaryButton()).padding(Layout.gutter).background(Palette.background)
                    } else {
                        MapPackDownloadButton(pack: selected, title: "Download · " + selected.sizeLabel, chooseDetail: false, accessibilityID: "download-selected-map")
                            .buttonStyle(PrimaryButton()).padding(Layout.gutter).background(Palette.background)
                    }
                }
            }
            .onAppear { selection = model.mapDownloads.installedPacks[countryID]?.detail ?? .normal }
            .onChange(of: model.mapDownloads.pending) { _, pending in if pending.contains(countryID) { dismiss() } }
    }
}

// The same renderer, style and local glyphs as the map tab, with three real
// extracts of the same Amsterdam viewport. No snapshot service or network.
struct MapDetailPreview: View {
    let detail: MapDetail
    @State private var viewport: MapViewport? = MapViewport(
        center: Coordinate(latitude: 52.3770, longitude: 4.8995), latitudeSpan: 0.0018, longitudeSpan: 0.006)
    var body: some View {
        let file = OfflineMapStyle.resourceRoot.appendingPathComponent("Previews/amsterdam-" + detail.rawValue + ".pmtiles")
        OfflineMapSurface(presentation: MapPresentation(items: [], routePoints: [], places: []), installed: [.netherlands: file],
            viewport: $viewport, focusRequest: nil, chromeInsets: EdgeInsets(), pinChanged: nil,
            selected: { _ in }, settled: { _, _ in }, failed: {}, interactive: false)
    }
}
