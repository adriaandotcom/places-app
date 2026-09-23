import Foundation

public struct Coordinate: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
    public func distance(to other: Coordinate) -> Double {
        let radians = Double.pi / 180
        let a = pow(sin((other.latitude - latitude) * radians / 2), 2)
            + cos(latitude * radians) * cos(other.latitude * radians)
            * pow(sin((other.longitude - longitude) * radians / 2), 2)
        return 6_371_000 * 2 * atan2(sqrt(min(1, a)), sqrt(max(0, 1 - a)))
    }
}

public enum ObservationSource: String, Codable, Sendable {
    case location, significantChange, visitArrival, visitDeparture, regionEnter, regionExit
    case motion, wifi, recovery, paused, resumed
}
public enum TransportMode: String, Codable, CaseIterable, Sendable {
    case unknown, walking, cycling, driving, train
    public var title: String {
        switch self {
        case .unknown: "Travelled"
        case .walking: "Walked"
        case .cycling: "Cycled"
        case .driving: "Drove"
        case .train: "Took the train"
        }
    }
    public var symbol: String {
        switch self {
        case .unknown: "point.topleft.down.to.point.bottomright.curvepath"
        case .walking: "figure.walk"
        case .cycling: "bicycle"
        case .driving: "car.fill"
        case .train: "tram.fill"
        }
    }
}
public enum MotionKind: String, Codable, Sendable { case unknown, stationary, walking, running, cycling, automotive }

public struct SensorObservation: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var timestamp: Date
    public var source: ObservationSource
    public var coordinate: Coordinate?
    public var coordinateTimestamp: Date?
    public var horizontalAccuracy: Double?
    public var speed: Double?
    public var motion: MotionKind?
    public var monitoredPlaceID: String?
    public var ssid: String?
    public var bssid: String?
    public var timezoneIdentifier: String
    public var policyVersion: String

    public init(id: String = UUID().uuidString, timestamp: Date, source: ObservationSource,
                coordinate: Coordinate? = nil, coordinateTimestamp: Date? = nil,
                horizontalAccuracy: Double? = nil, speed: Double? = nil, motion: MotionKind? = nil,
                monitoredPlaceID: String? = nil, ssid: String? = nil, bssid: String? = nil,
                timezoneIdentifier: String = TimeZone.current.identifier) {
        self.id = id; self.timestamp = timestamp; self.source = source
        self.coordinate = coordinate; self.coordinateTimestamp = coordinateTimestamp ?? (coordinate == nil ? nil : timestamp)
        self.horizontalAccuracy = horizontalAccuracy; self.speed = speed; self.motion = motion
        self.monitoredPlaceID = monitoredPlaceID; self.ssid = ssid; self.bssid = bssid?.lowercased()
        self.timezoneIdentifier = timezoneIdentifier; self.policyVersion = TrackingPolicy.version
    }

    // A platform callback may deliver the same sample more than once, with a different local UUID.
    public var deduplicationKey: String {
        [source.rawValue, String(timestamp.timeIntervalSince1970),
         coordinate.map { "\($0.latitude),\($0.longitude)" } ?? "", horizontalAccuracy.map(String.init(describing:)) ?? "",
         speed.map(String.init(describing:)) ?? "", motion?.rawValue ?? "", monitoredPlaceID ?? "", ssid ?? "", bssid ?? ""]
            .joined(separator: "|")
    }
    public var usableCoordinate: Coordinate? {
        guard let coordinate, coordinate.isValid, let accuracy = horizontalAccuracy,
              accuracy.isFinite, accuracy >= 0, accuracy <= 250,
              let coordinateTimestamp, abs(timestamp.timeIntervalSince(coordinateTimestamp)) <= 120 else { return nil }
        return coordinate
    }
}

public struct Place: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var address: String
    public var coordinate: Coordinate
    public var radius: Double
    public var symbol: String
    public var colorIndex: Int
    public var expectedSSIDs: [String]
    public var createdAt: Date
    public init(id: String = UUID().uuidString, name: String, address: String = "", coordinate: Coordinate,
                radius: Double = 100, symbol: String = "mappin", colorIndex: Int = 0,
                expectedSSIDs: [String] = [], createdAt: Date = Date()) {
        self.id = id; self.name = name; self.address = address; self.coordinate = coordinate
        self.radius = radius; self.symbol = symbol; self.colorIndex = colorIndex
        self.expectedSSIDs = expectedSSIDs; self.createdAt = createdAt
    }
}

