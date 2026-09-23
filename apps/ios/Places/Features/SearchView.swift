import SwiftUI

struct SearchView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Find that place.").font(BrandFont.hero)
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                    TextField("Search places and addresses", text: $model.searchText).font(BrandFont.body)
                        .autocorrectionDisabled().accessibilityIdentifier("local-search")
                    if !model.searchText.isEmpty {
                        Button("Clear", systemImage: "xmark.circle.fill") { model.searchText = "" }.labelStyle(.iconOnly)
                    }
                }.padding(16).background(Palette.paper, in: RoundedRectangle(cornerRadius: 18))
                if model.searchText.isEmpty {
                    Text("Search your saved names and addresses.").font(BrandFont.body).foregroundStyle(Palette.muted)
                } else if model.searchResults.isEmpty {
                    EmptyHistory(symbol: "text.magnifyingglass", title: "No places found", message: "Try a shorter name or an address you’ve saved.")
                }
                ForEach(model.searchResults) { place in
                    NavigationLink { PlaceDetail(placeID: place.id) } label: {
                        InfoRow(symbol: place.symbol, title: place.name, subtitle: place.address.isEmpty ? "Saved place" : place.address, colorIndex: place.colorIndex)
                    }.buttonStyle(.plain)
                }
            }.padding(Layout.gutter)
        }.background(Palette.background).foregroundStyle(Palette.ink).navigationBarTitleDisplayMode(.inline)
            .task(id: model.searchText) { await model.search() }
    }
}
