import SwiftUI
import UniformTypeIdentifiers
import PlacesCore

struct DraftPhotoThumbnail: View {
    let id: String
    let files: [MemoryPhotoFile]
    var body: some View {
        if let file = files.first(where: { $0.id == id }), let image = UIImage(contentsOfFile: file.thumbnailURL.path) {
            Image(uiImage: image).resizable().scaledToFill()
        } else { StoredPhoto(id: id, thumbnail: true) }
    }
}

struct MemoryPhotoOrderEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var memory: PlaceMemory
    let files: [MemoryPhotoFile]
    var body: some View {
        List {
            ForEach(Array(memory.orderedPhotoIDs.enumerated()), id: \.element) { index, id in
                HStack(spacing: Layout.spacing) {
                    DraftPhotoThumbnail(id: id, files: files)
                        .frame(width: Layout.avatarSize, height: Layout.avatarSize).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: Layout.compact))
                    VStack(alignment: .leading, spacing: Layout.compact) {
                        Text(memory.photoDetails?[id]?.caption.isEmpty == false ? memory.photoDetails![id]!.caption : "Photo \(index + 1)").lineLimit(2)
                        if let date = PhotoDate.label(memory.photoDetails?[id]) { Text(date).font(.caption).foregroundStyle(Palette.muted) }
                    }
                }
            }.onMove { source, destination in
                var ids = memory.orderedPhotoIDs; ids.move(fromOffsets: source, toOffset: destination)
                memory.photoIDs = ids; memory.photosManuallyOrdered = true
            }
        }.environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden).background(Palette.background)
            .navigationTitle("Photo order").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Date order") { memory.photosManuallyOrdered = false } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
    }
}

enum PhotoDate {
    static func label(_ details: MemoryPhotoDetails?) -> String? {
        guard let date = details?.createdAt else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        formatter.timeZone = TimeZone(secondsFromGMT: details?.utcOffsetSeconds ?? 0)
        return formatter.string(from: date)
    }
}

struct SavedMemoryPhotoBrowser: View {
    @Environment(AppModel.self) private var model
    let memoryID: String
    let initialID: String
    @State private var epoch: Int?
    var body: some View {
        if let memory = model.memories.memories.first(where: { $0.id == memoryID }) {
            MemoryPhotoBrowser(photoIDs: memory.orderedPhotoIDs, initialID: initialID, details: memory.photoDetails ?? [:],
                load: { try await model.store?.photoData(id: $0) }, saveCaption: { id, caption in
                    guard let epoch else { throw CancellationError() }
                    try await model.changeMemories(epoch: epoch) { try await $0.updatePhotoCaption(memoryID: memoryID, photoID: id, caption: caption) }
                }).onAppear { if epoch == nil { epoch = model.memoryEpoch } }
        }
    }
}

