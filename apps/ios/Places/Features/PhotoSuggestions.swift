import SwiftUI
import PlacesCore

struct PhotoEvidenceSettings: View {
    @Environment(AppModel.self) private var model
    @State private var removing = false
    var body: some View {
        let library = model.photoLibrary
        Form {
            Section {
                Toggle("Use photo locations", isOn: Binding(get: { library.enabled }, set: { value in Task { await library.setEnabled(value) } }))
                    .accessibilityIdentifier("photo-evidence-toggle")
            } header: {
                Text("Remember missing places")
            } footer: {
                Text("Full Access lets Places find recent photos automatically, including new ones. Selected Photos only shares images you choose, so you would have to keep selecting photos yourself.")
            }
            if library.enabled {
                Section {
                    LabeledContent("Camera model", value: library.currentModel ?? "Not recognized")
                    Text(library.status).font(.footnote).foregroundStyle(Palette.muted)
                    if let date = library.lastScan { LabeledContent("Last complete scan") { Text(date, style: .relative).font(.footnote) } }
                    if library.canRead {
                        if library.scanning { ProgressView("Checking recent photos…") }
                        Button("Check recent photos") { Task { await library.sync() } }.disabled(library.scanning)
                        NavigationLink("Review photo suggestions") { PhotoSuggestionsOverview() }
                    } else { Button("Manage Photos access in Settings") { model.tracking.openSettings() } }
                }
            }
            Section("What happens when you enable it") {
                Text("iOS grants access to your whole library. Places limits its checks to photos from the last 30 days, reading their dates, saved locations and camera models on this iPhone.")
                Text("Only photos matching this iPhone model are used. Another iPhone of the same model can also match; this cannot prove which device took a photo.")
                Text("Checks run when you open Places and when iOS allows background refresh. Automatic checks only read originals already on this iPhone; they don’t download photos from iCloud.")
            }.font(.subheadline)
            Section("You choose what to add") {
                Text("Photo locations suggest missing places and memories. You review places and visit times before adding them. They don’t automatically create visits or routes, or overwrite your corrections.")
                Text("Places does not upload your photos or their location metadata. Photos are only copied into a memory after you select them; selected iCloud photos may download at that point.")
                Text("Turning this off stops checks and hides suggestions. Avatars and manually added photos keep working with Apple’s selective picker, even if you remove Full Access.")
            }.font(.subheadline)
            Section {
                Button("Remove imported photo evidence…", role: .destructive) { removing = true }
            } footer: { Text("Imported metadata stays on this iPhone until you remove it here. This turns the feature off and removes that metadata and review history. Memories and visits you confirmed are kept.") }
        }.scrollContentBackground(.hidden).background(Palette.background).navigationTitle("Photo locations")
            .task { library.updateAuthorization() }
            .confirmationDialog("Remove imported photo evidence?", isPresented: $removing, titleVisibility: .visible) {
                Button("Remove and turn off", role: .destructive) { Task { await library.erase() } }
            }
    }
}

/// A permission-free entry point shared by empty days and unknown locations.
struct PhotoLocationTip: View {
    @Environment(AppModel.self) private var model
    let day: Date
    @State private var showingSettings = false
    private var isRecentDay: Bool {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let firstDay = calendar.date(byAdding: .day, value: -30, to: today) else { return false }
        return (firstDay...today).contains(calendar.startOfDay(for: day))
    }
    var body: some View {
        Group {
            if !model.photoLibrary.canRead, isRecentDay {
                Button { showingSettings = true } label: {
                    InfoRow(symbol: "photo.on.rectangle.angled", title: "Find places in your photos",
                        subtitle: "Photos from the last 30 days may help fill gaps in your timeline. Set up photo locations.",
                        showsDisclosure: true)
                }.buttonStyle(.plain).foregroundStyle(Palette.ink).padding(.top, Layout.spacing)
                    .accessibilityIdentifier("photo-location-tip")
            }
        }.sheet(isPresented: $showingSettings) {
            NavigationStack {
                PhotoEvidenceSettings().navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingSettings = false }
                        }
                    }
            }.environment(\.hasMainNavigation, false)
        }
    }
}

struct PhotoSuggestionsOverview: View {
    @Environment(AppModel.self) private var model
    var day: Date?
    private var groups: [PhotoVisitSuggestion] {
        model.photoLibrary.suggestions.filter { group in day.map { Calendar.current.isDate($0, inSameDayAs: group.start) } ?? true }
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Layout.spacing) {
                Text("Remember a missing place, or turn a few photos into a memory. Locations come from photos matching your iPhone model.")
                    .font(.subheadline).foregroundStyle(Palette.muted)
                if !model.photoLibrary.canRead {
                    NavigationLink("Set up photo locations") { PhotoEvidenceSettings() }
                } else if groups.isEmpty {
                    EmptyState(symbol: "photo.on.rectangle.angled", title: "No suggestions yet",
                        message: "Photos need a date, a location and a matching camera model. Reviewed photos won’t appear again.")
                }
                ForEach(groups) { group in
                    NavigationLink { PhotoSuggestionReview(group: group) } label: { PhotoSuggestionCard(group: group) }.buttonStyle(.plain)
                }
            }.padding(Layout.gutter)
        }.background(Palette.background).modifier(MainNavigationClearance()).navigationTitle("Photo suggestions")
            .refreshable { await model.photoLibrary.sync() }
            .task { model.photoLibrary.updateAuthorization(); model.photoLibrary.requestScan() }
    }
}

