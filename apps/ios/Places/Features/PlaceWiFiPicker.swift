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
    let chooseNetwork: ([WiFiSuggestion]) -> Void
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
                WiFiNameLabel(name: name).accessibilityIdentifier("saved-wifi-\(name)")
                    .modifier(SwipeToDelete(nativeRow: true, allowsFullSwipe: false, title: "Remove") { removing = name })
            }
            HStack(spacing: Layout.compact) {
                TextField("Network name", text: $draft.entry)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .focused($fieldFocused).submitLabel(.done).onSubmit(add)
                    .padding(Layout.compact)
                    .overlay { RoundedRectangle(cornerRadius: Layout.compact)
                        .strokeBorder(fieldFocused ? Palette.green : Palette.line) }
                    .accessibilityLabel("Wi-Fi network name").accessibilityIdentifier("wifi-name")
                Button(action: add) { WiFiActionIcon(symbol: "checkmark") }
                    .buttonStyle(.borderless).accessibilityLabel("Add Wi-Fi name").accessibilityIdentifier("add-wifi")
            }.id("place-wifi-entry")
            if let error = draft.error { Text(error).font(.footnote).foregroundStyle(.red) }
        } header: {
            Text("Wi-Fi networks").textCase(nil)
        } footer: {
            VStack(alignment: .leading, spacing: Layout.compact) {
                if !available.isEmpty {
                    Button {
                        fieldFocused = false; chooseNetwork(suggestions)
                        if !model.uiTesting { model.tracking.refreshCurrentWiFi() }
                    } label: {
                        Label("Choose a Wi-Fi network", systemImage: "wifi")
                            .font(.body).padding(.vertical, Layout.compact)
                    }.buttonStyle(.bordered).buttonBorderShape(.capsule).tint(Palette.green)
                        .frame(maxWidth: .infinity).accessibilityIdentifier("choose-wifi-network")
                }
                if unavailable { Text("Suggestions couldn’t be loaded. You can enter a network name.") }
            }.textCase(nil)
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
        } message: { _ in Text("The saved name will be removed when you save this place. Learned connections and recorded history stay intact.") }
    }
    private func add() {
        if draft.add() { fieldFocused = false }
    }
}

/// Consistent geometry for the picker add action and inline confirmation.
private struct WiFiActionIcon: View {
    let symbol: String
    @ScaledMetric(relativeTo: .body) private var diameter = Layout.spacing * 2
    var body: some View {
        Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .background(Palette.controlGreen, in: Circle())
            .frame(minWidth: Layout.touchTarget, minHeight: Layout.touchTarget)
            .contentShape(Rectangle()).accessibilityHidden(true)
    }
}

struct WiFiNameLabel: View {
    let name: String
    var subtitle: String? = nil
    var body: some View {
        HStack(spacing: Layout.spacing) {
            Image(systemName: "wifi").font(.title3)
                .frame(width: Layout.touchTarget).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Layout.compact) {
                Text(name).font(.body).fixedSize(horizontal: false, vertical: true)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(Palette.muted) }
            }
        }.frame(minHeight: Layout.touchTarget).foregroundStyle(Palette.ink)
    }
}

struct WiFiSuggestionQuery: Equatable {
    var coordinate: Coordinate?
    var radius: Double
    var connectionID: String?
    var revision: Int
}

struct PlaceWiFiPicker: View {
    @Environment(\.dismiss) private var dismiss
    let suggestions: [WiFiSuggestion]
    @Binding var draft: PlaceWiFiDraft
    let enterName: () -> Void
    @State private var search = ""
    private var matching: [WiFiSuggestion] {
        suggestions.filter { !draft.names.contains($0.ssid) && (search.isEmpty || $0.ssid.localizedStandardContains(search)) }
    }
    var body: some View {
        List {
            if matching.contains(where: \.isConnected) {
                Section("Connected now") {
                    ForEach(matching.filter(\.isConnected)) { suggestion in WiFiSuggestionRow(suggestion: suggestion, draft: $draft) }
                }
            }
            if matching.contains(where: { !$0.isConnected }) {
                Section("Seen near this place") {
                    ForEach(matching.filter { !$0.isConnected }) { suggestion in WiFiSuggestionRow(suggestion: suggestion, draft: $draft) }
                }
            }
            if matching.isEmpty {
                Text(search.isEmpty ? "No more networks to add here." : "No matching networks.").foregroundStyle(Palette.muted)
            }
            Button("Enter a Wi-Fi name", systemImage: "keyboard", action: enterName)
        }.scrollContentBackground(.hidden).background(Palette.background).foregroundStyle(Palette.ink)
            .navigationTitle("Choose a Wi-Fi network").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Find a network")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}

private struct WiFiSuggestionRow: View {
    let suggestion: WiFiSuggestion
    @Binding var draft: PlaceWiFiDraft
    var body: some View {
        Button {
            guard !draft.names.contains(suggestion.ssid) else { return }
            draft.names.append(suggestion.ssid); draft.error = nil
        } label: {
            HStack(spacing: Layout.compact) {
                VStack(alignment: .leading, spacing: Layout.compact) {
                    Text(suggestion.ssid).font(.body).foregroundStyle(Palette.ink)
                    if !suggestion.isConnected {
                        Text("Last seen \(suggestion.lastSeen.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(Palette.muted)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                WiFiActionIcon(symbol: "plus")
            }.frame(minHeight: Layout.touchTarget).contentShape(Rectangle())
        }.accessibilityLabel("Add \(suggestion.ssid)")
    }
}
