import SwiftUI
import PlacesCore

struct PlaceIconPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: String
    var colorIndex: Int
    @State private var query = ""
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Layout.iconTile), spacing: Layout.compact)], spacing: Layout.spacing) {
                ForEach(PlaceIconCatalog.search(query)) { icon in
                    Button {
                        selection = icon.symbol
                        dismiss()
                    } label: {
                        VStack(spacing: Layout.compact) {
                            Image(systemName: icon.symbol).font(.title2)
                                .frame(height: Layout.touchTarget)
                            Text(icon.title).font(.caption).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity, minHeight: Layout.iconTile)
                            .padding(Layout.compact)
                            .foregroundStyle(Palette.ink)
                            .background(selection == icon.symbol ? Palette.soft(colorIndex) : Palette.paper,
                                        in: RoundedRectangle(cornerRadius: Layout.spacing))
                            .overlay(alignment: .topTrailing) {
                                if selection == icon.symbol { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.green) }
                            }
                    }.buttonStyle(.plain).accessibilityLabel(icon.title)
                        .accessibilityIdentifier("icon-\(icon.symbol)")
                        .accessibilityAddTraits(selection == icon.symbol ? .isSelected : [])
                }
            }.padding(Layout.gutter)
            if PlaceIconCatalog.search(query).isEmpty {
                Text("No icons found. Try a place or activity.").foregroundStyle(Palette.muted).padding(Layout.gutter)
            }
        }.background(Palette.background).navigationTitle("Choose an icon").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Work, coffee, gym…")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
}
