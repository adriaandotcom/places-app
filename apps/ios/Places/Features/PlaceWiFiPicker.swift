import SwiftUI
import PlacesCore

struct PlaceWiFiDraft {
    var names: [String]
    var entry = ""
    var error: String?

    @discardableResult mutating func add() -> Bool {
        let value = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { error = "Enter a Wi-Fi name first."; return false }
        guard !value.contains("\n"), value.utf8.count <= 32 else { error = "Check the network name in Wi-Fi settings."; return false }
        guard !names.contains(value) else { error = "This network is already added."; return false }
        names.append(value); entry = ""; error = nil
        return true
    }
    mutating func finish() -> Bool {
        entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || add()
    }
}

/// Shared by onboarding, new-place, visit naming and saved-place editing.
/// Everything stays in the draft until the enclosing place is saved.
struct PlaceWiFiEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: PlaceWiFiDraft
    let coordinate: Coordinate?
    let radius: Double
    @FocusState.Binding var fieldFocused: Bool
    @State private var adding = false
    @State private var removing: String?
    @State private var suggestions: [WiFiSuggestion] = []
    @State private var unavailable = false
    private var available: [WiFiSuggestion] { suggestions.filter { !draft.names.contains($0.ssid) } }
    private var query: WiFiSuggestionQuery {
        WiFiSuggestionQuery(coordinate: coordinate, radius: radius,
            connectionID: model.tracking.currentWiFiObservation?.id, revision: model.historyRevision)
    }
    var body: some View {
        Section {
            ForEach(draft.names, id: \.self) { name in
                HStack(spacing: Layout.spacing) {
                    Label(name, systemImage: "wifi").foregroundStyle(Palette.ink)
                    Spacer(minLength: 0)
                    Button { removing = name } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(Palette.muted)
                        .frame(minWidth: Layout.touchTarget, minHeight: Layout.touchTarget)
                        .accessibilityLabel("Remove \(name)")
                }.accessibilityIdentifier("saved-wifi-\(name)")
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Remove", systemImage: "trash") { removing = name }.tint(.red)
                    }
            }
            ForEach(available) { suggestion in
                WiFiSuggestionRow(suggestion: suggestion) {
                    draft.names.append(suggestion.ssid); draft.error = nil
                }
            }
            if adding {
                HStack {
                    TextField("Network name", text: $draft.entry)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .focused($fieldFocused).submitLabel(.done).onSubmit(add)
                        .accessibilityLabel("Wi-Fi network name").accessibilityIdentifier("wifi-name")
                    Button(action: add) { Image(systemName: "plus.circle.fill") }
                        .buttonStyle(.borderless).font(.title3)
                        .frame(minWidth: Layout.touchTarget, minHeight: Layout.touchTarget)
                        .accessibilityLabel("Add Wi-Fi name").accessibilityIdentifier("add-wifi")
                }
            }
            if let error = draft.error { Text(error).font(.footnote).foregroundStyle(.red) }
            if !adding {
                Button {
                    adding = true; fieldFocused = true
                } label: {
                    Label("Add Wi-Fi network", systemImage: "plus.circle")
                        .frame(minHeight: Layout.touchTarget)
                }.accessibilityIdentifier("add-wifi-network")
            }
        } header: { Text("Wi-Fi at this place") } footer: {
            Text(unavailable ? "Suggestions couldn’t be loaded. You can add a network name."
                : coordinate == nil ? "Choose this place’s location to see networks recorded nearby."
                : "Networks recorded nearby appear here. Add any that belong to this place.")
        }
        .task { if !model.uiTesting { model.tracking.refreshCurrentWiFi() } }
        .task(id: query) {
            suggestions = []; unavailable = false
            guard let coordinate else { return }
            do {
                let values = try await model.store?.wifiSuggestions(near: coordinate, placeRadius: radius,
                    connected: model.tracking.currentWiFiObservation) ?? []
                try Task.checkCancellation()
                suggestions = values
            } catch is CancellationError { }
            catch { if !Task.isCancelled { unavailable = true } }
        }
        .confirmationDialog("Remove this Wi-Fi name?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible, presenting: removing) { name in
            Button("Remove Wi-Fi name", role: .destructive) { draft.names.removeAll { $0 == name }; removing = nil }
        } message: { _ in Text("It will be removed from this place when you save. Recorded history stays intact.") }
    }
    private func add() {
        if draft.add() { adding = false; fieldFocused = false }
    }
}

struct WiFiSuggestionQuery: Equatable {
    var coordinate: Coordinate?
    var radius: Double
    var connectionID: String?
    var revision: Int
}

struct WiFiSuggestionRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let suggestion: WiFiSuggestion
    let add: () -> Void
    var body: some View {
        Button(action: add) {
            HStack(spacing: Layout.spacing) {
                if !dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: "wifi").font(.system(size: 22)).foregroundStyle(Palette.green)
                }
                VStack(alignment: .leading, spacing: Layout.compact) {
                    Text(suggestion.ssid).foregroundStyle(Palette.ink)
                    if suggestion.isConnected { Text("Connected now").font(.caption).foregroundStyle(Palette.green) }
                    else {
                        Text("Last seen \(suggestion.lastSeen.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(Palette.muted)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "plus.circle.fill").font(.system(size: 22)).foregroundStyle(Palette.green)
            }.frame(minHeight: Layout.touchTarget).contentShape(Rectangle())
        }.accessibilityLabel("Add \(suggestion.ssid)")
    }
}