/// Shared by saved memories and unsaved drafts; it never requests library access.
struct MemoryPhotoBrowser: View {
    @Environment(\.dismiss) private var dismiss
    let photoIDs: [String]
    let details: [String: MemoryPhotoDetails]
    let load: (String) async throws -> Data?
    let saveCaption: ((String, String) async throws -> Void)?
    @State private var selectedID: String
    private enum Detail: Identifiable {
        case caption(String), location(String)
        var id: String { switch self { case .caption(let id): "caption-" + id; case .location(let id): "location-" + id } }
    }
    @State private var presentedDetail: Detail?
    @State private var share: SharedPhoto?
    @State private var sharePreview: Image?
    @State private var exporting = false
    @State private var exportError: String?
    init(photoIDs: [String], initialID: String, details: [String: MemoryPhotoDetails],
         load: @escaping (String) async throws -> Data?, saveCaption: ((String, String) async throws -> Void)? = nil) {
        self.photoIDs = photoIDs; self.details = details; self.load = load; self.saveCaption = saveCaption
        _selectedID = State(initialValue: initialID)
    }
    private var index: Int { photoIDs.firstIndex(of: selectedID) ?? 0 }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                MemoryPhotoPager(photoIDs: photoIDs, selectedID: $selectedID, load: load)
                VStack(spacing: Layout.compact) {
                    if let date = PhotoDate.label(details[selectedID]) { Text(date).font(.caption).foregroundStyle(Palette.muted).accessibilityIdentifier("photo-created-at") }
                    if saveCaption != nil { Button { presentedDetail = .caption(selectedID) } label: {
                        Text(details[selectedID]?.caption.isEmpty == false ? details[selectedID]!.caption : "Add a caption…")
                            .font(.subheadline).lineLimit(3).frame(maxWidth: .infinity, minHeight: Layout.touchTarget)
                    }.accessibilityIdentifier("photo-caption") }
                }.padding(.horizontal, Layout.gutter).padding(.bottom, Layout.compact)
            }.background(Palette.background).foregroundStyle(Palette.ink)
                .navigationTitle("\(index + 1) of \(photoIDs.count)").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                    ToolbarItemGroup(placement: .bottomBar) {
                        Menu {
                            if let share, let sharePreview {
                                ShareLink(item: share, preview: SharePreview("Photo", image: sharePreview)) { Label("Share photo", systemImage: "square.and.arrow.up") }
                                Button("Save to Files", systemImage: "folder") { exporting = true }
                            }
                        } label: { Label("Export photo", systemImage: "square.and.arrow.up") }
                            .disabled(share == nil).accessibilityIdentifier("export-memory-photo")
                        Spacer()
                        Button("Previous photo", systemImage: "chevron.left") { selectedID = photoIDs[index - 1] }.disabled(index == 0)
                        Button("Next photo", systemImage: "chevron.right") { selectedID = photoIDs[index + 1] }.disabled(index + 1 >= photoIDs.count)
                        Spacer()
                        if details[selectedID]?.coordinate != nil {
                            Button("Photo location", systemImage: "info.circle") { presentedDetail = .location(selectedID) }.accessibilityIdentifier("photo-location")
                        }
                    }
                }
                .task(id: selectedID) {
                    share = nil; sharePreview = nil
                    do {
                        guard let data = try await load(selectedID), !Task.isCancelled, let image = UIImage(data: data) else { return }
                        share = SharedPhoto(data: data); sharePreview = Image(uiImage: image)
                    } catch { /* The page displays the load failure; sharing stays unavailable. */ }
                }
                .fileExporter(isPresented: $exporting, document: share.map { PhotoDocument(data: $0.data) }, contentType: .jpeg, defaultFilename: "Places photo") { result in
                    if case .failure(let error) = result { exportError = error.localizedDescription }
                }
                .alert("Couldn’t export photo", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
                    Button("OK") {}
                } message: { Text(exportError ?? "") }
        }
        // One presenter on the browser root, independent of paging content and
        // toolbar updates while a photo finishes loading.
        .sheet(item: $presentedDetail) { detail in
            NavigationStack {
                switch detail {
                case .caption(let id):
                    PhotoCaptionEditor(caption: details[id]?.caption ?? "", cancel: { presentedDetail = nil }, save: { caption in
                        try await saveCaption?(id, caption)
                        presentedDetail = nil
                    })
                case .location(let id):
                    ScrollView {
                        if let coordinate = details[id]?.coordinate {
                            PrivacyMapView(items: [], routePoints: [], customPresentation: MapPresentation(pins: [
                                MapPin(id: id, name: "Photo location", coordinate: coordinate, symbol: "photo", colorIndex: 1)
                            ])).frame(height: Layout.mapHeight).clipShape(RoundedRectangle(cornerRadius: Layout.cardRadius))
                                .padding(Layout.gutter)
                        }
                    }.background(Palette.background).navigationTitle("Photo location").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { presentedDetail = nil } } }
                }
            }
        }
    }
}

private struct SharedPhoto: Transferable {
    let data: Data
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .jpeg) { $0.data }.suggestedFileName("Places photo.jpg")
    }
}

private struct PhotoDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.jpeg] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

