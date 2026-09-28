import SwiftUI
import PlacesCore

struct PlacesView: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false
    @State private var section = "Places"
    @State private var addingTrip = false
    @State private var addingPerson = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Your \(section.lowercased())").font(BrandFont.hero)
                Picker("Browse", selection: $section) {
                    Text("Places").tag("Places")
                    Text("Trips").tag("Trips")
                    Text("People").tag("People")
                }.pickerStyle(.segmented).accessibilityIdentifier("places-collection")
                if section == "Trips" { TripsList() }
                else if section == "People" { PeopleList() }
                else {
                if model.places.isEmpty {
                    EmptyHistory(symbol: "mappin.and.ellipse", title: "Start with somewhere familiar", message: "Add home, work, or a favourite stop. A name and a location are all you need.")
                    Button("Add a place") { adding = true }.buttonStyle(PrimaryButton())
                }
                ForEach(model.places) { place in
                    NavigationLink { PlaceDetail(placeID: place.id) } label: {
                        InfoRow(symbol: place.symbol, title: place.name, subtitle: place.address.isEmpty ? "Saved place" : place.address, colorIndex: place.colorIndex)
                    }.buttonStyle(.plain)
                }
                }
            }.padding(Layout.gutter)
        }.background(Palette.background).foregroundStyle(Palette.ink).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if section == "Places" { Button("Add place", systemImage: "plus") { adding = true }.accessibilityIdentifier("add-place") }
                    else if section == "Trips" { Button("Add trip", systemImage: "plus") { addingTrip = true }.accessibilityIdentifier("add-trip") }
                    else { Button("Add person", systemImage: "plus") { addingPerson = true }.accessibilityIdentifier("add-person") }
                }
            }
            .sheet(isPresented: $adding) { NavigationStack { PlaceEditor() } }
            .sheet(isPresented: $addingTrip) { NavigationStack { TripEditor() } }
            .sheet(isPresented: $addingPerson) { NavigationStack { PersonEditor() } }
    }
}

struct PlaceDetail: View {
    @Environment(AppModel.self) private var model
    let placeID: String
    private enum Editor: String, Identifiable {
        case place, wifi
        var id: String { rawValue }
    }
    @State private var editor: Editor?
    @State private var tripIDs: [String] = []
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
                    if !tripIDs.isEmpty {
                        Text("Trips here").font(BrandFont.heading)
                        ForEach(model.memories.trips.filter { tripIDs.contains($0.id) }) { trip in TripLink(trip: trip) }
                    }
                    MemorySection(context: .place(place))
                    InfoRow(symbol: "scope", title: "Recognition area", subtitle: "Within \(Int(place.radius)) metres, when the evidence is clear.", colorIndex: place.colorIndex)
                    let points = model.accessPoints.filter { $0.placeID == placeID }
                    let networks = model.networks.filter { network in points.contains { $0.networkID == network.id } || place.expectedSSIDs.contains(network.ssid) }
                    let names = place.expectedSSIDs + networks.map(\.ssid).filter { !place.expectedSSIDs.contains($0) }
                    HStack {
                        Text("Wi-Fi networks").font(BrandFont.heading)
                        Spacer()
                        Button(names.isEmpty ? "Add" : "Edit") { editor = .wifi }
                            .frame(minWidth: Layout.touchTarget, minHeight: Layout.touchTarget)
                            .foregroundStyle(Palette.green)
                            .accessibilityLabel("Edit Wi-Fi networks").accessibilityIdentifier("place-edit-wifi")
                    }
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
                                        HStack { WiFiNameLabel(name: name, subtitle: place.expectedSSIDs.contains(name) ? nil : "Learned here"); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted) }
                                    }.buttonStyle(.plain)
                                } else { WiFiNameLabel(name: name) }
                            }
                        }.padding(Layout.spacing).background(Palette.paper, in: RoundedRectangle(cornerRadius: Layout.cardRadius))
                    }
                    Text("Coordinates are stored locally. Changing a place re-evaluates observations, while preserving your timeline corrections.").font(.footnote).foregroundStyle(Palette.muted)
                    Button("Edit place") { editor = .place }.buttonStyle(PrimaryButton())
                }.padding(Layout.gutter)
            }
        }.background(Palette.background).foregroundStyle(Palette.ink).navigationBarTitleDisplayMode(.inline)
            .task(id: model.historyRevision) { tripIDs = (try? await model.store?.tripIDs(visiting: placeID)) ?? [] }
            .sheet(item: $editor) { target in
                if let place { NavigationStack { PlaceEditor(place: place, wifiOnly: target == .wifi) } }
            }
    }
}
