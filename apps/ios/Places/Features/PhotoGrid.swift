import SwiftUI

struct PhotoReference: Identifiable { let id: String }

/// Image loading stays with the thumbnail source; the grid owns layout and actions.
struct PhotoGrid<Item: Identifiable, Thumbnail: View>: View {
    let items: [Item]
    var label: (Int) -> String = { "Photo \($0 + 1)" }
    var open: ((Item) -> Void)?
    var remove: ((Item) -> Void)?
    var reorder: (() -> Void)?
    var add: (() -> Void)?
    var addLabel = "Add photos"
    var addIdentifier = ""
    var addingDisabled = false
    var photoIdentifierPrefix = ""
    var showsContextMenu = true
    var addBackground = Palette.background
    @ViewBuilder let thumbnail: (Item) -> Thumbnail
    @State private var removing: Item?
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Layout.portraitSize), spacing: Layout.compact)], spacing: Layout.compact) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Group {
                    if let open {
                        Button { open(item) } label: { tile(item) }.buttonStyle(.plain).accessibilityLabel(label(index))
                            .accessibilityIdentifier(photoIdentifierPrefix.isEmpty ? "" : photoIdentifierPrefix + String(describing: item.id))
                    } else { tile(item).accessibilityLabel(label(index)) }
                }
                .contextMenu {
                    if showsContextMenu {
                        if let open { Button("View photo", systemImage: "arrow.up.left.and.arrow.down.right") { open(item) } }
                        if let reorder { Button("Reorder photos", systemImage: "arrow.up.arrow.down", action: reorder) }
                        if remove != nil { Button("Delete photo", systemImage: "trash", role: .destructive) { removing = item } }
                    }
                }
                .accessibilityActions {
                    if let reorder { Button("Reorder photos", action: reorder) }
                    if remove != nil { Button("Delete photo") { removing = item } }
                }
            }
            if let add {
                Button(action: add) {
                    PhotoGridTile {
                        addBackground.overlay { Image(systemName: "plus").font(.title2).foregroundStyle(Palette.green) }
                    }
                }.buttonStyle(.plain).accessibilityLabel(addLabel).accessibilityIdentifier(addIdentifier).disabled(addingDisabled)
            }
        }
        .confirmationDialog("Remove this photo?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { item in
            Button("Delete photo", role: .destructive) { remove?(item); removing = nil }
        } message: { _ in Text("The original photo in your library is kept.") }
    }
    private func tile(_ item: Item) -> some View {
        PhotoGridTile { thumbnail(item) }
    }
}

/// The image and add button receive the same square proposal, independent of
/// their intrinsic sizes or a Form's automatic button layout.
private struct PhotoGridTile<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        Color.clear.aspectRatio(1, contentMode: .fit).overlay {
            GeometryReader { geometry in
                content.frame(width: geometry.size.width, height: geometry.size.height).clipped()
            }
        }.clipShape(RoundedRectangle(cornerRadius: Layout.compact)).contentShape(Rectangle())
    }
}
