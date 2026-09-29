import SwiftUI
import PlacesCore

struct MergePlacePicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let edited: Place
    let onMerged: () -> Void
    @State private var query = ""
    @State private var selected: Place?
    @State private var saving = false
    @State private var error: String?
    private var choices: [Place] {
        model.places.filter { $0.id != edited.id && (query.isEmpty || $0.name.localizedStandardContains(query)) }
            .sorted { $0.coordinate.distance(to: edited.coordinate) < $1.coordinate.distance(to: edited.coordinate) }
    }
    private var plan: PlaceMergePlan? {
        selected.map { PlaceMergePlan(edited, $0, memories: model.memories.memories) }
    }
    private var placeList: some View {
        List {
            Section("Merge with") {
                ForEach(choices) { place in
                    Button { selected = place } label: { SavedPlaceRow(place: place, showsDisclosure: true) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("merge-with-\(place.id)")
                        .accessibilityAddTraits(selected?.id == place.id ? .isSelected : [])
                }
                if choices.isEmpty { Text("No other places match.").foregroundStyle(Palette.muted) }
            }
            if let error { Text(error).foregroundStyle(Palette.warning) }
        }
    }
    var body: some View {
        placeList.scrollContentBackground(.hidden).background(Palette.background)
            .navigationTitle("Merge place").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Find a saved place")
            .disabled(saving).interactiveDismissDisabled(saving)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) } }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let plan {
                    VStack(alignment: .leading, spacing: Layout.compact) {
                        SavedPlaceRow(place: plan.kept, title: "Keep " + plan.kept.name, subtitle: "Appearance and recognition area")
                        Text("Visits, memories, photos and Wi-Fi networks from \(plan.removed.name) will be added here.")
                            .font(.footnote).foregroundStyle(Palette.muted)
                        Button("Merge into \(plan.kept.name)") { merge(plan) }
                            .buttonStyle(PrimaryButton()).disabled(saving)
                            .accessibilityIdentifier("confirm-place-merge")
                    }.padding(Layout.gutter).background(Palette.background)
                }
            }
    }
    private func merge(_ plan: PlaceMergePlan) {
        let otherID = plan.kept.id == edited.id ? plan.removed.id : plan.kept.id
        saving = true
        Task {
            do { try await model.mergePlaces(edited, with: otherID, keeping: plan.kept.id); onMerged() }
            catch { self.error = "Couldn’t merge these places. Please try again." }
            saving = false
        }
    }
}
