import SwiftUI
import PlacesCore

struct CatalogPlaceRow: View {
    let place: CatalogPlace
    let anchor: Coordinate?
    let saved: Bool
    var body: some View {
        HStack(spacing: Layout.spacing) {
            Image(systemName: saved ? "checkmark.circle.fill" : place.symbol)
                .foregroundStyle(Palette.controlGreen).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(place.name).foregroundStyle(Palette.ink)
                Text(saved ? "Already saved" : [place.categoryTitle, detail].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(Palette.muted)
                if !place.address.isEmpty { Text(place.address).font(.caption).foregroundStyle(Palette.muted) }
            }
        }.frame(minHeight: Layout.touchTarget).accessibilityElement(children: .combine)
    }
    private var detail: String {
        guard let anchor else { return place.region }
        let metres = place.coordinate.distance(to: anchor)
        return metres < 1_000 ? "\(Int(metres.rounded())) m" : String(format: "%.1f km", metres / 1_000)
    }
}

struct PlaceCatalogSearch: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let anchor: Coordinate?
    let select: (CatalogPlace) -> Void
    @State private var query = ""
    @FocusState private var queryFocused: Bool
    @State private var results: [CatalogPlace] = []
    @State private var loading = false
    @State private var failed = false
    var body: some View {
        List {
            Section {
                TextField("Name, category or address", text: $query)
                    .autocorrectionDisabled().submitLabel(.search).accessibilityIdentifier("catalog-query")
                    .focused($queryFocused).onSubmit { queryFocused = false }
            } footer: { Text("Amsterdam & surroundings · Kos island. Searched on this iPhone.") }
            if loading { ProgressView("Searching…") }
            else if failed { Text("Place suggestions are unavailable. You can still enter a place yourself.") }
            else if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && results.isEmpty {
                Text("No matching places. Try another name, or enter it yourself.").foregroundStyle(Palette.muted)
            }
            ForEach(results) { place in
                Button { select(place); dismiss() } label: {
                    CatalogPlaceRow(place: place, anchor: anchor, saved: place.reference.savedPlace(in: model.places) != nil)
                }.accessibilityIdentifier("catalog-result-\(place.id)")
            }
        }.scrollDismissesKeyboard(.interactively).scrollContentBackground(.hidden).background(Palette.background)
            .navigationTitle("Find a place").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task(id: query) {
                results = []; failed = false
                guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { loading = false; return }
                loading = true
                do {
                    try await Task.sleep(for: .milliseconds(180))
                    let matches = try await PlaceCatalog.shared.search(query, near: anchor)
                    try Task.checkCancellation()
                    results = matches; loading = false
                } catch is CancellationError { }
                catch { if !Task.isCancelled { failed = true; loading = false } }
            }
    }
}

struct OfflinePlaceDataView: View {
    @State private var packs: [PlaceCatalogPack] = []
    @State private var attribution = ""
    @State private var failed = false
    var body: some View {
        List {
            Section {
                Text("These places are included with the app. Searches stay on your iPhone. Suggestions may be incomplete or out of date; check them before saving.")
            }
            ForEach(packs) { pack in
                Section(pack.name) {
                    LabeledContent("Places", value: pack.count.formatted())
                    LabeledContent("Data release", value: pack.release)
                }
            }
            if failed { Text("Offline place data is unavailable. You can still add places manually.") }
            Section("Attribution & licenses") { Text(attribution).font(.caption).textSelection(.enabled) }
        }.navigationTitle("Offline place data").task {
            do {
                packs = try await PlaceCatalog.shared.packs()
                attribution = try await PlaceCatalog.shared.attribution()
            } catch { failed = true }
        }
    }
}
