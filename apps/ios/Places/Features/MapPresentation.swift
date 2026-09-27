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
    var fittingViewport: MapViewport? {
        let points = coordinates.filter(\.isValid)
        guard let first = points.first else { return nil }
        let south = points.map(\.latitude).min()!, north = points.map(\.latitude).max()!
        // Find the smallest longitude arc, including trips across the date line.
        let longitudes = points.map { ($0.longitude + 360).truncatingRemainder(dividingBy: 360) }.sorted()
        var west = longitudes[0], span = 0.0, largestGap = -1.0
        for index in longitudes.indices {
            let next = index + 1 < longitudes.count ? longitudes[index + 1] : longitudes[0] + 360
            if next - longitudes[index] > largestGap {
                largestGap = next - longitudes[index]; west = next.truncatingRemainder(dividingBy: 360)
                span = 360 - largestGap
            }
        }
        let longitude = (west + span / 2 + 180).truncatingRemainder(dividingBy: 360) - 180
        let minimumLatitude = max(1_000, (radius ?? 100) * 4) / 111_320
        return MapViewport(center: Coordinate(latitude: (south + north) / 2, longitude: longitude),
            latitudeSpan: min(170, max(minimumLatitude, (north - south) * 1.6)),
            longitudeSpan: min(360, max(minimumLatitude / max(0.01, cos(first.latitude * .pi / 180)), span * 1.6)))
    }

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
            let points = routePoints.filter { $0.timestamp >= item.start && $0.timestamp <= (item.end ?? .distantFuture) && $0.coordinate.isValid }
                .sorted { $0.timestamp < $1.timestamp }.map(\.coordinate)
            if item.kind == .journey, points.count > 1 {
                paths.append(MapPath(id: item.id, coordinates: points, dashed: false))
                if let connection = item.connection {
                    for (suffix, from, to) in [("start", connection.from.coordinate, points[0]),
                                                ("end", points[points.count - 1], connection.to.coordinate)] where from.distance(to: to) > 1 {
                        paths.append(MapPath(id: item.id + suffix, coordinates: [from, to], dashed: true))
                    }
                }
            } else if let connection = item.connection, item.kind == .gap || item.kind == .journey {
                paths.append(MapPath(id: item.id, coordinates: [connection.from.coordinate, connection.to.coordinate], dashed: true))
                for (letter, endpoint) in [("A", connection.from), ("B", connection.to)] {
                    guard !pins.contains(where: { $0.coordinate == endpoint.coordinate }) else { continue }
                    pins.append(MapPin(id: item.id + letter, name: places.first { $0.id == endpoint.placeID }?.name ?? (letter == "A" ? "Earlier location" : "Later location"), coordinate: endpoint.coordinate, symbol: "circle.fill", colorIndex: letter == "A" ? 1 : 0, letter: letter))
                }
            }
        }
    }
}
