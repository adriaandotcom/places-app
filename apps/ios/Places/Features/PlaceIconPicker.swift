import SwiftUI
import PlacesCore

struct PlaceIconPicker: View {
    @Environment(\.dismiss) private var dismiss
    @State var symbol: String
    @State var colorIndex: Int
    @State var customColorHex: String?
    let apply: (String, Int, String?) -> Void
    @State private var query = ""
    @State private var searching = false
    @State private var revealed: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ScrollView {
            VStack(spacing: Layout.spacing) {
                PlaceIcon(symbol: symbol, colorIndex: colorIndex, customColorHex: customColorHex, size: 64)
                PlaceColorPicker(colorIndex: $colorIndex, customColorHex: $customColorHex)
            }.padding(Layout.gutter)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Layout.iconTile), spacing: Layout.compact)], spacing: Layout.spacing) {
                ForEach(PlaceIconCatalog.search(query)) { icon in
                    Button {
                        symbol = icon.symbol; searching = false
                    } label: {
                        VStack(spacing: Layout.compact) {
                            ZStack {
                                if reduceMotion || revealed.contains(icon.symbol) {
                                    Image(systemName: icon.symbol).font(.title2)
                                        .transition(.symbolEffect(.drawOn.wholeSymbol, options: .speed(2)))
                                }
                            }.frame(maxWidth: .infinity).frame(height: Layout.touchTarget)
                            Text(icon.title).font(.caption).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity, minHeight: Layout.iconTile)
                            .padding(Layout.compact)
                            .foregroundStyle(Palette.ink)
                            .background(PlaceIconCatalog.canonicalSymbol(symbol) == icon.symbol ? Palette.soft(colorIndex, hex: customColorHex) : Palette.paper,
                                        in: RoundedRectangle(cornerRadius: Layout.spacing))
                            .overlay(alignment: .topTrailing) {
                                if PlaceIconCatalog.canonicalSymbol(symbol) == icon.symbol { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.green) }
                            }
                    }.buttonStyle(.plain).accessibilityLabel(icon.title)
                        .accessibilityIdentifier("icon-\(icon.symbol)")
                        .accessibilityAddTraits(PlaceIconCatalog.canonicalSymbol(symbol) == icon.symbol ? .isSelected : [])
                        .onScrollVisibilityChange(threshold: 0.3) { visible in
                            guard visible, !revealed.contains(icon.symbol) else { return }
                            if reduceMotion { revealed.insert(icon.symbol) }
                            else { withAnimation(.linear(duration: 0.22)) { _ = revealed.insert(icon.symbol) } }
                        }
                }
            }.padding(Layout.gutter)
            if PlaceIconCatalog.search(query).isEmpty {
                Text("No icons found. Try a place or activity.").foregroundStyle(Palette.muted).padding(Layout.gutter)
            }
        }.background(Palette.background).navigationTitle("Icon & color").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, isPresented: $searching, placement: .navigationBarDrawer(displayMode: .always), prompt: "Work, coffee, gym…")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { apply(symbol, colorIndex, customColorHex); dismiss() }
                        .accessibilityIdentifier("save-place-appearance")
                }
            }
            .onChange(of: query) { _, value in
                // Typing is immediate; drawing is only a once-per-visit browse effect.
                revealed.formUnion(PlaceIconCatalog.search(value).map(\.symbol))
            }
    }
}