private struct PhotoCaptionEditor: View {
    @State var caption: String
    let cancel: () -> Void
    let save: (String) async throws -> Void
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        Form { TextField("Add a caption…", text: $caption, axis: .vertical).lineLimit(3...8).accessibilityIdentifier("photo-caption-input") }
            .scrollContentBackground(.hidden).background(Palette.background)
            .navigationTitle("Caption").navigationBarTitleDisplayMode(.inline)
            .modifier(EditorControls(saving: saving, canSave: true, error: $error, errorTitle: "Couldn’t save caption", cancel: cancel, save: {
                saving = true
                Task {
                    do { try await save(caption) } catch { self.error = error.localizedDescription }
                    saving = false
                }
            }))
    }
}

struct PhotoBrowserPage: View {
    let id: String
    let active: Bool
    let load: (String) async throws -> Data?
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let image { ZoomablePhoto(image: image, active: active) }
            else if failed { ContentUnavailableView("Photo unavailable", systemImage: "photo") }
            else { ProgressView() }
        }.task(id: id) {
            do {
                guard let data = try await load(id), !Task.isCancelled, let decoded = UIImage(data: data) else { failed = true; return }
                image = decoded
            } catch { failed = true }
        }
    }
}

/// UIScrollView supplies native pinch, pan, double-tap and gesture cancellation.
private struct ZoomablePhoto: UIViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let image: UIImage
    let active: Bool
    func makeUIView(context: Context) -> PhotoZoomScrollView { PhotoZoomScrollView() }
    func updateUIView(_ view: PhotoZoomScrollView, context: Context) {
        view.animateZoom = !reduceMotion
        if view.photo.image !== image { view.photo.image = image; view.resetLayout() }
        if !active { view.setZoomScale(1, animated: false) }
    }
}

private final class PhotoZoomScrollView: UIScrollView, UIScrollViewDelegate {
    let photo = UIImageView()
    var animateZoom = true
    private var previousSize = CGSize.zero
    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self; minimumZoomScale = 1; maximumZoomScale = 5
        showsHorizontalScrollIndicator = false; showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never; backgroundColor = .clear
        photo.contentMode = .scaleAspectFit; addSubview(photo)
        panGestureRecognizer.isEnabled = false
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2; addGestureRecognizer(doubleTap)
        isAccessibilityElement = true; accessibilityLabel = "Photo"; accessibilityIdentifier = "zoomable-memory-photo"
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Zoom in or out", target: self, selector: #selector(accessibleZoom))]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func resetLayout() { previousSize = .zero; setNeedsLayout() }
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != previousSize, bounds.width > 0, bounds.height > 0, let image = photo.image {
            previousSize = bounds.size; setZoomScale(1, animated: false)
            let ratio = min(bounds.width / image.size.width, bounds.height / image.size.height)
            photo.frame = CGRect(origin: .zero, size: CGSize(width: image.size.width * ratio, height: image.size.height * ratio))
            contentSize = photo.bounds.size
        }
        centerPhoto()
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { photo }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        panGestureRecognizer.isEnabled = zoomScale > 1.01
        accessibilityValue = zoomScale > 1.01 ? "Zoomed" : "Full photo"
        centerPhoto()
    }
    private func centerPhoto() {
        let horizontal = max(0, (bounds.width - photo.frame.width) / 2)
        let vertical = max(0, (bounds.height - photo.frame.height) / 2)
        let inset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        if contentInset != inset { contentInset = inset }
    }
    @objc private func toggleZoom(_ gesture: UITapGestureRecognizer) {
        if zoomScale > 1.01 { setZoomScale(1, animated: animateZoom) }
        else {
            let point = gesture.location(in: photo), width = bounds.width / 3, height = bounds.height / 3
            zoom(to: CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height), animated: animateZoom)
        }
    }
    @objc private func accessibleZoom() -> Bool { setZoomScale(zoomScale > 1.01 ? 1 : 3, animated: animateZoom); return true }
}
