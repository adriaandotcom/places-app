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
                        SavedPlaceRow(place: place, title: "Use \(place.name)", subtitle: suggestion.context, showsDisclosure: true)
                            .padding(Layout.compact)
                    }.buttonStyle(.plain).accessibilityIdentifier("adjacent-place-\(place.id)")
                }
            }
        }.modifier(CardSurface(padding: 0))
    }
}
