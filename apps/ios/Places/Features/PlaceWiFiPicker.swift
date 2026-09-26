import SwiftUI
import PlacesCore

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
