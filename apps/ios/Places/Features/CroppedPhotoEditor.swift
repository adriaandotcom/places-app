import SwiftUI
import PhotosUI
import ImageIO
import Vision
import PlacesCore

/// The same private picker and square crop for people, places and trips.
struct CroppedPhotoField<Preview: View>: View {
    @Binding var photo: Data?
    var photoIDs: [String] = []
    var suggestsFaces = false
    let identifier: String
    @ViewBuilder let preview: () -> Preview
    @State private var choosing = false
    var body: some View {
        VStack(spacing: Layout.compact) {
            Button { choosing = true } label: { preview() }
                .buttonStyle(.plain).accessibilityLabel(photo == nil ? "Add photo" : "Change photo")
                .accessibilityIdentifier(identifier)
            Button(photo == nil ? "Add photo" : "Change photo") { choosing = true }.buttonStyle(.borderless)
            if photo != nil { Button("Remove photo", role: .destructive) { photo = nil }.buttonStyle(.borderless) }
        }.frame(maxWidth: .infinity).padding(.vertical, Layout.compact)
            .sheet(isPresented: $choosing) {
                NavigationStack {
                    CroppedPhotoChooser(photoIDs: photoIDs, suggestsFaces: suggestsFaces) { photo = $0; choosing = false }
                }
            }
    }
}

private struct PhotoCropSource: Identifiable, Hashable {
    let id = UUID()
    let data: Data
    var crop: CGRect?
}
private struct PhotoCropSuggestion: Identifiable, Sendable {
    let id: String
    let photoID: String
    let preview: Data
    let crop: CGRect?
}

struct CroppedPhotoChooser: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var photoIDs: [String] = []
    var suggestsFaces = false
    let use: (Data) -> Void
    @State private var selection: PhotosPickerItem?
    @State private var source: PhotoCropSource?
    @State private var faces: [PhotoCropSuggestion] = []
    @State private var photos: [PhotoCropSuggestion] = []
    @State private var scanPhotoIDs: [String]?
    @State private var scannedPhotoIDs: Set<String> = []
    @State private var scanning = true
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.spacing) {
                PhotosPicker(selection: $selection, matching: .images, preferredItemEncoding: .current) {
                    Label("Choose a photo", systemImage: "photo.badge.plus")
                }.buttonStyle(PrimaryButton()).disabled(loading).accessibilityIdentifier("choose-crop-photo")
                if loading { ProgressView("Opening photo…") }
                if !faces.isEmpty {
                    SectionHeading(title: "Faces from shared trips")
                    suggestionGrid(faces, facesOnly: true)
                }
                if !photos.isEmpty {
                    SectionHeading(title: "Photos from memories")
                    suggestionGrid(photos, facesOnly: false)
                }
                if scanning { ProgressView("Finding photos on this iPhone…") }
            }.padding(Layout.gutter)
        }.background(Palette.background).foregroundStyle(Palette.ink)
            .navigationTitle("Choose photo").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onChange(of: selection) { importSelection() }
            .navigationDestination(item: $source) { source in PhotoCropEditor(source: source, use: use) }
            .task { await loadSuggestions() }
            .alert("Couldn’t open photo", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") {} } message: { Text(error ?? "") }
    }
    @ViewBuilder private func suggestionGrid(_ suggestions: [PhotoCropSuggestion], facesOnly: Bool) -> some View {
        PhotoGrid(items: suggestions, label: { facesOnly ? "Suggested face \($0 + 1)" : "Suggested photo \($0 + 1)" }, open: open) { suggestion in
            if let image = UIImage(data: suggestion.preview) { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "photo").foregroundStyle(Palette.muted) }
        }.disabled(loading)
    }

    private func importSelection() {
        guard !loading, let selected = selection else { return }
        selection = nil; loading = true
        Task {
            defer { loading = false }
            do {
                guard let data = try await selected.loadTransferable(type: Data.self) else { throw MemoryError.invalidPhoto }
                let clean = try await Task.detached(priority: .userInitiated) { try MemoryPhotoImport.make(data).jpeg }.value
                source = PhotoCropSource(data: clean)
            } catch { self.error = "Try choosing that photo again." }
        }
    }
    private func open(_ suggestion: PhotoCropSuggestion) {
        guard !loading else { return }
        loading = true
        Task {
            defer { loading = false }
            do {
                guard let data = try await model.store?.photoData(id: suggestion.photoID) else { throw MemoryError.invalidPhoto }
                source = PhotoCropSource(data: data, crop: suggestion.crop)
            } catch { self.error = "This photo is no longer available." }
        }
    }
    private func loadSuggestions() async {
        scanning = true
        defer { scanning = false }
        guard let store = model.store else { return }
        // Keep one ordered snapshot while this chooser is open. Returning from
        // Photos or the crop screen resumes unfinished work without duplicating it.
        if scanPhotoIDs == nil {
            var seen: Set<String> = []
            scanPhotoIDs = Array(photoIDs.filter { seen.insert($0).inserted }.prefix(40))
        }
        for id in scanPhotoIDs ?? [] where !scannedPhotoIDs.contains(id) {
            guard !Task.isCancelled else { return }
            do {
                guard let preview = try await store.photoData(id: id, thumbnail: true) else {
                    scannedPhotoIDs.insert(id); continue
                }
                guard !Task.isCancelled else { return }
                // Show inexpensive thumbnails before running face detection.
                if !photos.contains(where: { $0.id == id }) {
                    photos.append(PhotoCropSuggestion(id: id, photoID: id, preview: preview, crop: nil))
                }
                if suggestsFaces, faces.count < 12, let data = try await store.photoData(id: id) {
                    let suggestions = await Task.detached(priority: .utility) {
                        (try? SquarePhotoImage.faceCrops(in: data))?.enumerated().compactMap { index, rect -> PhotoCropSuggestion? in
                            guard let thumb = try? SquarePhotoImage.cropped(data, rect: rect, maximumSize: 160) else { return nil }
                            return PhotoCropSuggestion(id: "\(id)-face-\(index)", photoID: id, preview: thumb, crop: rect)
                        } ?? []
                    }.value
                    guard !Task.isCancelled else { return }
                    faces.append(contentsOf: suggestions.prefix(12 - faces.count))
                }
                scannedPhotoIDs.insert(id)
            } catch {
                guard !Task.isCancelled else { return }
                scannedPhotoIDs.insert(id)
            }
        }
    }
}

