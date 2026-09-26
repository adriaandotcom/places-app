import SwiftUI
import PlacesCore

struct WiFiSuggestionQuery: Equatable {
    var coordinate: Coordinate?
    var radius: Double
    var connectionID: String?
    var revision: Int
}

struct PlaceWiFiPicker: View {
    @Environment(\.dismiss) private var dismiss
    let suggestions: [WiFiSuggestion]
    let add: (WiFiSuggestion) -> Void
    let enterName: () -> Void
    @State private var search = ""
    private var matching: [WiFiSuggestion] {
        suggestions.filter { search.isEmpty || $0.ssid.localizedStandardContains(search) }
    }

    var body: some View {
        List {
            if matching.contains(where: \.isConnected) {
                Section("Connected now") {
                    ForEach(matching.filter(\.isConnected)) { suggestion in
                        WiFiSuggestionRow(suggestion: suggestion) { add(suggestion) }
                    }
                }
            }
            if matching.contains(where: { !$0.isConnected }) {
                Section("Seen nearby") {
                    ForEach(matching.filter { !$0.isConnected }) { suggestion in
                        WiFiSuggestionRow(suggestion: suggestion) { add(suggestion) }
                    }
                }
            }
            if matching.isEmpty {
                Text(search.isEmpty ? "No more networks to add here." : "No matching networks.")
                    .foregroundStyle(Palette.muted)
            }
            Section {
                Button("Enter Wi-Fi name…", systemImage: "keyboard", action: enterName)
                    .accessibilityIdentifier("enter-wifi-manually")
            } footer: {
                Text("Networks Places has observed around this location. Saved only on this iPhone.")
            }
        }.scrollContentBackground(.hidden).background(Palette.background)
            .navigationTitle("Add Wi-Fi to this place").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Find a network")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}

private struct WiFiSuggestionRow: View {
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
                    if !suggestion.isConnected {
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
