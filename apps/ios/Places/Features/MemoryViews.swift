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
        case .trip(let trip): PlaceMemory(tripID: trip.id)
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
                PhotoGrid(items: memory.photoIDs.map { PhotoReference(id: $0) },
                    open: { selectedPhoto = $0 }, add: { editing = MemoryEditRequest(addPhotos: true) }, addLabel: "Add photos to memory", addIdentifier: "add-photos-to-memory") { photo in
                    StoredPhoto(id: photo.id, thumbnail: true)
                }
            }
        }.modifier(CardSurface())
            .sheet(item: $editing) { request in NavigationStack { MemoryEditor(memory: memory, addPhotos: request.addPhotos) } }
            .sheet(item: $selectedPhoto) { photo in
                NavigationStack {
                    StoredPhoto(id: photo.id, thumbnail: false).background(Palette.background)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { selectedPhoto = nil } } }
                }
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
    private let addPhotos: Bool
    @State private var offeredPhotos = false
    init(memory: PlaceMemory, addPhotos: Bool = false) { _draft = State(initialValue: memory); self.addPhotos = addPhotos }
    private var exists: Bool { model.memories.memories.contains { $0.id == draft.id } }
    var body: some View {
        Form {
            Section {
                PersonMentionEditor(text: $draft.text, mentions: Binding(get: { draft.mentions ?? [] }, set: { draft.mentions = $0 }), label: "Write a note…", identifier: "memory-note")
            }
            Section {
                PeopleSelectionField(selection: $draft.personIDs).accessibilityIdentifier("memory-people")
                if draft.visitStart == nil { DatePicker("Date", selection: $draft.date, in: ...Date(), displayedComponents: .date) }
            }
            Section("Photos") {
                if !draft.photoIDs.isEmpty {
                    PhotoGrid(items: draft.photoIDs.map { PhotoReference(id: $0) }, remove: { reference in
                        if let photo = photos.first(where: { $0.id == reference.id }) { photoDraft.remove(photo) }
                        draft.photoIDs.removeAll { $0 == reference.id }; photos.removeAll { $0.id == reference.id }
                    }) { reference in
                        if let photo = photos.first(where: { $0.id == reference.id }), let image = UIImage(contentsOfFile: photo.thumbnailURL.path) {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else { StoredPhoto(id: reference.id, thumbnail: true) }
                    }
                }
                if importing { ProgressView(importProgress) }
                Button("Add photos", systemImage: "photo.badge.plus") { choosingPhotos = true }
                    .disabled(importing).accessibilityIdentifier("add-memory-photos")
            }
            if exists {
                Section { Button("Delete memory", role: .destructive) { confirmDelete = true } }
            }
        }.scrollContentBackground(.hidden).background(Palette.background).foregroundStyle(Palette.ink)
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
            .modifier(EditorControls(saving: saving,
                canSave: !importing && (!draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.photoIDs.isEmpty || !draft.personIDs.isEmpty),
                dismissalBlocked: importing, error: $error, errorTitle: "Couldn’t save memory", saveIdentifier: "save-memory",
                cancel: { importTask?.cancel(); photoDraft.discard(); dismiss() }, save: { save() }))
            .confirmationDialog("Delete this memory and its photos?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete memory", role: .destructive) { save(deleting: true) }
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
                photoDraft.discard(); dismiss()
            } catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}

/// Re-encode pixels only: no original EXIF, GPS, camera identifiers or filenames.
/// These bounded copies live in the same protected, backup-excluded SQLite store as history.
enum MemoryPhotoImport {
    nonisolated static func make(_ data: Data) throws -> MemoryPhoto {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw MemoryError.invalidPhoto }
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
                               thumbnail: encoded(maximumSize: 320, byteLimit: 50_000))
    }
}
