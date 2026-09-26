import Foundation
import PlacesCore

struct MapViewport: Equatable {
    var center: Coordinate
    var latitudeSpan: Double
    var longitudeSpan: Double
}

struct MapPin: Equatable, Identifiable {
    var id: String
    var name: String
    var coordinate: Coordinate
    var symbol: String
    var colorIndex: Int
    var placeID: String?
    var letter: String?
}

struct MapPath: Equatable, Identifiable {
    var id: String
    var coordinates: [Coordinate]
    var dashed: Bool
}

struct MapPresentation: Equatable {
    var pins: [MapPin] = []
    var paths: [MapPath] = []
    var radius: Double?
    var coordinates: [Coordinate] { pins.map(\.coordinate) + paths.flatMap(\.coordinates) }

    init(pins: [MapPin], radius: Double? = nil) { self.pins = pins; self.radius = radius }
    init(items: [TimelineItem], routePoints: [RoutePoint], places: [Place]) {
        let ids = Set(items.compactMap(\.placeID))
        pins = places.filter { ids.contains($0.id) }.map {
            MapPin(id: $0.id, name: $0.name, coordinate: $0.coordinate, symbol: $0.symbol, colorIndex: $0.colorIndex, placeID: $0.id)
        }
        for item in items {
            if item.kind == .stay, !places.contains(where: { $0.id == item.placeID }), let coordinate = item.coordinate, coordinate.isValid {
                pins.append(MapPin(id: item.id, name: "Somewhere new", coordinate: coordinate, symbol: "mappin", colorIndex: 4))
            }
            let points = routePoints.filter { $0.timestamp >= item.start && $0.timestamp <= (item.end ?? .distantFuture) }.map(\.coordinate)
            if item.kind == .journey, points.count > 1 {
                paths.append(MapPath(id: item.id, coordinates: points, dashed: false))
            } else if let connection = item.connection, item.kind == .gap || item.kind == .journey {
                paths.append(MapPath(id: item.id, coordinates: [connection.from.coordinate, connection.to.coordinate], dashed: true))
                for (letter, endpoint) in [("A", connection.from), ("B", connection.to)] {
                    pins.append(MapPin(id: item.id + letter, name: places.first { $0.id == endpoint.placeID }?.name ?? (letter == "A" ? "Earlier location" : "Later location"), coordinate: endpoint.coordinate, symbol: "circle.fill", colorIndex: letter == "A" ? 1 : 0, letter: letter))
                }
            }
        }
    }
}
