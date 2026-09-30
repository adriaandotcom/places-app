import SwiftUI
import PlacesCore
import CryptoKit
#if canImport(JournalingSuggestions) && !targetEnvironment(simulator)
@preconcurrency import JournalingSuggestions
#endif

struct AppleSuggestionSelection: Identifiable {
    let id: String
    var title: String
    var date: DateInterval?
    var candidates: [PastVisitCandidate]
    var photos: [MemoryPhotoFile]
    // Own the protected files until the review is saved or dismissed.
    let photoDraft: MemoryPhotoDraft
    var sourceName = "Apple"

    func memory(at place: Place) -> PlaceMemory {
        var memory = PlaceMemory(id: PlaceMemory.suggestionID(id, placeID: place.id), text: title,
            date: date?.start ?? photos.compactMap { $0.details?.createdAt }.min() ?? Date(),
            placeID: place.id, photoIDs: photos.map(\.id))
        memory.photoDetails = Dictionary(uniqueKeysWithValues: photos.compactMap { photo in photo.details.map { (photo.id, $0) } })
        return memory
    }
}

struct PastVisitsRequest: Identifiable { let id = UUID(); let day: Date }

struct AddPastVisitsButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label("Add past visits", systemImage: "clock.arrow.circlepath").frame(maxWidth: .infinity)
        }.buttonStyle(PrimaryButton()).accessibilityIdentifier("add-past-visits")
    }
}

