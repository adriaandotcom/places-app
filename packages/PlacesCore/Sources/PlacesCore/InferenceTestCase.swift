import Foundation

/// Portable, local regression input. Expected results are a snapshot of the
/// user's current timeline, including their corrections, not verified truth.
public struct InferenceTestCase: Codable, Sendable {
    public let formatVersion: Int
    public let policyVersion: String
    public let instructions: String
    public let privacy: String
    public let input: Input
    public var expectedTimeline: [TimelineExpectation]

    public struct Input: Codable, Sendable {
        public let observations: [SensorObservation]
        public let places: [Place]
        public let networks: [WiFiNetwork]
        public let accessPoints: [WiFiAccessPoint]
        public let corrections: [UserOverride]
    }

    /// Compare behavior instead of generated IDs, explanatory copy, or GPS rounding.
    public struct TimelineExpectation: Codable, Equatable, Sendable {
        public var kind: TimelineKind
        public var start: Date
        public var end: Date?
        public var placeID: String?
        public var mode: TransportMode
        public var isUserEdited: Bool

        public init(_ item: TimelineItem) {
            kind = item.kind
            start = Self.milliseconds(item.start)
            end = item.end.map(Self.milliseconds)
            placeID = item.placeID; mode = item.mode; isUserEdited = item.isUserEdited
        }
        private static func milliseconds(_ date: Date) -> Date {
            Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1_000).rounded() / 1_000)
        }
    }

    public func replay() -> [TimelineExpectation] {
        let inferred = InferenceEngine.infer(observations: input.observations, places: input.places,
                                             networks: input.networks, accessPoints: input.accessPoints)
        return InferenceEngine.applying(input.corrections, to: inferred).map(TimelineExpectation.init)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        let result = try decoder.decode(Self.self, from: data)
        guard result.formatVersion == 1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unsupported Places test case version."))
        }
        return result
    }

    static func redacting(_ archive: HistoryArchive) -> Self {
        let placeIDs = aliases(archive.places.map(\.id) + archive.observations.compactMap(\.monitoredPlaceID)
            + archive.timeline.compactMap(\.placeID) + archive.corrections.compactMap(\.placeID)
            + archive.accessPoints.compactMap(\.placeID), prefix: "place")
        let observationIDs = aliases(archive.observations.map(\.id), prefix: "observation")
        let correctionIDs = aliases(archive.corrections.map(\.id), prefix: "correction")
        let networkIDs = aliases(archive.networks.map(\.id) + archive.accessPoints.map(\.networkID), prefix: "network")
        let pointIDs = aliases(archive.accessPoints.map(\.id), prefix: "access-point")
        let ssids = aliases(archive.networks.map(\.ssid) + archive.observations.compactMap(\.ssid)
            + archive.places.flatMap(\.expectedSSIDs), prefix: "Wi-Fi")
        let bssids = aliases(archive.accessPoints.map(\.bssid) + archive.observations.compactMap(\.bssid), prefix: "access-point-address")

        // A whole-day shift keeps time of day and all elapsed intervals while
        // replacing real dates. Zone names become per-sample fixed UTC offsets;
        // offset changes still survive without disclosing a geographic zone name.
        let earliest = (archive.observations.map(\.timestamp) + archive.places.map(\.createdAt)
            + archive.timeline.map(\.start) + archive.corrections.map(\.start)
            + archive.networks.map(\.firstSeen)).min() ?? Date(timeIntervalSince1970: 0)
        let offset = 946_857_600 - floor(earliest.timeIntervalSince1970 / 86_400) * 86_400
        func date(_ value: Date) -> Date { value.addingTimeInterval(offset) }
        let anchor = archive.observations.compactMap(\.coordinate).first ?? archive.places.first?.coordinate
            ?? Coordinate(latitude: 0, longitude: 0)
        let rotation = CoordinateRotation(anchor: anchor)

        let observations = archive.observations.map { value in
            var copy = value
            copy.id = observationIDs[value.id]!
            copy.timestamp = date(value.timestamp); copy.coordinateTimestamp = value.coordinateTimestamp.map(date)
            copy.coordinate = value.coordinate.map(rotation.apply)
            copy.monitoredPlaceID = value.monitoredPlaceID.flatMap { placeIDs[$0] }
            copy.ssid = value.ssid.flatMap { ssids[$0] }; copy.bssid = value.bssid.flatMap { bssids[$0] }
            let seconds = TimeZone(identifier: value.timezoneIdentifier)?.secondsFromGMT(for: value.timestamp) ?? 0
            copy.timezoneIdentifier = TimeZone(secondsFromGMT: seconds)?.identifier ?? "GMT"
            copy.policyVersion = TrackingPolicy.version
            return copy
        }
        let places = archive.places.map { value in
            Place(id: placeIDs[value.id]!, name: placeIDs[value.id]!, coordinate: rotation.apply(value.coordinate),
                  radius: value.radius, expectedSSIDs: value.expectedSSIDs.compactMap { ssids[$0] }, createdAt: date(value.createdAt))
        }
        let networks = archive.networks.map { value in
            WiFiNetwork(id: networkIDs[value.id]!, ssid: ssids[value.ssid]!, classification: value.classification,
                        userClassified: value.userClassified, firstSeen: date(value.firstSeen), lastSeen: date(value.lastSeen))
        }
        let points = archive.accessPoints.map { value in
            WiFiAccessPoint(id: pointIDs[value.id]!, networkID: networkIDs[value.networkID]!, bssid: bssids[value.bssid]!,
                            placeID: value.placeID.flatMap { placeIDs[$0] }, lastSeen: date(value.lastSeen))
        }
        let corrections = archive.corrections.map { value in
            UserOverride(id: correctionIDs[value.id]!, start: date(value.start), end: date(value.end), kind: value.kind,
                         placeID: value.placeID.flatMap { placeIDs[$0] }, mode: value.mode, createdAt: date(value.createdAt))
        }
        let expected = archive.timeline.map { value in
            var copy = value
            copy.start = date(value.start); copy.end = value.end.map(date)
            copy.placeID = value.placeID.flatMap { placeIDs[$0] }
            return TimelineExpectation(copy)
        }
        return Self(formatVersion: 1, policyVersion: TrackingPolicy.version,
                    instructions: "Dates are Unix seconds. expectedTimeline snapshots the saved, corrected history. Review it against what happened, or edit it to describe the desired result. In Swift: InferenceTestCase.decode(data), then compare replay() with expectedTimeline. Millisecond precision is used for timeline comparisons.",
                    privacy: "Names, addresses, identifiers, dates, geographic time zone names, and absolute locations are replaced. Distances, route shapes, time of day, UTC offsets, and durations remain and can still be identifying. Review before sharing. Diagnostic free text and device metadata are excluded.",
                    input: Input(observations: observations, places: places, networks: networks, accessPoints: points, corrections: corrections),
                    expectedTimeline: expected)
    }

    private static func aliases(_ values: [String], prefix: String) -> [String: String] {
        // Preserve lexical ordering for equal-timestamp deterministic tie breaks.
        Dictionary(uniqueKeysWithValues: Set(values).sorted().enumerated().map {
            ($0.element, "\(prefix)-\(String(format: "%08d", $0.offset + 1))")
        })
    }
}

/// Rotate the globe instead of adding latitude/longitude offsets: spherical
/// distances remain unchanged, including at the poles and across the date line.
private struct CoordinateRotation {
    let latitude: Double
    let longitude: Double
    init(anchor: Coordinate) {
        latitude = anchor.latitude * .pi / 180
        longitude = anchor.longitude * .pi / 180
    }
    func apply(_ point: Coordinate) -> Coordinate {
        let lat = point.latitude * .pi / 180, lon = point.longitude * .pi / 180 - longitude
        let x = cos(lat) * cos(lon), y = cos(lat) * sin(lon), z = sin(lat)
        let rotatedX = cos(latitude) * x + sin(latitude) * z
        let rotatedZ = -sin(latitude) * x + cos(latitude) * z
        let roll = 37.0 * Double.pi / 180
        let finalY = cos(roll) * y - sin(roll) * rotatedZ
        let finalZ = sin(roll) * y + cos(roll) * rotatedZ
        return Coordinate(latitude: atan2(finalZ, hypot(rotatedX, finalY)) * 180 / .pi,
                          longitude: atan2(finalY, rotatedX) * 180 / .pi)
    }
}
