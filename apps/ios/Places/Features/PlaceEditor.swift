import SwiftUI
import PlacesCore

struct PlaceEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private let original: Place?
    private let assigning: TimelineItem?
    private let onSave: (() -> Void)?
    private let onSavedPlace: ((Place) -> Void)?
    private let wifiOnly: Bool
    @State private var visitArrival: Date
    @State private var visitDeparture: Date
    @State private var name: String
    @State private var city: String
    @State private var country: String
    @State private var address: String
    @State private var latitude: String
    @State private var longitude: String
    @State private var coordinate: Coordinate?
    @State private var radius: Double
    @State private var area: PlaceArea?
    @State private var choosingArea = false
    @State private var symbol: String
    @State private var tripRole: PlaceTripRole
    @State private var userChoseIcon: Bool
    @State private var customColorHex: String?
    @State private var photoJPEG: Data?
    @State private var mergeDraft: Place?
    @State private var didMerge = false
    @State private var colorIndex: Int
    @State private var wifi: PlaceWiFiDraft
    @FocusState private var wifiFocused: Bool
    @State private var choosingWiFi = false
    @State private var wifiSuggestions: [WiFiSuggestion] = []
    @State private var enterWiFiAfterPicker = false
    @State private var adjacent: [AdjacentPlaceSuggestion] = []
    @State private var choosingIcon = false
    @State private var choosingCatalog = false
    @State private var catalogReference: PlaceCatalogReference?
    @State private var catalogCategory: String?
    @State private var catalogName: String?
    @State private var nearbyPlaces: [CatalogPlace] = []
    @State private var recentSearchAnchor: Coordinate?
    private var searchAnchor: Coordinate? { coordinate ?? assigning?.coordinate ?? recentSearchAnchor }
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
    @State private var deleting = false
    @FocusState private var focusedField: Field?
    private enum Field { case name, address, city, country, latitude, longitude }
    private var usesCoordinates: Bool { !model.mapsAvailable && (manualCoordinates || model.mapsChoiceMade) }
    private var wifiCoordinate: Coordinate? {
        if usesCoordinates {
            guard let lat = Double(latitude), let lon = Double(longitude) else { return nil }
            let value = Coordinate(latitude: lat, longitude: lon)
            return value.isValid ? value : nil
        }
        return coordinate
    }

    init(place: Place? = nil, suggestedName: String = "", coordinate: Coordinate? = nil,
         assigning: TimelineItem? = nil, suggestion: CatalogPlace? = nil, wifiOnly: Bool = false, onSave: (() -> Void)? = nil, onSavedPlace: ((Place) -> Void)? = nil) {
        original = place
        self.assigning = assigning
        self.onSave = onSave
        self.onSavedPlace = onSavedPlace
        self.wifiOnly = wifiOnly
        _visitArrival = State(initialValue: assigning?.start ?? Date())
        _visitDeparture = State(initialValue: assigning?.end ?? Date())
        let point = place?.coordinate ?? suggestion?.coordinate ?? coordinate
        _name = State(initialValue: place?.name ?? suggestion?.name ?? suggestedName)
        _city = State(initialValue: place?.locality?.city ?? "")
        _country = State(initialValue: place?.locality?.country ?? "")
        _address = State(initialValue: place?.address ?? suggestion?.address ?? "")
        _latitude = State(initialValue: point.map { String($0.latitude) } ?? "")
        _longitude = State(initialValue: point.map { String($0.longitude) } ?? "")
        _coordinate = State(initialValue: point)
        _radius = State(initialValue: place?.radius ?? 100)
        _area = State(initialValue: place?.area)
        _symbol = State(initialValue: place?.symbol ?? suggestion?.symbol ?? PlaceIconMatcher.suggestedSymbol(name: suggestedName) ?? "mappin")
        _userChoseIcon = State(initialValue: place != nil)
        _tripRole = State(initialValue: place?.tripRole ?? .automatic)
        _customColorHex = State(initialValue: place?.customColorHex)
        _photoJPEG = State(initialValue: place?.photoJPEG)
        _colorIndex = State(initialValue: place?.colorIndex ?? (suggestedName == "Work" ? 1 : 0))
        _wifi = State(initialValue: PlaceWiFiDraft(names: place?.expectedSSIDs ?? []))
        _catalogReference = State(initialValue: place?.catalogReference ?? suggestion?.reference)
        _catalogCategory = State(initialValue: suggestion?.category)
        _catalogName = State(initialValue: suggestion?.name)
    }

    var body: some View {
        ScrollViewReader { scroll in
        Form {
            if !wifiOnly {
            if let assigning, assigning.kind != .stay {
                Section {
                    DatePicker("Arrival", selection: $visitArrival, in: assigning.start...(assigning.end ?? Date()))
                        .accessibilityIdentifier("visit-arrival")
                    DatePicker("Departure", selection: $visitDeparture, in: assigning.start...(assigning.end ?? Date()))
                        .accessibilityIdentifier("visit-departure")
                } header: { Text("When were you here?") }
                footer: { Text("Choose the part of this interval you spent here. The rest of your timeline is kept.") }
            }
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
            if !adjacent.isEmpty {
                Section("From your timeline") { AdjacentPlaceRows(suggestions: adjacent, select: useSavedPlace) }
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
                Text(original == nil && searchAnchor != nil ? "Nearby suggestions" : "Offline suggestions")
            }
            Section("Details") {
                Button { choosingIcon = true } label: {
                    HStack(spacing: Layout.spacing) {
                        PlaceIcon(symbol: symbol, colorIndex: colorIndex, customColorHex: customColorHex, photoJPEG: photoJPEG)
                        Text(PlaceIconCatalog.title(for: symbol)).foregroundStyle(Palette.ink)
                        Spacer()
                        Text("Change appearance").font(.subheadline)
                        Image(systemName: "chevron.right").font(.caption)
                    }.frame(minHeight: Layout.touchTarget)
                }.accessibilityIdentifier("choose-place-icon")
            }
            Section {
                Picker("Trip detection", selection: $tripRole) {
                    ForEach(PlaceTripRole.allCases, id: \.self) { role in Text(role.title).tag(role) }
                }
            } footer: { Text(tripRole.explanation) }
            Section {
                DisclosureGroup("City & country") {
                    TextField("City (optional)", text: $city).accessibilityIdentifier("place-city").focused($focusedField, equals: .city)
                    TextField("Country (optional)", text: $country).accessibilityIdentifier("place-country").focused($focusedField, equals: .country)
                    NavigationLink("Apple Location Details…") { CityLookupSettings() }
                }
            }
            Section("Location") {
                LabeledContent("Address") {
                    TextField("Street, city…", text: $address).multilineTextAlignment(.trailing)
                        .focused($focusedField, equals: .address).accessibilityIdentifier("place-address")
                }
                if (assigning != nil || catalogReference != nil) && coordinate != nil && !changingLocation && area == nil {
                    HStack {
                        Label(catalogReference == nil ? "Using this visit’s location" : "Using the suggested location", systemImage: "mappin.circle.fill")
                        Spacer()
                        Button("Change") { changingLocation = true }
                            .accessibilityLabel("Change this place’s location")
                    }
                } else {
                    if model.mapsAvailable {
                        PlaceLocationMap(coordinate: $coordinate, radius: radius, colorIndex: colorIndex, customColorHex: customColorHex, name: name.isEmpty ? "Place" : name, area: area)
                            .frame(height: Layout.mapHeight).listRowInsets(EdgeInsets())
                        if area == nil { Label(coordinate == nil ? "Tap the map to place your pin" : "Tap the map to move your pin", systemImage: "hand.tap")
                            .font(.subheadline).foregroundStyle(Palette.muted) }
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
                    if area == nil && (model.mapsAvailable || usesCoordinates) {
                        HStack {
                            Text("Recognition radius"); Spacer()
                            Text("\(Int(radius)) m").foregroundStyle(Palette.muted).accessibilityIdentifier("recognition-radius-value")
                        }
                        Slider(value: $radius, in: 50...1000, step: 25).accessibilityLabel("Recognition radius in metres")
                    }
                }
                Button { choosingArea = true } label: {
                    HStack {
                        Label(area == nil ? "Choose or draw an area" : "Change area", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        Spacer(); Image(systemName: "chevron.right").font(.caption)
                    }.frame(minHeight: Layout.touchTarget)
                }.accessibilityIdentifier("choose-place-area")
                if area != nil {
                    Button("Use a radius instead") { area = nil }.accessibilityIdentifier("use-place-radius")
                }
            }
            }
            PlaceWiFiEditor(draft: $wifi, coordinate: wifiCoordinate, radius: radius, fieldFocused: $wifiFocused) { suggestions in
                wifiSuggestions = suggestions; choosingWiFi = true
            }
            if original != nil && !wifiOnly {
                Section {
                    Button("Delete place", systemImage: "trash", role: .destructive) { deleting = true }
                        .foregroundStyle(.red)
                        .disabled(saving).accessibilityIdentifier("delete-place")
                    Button("Merge place", systemImage: "arrow.triangle.merge") {
                        if let place = preparedPlace() { mergeDraft = place }
                    }.disabled(saving || model.places.count < 2).accessibilityIdentifier("merge-place")
                }
            }
        }.scrollContentBackground(.hidden).background(Palette.background).foregroundStyle(Palette.ink)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                if wifiFocused {
                    withAnimation { scroll.scrollTo("place-wifi-entry", anchor: .bottom) }
                }
            }
            .navigationTitle(wifiOnly ? "Wi-Fi networks" : original != nil ? "Edit place" : assigning?.kind == .stay ? "Name this place" : assigning != nil ? "Add a visit" : "Add a place").navigationBarTitleDisplayMode(.inline)
            .modifier(EditorControls(saving: saving, error: $validation, errorTitle: "Couldn’t save this place",
                saveIdentifier: "save-place", cancel: { dismiss() }, save: save))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if focusedField != nil || wifiFocused {
                    HStack {
                        Spacer()
                        Button("Done") { focusedField = nil; wifiFocused = false }
                            .buttonStyle(.glass).buttonBorderShape(.capsule).tint(Palette.green)
                            .accessibilityIdentifier("dismiss-keyboard")
                    }.padding(.horizontal, Layout.gutter).padding(.vertical, Layout.compact)
                        .background(Palette.background)
                }
            }
            .task {
                if let assigning { adjacent = (try? await model.store?.adjacentPlaces(for: assigning)) ?? [] }
                // Reuse a fresh authorized fix; searching must never start sensors
                // or silently set the new place's coordinates.
                if let fix = model.tracking.currentLocation,
                   (0...900).contains(Date().timeIntervalSince(fix.timestamp)),
                   (0...200).contains(fix.horizontalAccuracy) {
                    recentSearchAnchor = Coordinate(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude)
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
            .sheet(isPresented: $choosingArea) {
                NavigationStack {
                    PlaceAreaEditor(coordinate: coordinate ?? recentSearchAnchor, area: area, colorIndex: colorIndex, customColorHex: customColorHex) { selected, point, suggestedName in
                        area = selected; coordinate = point; changingLocation = true
                        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let suggestedName { name = suggestedName }
                    }
                }
            }
            .sheet(isPresented: $choosingWiFi, onDismiss: {
                withAnimation { scroll.scrollTo("place-wifi-entry", anchor: .bottom) }
                if enterWiFiAfterPicker { enterWiFiAfterPicker = false; wifiFocused = true }
            }) {
                NavigationStack {
                    PlaceWiFiPicker(suggestions: wifiSuggestions, draft: $wifi) {
                        enterWiFiAfterPicker = true; choosingWiFi = false
                    }
                }
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
            .sheet(isPresented: $choosingIcon) {
                NavigationStack {
                    PlaceIconPicker(symbol: symbol, colorIndex: colorIndex, customColorHex: customColorHex, photoJPEG: photoJPEG,
                        photoIDs: model.memories.memories.filter { original != nil && $0.placeID == original?.id }.sorted { $0.date > $1.date }.flatMap(\.photoIDs)) { icon, index, hex, photo in
                        symbol = icon; colorIndex = index; customColorHex = hex; photoJPEG = photo; userChoseIcon = true
                    }
                }
            }
            .sheet(item: $mergeDraft, onDismiss: { if didMerge { dismiss() } }) { draft in
                NavigationStack { MergePlacePicker(edited: draft) { didMerge = true; mergeDraft = nil } }
            }
            .onChange(of: name) { _, value in
                if !userChoseIcon { symbol = PlaceIconMatcher.suggestedSymbol(name: value, category: value == catalogName ? catalogCategory : nil) ?? "mappin" }
            }
            .onChange(of: coordinate) { _, value in
                if let value { latitude = String(value.latitude); longitude = String(value.longitude); locationError = nil }
            }
            .confirmationDialog("Delete this place?", isPresented: $deleting, titleVisibility: .visible) {
                Button("Delete place", role: .destructive) {
                    guard let original else { return }
                    saving = true
                    Task {
                        do { try await model.deletePlace(original.id); dismiss() }
                        catch { validation = "Couldn’t delete this place. Please try again." }
                        saving = false
                    }
                }
            } message: { Text("Its name and Wi-Fi associations will be removed. Timeline evidence, notes and photos are kept.") }
            .onDisappear { locationRequest.cancel() }
        }
    }
    private func selectCatalog(_ candidate: CatalogPlace) {
        if let existing = candidate.reference.savedPlace(in: model.places), existing.id != original?.id {
            if choosingCatalog { pendingSavedSuggestion = existing }
            else { existingSuggestion = existing }
            return
        }
        locationRequest.cancel()
        area = nil
        catalogCategory = candidate.category; catalogName = candidate.name
        name = candidate.name; address = candidate.address; coordinate = candidate.coordinate
        latitude = String(candidate.coordinate.latitude); longitude = String(candidate.coordinate.longitude)
        if !userChoseIcon { symbol = candidate.symbol }
        catalogReference = candidate.reference
        locationError = nil; locationSelected = false; focusedField = nil
    }
    private func useSavedPlace(_ place: Place) {
        existingSuggestion = nil
        guard assigning != nil else { onSavedPlace?(place); dismiss(); return }
        guard validVisitInterval else { return }
        saving = true
        Task {
            if await model.save(place, assigning: assignment) {
                onSavedPlace?(place)
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
                area = nil
                coordinate = Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
                locationSelected = true
            } catch is CancellationError { }
            catch { locationError = error.localizedDescription }
        }
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
        guard validVisitInterval else { return }
        if let catalogReference, let saved = catalogReference.savedPlace(in: model.places), saved.id != original?.id {
            useSavedPlace(saved); return
        }
        guard let place = preparedPlace() else { return }
        saving = true; focusedField = nil; wifiFocused = false
        Task {
            if await model.save(place, assigning: assignment) {
                onSavedPlace?(place)
                if let onSave { onSave() } else { dismiss() }
            }
            saving = false
        }
    }
    private var assignment: TimelineItem? {
        guard var item = assigning else { return nil }
        if item.kind != .stay { item.start = visitArrival; item.end = visitDeparture }
        return item
    }
    private var validVisitInterval: Bool {
        guard let assigning, assigning.kind != .stay else { return true }
        guard visitDeparture > visitArrival, visitArrival >= assigning.start,
              visitDeparture <= (assigning.end ?? Date()) else {
            validation = "Choose an arrival and a later departure within this interval."
            return false
        }
        return true
    }
    private func preparedPlace() -> Place? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            focusedField = .name; validation = "Give this place a name."; return nil
        }
        var point = coordinate
        if usesCoordinates {
            if let lat = Double(latitude.replacingOccurrences(of: ",", with: ".")),
               let lon = Double(longitude.replacingOccurrences(of: ",", with: ".")) { point = Coordinate(latitude: lat, longitude: lon) }
            else { point = nil }
        }
        guard let point, point.isValid else {
            validation = usesCoordinates ? "Enter latitude from −90 to 90 and longitude from −180 to 180, or use your current location."
                : "Choose a location on the map or use your current location."; return nil
        }
        guard wifi.finish() else { wifiFocused = true; return nil }
        var place = Place(id: original?.id ?? UUID().uuidString, name: name.trimmingCharacters(in: .whitespacesAndNewlines), address: address,
            coordinate: point, radius: radius, symbol: symbol, colorIndex: colorIndex,
            expectedSSIDs: wifi.names, createdAt: original?.createdAt ?? Date(), catalogReference: catalogReference, locality: savedLocality, tripRole: tripRole, area: area, customColorHex: customColorHex, userEditedAt: original?.userEditedAt, mergedPlaceIDs: original?.mergedPlaceIDs, photoJPEG: photoJPEG)
        if original?.tripRole == nil && tripRole == .automatic { place.tripRole = nil }
        if original != place { place.userEditedAt = Date() }
        return place
    }
}

struct SavedPlacePicker: View {
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
                    SavedPlaceRow(place: place)
                }.accessibilityIdentifier("saved-place-\(place.id)")
            }
            if places.isEmpty { Text("No saved places match this name.").foregroundStyle(Palette.muted) }
        }.searchable(text: $query, prompt: "Saved places")
            .scrollContentBackground(.hidden).background(Palette.background)
            .navigationTitle("Use a saved place").navigationBarTitleDisplayMode(.inline)
    }
}
