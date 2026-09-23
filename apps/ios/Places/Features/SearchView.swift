import SwiftUI

struct SearchView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Find a familiar\nlittle corner.").font(BrandFont.hero)
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                    TextField("Search places and addresses", text: $model.searchText).font(BrandFont.body)
                        .autocorrectionDisabled().accessibilityIdentifier("local-search")
                    if !model.searchText.isEmpty {
                        Button("Clear", systemImage: "xmark.circle.fill") { model.searchText = "" }.labelStyle(.iconOnly)
                    }
                }.padding(16).background(Palette.paper, in: RoundedRectangle(cornerRadius: 18))
                if model.searchText.isEmpty {
                    EmptyHistory(symbol: "magnifyingglass", title: "Remember the name, or just the street", message: "Search names and addresses you’ve saved. Everything is searched on this iPhone.")
                } else if model.searchResults.isEmpty {
                    EmptyHistory(symbol: "text.magnifyingglass", title: "No places found", message: "Try a shorter name or an address you’ve saved.")
                }
                ForEach(model.searchResults) { place in
                    NavigationLink { PlaceDetail(placeID: place.id) } label: {
                        InfoRow(symbol: place.symbol, title: place.name, subtitle: place.address.isEmpty ? "Saved place" : place.address, colorIndex: place.colorIndex)
                    }.buttonStyle(.plain)
                }
            }.padding(Layout.gutter)
        }.background(Palette.background).foregroundStyle(Palette.ink).navigationTitle("Search").navigationBarTitleDisplayMode(.inline)
            .task(id: model.searchText) { await model.search() }
    }
}