/// Shared by timeline gaps, known-place details and the import overview.
struct PhotoSuggestionSection: View {
    @Environment(AppModel.self) private var model
    var item: TimelineItem?
    var placeID: String?
    var day: Date?
    private var groups: [PhotoVisitSuggestion] {
        model.photoLibrary.suggestions.filter { group in
            if let item { return group.relates(to: item) }
            if let placeID { return group.place(in: model.places)?.id == placeID }
            return day.map { Calendar.current.isDate($0, inSameDayAs: group.start) } ?? true
        }
    }
    var body: some View {
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: Layout.spacing) {
                SectionHeading(title: "From your photos")
                ForEach(Array(groups.prefix(3))) { group in
                    NavigationLink { PhotoSuggestionReview(group: group) } label: { PhotoSuggestionCard(group: group) }.buttonStyle(.plain)
                }
                NavigationLink("Review all photo suggestions") { PhotoSuggestionsOverview(day: day) }
                    .frame(minHeight: Layout.touchTarget)
            }.padding(.top, Layout.spacing)
        }
    }
}

private struct PhotoSuggestionCard: View {
    @Environment(AppModel.self) private var model
    let group: PhotoVisitSuggestion
    var body: some View {
        VStack(alignment: .leading, spacing: Layout.compact) {
            HStack {
                VStack(alignment: .leading, spacing: Layout.compact) {
                    Text(group.place(in: model.places)?.name ?? "Remember this place?").font(BrandFont.title)
                    Text(group.start.formatted(date: .abbreviated, time: .shortened)).font(.footnote).foregroundStyle(Palette.muted)
                }
                Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted)
            }
            HStack(spacing: Layout.compact) {
                ForEach(Array(group.photos.prefix(3))) { photo in LibraryPhotoThumbnail(photo: photo).frame(height: 84).clipShape(RoundedRectangle(cornerRadius: Layout.compact)) }
            }
            Text(group.place(in: model.places) == nil ? "Name the place and create a memory" : "Create a memory with these photos")
                .font(.subheadline).foregroundStyle(Palette.green)
        }.modifier(CardSurface()).accessibilityIdentifier("photo-suggestion-\(group.id)")
    }
}

struct LibraryPhotoThumbnail: View {
    @Environment(AppModel.self) private var model
    let photo: PhotoLocationEvidence
    @State private var image: UIImage?
    var body: some View {
        GeometryReader { size in
            Group {
                if model.photoLibrary.canRead, let image { Image(uiImage: image).resizable().scaledToFill() }
                else { Image(systemName: "photo").foregroundStyle(Palette.muted) }
            }.frame(width: size.size.width, height: size.size.height).clipped()
        }.task(id: photo.id) { image = await model.photoLibrary.thumbnail(photo.assetID) }
            .onChange(of: model.photoLibrary.canRead) { _, allowed in if !allowed { image = nil } }
            .accessibilityLabel("Photo taken \(photo.capturedAt.formatted(date: .abbreviated, time: .shortened))")
    }
}

