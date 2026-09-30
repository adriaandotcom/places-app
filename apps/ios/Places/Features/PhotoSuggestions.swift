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
                Text("iOS grants access to your whole library. Places limits its checks to photos from the last 30 days, reading their dates, saved locations and camera models on this iPhone. It counts faces on-device to suggest people-filled moments first; it does not identify anyone.")
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
    @Environment(\.hasMainNavigation) private var hasMainNavigation
    var day: Date?
    var item: TimelineItem?
    var placeID: String?
    var excludingID: String?
    private var groups: [PhotoVisitSuggestion] {
        photoSuggestions(model, day: day, item: item, placeID: placeID).filter { $0.id != excludingID }
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Layout.spacing) {
                if !model.photoLibrary.canRead {
                    NavigationLink("Set up photo locations") { PhotoEvidenceSettings() }
                } else if groups.isEmpty {
                    EmptyState(symbol: "photo.on.rectangle.angled", title: "No suggestions yet",
                        message: "Reviewed photos won’t appear again. New suggestions appear as you take more photos.")
                }
                ForEach(groups) { group in
                    PhotoSuggestionCard(group: group).modifier(CardSurface(padding: 0))
                        .modifier(SwipeToDelete { Task { await model.photoLibrary.deleteSuggestions([group], undo: model.deleteUndo) } })
                }
            }.padding(Layout.gutter)
        }.background(Palette.background).modifier(MainNavigationClearance()).navigationTitle("Photo suggestions")
            .modifier(DeleteUndoPresentation(undo: model.deleteUndo, enabled: !hasMainNavigation))
            .refreshable { await model.photoLibrary.sync() }
            .task { model.photoLibrary.updateAuthorization(); model.photoLibrary.requestScan() }
    }
}

@MainActor private func photoSuggestions(_ model: AppModel, day: Date?, item: TimelineItem?, placeID: String?) -> [PhotoVisitSuggestion] {
    model.photoLibrary.suggestions.filter { group in
        if let item { return group.relates(to: item) }
        if let placeID { return group.place(in: model.places)?.id == placeID }
        return day.map { Calendar.current.isDate($0, inSameDayAs: group.start) } ?? true
    }
}

/// One ranked suggestion, with the remaining suggestions attached to the same card.
struct PhotoSuggestionSection: View {
    @Environment(AppModel.self) private var model
    var item: TimelineItem?
    var placeID: String?
    var day: Date?
    private var groups: [PhotoVisitSuggestion] { photoSuggestions(model, day: day, item: item, placeID: placeID) }
    var body: some View {
        let groups = groups
        if let group = groups.first {
            VStack(spacing: 0) {
                PhotoSuggestionCard(group: group)
                if groups.count > 1 {
                    Divider().padding(.horizontal, Layout.spacing)
                    NavigationLink {
                        PhotoSuggestionsOverview(day: day, item: item, placeID: placeID, excludingID: group.id)
                    } label: {
                        PhotoSuggestionActionLabel(title: "Review \(groups.count - 1) more \(groups.count == 2 ? "suggestion" : "suggestions")", disclosure: true)
                    }.foregroundStyle(Palette.green).accessibilityIdentifier("more-photo-suggestions")
                }
            }.modifier(CardSurface(padding: 0))
                .modifier(SwipeToDelete { Task { await model.photoLibrary.deleteSuggestions(groups, undo: model.deleteUndo) } })
                .padding(.top, Layout.spacing)
        }
    }
}

private struct PhotoSuggestionActionLabel: View {
    let title: String
    var disclosure = false
    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: Layout.compact)
            if disclosure { Image(systemName: "chevron.right").font(.caption) }
        }.font(.subheadline).foregroundStyle(Palette.green)
            .frame(minHeight: Layout.touchTarget).padding(.horizontal, Layout.spacing)
            .contentShape(Rectangle())
    }
}

