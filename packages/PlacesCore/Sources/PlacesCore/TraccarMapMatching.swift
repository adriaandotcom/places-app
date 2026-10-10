import Foundation

/// An experimental rendering of Traccar evidence, never an input to timeline inference.
public enum TraccarMatchingMode: String, Codable, CaseIterable, Sendable {
    case walking, bicycle, driving
    public var costing: String {
        switch self { case .walking: "pedestrian"; case .bicycle: "bicycle"; case .driving: "auto" }
    }
    public var title: String {
        switch self { case .walking: "Walking"; case .bicycle: "Bicycle"; case .driving: "Driving" }
    }
    fileprivate var maximumSpeed: Double {
        switch self { case .walking: 8; case .bicycle: 25; case .driving: 70 }
    }
}

public struct TraccarMatchingTrace: Sendable {
    public let sections: [[TraccarPoint]]
    public let excludedPointCount: Int

    /// Accepts only the independent orange collector. Poor fixes and gaps break the
    /// trace rather than silently joining their neighbours. Chunking bounds native work.
    public init(points: [TraccarPoint], mode: TraccarMatchingMode) {
        var sections: [[TraccarPoint]] = [], section: [TraccarPoint] = []
        var excluded = 0
        var seen = Set<String>()
        func finish() {
            if section.count > 1 { sections.append(section) }
            section = []
        }
        for point in points.sorted(by: { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) }) {
            guard seen.insert(point.id).inserted else { continue }
            guard point.isValid, let accuracy = point.accuracy, accuracy <= 100 else {
                excluded += 1; finish(); continue
            }
            if let previous = section.last {
                let seconds = point.timestamp.timeIntervalSince(previous.timestamp)
                let uncertainty = accuracy + (previous.accuracy ?? 0)
                if seconds <= 0 || seconds > 300 ||
                    previous.coordinate.distance(to: point.coordinate) > mode.maximumSpeed * seconds + uncertainty {
                    finish()
                }
            }
            section.append(point)
            if section.count == 250 {
                finish()
                // Share the boundary fix, not an unobserved connection.
                section = [point]
            }
        }
        finish()
        self.sections = sections
        self.excludedPointCount = excluded
    }

    public static func request(for points: [TraccarPoint], mode: TraccarMatchingMode) throws -> String {
        guard points.count >= 2, points.count <= 250,
              points.allSatisfy({ $0.isValid && $0.accuracy != nil && $0.accuracy! <= 100 }),
              zip(points, points.dropFirst()).allSatisfy({ $0.timestamp < $1.timestamp }) else {
            throw TraccarMatchingError.invalidTrace
        }
        let request = Request(shape: points.map {
            .init(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude,
                  time: $0.timestamp.timeIntervalSince1970, accuracy: Int(ceil($0.accuracy!)))
        }, costing: mode.costing)
        return String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
    }

    private struct Request: Encodable {
        struct Point: Encodable { let lat: Double; let lon: Double; let time: Double; let accuracy: Int }
        struct Filters: Encodable {
            let action = "include"
            let attributes = ["shape", "edge.length", "matched.type", "matched.distance_from_trace_point",
                              "matched.begin_route_discontinuity", "matched.end_route_discontinuity"]
        }
        let shape: [Point]
        let costing: String
        let shape_match = "map_snap"
        let use_timestamps = true
        let units = "kilometers"
        let filters = Filters()
    }
}

public enum TraccarMatchingError: Error, Equatable, Sendable {
    case invalidTrace, invalidResponse, incompleteMatch
}

public struct TraccarMatchedSection: Equatable, Sendable {
    public let coordinates: [Coordinate]
    public let distanceMeters: Double
    /// Observed first-to-last time, including stops. Never the routing engine's ETA.
    public let observedSeconds: TimeInterval
    public let pointIDs: [String]

    public static func decode(_ json: String, points: [TraccarPoint]) throws -> Self {
        guard json.utf8.count <= 8_000_000, points.count >= 2 else { throw TraccarMatchingError.invalidResponse }
        let response = try JSONDecoder().decode(Response.self, from: Data(json.utf8))
        guard response.matched_points.count == points.count else { throw TraccarMatchingError.invalidResponse }
        // A disconnected or partially matched shape must not become a solid route.
        // The original orange points and dashed trace remain available as the fallback.
        for (match, point) in zip(response.matched_points, points) {
            guard ["matched", "interpolated"].contains(match.type),
                  match.begin_route_discontinuity != true, match.end_route_discontinuity != true,
                  let offset = match.distance_from_trace_point, offset.isFinite, offset >= 0,
                  offset <= max(30, (point.accuracy ?? 0) * 2) else {
                throw TraccarMatchingError.incompleteMatch
            }
        }
        guard response.units == "kilometers", !response.edges.isEmpty,
              response.edges.allSatisfy({ $0.length.isFinite && $0.length >= 0 }) else {
            throw TraccarMatchingError.invalidResponse
        }
        let distance = response.edges.reduce(0) { $0 + $1.length * 1_000 }
        let coordinates = try decodePolyline(response.shape)
        guard distance.isFinite, coordinates.count >= 2 else { throw TraccarMatchingError.invalidResponse }
        return Self(coordinates: coordinates, distanceMeters: distance,
                    observedSeconds: points.last!.timestamp.timeIntervalSince(points.first!.timestamp),
                    pointIDs: points.map(\.id))
    }

    private struct Response: Decodable {
        struct Edge: Decodable { let length: Double }
        struct Match: Decodable {
            let type: String
            let distance_from_trace_point: Double?
            let begin_route_discontinuity: Bool?
            let end_route_discontinuity: Bool?
        }
        let shape: String
        let units: String
        let edges: [Edge]
        let matched_points: [Match]
    }

    /// Valhalla's shape uses polyline6. Bound both accumulation and output so a
    /// malformed native response cannot overflow or allocate an unbounded path.
    private static func decodePolyline(_ string: String) throws -> [Coordinate] {
        let bytes = Array(string.utf8)
        var index = 0, latitude: Int64 = 0, longitude: Int64 = 0
        var result: [Coordinate] = []
        func delta() throws -> Int64 {
            var value: Int64 = 0, shift = 0
            while index < bytes.count, shift <= 30 {
                let byte = bytes[index]; index += 1
                guard byte >= 63, byte <= 126 else { throw TraccarMatchingError.invalidResponse }
                let part = Int64(byte - 63)
                value |= (part & 31) << shift
                if part < 32 { return value & 1 == 0 ? value >> 1 : ~(value >> 1) }
                shift += 5
            }
            throw TraccarMatchingError.invalidResponse
        }
        while index < bytes.count {
            latitude += try delta(); longitude += try delta()
            let point = Coordinate(latitude: Double(latitude) / 1_000_000, longitude: Double(longitude) / 1_000_000)
            guard point.isValid, result.count < 100_000 else { throw TraccarMatchingError.invalidResponse }
            result.append(point)
        }
        return result
    }
}
