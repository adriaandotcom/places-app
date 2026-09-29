import SwiftUI
import PlacesCore

/// Shared presets and local favorites; the native picker supplies the full spectrum.
struct PlaceColorPicker: View {
    @Environment(AppModel.self) private var model
    @Binding var colorIndex: Int
    @Binding var customColorHex: String?
    @State private var favorites: [String] = []
    @State private var error: String?
    @State private var saving = false
    private var isFavorite: Bool { customColorHex.map(favorites.contains) ?? false }
    var body: some View {
        VStack(alignment: .leading, spacing: Layout.compact) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Layout.compact) {
                    ForEach(Palette.accents.indices, id: \.self) { index in
                        Button { colorIndex = index; customColorHex = nil } label: {
                            ColorSwatch(color: Palette.accent(index), selected: customColorHex == nil && colorIndex == index)
                        }.accessibilityLabel("Preset color \(index + 1)").accessibilityIdentifier("place-color-\(index)")
                    }
                    ForEach(favorites, id: \.self) { hex in
                        Button { customColorHex = hex } label: {
                            ColorSwatch(color: Palette.accent(0, hex: hex), selected: customColorHex == hex, favorite: true)
                        }.accessibilityLabel("Favorite color \(hex)")
                    }
                }
            }.buttonStyle(.plain).accessibilityIdentifier("place-color-swatches")
            HStack {
                ColorPicker("Custom color", selection: Binding(get: { Palette.accent(colorIndex, hex: customColorHex) },
                    set: { customColorHex = Palette.hex($0) }), supportsOpacity: false)
                    .accessibilityIdentifier("custom-place-color")
                Button(isFavorite ? "Remove favorite" : "Save favorite", systemImage: isFavorite ? "star.fill" : "star") {
                    if let hex = customColorHex { save(isFavorite ? favorites.filter { $0 != hex } : favorites + [hex]) }
                }.labelStyle(.iconOnly).frame(width: Layout.touchTarget, height: Layout.touchTarget)
                    .disabled(customColorHex == nil || saving)
                    .accessibilityIdentifier("favorite-place-color")
            }.frame(minHeight: Layout.touchTarget)
        }.task {
            if let value = try? await model.store?.setting("favoritePlaceColors"), let data = value.data(using: .utf8),
               let saved = try? JSONDecoder().decode([String].self, from: data) {
                favorites = saved.filter { $0.count == 6 && UInt($0, radix: 16) != nil }
            }
        }.alert("Couldn’t save colors", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }
    private func save(_ colors: [String]) {
        guard !saving else { return }; saving = true
        Task {
            defer { saving = false }
            do {
                guard let store = model.store else { throw CancellationError() }
                let data = try JSONEncoder().encode(colors)
                try await store.setSetting("favoritePlaceColors", value: String(decoding: data, as: UTF8.self))
                favorites = colors
            } catch { self.error = "Please try again." }
        }
    }
}

private struct ColorSwatch: View {
    let color: Color
    let selected: Bool
    var favorite = false
    var body: some View {
        Circle().fill(color).frame(width: 30, height: 30)
            .overlay(Circle().stroke(Palette.line, lineWidth: 1))
            .overlay {
                if selected || favorite {
                    Image(systemName: selected ? "checkmark" : "star.fill").font(.caption.bold())
                        .foregroundStyle(Palette.iconInk(0, hex: Palette.hex(color)))
                }
            }.frame(width: Layout.touchTarget, height: Layout.touchTarget)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
