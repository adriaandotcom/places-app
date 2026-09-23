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

struct PlaceEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private let original: Place?
    @State private var name: String
    @State private var address: String
    @State private var latitude: String
    @State private var longitude: String
    @State private var radius: Double
    @State private var symbol: String
    @State private var colorIndex: Int
    @State private var wifiText: String
    @State private var validation: String?
    @State private var saving = false
    private let symbols = ["house.fill", "briefcase.fill", "cup.and.saucer.fill", "fork.knife", "leaf.fill", "heart.fill", "dumbbell.fill", "mappin"]

    init(place: Place? = nil, suggestedName: String = "", coordinate: Coordinate? = nil) {
        original = place
        _name = State(initialValue: place?.name ?? suggestedName)
        _address = State(initialValue: place?.address ?? "")
        _latitude = State(initialValue: (place?.coordinate ?? coordinate).map { String($0.latitude) } ?? "")
        _longitude = State(initialValue: (place?.coordinate ?? coordinate).map { String($0.longitude) } ?? "")
        _radius = State(initialValue: place?.radius ?? 100)
        _symbol = State(initialValue: place?.symbol ?? (suggestedName == "Home" ? "house.fill" : suggestedName == "Work" ? "briefcase.fill" : "mappin"))
        _colorIndex = State(initialValue: place?.colorIndex ?? 0)
        _wifiText = State(initialValue: place?.expectedSSIDs.joined(separator: "\n") ?? "")
    }
    var body: some View {
        Form {
            Section("Place") {
                TextField("Name", text: $name).accessibilityIdentifier("place-name")
                TextField("Address (optional)", text: $address)
                HStack(spacing: 14) {
                    ForEach(0..<Palette.accents.count, id: \.self) { index in
                        Button { colorIndex = index } label: {
                            Circle().fill(Palette.accent(index)).frame(width: 30, height: 30)
                                .overlay { if colorIndex == index { Image(systemName: "checkmark").foregroundStyle(.white).bold() } }
                                .frame(minWidth: 44, minHeight: 44)
                        }.buttonStyle(.plain).accessibilityLabel("Colour \(index + 1)").accessibilityAddTraits(index == colorIndex ? .isSelected : [])
                    }
                }.horizontalScrollIfNeeded()
                Picker("Icon", selection: $symbol) { ForEach(symbols, id: \.self) { value in Label(value.replacingOccurrences(of: ".fill", with: ""), systemImage: value).tag(value) } }
            }
            Section {
                Button("Use my current location", systemImage: "location") { useCurrentLocation() }
                TextField("Latitude", text: $latitude).keyboardType(.numbersAndPunctuation).accessibilityIdentifier("place-latitude")
                TextField("Longitude", text: $longitude).keyboardType(.numbersAndPunctuation).accessibilityIdentifier("place-longitude")
                HStack { Text("Radius"); Spacer(); Text("\(Int(radius)) m").foregroundStyle(.secondary) }
                Slider(value: $radius, in: 50...1000, step: 25).accessibilityLabel("Recognition radius in metres")
            } header: { Text("Location") } footer: {
                Text("Enter coordinates or use a recent fix. Address text is a label and is never sent to a lookup service.")
            }
            Section {
                TextField("One Wi-Fi name per line", text: $wifiText, axis: .vertical).lineLimit(3...6).autocorrectionDisabled().textInputAutocapitalization(.never)
                if let ssid = model.tracking.currentSSID {
                    Button("Add connected Wi-Fi") {
                        var names = wifiText.split(separator: "\n").map(String.init)
                        if !names.contains(ssid) { names.append(ssid); wifiText = names.joined(separator: "\n") }
                    }
                }
            } header: { Text("Expected Wi-Fi names (optional)") } footer: {
                Text("A name alone does not prove a location. Access points are learned when connected Wi-Fi and geography agree.")
            }
            if let validation { Section { Text(validation).foregroundStyle(.red).accessibilityIdentifier("place-validation") } }
        }.scrollContentBackground(.hidden).background(Palette.background).navigationTitle(original == nil ? "Add a place" : "Edit place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(saving ? "Saving…" : "Save") { save() }.disabled(saving).accessibilityIdentifier("save-place") }
            }
    }
    private func useCurrentLocation() {
        guard let location = model.tracking.currentLocation, Date().timeIntervalSince(location.timestamp) < 120,
              location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 250 else {
            validation = "A recent location is not available yet. Enable location access, wait for a fix, or enter coordinates manually."
            return
        }
        latitude = String(location.coordinate.latitude); longitude = String(location.coordinate.longitude); validation = nil
    }
    private func save() {
        guard let lat = Double(latitude.replacingOccurrences(of: ",", with: ".")),
              let lon = Double(longitude.replacingOccurrences(of: ",", with: ".")),
              Coordinate(latitude: lat, longitude: lon).isValid, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            validation = "Enter a name and valid latitude (−90 to 90) and longitude (−180 to 180)."; return
        }
        var uniqueNames: [String] = []
        for line in wifiText.split(separator: "\n") {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty && !uniqueNames.contains(value) { uniqueNames.append(value) }
        }
        let place = Place(id: original?.id ?? UUID().uuidString, name: name.trimmingCharacters(in: .whitespacesAndNewlines), address: address,
            coordinate: Coordinate(latitude: lat, longitude: lon), radius: radius, symbol: symbol, colorIndex: colorIndex,
            expectedSSIDs: uniqueNames, createdAt: original?.createdAt ?? Date())
        saving = true
        Task { if await model.save(place) { dismiss() }; saving = false }
    }
}

struct WiFiClassificationPicker: View {
    @Environment(AppModel.self) private var model
    let network: WiFiNetwork
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(network.ssid, systemImage: "wifi").font(BrandFont.title)
            Picker("Network type", selection: Binding(get: {
                model.networks.first { $0.id == network.id }?.classification ?? network.classification
            }, set: { value in Task { await model.classify(network, as: value) } })) {
                ForEach(WiFiClassification.allCases, id: \.self) { value in Text(value.rawValue.capitalized).tag(value) }
            }.pickerStyle(.menu)
            Text("Portable and ignored networks never identify a fixed place. Shared names need a matching access point and geography.")
                .font(.caption).foregroundStyle(Palette.muted)
        }.padding(Layout.spacing).background(Palette.paper, in: RoundedRectangle(cornerRadius: 20))
    }
}

private extension View {
    func horizontalScrollIfNeeded() -> some View { ScrollView(.horizontal, showsIndicators: false) { self } }
}
