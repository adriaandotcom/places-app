import SwiftUI
import PlacesCore

/// Saved places only. CatalogPlaceRow keeps lookup results distinct.
struct SavedPlaceRow: View {
    let place: Place
    var title: String?
    var subtitle: String?
    var card = false
    var showsDisclosure = false
    var body: some View {
        InfoRow(symbol: place.symbol, title: title ?? place.name,
                subtitle: subtitle ?? (place.address.isEmpty ? "Saved place" : place.address),
                colorIndex: place.colorIndex, customColorHex: place.customColorHex, card: card, showsDisclosure: showsDisclosure)
            .foregroundStyle(Palette.ink).contentShape(Rectangle())
    }
}
