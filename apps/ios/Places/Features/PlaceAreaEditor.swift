import SwiftUI
import PlacesCore

struct PlaceAreaEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var coordinate: Coordinate?
    @State var area: PlaceArea?
    let colorIndex: Int
    let select: (PlaceArea, Coordinate, String?) -> Void
    @State private var drawing = false
    @State private var vertices: [Coordinate] = []
    @State private var selectedName: String?
    @State private var focusRequest = UUID()
    @State private var nearby = MapParkCatalog.Nearby(parks: [], available: false)
    @State private var loading = false
    @State private var query = ""
    @FocusState private var searching: Bool
    private var shownParks: [MapPark] {
        Array(nearby.parks.filter { query.isEmpty || $0.name.localizedStandardContains(query) }.prefix(30))
    }
    private var proposedArea: PlaceArea? { drawing ? (vertices.count >= 3 ? PlaceArea(vertices: vertices) : nil) : area }
    private var canSave: Bool {
        if drawing { return PlaceArea.isSimple(vertices) }
        return area?.isValid == true && coordinate != nil
    }
    private var files: [URL] {
        guard let coordinate else { return [] }
        let viewport = MapViewport(center: coordinate, latitudeSpan: 0.08, longitudeSpan: 0.12)
        let countries = OfflineMapCoverage.countries(in: viewport, available: Set(model.mapDownloads.installed.keys))
        return countries.compactMap { model.mapDownloads.installed[$0] }
    }
    var body: some View {
        ScrollViewReader { scroll in
        Form {
            if model.mapsAvailable {
                Section {
                    PlaceLocationMap(coordinate: $coordinate, radius: 100, colorIndex: colorIndex, name: selectedName ?? "Place", area: proposedArea,
                        drawing: drawing ? vertices : [], focusRequest: focusRequest,
                        onTap: { point in
                            if drawing { if vertices.count < 256 { vertices.append(point) } }
                            else if area == nil { coordinate = point }
                        })
                        .frame(height: 340).listRowInsets(EdgeInsets()).id("area-map")
                    if drawing {
                        Text("Tap around the edge to add corners. Pan or zoom to reach the rest of the area.")
                            .font(.footnote).foregroundStyle(Palette.muted)
                        HStack {
                            Button("Undo", systemImage: "arrow.uturn.backward") { if !vertices.isEmpty { vertices.removeLast() } }
                                .disabled(vertices.isEmpty).accessibilityIdentifier("undo-area-corner")
                            Spacer()
                            Text("\(vertices.count) corners").font(.footnote).foregroundStyle(Palette.muted)
                            Spacer()
                            Button("Clear") { vertices = [] }.disabled(vertices.isEmpty)
                        }
                        if vertices.count >= 3 && !canSave {
                            Text("The edges cross. Undo a corner and draw around the outside.").font(.footnote).foregroundStyle(Palette.muted)
                        }
                    } else {
                        Button("Draw an area", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                            drawing = true; vertices = []; selectedName = nil; area = nil
                        }.accessibilityIdentifier("draw-place-area")
                    }
                }
                if !drawing {
                    Section {
                        if loading { ProgressView() }
                        else if nearby.parks.isEmpty {
                            Text(nearby.available ? "No park outlines nearby. You can draw your own area."
                                : "Park outlines come with country downloads, at every detail level. Download or update this country’s map to choose a park here.")
                                .font(.subheadline).foregroundStyle(Palette.muted)
                        }
                        if !nearby.parks.isEmpty {
                            TextField("Search parks", text: $query).autocorrectionDisabled().focused($searching)
                                .accessibilityIdentifier("park-outline-search")
                            if shownParks.isEmpty { Text("No nearby parks match this name.").foregroundStyle(Palette.muted) }
                        }
                        ForEach(shownParks) { park in
                            Button {
                                area = park.area; coordinate = park.coordinate; selectedName = park.name; focusRequest = UUID()
                                searching = false
                                withAnimation { scroll.scrollTo("area-map", anchor: .top) }
                            } label: {
                                HStack {
                                    Label(park.name, systemImage: "tree")
                                    Spacer()
                                    if area == park.area { Image(systemName: "checkmark").foregroundStyle(Palette.green) }
                                    else { Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted) }
                                }.foregroundStyle(Palette.ink).frame(minHeight: Layout.touchTarget)
                            }.accessibilityIdentifier("park-outline-\(park.id)")
                        }
                        NavigationLink("Manage downloaded maps") { MapsSettings() }
                    } header: { Text("Nearby parks") } footer: {
                        Text("OpenStreetMap outlines from downloaded country maps. Your selection is saved with this place.")
                    }
                }
            } else {
                Section {
                    Text("Choose a map to draw an area or select a park outline.")
                    NavigationLink("Choose maps") { MapsSettings() }
                }
            }
        }.scrollContentBackground(.hidden).background(Palette.background).foregroundStyle(Palette.ink)
            .navigationTitle("Place area").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use area") {
                        guard let proposedArea, canSave, let point = drawing ? vertices.first : coordinate else { return }
                        select(proposedArea, point, selectedName); dismiss()
                    }.disabled(!canSave).accessibilityIdentifier("use-place-area")
                }
            }
            .task(id: files) { await loadNearby() }
            .onChange(of: coordinate) { _, _ in if area == nil && !drawing { Task { await loadNearby() } } }
        }
    }
    private func loadNearby() async {
        guard let coordinate else { return }
        loading = true
        let result = await MapParkCatalog.shared.nearby(coordinate, files: files)
        guard !Task.isCancelled else { return }
        nearby = result; loading = false
    }
}
