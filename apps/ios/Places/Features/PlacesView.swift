import SwiftUI
import PlacesCore

struct PlacesView: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false
    @State private var addingTrip = false
    @State private var addingPerson = false
    var body: some View {
        @Bindable var model = model
        let section = model.librarySection
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Your \(section.lowercased())").font(BrandFont.hero)
                Picker("Browse", selection: $model.librarySection) {
                    Text("Places").tag("Places")
                    Text("Trips").tag("Trips")
                    Text("People").tag("People")
                }.pickerStyle(.segmented).accessibilityIdentifier("places-collection")
                if section == "Trips" { TripsList() }
                else if section == "People" { PeopleList() }
                else {
                if model.places.isEmpty {
                    EmptyState(symbol: "mappin.and.ellipse", title: "Start with somewhere familiar", message: "Add home, work, or a favourite stop. A name and a location are all you need.", actionTitle: "Add a place", action: { adding = true })
                }
                ForEach(model.places) { place in
                    NavigationLink { PlaceDetail(placeID: place.id) } label: {
                        SavedPlaceRow(place: place, card: true)
                    }.buttonStyle(.plain)
                }
                }
            }.padding(Layout.gutter)
        }.modifier(MainNavigationClearance()).background(Palette.background).foregroundStyle(Palette.ink).navigationBarTitleDisplayMode(.inline)
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
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let placeID: String
    private var place: Place? { model.places.first { $0.id == placeID || ($0.mergedPlaceIDs ?? []).contains(placeID) } }
    var body: some View {
        ScrollView {
            if let place {
                VStack(alignment: .leading, spacing: Layout.spacing) {
                    HStack(spacing: Layout.spacing) {
                        PlaceIcon(symbol: place.symbol, colorIndex: place.colorIndex, customColorHex: place.customColorHex)
                        Text(place.name).font(BrandFont.heading)
                    }
                    PlaceRecognitionMap(place: place)
                    PlaceDetailsContent(place: place, memoryContext: .place(place))
                }.padding(Layout.gutter)
            }
        }.modifier(MainNavigationClearance()).background(Palette.background).foregroundStyle(Palette.ink)
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: place == nil) { _, missing in if missing { dismiss() } }
    }
}
