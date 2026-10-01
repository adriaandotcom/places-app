import SwiftUI
import PhotosUI
import ImageIO
import UniformTypeIdentifiers
import PlacesCore

enum MemoryContext {
    case trip(Trip), place(Place), visit(TimelineItem)
    var tripPersonIDs: [String] {
        if case .trip(let trip) = self { return trip.personIDs }
        return []
    }
    var draft: PlaceMemory {
        switch self {
        case .trip(let trip): PlaceMemory(tripID: trip.id, personIDs: trip.personIDs)
        case .place(let place): PlaceMemory(placeID: place.id)
        case .visit(let item): PlaceMemory(date: item.start, placeID: item.placeID, visitStart: item.start)
        }
    }
    func includes(_ memory: PlaceMemory) -> Bool {
        switch self {
        case .trip(let trip): memory.belongs(to: trip)
        case .place(let place): memory.placeID == place.id
        case .visit(let item): memory.belongs(to: item)
        }
    }
}

struct MemorySection: View {
    @Environment(AppModel.self) private var model
    let context: MemoryContext
    @State private var editing: PlaceMemory?
    var body: some View {
        let memories = model.memories.memories.filter(context.includes)
        VStack(alignment: .leading, spacing: Layout.spacing) {
            if memories.isEmpty, case .trip = context {
                EmptyState(symbol: "photo.on.rectangle.angled", title: "A trip worth remembering",
                    message: "Keep a photo, a little note, or a moment together.", style: .card,
                    actionTitle: "Add a memory", actionIdentifier: "add-memory", action: { editing = context.draft })
            } else {
                SectionHeading(title: "Memories", actionTitle: "Add", actionSymbol: "plus", actionIdentifier: "add-memory", action: { editing = context.draft })
                ForEach(memories) { memory in
                    MemoryCard(memory: memory, tripPersonIDs: context.tripPersonIDs)
                }
            }
        }
        .sheet(item: $editing) { memory in NavigationStack { MemoryEditor(memory: memory) } }
    }
}

struct MemoryCard: View {
    @Environment(AppModel.self) private var model
    let memory: PlaceMemory
    var tripPersonIDs: [String] = []
    @State private var editing: MemoryEditRequest?
    @State private var selectedPhoto: PhotoReference?
    private var context: String {
        let date = memory.date.formatted(date: .abbreviated, time: .omitted)
        if let place = model.places.first(where: { $0.id == memory.placeID }) {
            return memory.visitStart == nil ? place.name : "\(place.name) · \(date)"
        }
        return date
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Layout.compact) {
            HStack {
                if let placeID = memory.placeID {
                    NavigationLink { PlaceDetail(placeID: placeID) } label: { Text(context).font(.subheadline) }
                        .frame(minHeight: Layout.touchTarget)
                } else if let trip = model.memories.trips.first(where: { $0.id == memory.tripID }) {
                    NavigationLink { TripDetail(tripID: trip.id) } label: { Text(trip.title + " · " + context).font(.subheadline) }
                        .frame(minHeight: Layout.touchTarget)
                } else { Text(context).font(.subheadline).foregroundStyle(Palette.muted) }
                Spacer()
                Button("Edit memory", systemImage: "pencil") { editing = MemoryEditRequest(addPhotos: false) }
                    .labelStyle(.iconOnly).frame(width: Layout.touchTarget, height: Layout.touchTarget).foregroundStyle(Palette.green)
            }
            if Set(memory.linkedPersonIDs) != Set(tripPersonIDs) {
                PersonAvatarGroup(personIDs: memory.linkedPersonIDs, border: Palette.paper)
            }
            if !memory.text.isEmpty { PersonMentionText(text: memory.text, mentions: memory.mentions ?? []) }
            if !memory.photoIDs.isEmpty {
                PhotoGrid(items: memory.orderedPhotoIDs.map { PhotoReference(id: $0) },
                    open: { selectedPhoto = $0 }, add: { editing = MemoryEditRequest(addPhotos: true) }, addLabel: "Add photos to memory", addIdentifier: "add-photos-to-memory") { photo in
                    StoredPhoto(id: photo.id, thumbnail: true)
                }
            }
        }.modifier(CardSurface())
            .sheet(item: $editing) { request in NavigationStack { MemoryEditor(memory: memory, addPhotos: request.addPhotos) } }
            .fullScreenCover(item: $selectedPhoto) { photo in
                SavedMemoryPhotoBrowser(memoryID: memory.id, initialID: photo.id)
            }
    }
}
private struct MemoryEditRequest: Identifiable { let id = UUID(); let addPhotos: Bool }

