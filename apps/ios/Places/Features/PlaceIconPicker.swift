import SwiftUI
import PlacesCore

struct PlaceIconPicker: View {
    @Environment(\.dismiss) private var dismiss
    @State var symbol: String
    @State var colorIndex: Int
    @State var customColorHex: String?
    @State var photoJPEG: Data?
    var photoIDs: [String] = []
    let apply: (String, Int, String?, Data?) -> Void
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var revealed: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ScrollViewReader { scroll in
        ScrollView {
            VStack(spacing: Layout.spacing) {
                CroppedPhotoField(photo: $photoJPEG, photoIDs: photoIDs, identifier: "choose-place-photo") {
                    PlaceIcon(symbol: symbol, colorIndex: colorIndex, customColorHex: customColorHex, photoJPEG: photoJPEG, size: Layout.portraitSize)
                }
                PlaceColorPicker(colorIndex: $colorIndex, customColorHex: $customColorHex)
            }.padding(Layout.gutter)
            HStack(spacing: Layout.compact) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted).accessibilityHidden(true)
                TextField("Work, coffee, gym…", text: $query)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .focused($searchFocused).submitLabel(.search).onSubmit { searchFocused = false }
                    .accessibilityLabel("Search icons").accessibilityIdentifier("place-icon-search")
                if !query.isEmpty {
                    Button("Clear icon search", systemImage: "xmark.circle.fill") { query = "" }
                        .labelStyle(.iconOnly).foregroundStyle(Palette.muted)
                        .frame(width: Layout.touchTarget, height: Layout.touchTarget)
                }
            }.frame(minHeight: Layout.touchTarget).padding(.horizontal, Layout.spacing)
                .background(Palette.paper, in: RoundedRectangle(cornerRadius: Layout.spacing))
                .padding(.horizontal, Layout.gutter).id("icon-search")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Layout.iconTile), spacing: Layout.compact)], spacing: Layout.spacing) {
                ForEach(PlaceIconCatalog.search(query)) { icon in
                    Button {
                        symbol = icon.symbol; photoJPEG = nil; searchFocused = false
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
                            .contentShape(Rectangle())
                            .foregroundStyle(Palette.ink)
                            .background(photoJPEG == nil && PlaceIconCatalog.canonicalSymbol(symbol) == icon.symbol ? Palette.soft(colorIndex, hex: customColorHex) : Palette.paper,
                                        in: RoundedRectangle(cornerRadius: Layout.spacing))
                            .overlay(alignment: .topTrailing) {
                                if photoJPEG == nil && PlaceIconCatalog.canonicalSymbol(symbol) == icon.symbol { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.green) }
                            }
                    }.buttonStyle(.plain).accessibilityLabel(icon.title)
                        .accessibilityIdentifier("icon-\(icon.symbol)")
                        .accessibilityAddTraits(photoJPEG == nil && PlaceIconCatalog.canonicalSymbol(symbol) == icon.symbol ? .isSelected : [])
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
        }.background(Palette.background).navigationTitle("Appearance").navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { apply(symbol, colorIndex, customColorHex, photoJPEG); dismiss() }
                        .accessibilityIdentifier("save-place-appearance")
                }
            }
            .onChange(of: searchFocused) { _, focused in
                if focused { scroll.scrollTo("icon-search", anchor: .top) }
            }
            .onChange(of: query) { _, value in
                // Typing is immediate; drawing is only a once-per-visit browse effect.
                revealed.formUnion(PlaceIconCatalog.search(value).map(\.symbol))
                if searchFocused { scroll.scrollTo("icon-search", anchor: .top) }
            }
        }
    }
}