enum SquarePhotoImage {
    nonisolated static func faceCrops(in data: Data) throws -> [CGRect] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 800
              ] as CFDictionary) else { throw MemoryError.invalidPhoto }
        let request = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).sorted { $0.boundingBox.width * $0.boundingBox.height > $1.boundingBox.width * $1.boundingBox.height }.map {
            square(around: CGRect(x: $0.boundingBox.minX, y: 1 - $0.boundingBox.maxY, width: $0.boundingBox.width, height: $0.boundingBox.height), width: Double(image.width), height: Double(image.height))
        }
    }
    /// A square in pixels, expressed as top-left normalized coordinates for the crop UI.
    nonisolated static func square(around face: CGRect, width: Double, height: Double) -> CGRect {
        let side = min(min(width, height), max(face.width * width, face.height * height) * 1.9)
        let x = min(max(0, face.midX * width - side / 2), width - side)
        let y = min(max(0, face.midY * height - side / 2), height - side)
        return CGRect(x: x / width, y: y / height, width: side / width, height: side / height)
    }
    nonisolated static func cropped(_ data: Data, rect: CGRect, maximumSize: Int = 512) throws -> Data {
        let original = try image(data)
        let bounds = CGRect(x: 0, y: 0, width: original.width, height: original.height)
        let requested = CGRect(x: rect.minX * bounds.width, y: rect.minY * bounds.height, width: rect.width * bounds.width, height: rect.height * bounds.height).intersection(bounds)
        guard !requested.isNull, requested.width >= 1, requested.height >= 1 else { throw MemoryError.invalidPhoto }
        let side = floor(min(requested.width, requested.height))
        let square = CGRect(x: floor(requested.midX - side / 2), y: floor(requested.midY - side / 2), width: side, height: side)
        guard let cropped = original.cropping(to: square) else { throw MemoryError.invalidPhoto }
        let size = min(maximumSize, Int(side))
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw MemoryError.invalidPhoto }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let image = context.makeImage() else { throw MemoryError.invalidPhoto }
        for quality in [0.85, 0.7, 0.5] {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw MemoryError.invalidPhoto }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            if CGImageDestinationFinalize(destination), data.length <= 200_000 { return data as Data }
        }
        throw MemoryError.invalidPhoto
    }
    nonisolated private static func image(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw MemoryError.invalidPhoto }
        return image
    }
}