public enum WiFiClassification: String, Codable, CaseIterable, Sendable {
    case unclassified, fixed, shared, portable, ignored
}
public struct WiFiNetwork: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var ssid: String
    public var classification: WiFiClassification
    public var userClassified: Bool
    public var firstSeen: Date
    public var lastSeen: Date
    public init(id: String = UUID().uuidString, ssid: String, classification: WiFiClassification = .fixed,
                userClassified: Bool = false, firstSeen: Date, lastSeen: Date) {
        self.id = id; self.ssid = ssid; self.classification = classification; self.userClassified = userClassified
        self.firstSeen = firstSeen; self.lastSeen = lastSeen
    }
}
public struct WiFiAccessPoint: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var networkID: String
    public var bssid: String
    public var placeID: String?
    public var lastSeen: Date
}

public enum TimelineKind: String, Codable, Sendable { case stay, journey, gap }
public struct TimelineItem: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: TimelineKind
    public var start: Date
    public var end: Date?
    public var placeID: String?
    public var mode: TransportMode
    public var reasons: [String]
    public var evidenceIDs: [String]
    public var isUserEdited: Bool
    public var lastEvidenceAt: Date
    public var coordinate: Coordinate?
    public init(id: String, kind: TimelineKind, start: Date, end: Date? = nil, placeID: String? = nil,
                mode: TransportMode = .unknown, reasons: [String] = [], evidenceIDs: [String] = [],
                isUserEdited: Bool = false, lastEvidenceAt: Date, coordinate: Coordinate? = nil) {
        self.id = id; self.kind = kind; self.start = start; self.end = end; self.placeID = placeID
        self.mode = mode; self.reasons = reasons; self.evidenceIDs = evidenceIDs
        self.isUserEdited = isUserEdited; self.lastEvidenceAt = lastEvidenceAt; self.coordinate = coordinate
    }
    public func duration(until now: Date = Date()) -> TimeInterval { max(0, (end ?? now).timeIntervalSince(start)) }
}

public struct UserOverride: Codable, Identifiable, Sendable {
    public var id: String
    public var start: Date
    public var end: Date
    public var kind: TimelineKind
    public var placeID: String?
    public var mode: TransportMode
    public var createdAt: Date
    public init(id: String = UUID().uuidString, start: Date, end: Date, kind: TimelineKind,
                placeID: String? = nil, mode: TransportMode = .unknown, createdAt: Date = Date()) {
        self.id = id; self.start = start; self.end = end; self.kind = kind
        self.placeID = placeID; self.mode = mode; self.createdAt = createdAt
    }
}
public struct RoutePoint: Codable, Identifiable, Sendable {
    public var id: String
    public var observationID: String
    public var timelineID: String
    public var timestamp: Date
    public var coordinate: Coordinate
    public var horizontalAccuracy: Double
}
public struct TrackingEvent: Codable, Identifiable, Sendable {
    public var id: String
    public var timestamp: Date
    public var state: TrackingState
    public var reason: String
    public var previousStateDuration: TimeInterval
    public var standardLocationActive: Bool
    public var policyVersion: String
    public var build: String
    public init(timestamp: Date, state: TrackingState, reason: String, previousStateDuration: TimeInterval,
                standardLocationActive: Bool, build: String) {
        self.id = UUID().uuidString; self.timestamp = timestamp; self.state = state; self.reason = reason
        self.previousStateDuration = max(0, previousStateDuration); self.standardLocationActive = standardLocationActive
        self.policyVersion = TrackingPolicy.version; self.build = build
    }
}

public struct HistoryArchive: Codable, Sendable {
    public let formatVersion: Int
    public let exportedAt: Date
    public let places: [Place]
    public let observations: [SensorObservation]
    public let timeline: [TimelineItem]
    public let corrections: [UserOverride]
    public let networks: [WiFiNetwork]
    public let accessPoints: [WiFiAccessPoint]
    public let routePoints: [RoutePoint]
    public let trackingEvents: [TrackingEvent]
}

public struct DiagnosticReport: Codable, Sendable {
    public let formatVersion: Int
    public let policyVersion: String
    public let observationCount: Int
    public let placeCount: Int
    public let timelineCount: Int
    public let stateDurations: [String: Double]
    public let locationFixCount: Int
    public let standardLocationSeconds: Double
    public let note: String
}

public enum PlacesError: Error, LocalizedError {
    case invalidPlace, invalidObservation, invalidCorrection
    public var errorDescription: String? {
        switch self {
        case .invalidPlace: "Give this place a name, valid coordinates, and a radius between 50 and 1,000 metres."
        case .invalidObservation: "This sensor observation could not be stored."
        case .invalidCorrection: "The correction needs a valid time interval and an existing place, if selected."
        }
    }
}
