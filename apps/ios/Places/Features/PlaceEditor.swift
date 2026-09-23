import SwiftUI
import PlacesCore

struct PlaceEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private let original: Place?
    private let assigning: TimelineItem?
    private let onSave: (() -> Void)?
    @State private var name: String
    @State private var address: String
    @State private var latitude: String
    @State private var longitude: String
    @State private var coordinate: Coordinate?
    @State private var radius: Double
    @State private var symbol: String
    @State private var colorIndex: Int
    @State private var wifiNames: [String]
    @State private var wifiDraft = ""
    @State private var wifiError: String?
    @State private var removingWiFi: String?
    @State private var choosingIcon = false
    @State private var manualCoordinates = false
    @State private var changingLocation = false
    @State private var locationRequest = CurrentLocationRequest()
    @State private var locationError: String?
    @State private var locationSelected = false
    @State private var validation: String?
    @State private var saving = false
    @FocusState private var focusedField: Field?
    private enum Field { case name, address, latitude, longitude, wifi }
    private var usesCoordinates: Bool { !model.mapsEnabled && (manualCoordinates || model.mapsChoiceMade) }

    init(place: Place? = nil, suggestedName: String = "", coordinate: Coordinate? = nil,
         assigning: TimelineItem? = nil, onSave: (() -> Void)? = nil) {
        original = place
        self.assigning = assigning
        self.onSave = onSave
        let point = place?.coordinate ?? coordinate
        _name = State(initialValue: place?.name ?? suggestedName)
        _address = State(initialValue: place?.address ?? "")
        _latitude = State(initialValue: point.map { String($0.latitude) } ?? "")
        _longitude = State(initialValue: point.map { String($0.longitude) } ?? "")
        _coordinate = State(initialValue: point)
        _radius = State(initialValue: place?.radius ?? 100)
        _symbol = State(initialValue: place?.symbol ?? (suggestedName == "Home" ? "house.fill" : suggestedName == "Work" ? "briefcase.fill" : "mappin"))
        _colorIndex = State(initialValue: place?.colorIndex ?? (suggestedName == "Work" ? 1 : 0))
        _wifiNames = State(initialValue: place?.expectedSSIDs ?? [])
    }

    var body: some View {
        Form {
            Section("Place") {
                TextField("Name", text: $name).accessibilityIdentifier("place-name").focused($focusedField, equals: .name)
                TextField("Address (optional)", text: $address).focused($focusedField, equals: .address)
                Button { choosingIcon = true } label: {
                    HStack(spacing: Layout.spacing) {
                        PlaceIcon(symbol: symbol, colorIndex: colorIndex)
                        Text(PlaceIconCatalog.title(for: symbol)).foregroundStyle(Palette.ink)
                        Spacer()
                        Text("Change icon").font(.subheadline)
                        Image(systemName: "chevron.right").font(.caption)
                    }.frame(minHeight: Layout.touchTarget)
                }.accessibilityIdentifier("choose-place-icon")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Layout.compact) {
                        ForEach(0..<Palette.accents.count, id: \.self) { index in
                            Button { colorIndex = index } label: {
                                Circle().fill(Palette.accent(index)).frame(width: 30, height: 30)
                                    .overlay { if colorIndex == index { Image(systemName: "checkmark").foregroundStyle(.white).bold() } }
                                    .frame(width: Layout.touchTarget, height: Layout.touchTarget)
                            }.buttonStyle(.plain).accessibilityLabel("Colour \(index + 1)")
                                .accessibilityAddTraits(index == colorIndex ? .isSelected : [])
                        }
                    }
                }
            }
            Section("Location") {
                if assigning != nil && coordinate != nil && !changingLocation {
                    HStack {
                        Label("Using this visit’s location", systemImage: "mappin.circle.fill")
                        Spacer()
                        Button("Change") { changingLocation = true }
                            .accessibilityLabel("Change this place’s location")
                    }
                } else {
                    if model.mapsEnabled {
                        PlaceLocationMap(coordinate: $coordinate, radius: radius, colorIndex: colorIndex)
                            .frame(height: Layout.mapHeight).listRowInsets(EdgeInsets())
                        Label(coordinate == nil ? "Tap the map to place your pin" : "Tap the map to move your pin", systemImage: "hand.tap")
                            .font(.subheadline).foregroundStyle(Palette.muted)
                    } else if !usesCoordinates {
                        VStack(alignment: .leading, spacing: Layout.spacing) {
                            Text("Choose your place on a map").font(BrandFont.title)
                            Text("Apple Maps requests map data from Apple for the area you view.").font(.subheadline).foregroundStyle(Palette.muted)
                            Button("Use Apple Maps") { Task { await model.setMapsEnabled(true) } }
                                .buttonStyle(.borderedProminent).tint(Palette.controlGreen).foregroundStyle(.white).accessibilityIdentifier("editor-enable-maps")
                            Button("Enter coordinates instead") {
                                manualCoordinates = true
                                Task { await model.setMapsEnabled(false) }
                            }.accessibilityIdentifier("enter-coordinates")
                        }.padding(.vertical, Layout.compact)
                    }
                    Button { useCurrentLocation() } label: {
                        HStack(spacing: Layout.compact) {
                            if locationRequest.isRequesting { ProgressView() }
                            else { Image(systemName: "location.fill") }
                            Text(locationRequest.isRequesting ? "Finding your location…" : "Use my current location")
                        }.frame(minHeight: Layout.touchTarget)
                    }.disabled(locationRequest.isRequesting).accessibilityIdentifier("use-current-location")
                    if let locationError {
                        InlineNotice(title: "Location unavailable", message: locationError, isError: true)
                            .listRowInsets(EdgeInsets()).accessibilityIdentifier("current-location-error")
                        if locationRequest.needsSettings {
                            Button("Open location settings") { model.tracking.openSettings() }
                        }
                    } else if locationSelected {
                        Label("Current location selected", systemImage: "checkmark.circle.fill")
                            .font(.subheadline).foregroundStyle(Palette.green)
                    }
                    if usesCoordinates {
                        TextField("Latitude", text: $latitude).keyboardType(.numbersAndPunctuation)
                            .accessibilityIdentifier("place-latitude").focused($focusedField, equals: .latitude)
                        TextField("Longitude", text: $longitude).keyboardType(.numbersAndPunctuation)
                            .accessibilityIdentifier("place-longitude").focused($focusedField, equals: .longitude)
                    }
                    if model.mapsEnabled || usesCoordinates {
                        HStack { Text("Recognition radius"); Spacer(); Text("\(Int(radius)) m").foregroundStyle(Palette.muted) }
                        Slider(value: $radius, in: 50...1000, step: 25).accessibilityLabel("Recognition radius in metres")
                    }
                }
            }
            Section {
                ForEach(wifiNames, id: \.self) { ssid in
                    HStack {
                        Label(ssid, systemImage: "wifi").foregroundStyle(Palette.ink)
                        Spacer()
                        Button("Remove Wi-Fi", systemImage: "minus.circle") { removingWiFi = ssid }
                            .labelStyle(.iconOnly).foregroundStyle(Palette.muted)
                            .frame(minWidth: Layout.touchTarget, minHeight: Layout.touchTarget)
                    }.swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Remove", systemImage: "trash") { removingWiFi = ssid }.tint(.red)
                    }
                }
                HStack {
                    TextField("Network name", text: $wifiDraft).autocorrectionDisabled().textInputAutocapitalization(.never)
                        .focused($focusedField, equals: .wifi).submitLabel(.done).onSubmit(addWiFi)
                        .accessibilityIdentifier("wifi-name")
                    Button("Add", systemImage: "plus.circle.fill", action: addWiFi)
                        .labelStyle(.iconOnly).frame(minWidth: Layout.touchTarget, minHeight: Layout.touchTarget)
                        .accessibilityLabel("Add Wi-Fi name").accessibilityIdentifier("add-wifi")
                }
                if let wifiError { Text(wifiError).font(.footnote).foregroundStyle(.red) }
                if let ssid = model.tracking.currentSSID, !wifiNames.contains(ssid) {
                    Button("Add connected Wi-Fi", systemImage: "wifi.badge.plus") { wifiNames.append(ssid); wifiError = nil }
                }
            } header: { Text("Wi-Fi networks (optional)") } footer: {
                Text("Add the networks you use here.")
            }
        }.scrollContentBackground(.hidden).background(Palette.background).foregroundStyle(Palette.ink)
            .navigationTitle(original != nil ? "Edit place" : assigning != nil ? "Name this place" : "Add a place").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) { Button(saving ? "Saving…" : "Save", action: save).disabled(saving).accessibilityIdentifier("save-place") }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { focusedField = nil }.accessibilityIdentifier("dismiss-keyboard") }
            }
            .interactiveDismissDisabled(saving)
            .sheet(isPresented: $choosingIcon) { NavigationStack { PlaceIconPicker(selection: $symbol, colorIndex: colorIndex) } }
            .confirmationDialog("Remove this Wi-Fi name?", isPresented: Binding(get: { removingWiFi != nil }, set: { if !$0 { removingWiFi = nil } }), titleVisibility: .visible) {
                Button("Remove Wi-Fi name", role: .destructive) {
                    if let removingWiFi { wifiNames.removeAll { $0 == removingWiFi } }
                    removingWiFi = nil
                }
            } message: { Text("It will be removed from this place when you save. Recorded history stays intact.") }
            .alert("Couldn’t save this place", isPresented: Binding(get: { validation != nil }, set: { if !$0 { validation = nil } })) {
                Button("OK") { validation = nil }
            } message: { Text(validation ?? "") }
            .onChange(of: coordinate) { _, value in
                if let value { latitude = String(value.latitude); longitude = String(value.longitude); locationError = nil }
            }
            .onDisappear { locationRequest.cancel() }
    }
    private func useCurrentLocation() {
        focusedField = nil; locationError = nil
        Task {
            do {
                let location = try await locationRequest.request()
                coordinate = Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
                locationSelected = true
            } catch is CancellationError { }
            catch { locationError = error.localizedDescription }
        }
    }
    private func addWiFi() {
        let value = wifiDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { wifiError = "Enter a Wi-Fi name first."; return }
        guard !value.contains("\n"), value.utf8.count <= 32 else { wifiError = "This doesn’t look like a Wi-Fi name. Check the name in Wi-Fi settings."; return }
        guard !wifiNames.contains(value) else { wifiError = "This network is already added."; return }
        wifiNames.append(value); wifiDraft = ""; wifiError = nil
    }
    private func save() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            focusedField = .name; validation = "Give this place a name."; return
        }
        var point = coordinate
        if usesCoordinates {
            if let lat = Double(latitude.replacingOccurrences(of: ",", with: ".")),
               let lon = Double(longitude.replacingOccurrences(of: ",", with: ".")) { point = Coordinate(latitude: lat, longitude: lon) }
            else { point = nil }
        }
        guard let point, point.isValid else {
            validation = usesCoordinates ? "Enter latitude from −90 to 90 and longitude from −180 to 180, or use your current location."
                : "Choose a location on the map or use your current location."; return
        }
        if !wifiDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            addWiFi()
            guard wifiError == nil else { focusedField = .wifi; return }
        }
        let place = Place(id: original?.id ?? UUID().uuidString, name: name.trimmingCharacters(in: .whitespacesAndNewlines), address: address,
            coordinate: point, radius: radius, symbol: symbol, colorIndex: colorIndex,
            expectedSSIDs: wifiNames, createdAt: original?.createdAt ?? Date())
        saving = true; focusedField = nil
        Task {
            if await model.save(place, assigning: assigning) {
                if let onSave { onSave() } else { dismiss() }
            }
            saving = false
        }
    }
}
