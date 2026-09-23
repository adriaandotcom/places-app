import Foundation

public struct PlaceIconOption: Identifiable, Sendable {
    public let symbol: String
    public let title: String
    public let keywords: String
    public var id: String { symbol }
    public init(_ symbol: String, _ title: String, _ keywords: String) {
        self.symbol = symbol; self.title = title; self.keywords = keywords
    }
}

// Our own place-focused vocabulary. Symbols are rendered by the public system API;
// search uses bundled words, without remote requests or undocumented OS catalogs.
public enum PlaceIconCatalog {
    public static let icons: [PlaceIconOption] = [
        .init("house.fill", "Home", "house apartment flat residence family"),
        .init("briefcase.fill", "Work", "briefcase office job business coworking workplace"),
        .init("building.2.fill", "Office", "work business building city coworking"),
        .init("cup.and.saucer.fill", "Café", "coffee cafe cup tea breakfast espresso"),
        .init("fork.knife", "Restaurant", "food dinner lunch dining eat meal"),
        .init("wineglass.fill", "Bar", "wine drinks pub alcohol cocktail"),
        .init("birthday.cake.fill", "Bakery", "cake bread pastry dessert birthday sweets"),
        .init("basket.fill", "Market", "food shopping groceries basket supermarket"),
        .init("cart.fill", "Supermarket", "shopping groceries food store cart"),
        .init("bag.fill", "Shop", "shopping store retail bag mall"),
        .init("dumbbell.fill", "Gym", "fitness exercise weights workout sport training"),
        .init("figure.yoga", "Yoga", "pilates stretch studio meditation fitness"),
        .init("figure.pool.swim", "Pool", "swimming water swim sport fitness"),
        .init("sportscourt.fill", "Sports court", "tennis basketball football soccer sport club"),
        .init("soccerball", "Football", "soccer stadium sport field match"),
        .init("figure.run", "Running", "run athletics track jogging sport"),
        .init("leaf.fill", "Garden", "nature green plants leaf allotment"),
        .init("tree.fill", "Park", "forest trees nature woods green outdoors"),
        .init("mountain.2.fill", "Mountains", "hiking hill nature trail outdoors"),
        .init("beach.umbrella.fill", "Beach", "sea coast sand holiday seaside"),
        .init("water.waves", "Waterfront", "river canal lake ocean sea water"),
        .init("tent.fill", "Campsite", "camp tent camping outdoors holiday"),
        .init("bed.double.fill", "Hotel", "sleep bed hostel accommodation stay holiday"),
        .init("building.columns.fill", "Museum", "gallery art culture history bank"),
        .init("books.vertical.fill", "Library", "books study read reading education"),
        .init("graduationcap.fill", "School", "education university college study campus"),
        .init("cross.case.fill", "Healthcare", "hospital doctor clinic medical health dentist"),
        .init("pills.fill", "Pharmacy", "medicine drugs health chemist"),
        .init("heart.fill", "Favourite", "love favorite family partner special"),
        .init("person.2.fill", "Friends", "people family social visit parents"),
        .init("figure.and.child.holdinghands", "Childcare", "nursery daycare kindergarten children school"),
        .init("pawprint.fill", "Pets", "dog cat vet animals pet"),
        .init("scissors", "Salon", "hair barber haircut beauty"),
        .init("washer.fill", "Laundry", "washing laundromat clothes cleaning"),
        .init("wrench.and.screwdriver.fill", "Workshop", "repair garage hardware tools maker"),
        .init("paintpalette.fill", "Art studio", "creative paint drawing art design"),
        .init("music.note", "Music", "concert venue band studio rehearsal piano"),
        .init("theatermasks.fill", "Theatre", "theater stage acting culture drama"),
        .init("film.fill", "Cinema", "movie film theater entertainment"),
        .init("ticket.fill", "Event", "festival concert tickets show venue"),
        .init("gamecontroller.fill", "Games", "arcade gaming games play entertainment"),
        .init("bicycle", "Bike stop", "bicycle cycling bike cycle parking"),
        .init("car.fill", "Car park", "car garage parking drive vehicle"),
        .init("tram.fill", "Station", "train tram rail metro subway station transport"),
        .init("bus.fill", "Bus stop", "bus coach public transport station"),
        .init("airplane", "Airport", "plane flight travel terminal aviation"),
        .init("ferry.fill", "Harbour", "harbor boat ferry port sailing transport"),
        .init("fuelpump.fill", "Fuel stop", "petrol gas gasoline fuel station"),
        .init("bolt.car.fill", "Charging", "electric ev car charging charger energy"),
        .init("bicycle.circle.fill", "Bike shop", "repair bicycle cycling bike shop"),
        .init("envelope.fill", "Post office", "mail parcel shipping delivery letters"),
        .init("shippingbox.fill", "Parcel point", "packages pickup delivery shipping box"),
        .init("building.fill", "Building", "apartment property address city"),
        .init("house.lodge.fill", "Cabin", "cottage lodge holiday home chalet"),
        .init("building.2.crop.circle.fill", "City", "town centre center city urban"),
        .init("globe.europe.africa.fill", "Travel", "world country trip holiday vacation"),
        .init("sun.max.fill", "Outdoors", "sun sunshine outside open air"),
        .init("moon.stars.fill", "Night out", "night nightlife evening stars"),
        .init("star.fill", "Special place", "star favorite favourite important"),
        .init("mappin", "Place", "pin location marker destination stop address")
    ]
    public static func search(_ query: String) -> [PlaceIconOption] {
        let words = normalized(query).split { !$0.isLetter && !$0.isNumber }
        return icons.filter { icon in
            let terms = normalized(icon.title + " " + icon.keywords + " " + icon.symbol)
            return words.allSatisfy { terms.contains($0) }
        }
    }
    public static func title(for symbol: String) -> String { icons.first { $0.symbol == symbol }?.title ?? "Custom icon" }
    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
