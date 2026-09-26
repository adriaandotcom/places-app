import SwiftUI
import PlacesCore

struct AdjacentPlaceRows: View {
    @Environment(AppModel.self) private var model
    let suggestions: [AdjacentPlaceSuggestion]
    let select: (Place) -> Void
    var body: some View {
        VStack(spacing: 0) {
            ForEach(suggestions) { suggestion in
                if let place = model.places.first(where: { $0.id == suggestion.placeID }) {
                    Button { select(place) } label: {
                        HStack(spacing: Layout.spacing) {
                            Image(systemName: place.symbol).foregroundStyle(Palette.green).frame(width: 28)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Use \(place.name)").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                                Text(suggestion.context).font(.caption).foregroundStyle(Palette.muted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted)
                        }.frame(minHeight: Layout.touchTarget).padding(Layout.compact)
                    }.buttonStyle(.plain).accessibilityIdentifier("adjacent-place-\(place.id)")
                }
            }
        }.background(Palette.paper, in: RoundedRectangle(cornerRadius: Layout.cardRadius))
    }
}