private struct PhotoSuggestionCard: View {
    @Environment(AppModel.self) private var model
    let group: PhotoVisitSuggestion
    @State private var creatingMemory = false
    @State private var preview: PhotoReference?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Layout.compact) {
                NavigationLink { PhotoSuggestionReview(group: group) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: Layout.compact) {
                            Text(group.place(in: model.places)?.name ?? "Remember this place?").font(BrandFont.title)
                            Text(group.start.formatted(date: .abbreviated, time: .shortened)).font(.footnote).foregroundStyle(Palette.muted)
                        }
                        Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted)
                    }.frame(minHeight: Layout.touchTarget).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("suggestion-review-\(group.id)")
                PhotoGrid(items: Array(group.previewPhotos.prefix(3)), open: { preview = PhotoReference(id: $0.id) }) { photo in
                    LibraryPhotoThumbnail(photo: photo)
                }
            }.padding(Layout.spacing)
            Button { creatingMemory = true } label: {
                PhotoSuggestionActionLabel(title: "Create memory with these photos")
            }.buttonStyle(.plain).accessibilityIdentifier("suggestion-create-memory-\(group.id)")
        }.accessibilityElement(children: .contain).accessibilityIdentifier("photo-suggestion-\(group.id)")
            .sheet(isPresented: $creatingMemory) {
                PhotoMemoryComposer(group: group).environment(\.hasMainNavigation, false)
            }
            .fullScreenCover(item: $preview) { photo in LibraryPhotoBrowser(photos: group.photos, initialID: photo.id) }
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

private struct LibraryPhotoBrowser: View {
    @Environment(AppModel.self) private var model
    let photos: [PhotoLocationEvidence]
    let initialID: String
    var body: some View {
        MemoryPhotoBrowser(photoIDs: photos.map(\.id), initialID: initialID,
            details: Dictionary(uniqueKeysWithValues: photos.map { ($0.id, MemoryPhotoDetails(createdAt: $0.capturedAt, coordinate: $0.coordinate)) }),
            load: { id in
                guard let photo = photos.first(where: { $0.id == id }) else { return nil }
                return try await model.photoLibrary.importPhoto(photo).jpeg
            })
    }
}

/// Directly opens the memory editor, including place selection for unknown locations.
private struct PhotoMemoryComposer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let group: PhotoVisitSuggestion
    var selectedPlace: Place?
    @State private var draft: PlaceMemory?
    @State private var files: [MemoryPhotoFile] = []
    @State private var photoDraft = MemoryPhotoDraft()
    @State private var error: String?
    @State private var preparationID = UUID()
    var body: some View {
        NavigationStack {
            Group {
                if let draft {
                    MemoryEditor(memory: draft, importing: files, suggestedCoordinate: group.coordinate, onSaved: {
                        Task { await model.photoLibrary.dismiss(group.photos); dismiss() }
                    })
                } else {
                    VStack(spacing: Layout.spacing) {
                        if let error { Text(error); Button("Try again") { preparationID = UUID() } }
                        else { ProgressView("Preparing photos…") }
                    }.padding(Layout.gutter).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .navigationTitle("Add a memory").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
                }
            }.background(Palette.background)
        }.task(id: preparationID) { if draft == nil { await prepare() } }
    }
    private func prepare() async {
        error = nil; photoDraft.discard(); files = []
        let epoch = model.memoryEpoch
        do {
            for photo in group.photos {
                let imported = try await model.photoLibrary.importPhoto(photo)
                try Task.checkCancellation()
                guard epoch == model.memoryEpoch else { throw CancellationError() }
                files.append(try photoDraft.append(imported))
            }
            var memory = PlaceMemory(date: group.start, placeID: (selectedPlace ?? group.place(in: model.places))?.id, photoIDs: files.map(\.id))
            memory.photoDetails = Dictionary(uniqueKeysWithValues: files.compactMap { file in file.details.map { (file.id, $0) } })
            draft = memory
        } catch is CancellationError { photoDraft.discard() }
        catch { self.error = "Couldn’t load these photos. Check Photos access and try again." }
    }
}