/// Keep the presenter above lazy rows and changing timeline pages. Saving one
/// suggestion can replace the empty day that originally opened this flow.
struct AppleSuggestionsFlow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var day: Date = Date()
    var place: Place?
    @State private var picker = false
    @State private var selection: AppleSuggestionSelection?
    @State private var loading = false
    @State private var started = false
    @State private var saved: String?
    @State private var error: String?
    @State private var loadTask: Task<Void, Never>?
    @State private var fixtureIndex = 0
    private var alreadyAdded: Bool {
        guard let selection, let place else { return false }
        return model.memories.memories.contains { $0.id == PlaceMemory.suggestionID(selection.id, placeID: place.id) }
    }
    var body: some View {
        Group {
            #if DEBUG
            if model.uiTesting {
                // Exercise the actual modal lifecycle; never skip directly to review.
                content.sheet(isPresented: $picker) { fixturePicker }
            } else { systemPicker }
            #else
            systemPicker
            #endif
        }.environment(\.hasMainNavigation, false)
            .onDisappear { loadTask?.cancel() }
    }

    private var content: some View {
        NavigationStack {
            Group {
                if let saved { completion(saved) }
                else if alreadyAdded { completion("This memory is already added") }
                else if let selection {
                    if let place {
                        MemoryEditor(memory: selection.memory(at: place), importing: selection.photos) { finish("Memory added") }
                            .id(selection.id)
                    } else {
                        PastVisitReview(selection: selection, day: day, onSaved: finish, chooseNext: choose).id(selection.id)
                    }
                } else {
                    VStack(spacing: Layout.spacing) {
                        if loading { ProgressView("Loading your suggestion…") }
                        else {
                            Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(Palette.green)
                            Text(error ?? "Choose a moment to remember").font(BrandFont.title).multilineTextAlignment(.center)
                            Button("Choose a suggestion", action: choose).buttonStyle(PrimaryButton())
                                .accessibilityIdentifier("choose-apple-suggestion")
                        }
                    }.padding(Layout.gutter).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .navigationTitle("Apple suggestions").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { loadTask?.cancel(); dismiss() } } }
                }
            }.background(Palette.background).foregroundStyle(Palette.ink)
                .interactiveDismissDisabled(loading)
        }.background {
            SuggestionPresentationReady {
                guard !started else { return }
                started = true
                choose()
            }.frame(width: 0, height: 0)
        }
    }

    private var systemPicker: some View {
        #if canImport(JournalingSuggestions) && !targetEnvironment(simulator)
        // Keep the picker on the stable navigation container, not on the branch
        // replaced when loading, reviewing, or choosing another suggestion.
        content.journalingSuggestionsPicker(isPresented: $picker) { suggestion in
            loading = true
            let epoch = model.memoryEpoch
            loadTask = Task {
                do {
                    let selected = try await Self.load(suggestion)
                    try Task.checkCancellation()
                    guard epoch == model.memoryEpoch else { throw CancellationError() }
                    selection = selected
                } catch is CancellationError {} catch {
                    self.error = "This suggestion couldn’t be loaded. Please choose it again."
                }
                loading = false; loadTask = nil
            }
            // Apple owns dismissal. Keep its completion alive until shared files
            // are copied instead of dismissing its presenter during the import.
            await loadTask?.value
        }
        #else
        content
        #endif
    }

    private func completion(_ title: String) -> some View {
        VStack(spacing: Layout.spacing) {
            Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(Palette.green)
            Text(title).font(BrandFont.heading).multilineTextAlignment(.center).accessibilityIdentifier("suggestion-saved")
            Button("Choose next suggestion", action: choose).buttonStyle(PrimaryButton()).accessibilityIdentifier("next-suggestion")
        }.padding(Layout.gutter).frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
    private func finish(_ message: String) {
        saved = message
        selection?.photoDraft.discard(); selection = nil
    }
    private func choose() {
        selection?.photoDraft.discard(); selection = nil; saved = nil; error = nil
        #if DEBUG
        if model.uiTesting {
            picker = true
            return
        }
        #endif
        #if canImport(JournalingSuggestions) && !targetEnvironment(simulator)
        picker = true
        #else
        error = "Open Places on your iPhone to choose Apple’s suggestions."
        #endif
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    #if canImport(JournalingSuggestions) && !targetEnvironment(simulator)
    private static func load(_ suggestion: JournalingSuggestion) async throws -> AppleSuggestionSelection {
        let individual = await suggestion.content(forType: JournalingSuggestion.Location.self)
        let groups = await suggestion.content(forType: JournalingSuggestion.LocationGroup.self)
        let undatedSelectionID = suggestion.items.map { $0.id.uuidString }.sorted().joined(separator: ",")
        let eventIdentity = suggestion.date.map { "\($0.start.timeIntervalSince1970):\($0.end.timeIntervalSince1970)" } ?? undatedSelectionID
        var seen: Set<String> = []
        let candidates = (individual + groups.flatMap(\.locations)).compactMap { location -> PastVisitCandidate? in
            let coordinate = location.location.map { Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
            let identity = [location.place ?? "", location.city ?? "",
                coordinate.map { "\($0.latitude),\($0.longitude)" } ?? "",
                location.date.map { String($0.timeIntervalSince1970) } ?? eventIdentity].joined(separator: "|")
            let id = digest(identity)
            guard seen.insert(id).inserted else { return nil }
            return PastVisitCandidate(id: id, name: location.place ?? location.city ?? "", city: location.city,
                                      coordinate: coordinate, date: location.date)
        }.sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
        let photoDraft = MemoryPhotoDraft()
        var photos: [MemoryPhotoFile] = []
        // Decode one image per selected item, including the still of a Live Photo.
        // Prefer Photo when an item exposes both representations, without dropping
        // separate photos that happen to contain the same pixels.
        for item in suggestion.items {
            try Task.checkCancellation()
            let source: (URL, Date?)?
            if item.hasContent(ofType: JournalingSuggestion.Photo.self) {
                guard let photo = try await item.content(forType: JournalingSuggestion.Photo.self) else { throw MemoryError.invalidPhoto }
                source = (photo.photo, photo.date)
            } else if item.hasContent(ofType: JournalingSuggestion.LivePhoto.self) {
                guard let photo = try await item.content(forType: JournalingSuggestion.LivePhoto.self) else { throw MemoryError.invalidPhoto }
                source = (photo.image, photo.date)
            } else { source = nil }
            guard let (url, date) = source else { continue }
            let photo = try await Task.detached(priority: .userInitiated) { try MemoryPhotoImport.make(url: url, date: date) }.value
            try Task.checkCancellation()
            photos.append(try photoDraft.append(photo))
        }
        photos.sort { ($0.details?.createdAt ?? .distantFuture) < ($1.details?.createdAt ?? .distantFuture) }
        return AppleSuggestionSelection(id: digest(suggestion.title + "|" + eventIdentity), title: suggestion.title,
            date: suggestion.date, candidates: candidates, photos: photos, photoDraft: photoDraft)
    }
    #endif

    #if DEBUG
    private var fixturePicker: some View {
        NavigationStack {
            VStack(spacing: Layout.spacing) {
                Text("Synthetic suggestion picker")
                Button("Use sample suggestion") {
                    do { selection = try Self.fixture(day: day, index: fixtureIndex); fixtureIndex += 1 }
                    catch { self.error = "Couldn’t load the sample suggestion." }
                    picker = false
                }.accessibilityIdentifier("select-fixture-suggestion")
            }.toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel picker") { picker = false }.accessibilityIdentifier("cancel-fixture-suggestion")
                }
            }
        }
    }

    private static func fixture(day: Date, index: Int) throws -> AppleSuggestionSelection {
        let start = Calendar.current.startOfDay(for: min(day, Date().addingTimeInterval(-86_400))).addingTimeInterval(Double(10 + index * 3) * 3600)
        let photoDraft = MemoryPhotoDraft()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 120)).image { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
        }
        guard let data = image.jpegData(compressionQuality: 0.8) else { throw MemoryError.invalidPhoto }
        var photo = try MemoryPhotoImport.make(data)
        photo.details?.createdAt = start
        return AppleSuggestionSelection(id: "fixture-suggestion-\(index)", title: "A day in the city", date: nil, candidates: [
            PastVisitCandidate(id: "fixture-past-visit-\(index)", name: index == 0 ? "Fixture Garden" : "Fixture Café", city: "Fixture City",
                coordinate: Coordinate(latitude: 52.36 + Double(index) * 0.01, longitude: 4.88), date: start)
        ], photos: [try photoDraft.append(photo)], photoDraft: photoDraft)
    }
    #endif
}

/// SwiftUI's onAppear runs before the enclosing sheet finishes presenting.
/// UIKit's viewDidAppear gives the nested picker a visible, settled presenter.
private struct SuggestionPresentationReady: UIViewControllerRepresentable {
    let ready: () -> Void
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.ready = ready }
    final class Controller: UIViewController {
        var ready: (() -> Void)?
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            ready?()
        }
    }
}
