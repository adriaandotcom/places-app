import SwiftUI
import PhotosUI
import ImageIO
import UniformTypeIdentifiers
import PlacesCore

enum MemoryContext {
    case trip(Trip), place(Place), visit(TimelineItem)
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
        VStack(alignment: .leading, spacing: Layout.spacing) {
            HStack {
                Text("Memories").font(BrandFont.heading)
                Spacer()
                Button("Add", systemImage: "plus") { editing = context.draft }
                    .frame(minHeight: Layout.touchTarget).foregroundStyle(Palette.green).accessibilityIdentifier("add-memory")
            }
            ForEach(model.memories.memories.filter(context.includes)) { memory in MemoryCard(memory: memory) }
        }
        .sheet(item: $editing) { memory in NavigationStack { MemoryEditor(memory: memory) } }
    }
}

struct MemoryCard: View {
    @Environment(AppModel.self) private var model
    let memory: PlaceMemory
    @State private var editing = false
    @State private var selectedPhoto: PhotoSelection?
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
                Button("Edit memory", systemImage: "pencil") { editing = true }
                    .labelStyle(.iconOnly).frame(width: Layout.touchTarget, height: Layout.touchTarget).foregroundStyle(Palette.green)
            }
            if !memory.text.isEmpty { Text(memory.text).font(BrandFont.body).textSelection(.enabled) }
            if !memory.personIDs.isEmpty {
                ForEach(model.memories.people.filter { memory.personIDs.contains($0.id) }) { person in
                    NavigationLink { PersonDetail(personID: person.id) } label: { Label(person.name, systemImage: "person") }
                        .font(.subheadline).frame(minHeight: Layout.touchTarget)
                }
            }
            if !memory.photoIDs.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: Layout.compact) {
                    ForEach(Array(memory.photoIDs.enumerated()), id: \.element) { index, id in
                        Button { selectedPhoto = PhotoSelection(id: id) } label: {
                            StoredPhoto(id: id, thumbnail: true).frame(height: 96).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }.accessibilityLabel("Photo \(index + 1)")
                    }
                }
            }
        }.padding(Layout.spacing).background(Palette.paper, in: RoundedRectangle(cornerRadius: Layout.cardRadius))
            .sheet(isPresented: $editing) { NavigationStack { MemoryEditor(memory: memory) } }
            .sheet(item: $selectedPhoto) { photo in
                NavigationStack {
                    StoredPhoto(id: photo.id, thumbnail: false).background(Palette.background)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { selectedPhoto = nil } } }
                }
            }
    }
}
private struct PhotoSelection: Identifiable { let id: String }

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
    @State private var importing = false
    @State private var importProgress = ""
    @State private var importTask: Task<Void, Never>?
    @State private var saving = false
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var epoch: Int?
    init(memory: PlaceMemory) { _draft = State(initialValue: memory) }
    private var exists: Bool { model.memories.memories.contains { $0.id == draft.id } }
    var body: some View {
        Form {
            Section {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $draft.text).frame(minHeight: 135).accessibilityLabel("Note").accessibilityIdentifier("memory-note")
                    if draft.text.isEmpty { Text("Write a note…").foregroundStyle(Palette.muted).padding(.top, 8).padding(.leading, 4).allowsHitTesting(false) }
                }
            }
            Section {
                NavigationLink {
                    PeoplePicker(selection: $draft.personIDs)
                } label: {
                    LabeledContent("With", value: model.memories.people.filter { draft.personIDs.contains($0.id) }.map(\.name).joined(separator: ", ").isEmpty ? "Add people" : model.memories.people.filter { draft.personIDs.contains($0.id) }.map(\.name).joined(separator: ", "))
                }.accessibilityIdentifier("memory-people")
                if draft.visitStart == nil { DatePicker("Date", selection: $draft.date, in: ...Date(), displayedComponents: .date) }
            }
            Section("Photos") {
                if !draft.photoIDs.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))]) {
                        ForEach(draft.photoIDs, id: \.self) { id in
                            VStack(spacing: 0) {
                                if let photo = photos.first(where: { $0.id == id }), let image = UIImage(contentsOfFile: photo.thumbnailURL.path) {
                                    Image(uiImage: image).resizable().scaledToFit().frame(height: 90)
                                } else { StoredPhoto(id: id, thumbnail: true).frame(height: 90).clipped() }
                                Button("Remove photo", systemImage: "xmark.circle.fill") {
                                    if let photo = photos.first(where: { $0.id == id }) { photoDraft.remove(photo) }
                                    draft.photoIDs.removeAll { $0 == id }; photos.removeAll { $0.id == id }
                                }.labelStyle(.iconOnly).frame(minHeight: Layout.touchTarget)
                            }
                        }
                    }
                }
                if importing { ProgressView(importProgress) }
                PhotosPicker(selection: $selection, matching: .images) {
                        Label("Add photos", systemImage: "photo.badge.plus")
                }.disabled(importing).accessibilityIdentifier("add-memory-photos")
            }
            if exists {
                Section { Button("Delete memory", role: .destructive) { confirmDelete = true } }
            }
        }.scrollContentBackground(.hidden).background(Palette.background).foregroundStyle(Palette.ink)
            .navigationTitle(exists ? "Memory" : "Add a memory").navigationBarTitleDisplayMode(.inline)
            .onAppear { if epoch == nil { epoch = model.memoryEpoch } }
            .onChange(of: selection) { _, selected in
                guard !selected.isEmpty else { return }
                importing = true
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
                    selection = []; importing = false; importTask = nil
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { importTask?.cancel(); photoDraft.discard(); dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(saving || importing || (draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.photoIDs.isEmpty && draft.personIDs.isEmpty))
                        .accessibilityIdentifier("save-memory")
                }
            }
            .interactiveDismissDisabled(saving || importing)
            .alert("Couldn’t save memory", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
            .confirmationDialog("Delete this memory and its photos?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete memory", role: .destructive) { save(deleting: true) }
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
