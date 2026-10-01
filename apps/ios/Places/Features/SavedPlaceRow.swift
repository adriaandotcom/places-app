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
            VStack(spacing: 0) {
                Button(action: chooseSaved) {
                    Text(place == nil ? "Choose a saved place" : "Replace with a saved place")
                        .frame(maxWidth: .infinity, minHeight: Layout.touchTarget, alignment: .leading).contentShape(Rectangle())
                }.accessibilityIdentifier("select-saved-place")
                Button(action: chooseDifferent) {
                    Text(place == nil ? "Name this place" : "Replace with a nearby place")
                        .frame(maxWidth: .infinity, minHeight: Layout.touchTarget, alignment: .leading).contentShape(Rectangle())
                }.accessibilityIdentifier("select-different-place")
            }.buttonStyle(.plain).foregroundStyle(Palette.green)
        } label: {
            if let place { SavedPlaceRow(place: place) }
            else { Label("Choose a place", systemImage: "mappin.and.ellipse").frame(minHeight: Layout.touchTarget) }
        }.disclosureGroupStyle(SelectionDisclosureStyle(identifier: "selected-place-options")).tint(Palette.green)
    }
}
