import SwiftUI
import PlacesCore

struct PlaceEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private let original: Place?
    private let assigning: TimelineItem?
    private let onSave: (() -> Void)?
    @State private var name: String
    @State private var city: String
    @State private var country: String
    @State private var address: String
    @State private var latitude: String
    @State private var longitude: String
    @State private var coordinate: Coordinate?
    @State private var radius: Double
    @State private var symbol: String
    @State private var userChoseIcon: Bool
    @State private var colorIndex: Int
    @State private var wifiNames: [String]
    @State private var wifiDraft = ""
    @State private var wifiError: String?
    @State private var removingWiFi: String?
    @State private var choosingWiFi = false
    @State private var enteringWiFiAfterPicker = false
    @State private var wifiSuggestions: [WiFiSuggestion] = []
    @State private var wifiSuggestionsUnavailable = false
    @State private var choosingIcon = false
    @State private var choosingCatalog = false
    @State private var catalogReference: PlaceCatalogReference?
    @State private var catalogCategory: String?
    @State private var catalogName: String?
    @State private var nearbyPlaces: [CatalogPlace] = []
    @State private var recentSearchAnchor: Coordinate?
    private var searchAnchor: Coordinate? { coordinate ?? recentSearchAnchor }
    @State private var catalogMessage: String?
    @State private var existingSuggestion: Place?
    @State private var pendingSavedSuggestion: Place?
    @State private var manualCoordinates = false
    @State private var changingLocation = false
    @State private var locationRequest = CurrentLocationRequest()
    @State private var locationError: String?
    @State private var locationSelected = false
    @State private var validation: String?
    @State private var saving = false
    @FocusState private var focusedField: Field?
    private enum Field { case name, address, latitude, longitude, wifi }
    private var usesCoordinates: Bool { !model.mapsAvailable && (manualCoordinates || model.mapsChoiceMade) }
    private var wifiCoordinate: Coordinate? {
        if usesCoordinates {
            guard let lat = Double(latitude), let lon = Double(longitude) else { return nil }
            let value = Coordinate(latitude: lat, longitude: lon)
            return value.isValid ? value : nil
        }
        return coordinate
    }
    private var availableWiFi: [WiFiSuggestion] { wifiSuggestions.filter { !wifiNames.contains($0.ssid) } }
    private var wifiQuery: WiFiSuggestionQuery {
        WiFiSuggestionQuery(coordinate: wifiCoordinate, radius: radius,
                            connectionID: model.tracking.currentWiFiObservation?.id, revision: model.historyRevision)
    }

    init(place: Place? = nil, suggestedName: String = "", coordinate: Coordinate? = nil,
         assigning: TimelineItem? = nil, suggestion: CatalogPlace? = nil, onSave: (() -> Void)? = nil) {
        original = place
        self.assigning = assigning
        self.onSave = onSave
        let point = place?.coordinate ?? suggestion?.coordinate ?? coordinate
        _name = State(initialValue: place?.name ?? suggestion?.name ?? suggestedName)
        _city = State(initialValue: place?.locality?.city ?? "")
        _country = State(initialValue: place?.locality?.country ?? "")
        _address = State(initialValue: place?.address ?? suggestion?.address ?? "")
        _latitude = State(initialValue: point.map { String($0.latitude) } ?? "")
        _longitude = State(initialValue: point.map { String($0.longitude) } ?? "")
        _coordinate = State(initialValue: point)
        _radius = State(initialValue: place?.radius ?? 100)
        _symbol = State(initialValue: place?.symbol ?? suggestion?.symbol ?? PlaceIconMatcher.suggestedSymbol(name: suggestedName) ?? "mappin")
        _userChoseIcon = State(initialValue: place != nil)
        _colorIndex = State(initialValue: place?.colorIndex ?? (suggestedName == "Work" ? 1 : 0))
        _wifiNames = State(initialValue: place?.expectedSSIDs ?? [])
        _catalogReference = State(initialValue: place?.catalogReference ?? suggestion?.reference)
        _catalogCategory = State(initialValue: suggestion?.category)
        _catalogName = State(initialValue: suggestion?.name)
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Name", text: $name).accessibilityIdentifier("place-name").focused($focusedField, equals: .name)
            }
            if let catalogReference, let saved = catalogReference.savedPlace(in: model.places), saved.id != original?.id {
                Section {
                    Button("Use saved place: \(saved.name)") { useSavedPlace(saved) }
                        .accessibilityIdentifier("reuse-suggested-place")
                }
            }
            if assigning != nil && !model.places.isEmpty {
                Section {
                    NavigationLink {
                        SavedPlacePicker(anchor: assigning?.coordinate, select: useSavedPlace)
                    } label: {
                        Label("Use a saved place", systemImage: "mappin.and.ellipse")
                            .frame(minHeight: Layout.touchTarget)
                    }.accessibilityIdentifier("choose-saved-place")
                }
            }
            Section {
                Button("Find a place", systemImage: "magnifyingglass") { choosingCatalog = true }
                    .accessibilityIdentifier("find-catalog-place")
                if original == nil && catalogReference == nil {
                    ForEach(nearbyPlaces) { candidate in
                        Button { selectCatalog(candidate) } label: {
                            CatalogPlaceRow(place: candidate, anchor: searchAnchor,
                                saved: candidate.reference.savedPlace(in: model.places) != nil, compact: true)
                        }.accessibilityIdentifier("nearby-catalog-\(candidate.id)")
                    }
                    if let catalogMessage { Text(catalogMessage).font(.footnote).foregroundStyle(Palette.muted) }
                }
            } header: {
                HStack {
                    Text(original == nil && searchAnchor != nil ? "Nearby suggestions" : "Offline suggestions")
                    Spacer()
                    OfflineSuggestionsInfoButton()
                }
            }
            Section("Details") {
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
            Section {
                DisclosureGroup("City & country") {
                    TextField("City (optional)", text: $city).accessibilityIdentifier("place-city")
                    TextField("Country (optional)", text: $country).accessibilityIdentifier("place-country")
                    NavigationLink("Apple Location Details…") { CityLookupSettings() }
                }
            }
            Section("Location") {
                if (assigning != nil || catalogReference != nil) && coordinate != nil && !changingLocation {
                    HStack {
                        Label(catalogReference == nil ? "Using this visit’s location" : "Using the suggested location", systemImage: "mappin.circle.fill")
                        Spacer()
                        Button("Change") { changingLocation = true }
                            .accessibilityLabel("Change this place’s location")
                    }
                } else {
                    if model.mapsAvailable {
                        PlaceLocationMap(coordinate: $coordinate, radius: radius, colorIndex: colorIndex)
                            .frame(height: Layout.mapHeight).listRowInsets(EdgeInsets())
                        Label(coordinate == nil ? "Tap the map to place your pin" : "Tap the map to move your pin", systemImage: "hand.tap")
                            .font(.subheadline).foregroundStyle(Palette.muted)
                    } else if !usesCoordinates {
                        VStack(alignment: .leading, spacing: Layout.spacing) {
                            Text("Choose your place on a map").font(BrandFont.title)
                            Text("Choose Apple Maps or download maps for use on this iPhone.").font(.subheadline).foregroundStyle(Palette.muted)
                        }.padding(.vertical, Layout.compact)
                        NavigationLink("Choose maps") { MapsSettings() }
                            .accessibilityIdentifier("editor-enable-maps")
                        Button("Enter coordinates instead") {
                            manualCoordinates = true
                            Task { await model.setMapsEnabled(false) }
                        }.accessibilityIdentifier("enter-coordinates")
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
                    if model.mapsAvailable || usesCoordinates {
                        HStack {
                            Text("Recognition radius"); Spacer()
                            Text("\(Int(radius)) m").foregroundStyle(Palette.muted).accessibilityIdentifier("recognition-radius-value")
                        }
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
                if !availableWiFi.isEmpty {
                    Button("Choose a network", systemImage: "wifi.badge.plus") {
                        focusedField = nil
                        if !model.uiTesting { model.tracking.refreshCurrentWiFi() }
                        choosingWiFi = true
                    }.accessibilityIdentifier("choose-wifi-network")
                }
            } header: { Text("Wi-Fi networks") } footer: {
                Text(wifiSuggestionsUnavailable ? "Suggestions couldn’t be loaded. You can enter a network name."
                     : wifiCoordinate == nil ? "Choose this place’s location to see networks recorded nearby."
                     : "Add the networks you use here.")
            }
        }.scrollContentBackground(.hidden).background(Palette.background).foregroundStyle(Palette.ink)
            .navigationTitle(original != nil ? "Edit place" : assigning != nil ? "Name this place" : "Add a place").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) { Button(saving ? "Saving…" : "Save", action: save).disabled(saving).accessibilityIdentifier("save-place") }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { focusedField = nil }.accessibilityIdentifier("dismiss-keyboard") }
            }
            .interactiveDismissDisabled(saving)
            .task {
                if !model.uiTesting { model.tracking.refreshCurrentWiFi() }
                // Reuse a fresh authorized fix; searching must never start sensors
                // or silently set the new place's coordinates.
                if let fix = model.tracking.currentLocation,
                   (0...900).contains(Date().timeIntervalSince(fix.timestamp)),
                   (0...200).contains(fix.horizontalAccuracy) {
                    recentSearchAnchor = Coordinate(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude)
                }
            }
            .task(id: wifiQuery) {
                wifiSuggestions = []; wifiSuggestionsUnavailable = false
                guard let coordinate = wifiCoordinate else { return }
                do {
                    let values = try await model.store?.wifiSuggestions(near: coordinate, placeRadius: radius,
                        connected: model.tracking.currentWiFiObservation) ?? []
                    try Task.checkCancellation()
                    wifiSuggestions = values
                } catch is CancellationError { }
                catch { if !Task.isCancelled { wifiSuggestionsUnavailable = true } }
            }
            .sheet(isPresented: $choosingWiFi, onDismiss: {
                if enteringWiFiAfterPicker { enteringWiFiAfterPicker = false; focusedField = .wifi }
            }) {
                NavigationStack {
                    PlaceWiFiPicker(suggestions: availableWiFi, add: { suggestion in
                        if !wifiNames.contains(suggestion.ssid) { wifiNames.append(suggestion.ssid) }
                        wifiError = nil
                    }, enterName: {
                        enteringWiFiAfterPicker = true; choosingWiFi = false
                    })
                }
            }
            .task(id: searchAnchor) {
                nearbyPlaces = []; catalogMessage = nil
                guard original == nil, catalogReference == nil, let coordinate = searchAnchor else { return }
                do {
                    let nearby = try await PlaceCatalog.shared.nearby(coordinate, limit: 3)
                    let covered = try await PlaceCatalog.shared.covers(coordinate)
                    try Task.checkCancellation()
                    nearbyPlaces = nearby
                    catalogMessage = !covered ? "No offline data for this area yet. You can enter a place yourself."
                        : nearby.isEmpty ? "No nearby suggestions. Search by name or enter a place yourself." : nil
                } catch is CancellationError { }
                catch { if !Task.isCancelled { catalogMessage = "Suggestions are unavailable. You can enter a place yourself." } }
            }
            .sheet(isPresented: $choosingCatalog, onDismiss: {
                existingSuggestion = pendingSavedSuggestion; pendingSavedSuggestion = nil
            }) {
                NavigationStack { PlaceCatalogSearch(anchor: searchAnchor, select: selectCatalog) }
            }
            .confirmationDialog("This place is already saved", isPresented: Binding(get: { existingSuggestion != nil }, set: { if !$0 { existingSuggestion = nil } }), titleVisibility: .visible) {
                if let existingSuggestion {
                    Button(assigning == nil ? "Use saved place" : "Assign this visit to \(existingSuggestion.name)") { useSavedPlace(existingSuggestion) }
                }
                Button("Cancel", role: .cancel) { existingSuggestion = nil }
            } message: { Text("Use your saved place instead of creating a duplicate.") }
            .sheet(isPresented: $choosingIcon) { NavigationStack { PlaceIconPicker(selection: Binding(get: { symbol }, set: { symbol = $0; userChoseIcon = true }), colorIndex: colorIndex) } }
            .confirmationDialog("Remove this Wi-Fi name?", isPresented: Binding(get: { removingWiFi != nil }, set: { if !$0 { removingWiFi = nil } }), titleVisibility: .visible, presenting: removingWiFi) { ssid in
                Button("Remove Wi-Fi name", role: .destructive) {
                    wifiNames.removeAll { $0 == ssid }
                    removingWiFi = nil
                }
            } message: { _ in Text("It will be removed from this place when you save. Recorded history stays intact.") }
            .alert("Couldn’t save this place", isPresented: Binding(get: { validation != nil }, set: { if !$0 { validation = nil } })) {
                Button("OK") { validation = nil }
            } message: { Text(validation ?? "") }
            .onChange(of: name) { _, value in
                if !userChoseIcon { symbol = PlaceIconMatcher.suggestedSymbol(name: value, category: value == catalogName ? catalogCategory : nil) ?? "mappin" }
            }
            .onChange(of: coordinate) { _, value in
                if let value { latitude = String(value.latitude); longitude = String(value.longitude); locationError = nil }
            }
            .onDisappear { locationRequest.cancel() }
    }
    private func selectCatalog(_ candidate: CatalogPlace) {
        if let existing = candidate.reference.savedPlace(in: model.places), existing.id != original?.id {
            if choosingCatalog { pendingSavedSuggestion = existing }
            else { existingSuggestion = existing }
            return
        }
        locationRequest.cancel()
        catalogCategory = candidate.category; catalogName = candidate.name
        name = candidate.name; address = candidate.address; coordinate = candidate.coordinate
        latitude = String(candidate.coordinate.latitude); longitude = String(candidate.coordinate.longitude)
        if !userChoseIcon { symbol = candidate.symbol }
        catalogReference = candidate.reference
        locationError = nil; locationSelected = false; focusedField = nil
    }
    private func useSavedPlace(_ place: Place) {
        existingSuggestion = nil
        guard assigning != nil else { dismiss(); return }
        saving = true
        Task {
            if await model.save(place, assigning: assigning) {
                if let onSave { onSave() } else { dismiss() }
            }
            saving = false
        }
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
    private var savedLocality: PlaceLocality? {
        let city = city.trimmingCharacters(in: .whitespacesAndNewlines)
        let country = country.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !city.isEmpty || !country.isEmpty else { return nil }
        if let original, original.locality?.city == city, original.locality?.country == country {
            if original.coordinate == coordinate { return original.locality }
            if original.locality?.source == .apple { return nil }
        }
        return PlaceLocality(city: city, country: country)
    }
    private func save() {
        if let catalogReference, let saved = catalogReference.savedPlace(in: model.places), saved.id != original?.id {
            useSavedPlace(saved); return
        }
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
            expectedSSIDs: wifiNames, createdAt: original?.createdAt ?? Date(), catalogReference: catalogReference, locality: savedLocality)
        saving = true; focusedField = nil
        Task {
            if await model.save(place, assigning: assigning) {
                if let onSave { onSave() } else { dismiss() }
            }
            saving = false
        }
    }
}