private struct PhotoSuggestionReview: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let group: PhotoVisitSuggestion
    @State private var selected: Set<String> = []
    @State private var initialized = false
    @State private var place: Place?
    @State private var addPlace = false
    @State private var choosePlace = false
    @State private var creatingMemory = false
    @State private var preview: PhotoReference?
    @State private var visit: AppleSuggestionSelection?
    @State private var undo = DeleteUndo()
    private var photos: [PhotoLocationEvidence] { group.photos.filter { selected.contains($0.id) } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.spacing) {
                if !model.photoLibrary.canRead {
                    Text("Automatic photo access is off. Your saved memories and selective photo picker still work.")
                } else {
                    VStack(alignment: .leading, spacing: Layout.compact) {
                        PhotoGrid(items: photos, open: { preview = PhotoReference(id: $0.id) }, remove: { photo in
                            selected.remove(photo.id)
                            undo.register("Photo removed") { selected.insert(photo.id) }
                        }) { LibraryPhotoThumbnail(photo: $0) }
                        Button("Create memory", systemImage: "photo.badge.plus") { creatingMemory = true }
                            .foregroundStyle(Palette.green).frame(minHeight: Layout.touchTarget).disabled(photos.isEmpty)
                            .accessibilityIdentifier("photo-create-memory")
                    }.modifier(CardSurface())
                    if model.mapsAvailable {
                        PrivacyMapView(customPresentation: MapPresentation(pins: [MapPin(id: group.id, name: place?.name ?? "Photo location", coordinate: group.coordinate, symbol: "photo", colorIndex: 4)]))
                            .frame(height: Layout.mapHeight).clipShape(RoundedRectangle(cornerRadius: Layout.cardRadius))
                    }
                    PlaceSelectionField(place: place, chooseSaved: { choosePlace = true }, chooseDifferent: { addPlace = true })
                        .modifier(CardSurface())
                    VStack(alignment: .leading, spacing: Layout.compact) {
                        Text(group.start.formatted(date: .complete, time: .shortened)).font(.subheadline).foregroundStyle(Palette.muted)
                        Button("Add to timeline", systemImage: "clock.badge.plus") { addVisit() }
                            .buttonStyle(PrimaryButton()).disabled(place == nil).accessibilityIdentifier("photo-add-visit")
                    }
                    Button("Delete suggestion", role: .destructive) {
                        Task { await model.photoLibrary.deleteSuggestions([group], undo: model.deleteUndo); dismiss() }
                    }.foregroundStyle(.red).frame(maxWidth: .infinity, minHeight: Layout.touchTarget)
                }
            }.padding(Layout.gutter)
        }.modifier(MainNavigationClearance()).background(Palette.background).foregroundStyle(Palette.ink)
            .navigationTitle("Photo suggestion").navigationBarTitleDisplayMode(.inline)
            .modifier(DeleteUndoPresentation(undo: undo))
            .task { if !initialized { initialized = true; selected = Set(group.photos.map(\.id)); place = group.place(in: model.places) } }
            .sheet(isPresented: $choosePlace) {
                NavigationStack { SavedPlacePicker(anchor: group.coordinate) { place = $0; choosePlace = false } }.environment(\.hasMainNavigation, false)
            }
            .sheet(isPresented: $addPlace) {
                NavigationStack { PlaceEditor(coordinate: group.coordinate, onSavedPlace: { saved in place = saved; addPlace = false }) }.environment(\.hasMainNavigation, false)
            }
            .sheet(isPresented: $creatingMemory) {
                PhotoMemoryComposer(group: PhotoVisitSuggestion(photos: photos), selectedPlace: place).environment(\.hasMainNavigation, false)
            }
            .fullScreenCover(item: $preview) { photo in LibraryPhotoBrowser(photos: photos, initialID: photo.id) }
            .sheet(item: $visit) { selection in
                NavigationStack { PastVisitReview(selection: selection, day: group.start, onSaved: { _ in
                    visit = nil; dismiss()
                }, chooseNext: { visit = nil }) }.environment(\.hasMainNavigation, false)
            }
    }
    private func addVisit() {
        guard let place else { return }
        visit = AppleSuggestionSelection(id: "photo-" + group.id, title: place.name,
            date: group.end > group.start ? DateInterval(start: group.start, end: group.end) : nil,
            candidates: [PastVisitCandidate(id: "photo-" + group.id, name: place.name, coordinate: place.coordinate, date: group.start)],
            photos: [], photoDraft: MemoryPhotoDraft(), sourceName: "Photo")
    }
}