private struct PhotoCropEditor: View {
    @Environment(\.dismiss) private var dismiss
    let source: PhotoCropSource
    let use: (Data) -> Void
    @State private var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var zoom: CGFloat = 1
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        VStack(spacing: Layout.spacing) {
            Spacer()
            if let image = UIImage(data: source.data) {
                SquareCropSurface(image: image, initialCrop: source.crop, crop: $crop, zoom: $zoom)
                    .aspectRatio(1, contentMode: .fit).clipped()
                    .overlay { Rectangle().stroke(Palette.green, lineWidth: 2).allowsHitTesting(false) }
                    .accessibilityIdentifier("photo-crop")
                HStack {
                    Image(systemName: "minus.magnifyingglass")
                    Slider(value: $zoom, in: 1...8).accessibilityLabel("Crop zoom")
                    Image(systemName: "plus.magnifyingglass")
                }.padding(.horizontal, Layout.gutter)
                Text("Move and pinch to crop").font(.subheadline).foregroundStyle(Palette.muted)
            }
            Spacer()
        }.padding(Layout.gutter).background(Palette.background)
            .navigationTitle("Crop photo").navigationBarTitleDisplayMode(.inline)
            .modifier(EditorControls(saving: saving, error: $error, errorTitle: "Couldn’t crop photo", saveTitle: "Use photo",
                saveIdentifier: "use-photo-crop", cancel: { dismiss() }, save: save))
    }
    private func save() {
        saving = true
        let rect = crop
        Task {
            do {
                let data = try await Task.detached(priority: .userInitiated) { try SquarePhotoImage.cropped(source.data, rect: rect) }.value
                use(data)
            }
            catch { self.error = "Try choosing the photo again." }
            saving = false
        }
    }
}

private struct SquareCropSurface: UIViewRepresentable {
    let image: UIImage
    let initialCrop: CGRect?
    @Binding var crop: CGRect
    @Binding var zoom: CGFloat
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> CropScrollView {
        let view = CropScrollView(image: image, initialCrop: initialCrop)
        view.delegate = context.coordinator
        return view
    }
    func updateUIView(_ view: CropScrollView, context: Context) {
        context.coordinator.parent = self
        if view.configured, abs(context.coordinator.lastZoom - zoom) > 0.001 {
            context.coordinator.lastZoom = zoom
            view.setZoomScale(view.minimumZoomScale * zoom, animated: false)
        }
    }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: SquareCropSurface
        var lastZoom: CGFloat = 1
        init(_ parent: SquareCropSurface) { self.parent = parent }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? CropScrollView)?.photo }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { update(scrollView) }
        func scrollViewDidScroll(_ scrollView: UIScrollView) { update(scrollView) }
        private func update(_ scrollView: UIScrollView) {
            guard let view = scrollView as? CropScrollView, view.configured else { return }
            let width = view.photo.bounds.width * view.zoomScale, height = view.photo.bounds.height * view.zoomScale
            guard width > 0, height > 0 else { return }
            let rect = CGRect(x: view.contentOffset.x / width, y: view.contentOffset.y / height,
                              width: view.bounds.width / width, height: view.bounds.height / height)
            let zoom = view.zoomScale / view.minimumZoomScale
            lastZoom = zoom
            DispatchQueue.main.async { self.parent.crop = rect; self.parent.zoom = zoom }
        }
    }
}

private final class CropScrollView: UIScrollView {
    let photo: UIImageView
    let initialCrop: CGRect?
    var configured = false
    init(image: UIImage, initialCrop: CGRect?) {
        photo = UIImageView(image: image); self.initialCrop = initialCrop
        super.init(frame: .zero)
        addSubview(photo); showsHorizontalScrollIndicator = false; showsVerticalScrollIndicator = false
        bounces = false; bouncesZoom = false; contentInsetAdjustmentBehavior = .never
        accessibilityLabel = "Photo crop"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard !configured, bounds.width > 0, bounds.height > 0, let size = photo.image?.size else { return }
        photo.frame = CGRect(origin: .zero, size: size); contentSize = size
        minimumZoomScale = max(bounds.width / size.width, bounds.height / size.height)
        maximumZoomScale = minimumZoomScale * 8
        configured = true
        let initialZoom = initialCrop.map { bounds.width / ($0.width * size.width) } ?? minimumZoomScale
        setZoomScale(min(maximumZoomScale, max(minimumZoomScale, initialZoom)), animated: false)
        let center = initialCrop.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: 0.5, y: 0.5)
        contentOffset = CGPoint(x: max(0, min(contentSize.width - bounds.width, center.x * contentSize.width - bounds.width / 2)),
                                y: max(0, min(contentSize.height - bounds.height, center.y * contentSize.height - bounds.height / 2)))
        delegate?.scrollViewDidScroll?(self)
    }
}