private struct SavedPlacePicker: View {
    @Environment(AppModel.self) private var model
    let anchor: Coordinate?
    let select: (Place) -> Void
    @State private var query = ""
    private var places: [Place] {
        model.places.filter {
            query.isEmpty || $0.name.localizedStandardContains(query) || $0.address.localizedStandardContains(query)
        }.sorted {
            if let anchor {
                let a = $0.coordinate.distance(to: anchor), b = $1.coordinate.distance(to: anchor)
                if a != b { return a < b }
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    var body: some View {
        List {
            ForEach(places) { place in
                Button { select(place) } label: {
                    HStack(spacing: Layout.spacing) {
                        PlaceIcon(symbol: place.symbol, colorIndex: place.colorIndex)
                        VStack(alignment: .leading) {
                            Text(place.name).foregroundStyle(Palette.ink)
                            if !place.address.isEmpty { Text(place.address).font(.caption).foregroundStyle(Palette.muted) }
                        }
                    }.frame(minHeight: Layout.touchTarget)
                }.accessibilityIdentifier("saved-place-\(place.id)")
            }
            if places.isEmpty { Text("No saved places match this name.").foregroundStyle(Palette.muted) }
        }.searchable(text: $query, prompt: "Saved places")
            .scrollContentBackground(.hidden).background(Palette.background)
            .navigationTitle("Use a saved place").navigationBarTitleDisplayMode(.inline)
    }
}