private struct PhotoSuggestionReview: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let group: PhotoVisitSuggestion
    @State private var selected: Set<String> = []
    @State private var initialized = false
    @State private var importTask: Task<Void, Never>?
    @State private var place: Place?
    @State private var addPlace = false
    @State private var choosePlace = false
    @State private var importing = false
    @State private var error: String?
    @State private var draftFiles = MemoryPhotoDraft()
    @State private var memory: PlaceMemory?
    @State private var files: [MemoryPhotoFile] = []
    @State private var visit: AppleSuggestionSelection?
    var body: some View {
        Form {
            if !model.photoLibrary.canRead {
                Section { Text("Automatic photo access is off. Your saved memories and selective photo picker still work.") }
            } else {
                Section {
                    Text(group.start.formatted(date: .complete, time: .shortened)).font(BrandFont.title)
                    Text("Photo times are points of evidence, not confirmed arrival or departure times.").font(.footnote).foregroundStyle(Palette.muted)
                    if model.mapsAvailable {
                        PrivacyMapView(customPresentation: MapPresentation(pins: [MapPin(id: group.id, name: place?.name ?? "Photo location", coordinate: group.coordinate, symbol: "photo", colorIndex: 4)]))
                            .frame(height: Layout.mapHeight).clipShape(RoundedRectangle(cornerRadius: Layout.cardRadius))
                    }
                }
                Section("Place") {
                    if let place { SavedPlaceRow(place: place) }
                    Button("Choose a saved place") { choosePlace = true }
                    Button(place == nil ? "Name this place" : "Choose a different nearby place", systemImage: "mappin.and.ellipse") { addPlace = true }
                }
                Section("Choose photos for your memory") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: Layout.compact) {
                        ForEach(group.photos) { photo in
                            Button {
                                if selected.contains(photo.id) { selected.remove(photo.id) } else { selected.insert(photo.id) }
                            } label: {
                                LibraryPhotoThumbnail(photo: photo).frame(height: 96)
                                    .clipShape(RoundedRectangle(cornerRadius: Layout.compact))
                                    .overlay(alignment: .bottomTrailing) {
                                        Image(systemName: selected.contains(photo.id) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(selected.contains(photo.id) ? Palette.green : .white)
                                            .background(.white, in: Circle()).padding(Layout.compact)
                                    }
                            }.buttonStyle(.plain).accessibilityAddTraits(selected.contains(photo.id) ? .isSelected : [])
                        }
                    }
                }
                Section {
                    Button("Create memory", systemImage: "photo.badge.plus") { importTask = Task { await prepare(addVisit: false) } }
                        .disabled(place == nil || selected.isEmpty || importing).accessibilityIdentifier("photo-create-memory")
                    Button("Review a missing visit", systemImage: "clock.badge.plus") { importTask = Task { await prepare(addVisit: true) } }
                        .disabled(place == nil || importing).accessibilityIdentifier("photo-add-visit")
                    if place == nil { Text("Choose or name the place first.").font(.footnote).foregroundStyle(Palette.muted) }
                    if importing { ProgressView("Preparing selected photos…") }
                } footer: { Text("Creating a memory copies only your selected photos. It may download those photos from your iCloud library. Adding a visit separately lets you review times and overlaps.") }
                Section { Button("Dismiss this suggestion") { Task { await model.photoLibrary.dismiss(group.photos); dismiss() } } }
            }
            if let error { Section { Text(error).foregroundStyle(Palette.warning) } }
        }.scrollContentBackground(.hidden).background(Palette.background).navigationTitle("From your photos")
            .navigationBarTitleDisplayMode(.inline).interactiveDismissDisabled(importing)
            .task { if !initialized { initialized = true; selected = Set(group.photos.map(\.id)); place = group.place(in: model.places) } }
            .onDisappear { importTask?.cancel() }
            .sheet(isPresented: $choosePlace) {
                NavigationStack { SavedPlacePicker(anchor: group.coordinate) { place = $0; choosePlace = false } }
            }
            .sheet(isPresented: $addPlace) {
                NavigationStack { PlaceEditor(coordinate: group.coordinate, onSavedPlace: { saved in place = saved; addPlace = false }) }
            }
            .sheet(item: $memory, onDismiss: { draftFiles.discard(); files = [] }) { memory in
                NavigationStack { MemoryEditor(memory: memory, importing: files, onSaved: {
                    self.memory = nil
                    Task { await model.photoLibrary.dismiss(group.photos.filter { selected.contains($0.id) }); dismiss() }
                }) }
            }
            .sheet(item: $visit, onDismiss: { draftFiles.discard(); files = [] }) { selection in
                NavigationStack { PastVisitReview(selection: selection, day: group.start, onSaved: { _ in
                    visit = nil; Task { await model.photoLibrary.dismiss(group.photos); dismiss() }
                }, chooseNext: { visit = nil }) }
            }
    }
    private func prepare(addVisit: Bool) async {
        guard let place, model.photoLibrary.canRead else { return }
        importing = true; error = nil; draftFiles.discard(); files = []
        let epoch = model.memoryEpoch
        do {
            for photo in group.photos where selected.contains(photo.id) {
                let imported = try await model.photoLibrary.importPhoto(photo)
                guard epoch == model.memoryEpoch else { throw CancellationError() }
                files.append(try draftFiles.append(imported))
            }
            try Task.checkCancellation()
            guard model.photoLibrary.canRead else { throw CancellationError() }
            if addVisit {
                visit = AppleSuggestionSelection(id: "photo-" + group.id, title: "Photos at \(place.name)",
                    date: group.end > group.start ? DateInterval(start: group.start, end: group.end) : nil,
                    candidates: [PastVisitCandidate(id: "photo-" + group.id, name: place.name, coordinate: place.coordinate, date: group.start)],
                    photos: files, photoDraft: draftFiles, sourceName: "Photo")
            } else {
                var draft = PlaceMemory(date: group.start, placeID: place.id, photoIDs: files.map(\.id))
                draft.photoDetails = Dictionary(uniqueKeysWithValues: files.compactMap { file in file.details.map { (file.id, $0) } })
                memory = draft
            }
        } catch { draftFiles.discard(); files = []; self.error = "Couldn’t load the selected photos. Check Photos access and try again." }
        importing = false
    }
}