struct StoredPhoto: View {
    @Environment(AppModel.self) private var model
    let id: String
    let thumbnail: Bool
    @State private var image: UIImage?
    @State private var unavailable = false
    var body: some View {
        GeometryReader { geometry in
            Group {
                if let image {
                    if thumbnail { Image(uiImage: image).resizable().scaledToFill() }
                    else { Image(uiImage: image).resizable().scaledToFit() }
                } else if unavailable { Image(systemName: "photo").foregroundStyle(Palette.muted) }
                else { ProgressView() }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }.task(id: id) {
            do {
                guard let data = try await model.store?.photoData(id: id, thumbnail: thumbnail), !Task.isCancelled else { unavailable = true; return }
                image = UIImage(data: data); unavailable = image == nil
            } catch { unavailable = true }
        }.accessibilityLabel(unavailable ? "Photo unavailable" : "Saved photo")
    }
}

struct MemoryEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: PlaceMemory
    @State private var photos: [MemoryPhotoFile] = []
    @State private var photoDraft = MemoryPhotoDraft()
    @State private var selection: [PhotosPickerItem] = []
    @State private var choosingPhotos = false
    @State private var importing = false
    @State private var importProgress = ""
    @State private var importTask: Task<Void, Never>?
    @State private var saving = false
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var epoch: Int?
    @State private var reordering = false
    @State private var selectedPhoto: PhotoReference?
    private let addPhotos: Bool
    private let suggestedCoordinate: Coordinate?
    private let onSaved: (() -> Void)?
    @State private var choosePlace = false
    @State private var addPlace = false
    @State private var undo = DeleteUndo()
    @State private var offeredPhotos = false
    init(memory: PlaceMemory, addPhotos: Bool = false, importing photos: [MemoryPhotoFile] = [], suggestedCoordinate: Coordinate? = nil, onSaved: (() -> Void)? = nil) {
        var memory = memory; memory.personIDs = memory.linkedPersonIDs
        _draft = State(initialValue: memory); self.addPhotos = addPhotos
        self.suggestedCoordinate = suggestedCoordinate
        _photos = State(initialValue: photos); self.onSaved = onSaved
    }
    private var exists: Bool { model.memories.memories.contains { $0.id == draft.id } }
    private var placeCoordinate: Coordinate? { suggestedCoordinate ?? model.places.first { $0.id == draft.placeID }?.coordinate }
    var body: some View {
        Form {
            if suggestedCoordinate != nil || draft.placeID != nil {
                Section {
                    PlaceSelectionField(place: model.places.first { $0.id == draft.placeID },
                        chooseSaved: { choosePlace = true }, chooseDifferent: { addPlace = true })
                }
            }
            Section {
                PersonMentionEditor(text: $draft.text, mentions: Binding(get: { draft.mentions ?? [] }, set: {
                    draft.mentions = $0
                    draft.personIDs = draft.linkedPersonIDs
                }), label: "Write a note…", identifier: "memory-note")
            }
            Section {
                PeopleSelectionField(selection: $draft.personIDs).accessibilityIdentifier("memory-people")
                if draft.visitStart == nil { DatePicker("Date", selection: $draft.date, in: ...Date(), displayedComponents: .date) }
            }
            Section("Photos") {
                    PhotoGrid(items: draft.orderedPhotoIDs.map { PhotoReference(id: $0) }, open: { selectedPhoto = $0 },
                    remove: { removePhoto($0.id) }, reorder: draft.photoIDs.count > 1 ? { reordering = true } : nil,
                    add: { choosingPhotos = true }, addIdentifier: "add-memory-photos", addingDisabled: importing, photoIdentifierPrefix: "draft-photo-") { reference in
                        DraftPhotoThumbnail(id: reference.id, files: photos)
                    }
                if importing { ProgressView(importProgress) }
            }
            if exists {
                Section {
                    Button("Delete memory", systemImage: "trash", role: .destructive) { confirmDelete = true }
                        .foregroundStyle(.red)
                }
            }
        }.scrollContentBackground(.hidden).background(Palette.background).foregroundStyle(Palette.ink)
            .modifier(DeleteUndoPresentation(undo: undo))
            .environment(\.hasMainNavigation, false)
            .navigationTitle(exists ? "Memory" : "Add a memory").navigationBarTitleDisplayMode(.inline)
            .onAppear { if epoch == nil { epoch = model.memoryEpoch } }
            .task {
                if addPhotos && !offeredPhotos { offeredPhotos = true; choosingPhotos = true }
            }
            // A lazy Form row can be recreated by history updates. Keep the presentation
            // on the editor itself so the system picker retains its browsing state.
            .photosPicker(isPresented: $choosingPhotos, selection: $selection, maxSelectionCount: nil,
                          selectionBehavior: .ordered, matching: .images, preferredItemEncoding: .current)
            .onChange(of: selection) { importSelectionIfReady() }
            .onChange(of: choosingPhotos) { importSelectionIfReady() }
            .sheet(isPresented: $reordering) { NavigationStack { MemoryPhotoOrderEditor(memory: $draft, files: photos) } }
            .sheet(isPresented: $choosePlace) {
                NavigationStack { SavedPlacePicker(anchor: placeCoordinate) { draft.placeID = $0.id; draft.visitStart = nil; choosePlace = false } }
            }
            .sheet(isPresented: $addPlace) {
                NavigationStack { PlaceEditor(coordinate: placeCoordinate, onSavedPlace: { draft.placeID = $0.id; draft.visitStart = nil; addPlace = false }) }
            }
            .fullScreenCover(item: $selectedPhoto) { photo in
                MemoryPhotoBrowser(photoIDs: draft.orderedPhotoIDs, initialID: photo.id, details: draft.photoDetails ?? [:], load: { id in
                    if let file = photos.first(where: { $0.id == id }) { return try Data(contentsOf: file.jpegURL) }
                    return try await model.store?.photoData(id: id)
                }, saveCaption: { id, caption in
                    var details = draft.photoDetails?[id] ?? MemoryPhotoDetails()
                    details.caption = caption
                    draft.photoDetails = (draft.photoDetails ?? [:]).merging([id: details]) { _, new in new }
                }, removePhoto: { removePhoto($0) })
            }
            .modifier(EditorControls(saving: saving,
                canSave: !importing && (suggestedCoordinate == nil || draft.placeID != nil) && (!draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.photoIDs.isEmpty || !draft.personIDs.isEmpty),
                dismissalBlocked: importing, error: $error, errorTitle: "Couldn’t save memory", saveIdentifier: "save-memory",
                cancel: { importTask?.cancel(); photoDraft.discard(); dismiss() }, save: { save() }))
            .confirmationDialog("Delete this memory and its photos?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete memory", role: .destructive) { save(deleting: true) }
            }
    }
    private func removePhoto(_ id: String) {
        guard let index = draft.photoIDs.firstIndex(of: id) else { return }
        let file = photos.first { $0.id == id }
        let details = draft.photoDetails?[id]
        draft.photoIDs.removeAll { $0 == id }; photos.removeAll { $0.id == id }
        draft.photoDetails?.removeValue(forKey: id)
        undo.register("Photo removed") {
            draft.photoIDs.insert(id, at: min(index, draft.photoIDs.count))
            if let file { photos.append(file) }
            if let details { draft.photoDetails = (draft.photoDetails ?? [:]).merging([id: details]) { _, restored in restored } }
        }
    }
    private func importSelectionIfReady() {
        // Selection and dismissal bindings may arrive in either order. Consume the
        // confirmed batch once, only after the picker has closed.
        guard !choosingPhotos, !importing, !selection.isEmpty else { return }
        let selected = selection
        selection = []; importing = true
        let expectedEpoch = model.memoryEpoch
        importTask = Task {
            do {
                for (index, item) in selected.enumerated() {
                    importProgress = "Adding photo \(index + 1) of \(selected.count)…"
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw MemoryError.invalidPhoto }
                    let photo = try await Task.detached(priority: .userInitiated) { try MemoryPhotoImport.make(data) }.value
                    try Task.checkCancellation()
                    guard model.memoryEpoch == expectedEpoch else { throw CancellationError() }
                    photos.append(try photoDraft.append(photo)); draft.photoIDs.append(photo.id)
                    if let details = photo.details { draft.photoDetails = (draft.photoDetails ?? [:]).merging([photo.id: details]) { _, new in new } }
                }
            } catch is CancellationError {} catch { self.error = "Some photos couldn’t be added. Try choosing them again." }
            importing = false; importTask = nil
        }
    }
    private func save(deleting: Bool = false) {
        guard let epoch else { return }
        let memory = draft, added = photos
        saving = true
        Task {
            do {
                try await model.changeMemories(epoch: epoch) { store in
                    if deleting { try await store.deleteMemory(id: memory.id) }
                    else { try await store.saveMemory(memory, importing: added) }
                }
                photoDraft.discard()
                if let onSaved { onSaved() } else { dismiss() }
            } catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}

/// Re-encode pixels only. Keep date and coordinates separately in protected storage;
/// camera identifiers, filenames and other original metadata are discarded.
/// These bounded copies live in the same protected, backup-excluded SQLite store as history.
enum MemoryPhotoImport {
    nonisolated static func make(_ data: Data) throws -> MemoryPhoto {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw MemoryError.invalidPhoto }
        return try make(source)
    }

    nonisolated static func make(url: URL, date: Date? = nil) throws -> MemoryPhoto {
        guard url.isFileURL, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw MemoryError.invalidPhoto }
        var photo = try make(source)
        if photo.details?.createdAt == nil { photo.details?.createdAt = date }
        return photo
    }

    nonisolated private static func make(_ source: CGImageSource) throws -> MemoryPhoto {
        func encoded(maximumSize: Int, byteLimit: Int) throws -> Data {
            var size = maximumSize
            while size >= 160 {
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: size,
                    kCGImageSourceShouldCacheImmediately: true]
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw MemoryError.invalidPhoto }
                for quality in [0.82, 0.65, 0.48] {
                    let output = NSMutableData()
                    guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw MemoryError.invalidPhoto }
                    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                    guard CGImageDestinationFinalize(destination) else { throw MemoryError.invalidPhoto }
                    if output.length <= byteLimit { return output as Data }
                }
                size = Int(Double(size) * 0.75)
            }
            throw MemoryError.invalidPhoto
        }
        return try MemoryPhoto(jpeg: encoded(maximumSize: 1600, byteLimit: 450_000),
                               thumbnail: encoded(maximumSize: 320, byteLimit: 50_000), details: details(from: source))
    }

    nonisolated static func details(from source: CGImageSource) -> MemoryPhotoDetails {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        var details = MemoryPhotoDetails()
        if let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.isLenient = false
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            if let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String {
                formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXXXX"
                details.createdAt = formatter.date(from: original + offset)
                if details.createdAt != nil {
                    let parts = offset.dropFirst().split(separator: ":").compactMap { Int($0) }
                    if parts.count == 2 { details.utcOffsetSeconds = (parts[0] * 3600 + parts[1] * 60) * (offset.hasPrefix("-") ? -1 : 1) }
                }
            }
            if details.createdAt == nil {
                // Without an offset, preserve the camera's wall-clock time, not a guessed zone.
                formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
                details.createdAt = formatter.date(from: original)
            }
        }
        if let latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
           let longitude = gps[kCGImagePropertyGPSLongitude] as? Double,
           let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String,
           let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String,
           ["N", "S"].contains(latRef), ["E", "W"].contains(lonRef),
           latitude.isFinite, longitude.isFinite, (0...90).contains(latitude), (0...180).contains(longitude) {
            details.coordinate = Coordinate(latitude: latitude * (latRef == "S" ? -1 : 1), longitude: longitude * (lonRef == "W" ? -1 : 1))
        }
        return details
    }
}
