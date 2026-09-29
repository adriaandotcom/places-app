import SwiftUI
import PlacesCore

struct PlaceRecognitionMap: View {
    @Environment(AppModel.self) private var model
    let place: Place
    var body: some View {
        if model.mapsAvailable {
            PrivacyMapView(customPresentation: MapPresentation(place: place))
                .frame(height: Layout.mapHeight).clipShape(RoundedRectangle(cornerRadius: Layout.cardRadius))
                .accessibilityIdentifier("place-recognition-map")
        }
    }
}

/// One set of place details, whether opened from a visit or the places library.
struct PlaceDetailsContent: View {
    @Environment(AppModel.self) private var model
    let place: Place
    let memoryContext: MemoryContext
    private enum Editor: String, Identifiable { case place, wifi; var id: String { rawValue } }
    @State private var editor: Editor?
    @State private var tripIDs: [String] = []
    var body: some View {
        VStack(alignment: .leading, spacing: Layout.spacing) {
            HStack(spacing: Layout.compact) {
                SavedPlaceRow(place: place, title: "About this place", subtitle: place.name)
                Button("Edit place", systemImage: "pencil") { editor = .place }
                    .labelStyle(.iconOnly).frame(width: Layout.touchTarget, height: Layout.touchTarget)
                    .accessibilityIdentifier("edit-place-details")
            }.modifier(CardSurface())
            if !place.address.isEmpty { LabeledContent("Address", value: place.address).font(.subheadline) }
            if let locality = place.locality {
                Text([locality.city, locality.country].filter { !$0.isEmpty }.joined(separator: ", "))
                    .font(.subheadline).foregroundStyle(Palette.muted).accessibilityIdentifier("place-locality-\(place.id)")
            } else if model.placeLookupEnabled {
                if model.lookingUpRegions { ProgressView("Finding city & country…") }
                else { Button("Try location details again") { model.retryRegionLookup(for: place.id) }.accessibilityIdentifier("retry-city-lookup") }
            }
            MemorySection(context: memoryContext)
            if !tripIDs.isEmpty {
                SectionHeading(title: "Trips here")
                ForEach(model.memories.trips.filter { tripIDs.contains($0.id) }) { trip in TripLink(trip: trip) }
            }
            let points = model.accessPoints.filter { $0.placeID == place.id }
            let networks = model.networks.filter { network in points.contains { $0.networkID == network.id } || place.expectedSSIDs.contains(network.ssid) }
            let names = place.expectedSSIDs + networks.map(\.ssid).filter { !place.expectedSSIDs.contains($0) }
            SectionHeading(title: "Wi-Fi networks", actionTitle: names.isEmpty ? "Add" : "Edit", actionIdentifier: "place-edit-wifi", action: { editor = .wifi })
            if names.isEmpty { Text("No Wi-Fi networks added.").font(BrandFont.body).foregroundStyle(Palette.muted) }
            else {
                VStack(alignment: .leading, spacing: Layout.compact) {
                    ForEach(names, id: \.self) { name in
                        if name != names.first { Divider() }
                        if let network = networks.first(where: { $0.ssid == name }) {
                            NavigationLink {
                                ScrollView { WiFiClassificationPicker(network: network).padding(Layout.gutter) }
                                    .background(Palette.background).navigationTitle("Network type").navigationBarTitleDisplayMode(.inline)
                            } label: {
                                HStack {
                                    WiFiNameLabel(name: name, subtitle: place.expectedSSIDs.contains(name) ? nil : "Learned here")
                                    Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted)
                                }
                            }.buttonStyle(.plain)
                        } else { WiFiNameLabel(name: name) }
                    }
                }.modifier(CardSurface())
            }
        }.task(id: "\(place.id)-\(model.historyRevision)") { tripIDs = (try? await model.store?.tripIDs(visiting: place.id)) ?? [] }
            .sheet(item: $editor) { target in
                NavigationStack { PlaceEditor(place: place, wifiOnly: target == .wifi) }
            }
    }
}
