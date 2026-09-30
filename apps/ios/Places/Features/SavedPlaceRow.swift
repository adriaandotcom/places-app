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
                colorIndex: place.colorIndex, customColorHex: place.customColorHex, photoJPEG: place.photoJPEG, card: card, showsDisclosure: showsDisclosure)
            .foregroundStyle(Palette.ink).contentShape(Rectangle())
    }
}

/// Keep the selected place prominent, with alternatives behind its chevron.
/// Used by photo review and the memory editor, including unnamed suggestions.
struct PlaceSelectionField: View {
    let place: Place?
    let chooseSaved: () -> Void
    let chooseDifferent: () -> Void
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Button("Choose a saved place", action: chooseSaved).foregroundStyle(Palette.green).frame(minHeight: Layout.touchTarget)
            Button(place == nil ? "Name this place" : "Choose a different nearby place", action: chooseDifferent)
                .foregroundStyle(Palette.green).frame(minHeight: Layout.touchTarget)
        } label: {
            if let place { SavedPlaceRow(place: place) }
            else { Label("Choose a place", systemImage: "mappin.and.ellipse").frame(minHeight: Layout.touchTarget) }
        }.disclosureGroupStyle(SelectionDisclosureStyle()).tint(Palette.green).accessibilityIdentifier("selected-place-options")
    }
}
