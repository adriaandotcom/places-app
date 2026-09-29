import Foundation

/// Stored with the place, independent of downloaded maps. Rings do not repeat
/// their first point; islands and holes from OSM stay separate.
public struct PlaceArea: Codable, Hashable, Sendable {
    public struct Polygon: Codable, Hashable, Sendable {
        public var outer: [Coordinate]
        public var holes: [[Coordinate]]
        public init(outer: [Coordinate], holes: [[Coordinate]] = []) { self.outer = outer; self.holes = holes }
    }
    public var polygons: [Polygon]
    public var sourceName: String?
    public init(polygons: [Polygon], sourceName: String? = nil) { self.polygons = polygons; self.sourceName = sourceName }
    public init(vertices: [Coordinate]) { polygons = [Polygon(outer: vertices)] }
    public var vertices: [Coordinate] { polygons.flatMap { $0.outer + $0.holes.flatMap { $0 } } }
    public var isValid: Bool {
        !polygons.isEmpty && polygons.count <= 256 && vertices.count <= 20_000
        && polygons.allSatisfy { polygon in
            ([polygon.outer] + polygon.holes).allSatisfy {
                $0.count >= 3 && $0.allSatisfy(\.isValid) && Set($0).count >= 3 && abs(Self.signedArea($0)) > 1e-12
            }
        }
    }
    public func contains(_ coordinate: Coordinate) -> Bool {
        coordinate.isValid && polygons.contains {
            Self.inside(coordinate, ring: $0.outer) && !$0.holes.contains { Self.inside(coordinate, ring: $0) }
        }
    }
    public func distance(to coordinate: Coordinate) -> Double {
        if contains(coordinate) { return 0 }
        let longitudeScale = 111_320 * max(0.01, cos(coordinate.latitude * .pi / 180))
        return polygons.flatMap { [$0.outer] + $0.holes }.flatMap { ring in
            ring.indices.map { index in
                let a = ring[index], b = ring[(index + 1) % ring.count]
                let ax = Self.longitude(a.longitude - coordinate.longitude) * longitudeScale
                let ay = (a.latitude - coordinate.latitude) * 111_320
                let bx = ax + Self.longitude(b.longitude - a.longitude) * longitudeScale
                let by = (b.latitude - coordinate.latitude) * 111_320
                let dx = bx - ax, dy = by - ay, length = dx * dx + dy * dy
                let t = length > 0 ? max(0, min(1, -(ax * dx + ay * dy) / length)) : 0
                return hypot(ax + t * dx, ay + t * dy)
            }
        }.min() ?? .infinity
    }
    public func transformed(_ transform: (Coordinate) -> Coordinate) -> Self {
        Self(polygons: polygons.map { Polygon(outer: $0.outer.map(transform), holes: $0.holes.map { $0.map(transform) }) })
    }
    /// Manual drawings reject crossings instead of silently changing their area.
    public static func isSimple(_ ring: [Coordinate]) -> Bool {
        guard ring.count >= 3, ring.count <= 256, Set(ring).count == ring.count,
              PlaceArea(vertices: ring).isValid else { return false }
        func cross(_ a: Coordinate, _ b: Coordinate, _ c: Coordinate) -> Double {
            longitude(b.longitude - a.longitude) * (c.latitude - a.latitude)
            - (b.latitude - a.latitude) * longitude(c.longitude - a.longitude)
        }
        for i in ring.indices {
            for j in ring.indices where j > i + 1 && !(i == 0 && j == ring.count - 1) {
                let a = ring[i], b = ring[(i + 1) % ring.count], c = ring[j], d = ring[(j + 1) % ring.count]
                let bx = longitude(b.longitude - a.longitude), cx = longitude(c.longitude - a.longitude), dx = longitude(d.longitude - a.longitude)
                let overlaps = max(min(0, bx), min(cx, dx)) <= min(max(0, bx), max(cx, dx))
                    && max(min(a.latitude, b.latitude), min(c.latitude, d.latitude)) <= min(max(a.latitude, b.latitude), max(c.latitude, d.latitude))
                if overlaps && cross(a, b, c) * cross(a, b, d) <= 0 && cross(c, d, a) * cross(c, d, b) <= 0 { return false }
            }
        }
        return true
    }
    private static func longitude(_ value: Double) -> Double {
        var value = value.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }; if value < -180 { value += 360 }
        return value
    }
    private static func signedArea(_ ring: [Coordinate]) -> Double {
        guard let first = ring.first else { return 0 }
        return ring.indices.reduce(0) { value, index in
            let a = ring[index], b = ring[(index + 1) % ring.count]
            return value + longitude(a.longitude - first.longitude) * (b.latitude - first.latitude)
                - longitude(b.longitude - first.longitude) * (a.latitude - first.latitude)
        } / 2
    }
    private static func inside(_ point: Coordinate, ring: [Coordinate]) -> Bool {
        guard ring.count >= 3 else { return false }
        let origin = ring[0].longitude
        let px = longitude(point.longitude - origin)
        var inside = false
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            let ax = longitude(a.longitude - origin) - px, bx = longitude(b.longitude - origin) - px
            let ay = a.latitude - point.latitude, by = b.latitude - point.latitude
            let cross = ax * by - bx * ay
            if abs(cross) < 1e-12 && min(ax, bx) <= 0 && max(ax, bx) >= 0 && min(ay, by) <= 0 && max(ay, by) >= 0 { return true }
            if (ay > 0) != (by > 0), ax + (bx - ax) * -ay / (by - ay) > 0 { inside.toggle() }
        }
        return inside
    }
}

extension Place {
    public func contains(_ point: Coordinate, tolerance: Double = 0) -> Bool {
        if let area { return area.contains(point) || (tolerance > 0 && area.distance(to: point) <= tolerance) }
        return coordinate.distance(to: point) <= radius + tolerance
    }
}

public struct MapPark: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var area: PlaceArea
    public var coordinate: Coordinate
    private enum CodingKeys: String, CodingKey { case id, name, area, coordinate }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        coordinate = try container.decode(Coordinate.self, forKey: .coordinate)
        if let unpacked = try? container.decode(PlaceArea.self, forKey: .area) { area = unpacked }
        else { area = try container.decode(PackedArea.self, forKey: .area).unpacked() }
    }
    private struct PackedArea: Decodable {
        struct Polygon: Decodable { let outer: [[Double]]; let holes: [[[Double]]] }
        let polygons: [Polygon]
        let sourceName: String?
        func unpacked() throws -> PlaceArea {
            func ring(_ points: [[Double]]) throws -> [Coordinate] {
                try points.map {
                    guard $0.count == 2 else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid park coordinate")) }
                    return Coordinate(latitude: $0[1], longitude: $0[0])
                }
            }
            return try PlaceArea(polygons: polygons.map { try PlaceArea.Polygon(outer: ring($0.outer), holes: $0.holes.map(ring)) }, sourceName: sourceName)
        }
    }
}
