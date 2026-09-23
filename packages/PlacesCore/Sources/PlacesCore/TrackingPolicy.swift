import Foundation

public enum TrackingState: String, Codable, CaseIterable, Sendable {
    case recovery, unknown, moving, stationaryCandidate, knownPlace, stationaryUnknown, lowPowerFallback, paused
    public var title: String {
        switch self {
        case .recovery: "Finding your place"
        case .unknown: "Waiting for a location"
        case .moving: "Recording your journey"
        case .stationaryCandidate: "Checking your stop"
        case .knownPlace: "At a known place"
        case .stationaryUnknown: "Stopped somewhere new"
        case .lowPowerFallback: "Using low-power signals"
        case .paused: "Tracking paused"
        }
    }
}

public struct SensorPolicy: Equatable, Sendable {
    public var standardUpdates: Bool
    public var desiredAccuracy: Double
    public var distanceFilter: Double
}

public enum TrackingPolicy {
    public static let version = "1.1"
    public static let stationaryDuration: TimeInterval = 180
    public static let evidenceGap: TimeInterval = 20 * 60
    public static let stationaryRadius: Double = 60

    public static func sensors(state: TrackingState, motion: MotionKind, lowPower: Bool) -> SensorPolicy {
        let active = [.recovery, .unknown, .moving, .stationaryCandidate].contains(state)
        let distance: Double = switch motion {
        case .cycling: 75
        case .automotive: 150
        default: 35
        }
        return SensorPolicy(standardUpdates: active, desiredAccuracy: lowPower ? 100 : 10,
                            distanceFilter: distance * (lowPower ? 2 : 1))
    }

    public static func sameStationaryArea(_ first: SensorObservation, _ second: SensorObservation) -> Bool {
        guard let a = first.usableCoordinate, let b = second.usableCoordinate else { return false }
        let uncertainty = min(150, (first.horizontalAccuracy ?? 0) + (second.horizontalAccuracy ?? 0))
        return a.distance(to: b) <= max(stationaryRadius, uncertainty)
    }

    public static func matchingPlace(for observation: SensorObservation, places: [Place]) -> Place? {
        guard let coordinate = observation.usableCoordinate,
              let accuracy = observation.horizontalAccuracy else { return nil }
        let candidates = places.filter {
            accuracy <= min(100, $0.radius) && coordinate.distance(to: $0.coordinate) <= $0.radius
        }.sorted { coordinate.distance(to: $0.coordinate) < coordinate.distance(to: $1.coordinate) }
        // Overlapping places cannot be resolved from one coarse fix.
        guard let closest = candidates.first else { return nil }
        if candidates.count > 1 {
            let first = coordinate.distance(to: closest.coordinate)
            let second = coordinate.distance(to: candidates[1].coordinate)
            if second - first < max(25, accuracy) { return nil }
        }
        return closest
    }

    public static func mode(for motion: MotionKind?) -> TransportMode {
        switch motion {
        case .walking, .running: .walking
        case .cycling: .cycling
        case .automotive: .driving
        default: .unknown
        }
    }
}
