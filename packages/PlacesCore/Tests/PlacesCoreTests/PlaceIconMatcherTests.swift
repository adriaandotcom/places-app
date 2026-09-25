import Testing
@testable import PlacesCore

@Test func iconDefaultsRecognizePlacesInEnglishDutchAndCatalogCategories() {
    let cases = [
        ("Coffee Club", "cup.and.saucer.fill"), ("Koffiehuis Voorbeeld", "cup.and.saucer.fill"),
        ("Café Voorbeeld", "cup.and.saucer.fill"), ("Airport Café", "cup.and.saucer.fill"),
        ("Office", "briefcase.fill"), ("Kantoor Voorbeeld", "briefcase.fill"),
        ("Coworking Voorbeeld", "laptopcomputer"), ("Amsterdam Airport", "airplane"),
        ("Station Voorbeeld", "tram.fill"), ("Markthal", "basket.fill"),
        ("Supermarkt", "cart.fill"), ("Groenteboer", "carrot.fill"),
        ("Podcast Studio", "mic.fill"), ("Schrijfclub", "pencil.and.scribble"),
        ("Shooting Range", "scope"), ("Fietsenmaker", "bicycle"),
        ("Table tennis", "figure.table.tennis"), ("Ice hockey", "figure.ice.hockey"),
        ("Airport taxi rank", "car.fill"), ("Art Studio", "paintpalette.fill")
    ]
    for (name, symbol) in cases { #expect(PlaceIconMatcher.suggestedSymbol(name: name) == symbol, "Name: \(name)") }
    #expect(PlaceIconMatcher.suggestedSymbol(name: "The Airport", category: "coffee_shop") == "cup.and.saucer.fill")
    #expect(PlaceIconMatcher.suggestedSymbol(name: "A completely opaque name", category: "greek_restaurant") == "fork.knife")
}

@Test func iconDefaultsDoNotMatchFragmentsInsideNames() {
    for name in ["Barbara", "Oscar", "Caroline", "Marcus", "Homeostasis", "Workshopper", "My unnamed corner"] {
        #expect(PlaceIconMatcher.suggestedSymbol(name: name) == nil, "Name: \(name)")
    }
}

@Test func iconLibraryKeepsOnePictogramAndPreservesLegacyAliases() {
    let symbols = PlaceIconCatalog.icons.map(\.symbol)
    #expect(Set(symbols).count == symbols.count)
    #expect(symbols.filter { $0 == "bicycle" || $0.hasPrefix("bicycle.") }.count == 1)
    for symbol in symbols {
        if symbol.hasSuffix(".fill") { #expect(!symbols.contains(String(symbol.dropLast(5)))) }
    }
    #expect(PlaceIconCatalog.canonicalSymbol("bicycle.circle.fill") == "bicycle")
    #expect(PlaceIconCatalog.title(for: "bicycle.circle.fill") == "Bicycle")
    for word in ["bicycle", "bike", "repair bicycle", "fiets", "fietsenmaker"] {
        #expect(PlaceIconCatalog.search(word).contains { $0.symbol == "bicycle" })
    }
    for word in ["coffee", "koffie", "koffiehuis", "coffeeshop", "café", "espresso"] {
        #expect(PlaceIconCatalog.search(word).contains { $0.symbol == "cup.and.saucer.fill" })
    }
    #expect(PlaceIconCatalog.search("writing club").contains { $0.symbol == "pencil.and.scribble" })
    #expect(PlaceIconCatalog.search("supermarket vegetables").contains { $0.symbol == "carrot.fill" })
}
