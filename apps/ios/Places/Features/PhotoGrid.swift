import SwiftUI

struct PhotoReference: Identifiable { let id: String }

/// Image loading stays with the thumbnail source; the grid owns layout and actions.
struct PhotoGrid<Item: Identifiable, Thumbnail: View>: View {
    let items: [Item]
    var label: (Int) -> String = { "Photo \($0 + 1)" }
    var open: ((Item) -> Void)?
    var remove: ((Item) -> Void)?
    var add: (() -> Void)?
    var addLabel = "Add photos"
    var addIdentifier = ""
    var addBackground = Palette.background
    @ViewBuilder let thumbnail: (Item) -> Thumbnail
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Layout.portraitSize))], spacing: Layout.compact) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                VStack(spacing: 0) {
                    if let open {
                        Button { open(item) } label: { tile(item) }.buttonStyle(.plain).accessibilityLabel(label(index))
                    } else { tile(item).accessibilityLabel(label(index)) }
                    if let remove {
                        Button("Remove photo", systemImage: "xmark.circle.fill") { remove(item) }
                            .buttonStyle(.plain).labelStyle(.iconOnly).frame(minWidth: Layout.touchTarget, minHeight: Layout.touchTarget)
                    }
                }
            }
            if let add {
                Button(action: add) {
                    Image(systemName: "plus").font(.title2).foregroundStyle(Palette.green)
                        .frame(maxWidth: .infinity).frame(height: Layout.portraitSize)
                        .background(addBackground, in: RoundedRectangle(cornerRadius: Layout.compact))
                }.buttonStyle(.plain).accessibilityLabel(addLabel).accessibilityIdentifier(addIdentifier)
            }
        }
    }
    private func tile(_ item: Item) -> some View {
        thumbnail(item).frame(maxWidth: .infinity).frame(height: Layout.portraitSize).clipped()
            .clipShape(RoundedRectangle(cornerRadius: Layout.compact))
    }
}
