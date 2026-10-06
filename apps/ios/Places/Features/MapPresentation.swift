import Foundation
import PlacesCore

struct MapViewport: Equatable, Sendable {
    var center: Coordinate
    var latitudeSpan: Double
    var longitudeSpan: Double
}

struct MapPin: Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var coordinate: Coordinate
    var symbol: String
    var colorIndex: Int
    var customColorHex: String?
    var photoJPEG: Data?
    var placeID: String?
    var letter: String?
    var isRecordedLocation = false
}

struct MapPath: Equatable, Identifiable, Sendable {
    var id: String
    var coordinates: [Coordinate]
    var dashed: Bool
}

struct RawMapPoint: Equatable, Identifiable, Sendable {
    var id: String
    var coordinate: Coordinate
    var timestamp: Date
    var measuredAt: Date?
    var source: String
    var device: String
    var accuracy: Double?
    var speed: Double?
    var colorIndex: Int
    var number = 0
    var timeLabel: String { timestamp.formatted(date: .omitted, time: .standard) }
    var accessibilityLabel: String { "Raw point \(number), \(timeLabel), \(device)" }
}

struct MapPresentation: Equatable, Sendable {
    var pins: [MapPin] = []
    var rawPoints: [RawMapPoint] = []
    var paths: [MapPath] = []
    var radius: Double?
    var areas: [PlaceArea] = []
    private var minimumSpanMeters = 1_000.0
    var coordinates: [Coordinate] { pins.map(\.coordinate) + rawPoints.map(\.coordinate) + paths.flatMap(\.coordinates) + areas.flatMap(\.vertices) }
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
        let minimumLatitude = max(minimumSpanMeters, (radius ?? 100) * 4) / 111_320
        return MapViewport(center: Coordinate(latitude: (south + north) / 2, longitude: longitude),
            latitudeSpan: min(170, max(minimumLatitude, (north - south) * 1.6)),
            longitudeSpan: min(360, max(minimumLatitude / max(0.01, cos(first.latitude * .pi / 180)), span * 1.6)))
    }

    init(pins: [MapPin], radius: Double? = nil) { self.pins = pins; self.radius = radius }
    init(recordedCoordinate: Coordinate, accuracy: Double?) {
        guard recordedCoordinate.isValid else { return }
        pins = [MapPin(id: "recorded-location", name: "Recorded location", coordinate: recordedCoordinate,
            symbol: "circle.fill", colorIndex: 1, isRecordedLocation: true)]
        radius = accuracy.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        minimumSpanMeters = 100
    }
    init(observations: [SensorObservation], photos: [PhotoLocationEvidence] = []) {
        rawPoints = observations.compactMap { observation in
            // Raw means raw: retain poor accuracy and cached coordinates as well.
            guard let coordinate = observation.coordinate, coordinate.isValid,
                  observation.timestamp.timeIntervalSince1970.isFinite else { return nil }
            let device: String
            let color: Int
            switch observation.companionDevice {
            case .watch: device = "Apple Watch"; color = 1
            case .mac: device = "Mac"; color = 5
            case nil: device = "iPhone"; color = 0
            }
            return RawMapPoint(id: "sensor:" + observation.id, coordinate: coordinate, timestamp: observation.timestamp,
                measuredAt: observation.coordinateTimestamp, source: observation.source.displayName, device: device,
                accuracy: observation.horizontalAccuracy, speed: observation.speed, colorIndex: color)
        }
        rawPoints += photos.filter { $0.coordinate.isValid && $0.capturedAt.timeIntervalSince1970.isFinite }.map {
            RawMapPoint(id: "photo:" + $0.id, coordinate: $0.coordinate, timestamp: $0.capturedAt,
                source: "Photo location", device: "Photos", colorIndex: 4)
        }
        rawPoints.sort { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) }
        for index in rawPoints.indices { rawPoints[index].number = index + 1 }
        if rawPoints.count > 1 {
            paths = [MapPath(id: "raw-observation-order", coordinates: rawPoints.map(\.coordinate), dashed: true)]
        }
    }
    init(place: Place) {
        pins = [MapPin(id: place.id, name: place.name, coordinate: place.coordinate,
            symbol: place.symbol, colorIndex: place.colorIndex, customColorHex: place.customColorHex, photoJPEG: place.photoJPEG)]
        radius = place.area == nil ? place.radius : nil
        areas = place.area.map { [$0] } ?? []
    }
    init(items: [TimelineItem], routePoints: [RoutePoint], places: [Place]) {
        let ids = Set(items.compactMap(\.placeID))
        pins = places.filter { ids.contains($0.id) }.map {
            MapPin(id: $0.id, name: $0.name, coordinate: $0.coordinate, symbol: $0.symbol, colorIndex: $0.colorIndex, customColorHex: $0.customColorHex, photoJPEG: $0.photoJPEG, placeID: $0.id)
        }
        for item in items {
            if item.kind == .stay, !places.contains(where: { $0.id == item.placeID }), let coordinate = item.coordinate, coordinate.isValid {
                pins.append(MapPin(id: item.id, name: "Somewhere new", coordinate: coordinate, symbol: "mappin", colorIndex: 4))
            }
            // A grouped walking visit can contain an unrecorded interval. Draw
            // each recorded member separately instead of connecting across it.
            let routes = item.kind == .stay ? (item.originalItems ?? [item]).filter(\.recordsRoute) : [item]
            for item in routes {
                let points = routePoints.filter { $0.timestamp >= item.start && $0.timestamp <= (item.end ?? .distantFuture) && $0.coordinate.isValid }
                    .sorted { $0.timestamp < $1.timestamp }.map(\.coordinate)
                if item.recordsRoute, points.count > 1 {
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
}
