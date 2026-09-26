import SwiftUI
import PlacesCore

struct PlacesView: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Your places").font(BrandFont.hero)
                Text("Familiar corners of your world.").font(BrandFont.body).foregroundStyle(Palette.muted)
                if model.places.isEmpty {
                    EmptyHistory(symbol: "mappin.and.ellipse", title: "Start with somewhere familiar", message: "Add home, work, or a favourite stop. A name and a location are all you need.")
                    Button("Add a place") { adding = true }.buttonStyle(PrimaryButton())
                }
                ForEach(model.places) { place in
                    NavigationLink { PlaceDetail(placeID: place.id) } label: {
                        InfoRow(symbol: place.symbol, title: place.name, subtitle: place.address.isEmpty ? "Saved place" : place.address, colorIndex: place.colorIndex)
                    }.buttonStyle(.plain)
                }
            }.padding(Layout.gutter)
        }.background(Palette.background).foregroundStyle(Palette.ink).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Add place", systemImage: "plus") { adding = true }.accessibilityIdentifier("add-place") }
            }
            .sheet(isPresented: $adding) { NavigationStack { PlaceEditor() } }
    }
}

struct PlaceDetail: View {
    @Environment(AppModel.self) private var model
    let placeID: String
    @State private var editing = false
    private var place: Place? { model.places.first { $0.id == placeID } }
    var body: some View {
        ScrollView {
            if let place {
                VStack(alignment: .leading, spacing: 22) {
                    PlaceIcon(symbol: place.symbol, colorIndex: place.colorIndex, size: 72).padding(.vertical, 12)
                    Text(place.name).font(BrandFont.hero)
                    if !place.address.isEmpty { Text(place.address).font(BrandFont.body).foregroundStyle(Palette.muted) }
                    if let locality = place.locality {
                        Text([locality.city, locality.country].filter { !$0.isEmpty }.joined(separator: ", "))
                            .font(BrandFont.body).foregroundStyle(Palette.muted)
                            .accessibilityIdentifier("place-locality-\(place.id)")
                    } else if model.placeLookupEnabled {
                        if model.lookingUpRegions {
                            ProgressView("Finding city & country…")
                        } else {
                            VStack(alignment: .leading, spacing: Layout.compact) {
                                Text(model.regionLookupIssues[place.id] ?? "City and country haven’t been found yet.")
                                    .font(.footnote).foregroundStyle(Palette.muted)
                                Button("Try location details again") { model.retryRegionLookup(for: place.id) }
                                    .frame(minHeight: Layout.touchTarget).accessibilityIdentifier("retry-city-lookup")
                            }
                        }
                    }
                    InfoRow(symbol: "scope", title: "Recognition area", subtitle: "Within \(Int(place.radius)) metres, when the evidence is clear.", colorIndex: place.colorIndex)
                    Text("Wi-Fi at this place").font(BrandFont.heading)
                    let points = model.accessPoints.filter { $0.placeID == placeID }
                    let networks = model.networks.filter { network in points.contains { $0.networkID == network.id } || place.expectedSSIDs.contains(network.ssid) }
                    if networks.isEmpty { Text("No networks learned yet. You can add expected Wi-Fi names when editing this place.").font(BrandFont.body).foregroundStyle(Palette.muted) }
                    ForEach(networks) { network in WiFiClassificationPicker(network: network) }
                    Text("Coordinates are stored locally. Changing a place re-evaluates observations, while preserving your timeline corrections.").font(.footnote).foregroundStyle(Palette.muted)
                    Button("Edit place") { editing = true }.buttonStyle(PrimaryButton())
                }.padding(Layout.gutter)
            }
        }.background(Palette.background).foregroundStyle(Palette.ink).navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $editing) { if let place { NavigationStack { PlaceEditor(place: place) } } }
    }
}
