import Foundation

/// Sampling persistence, not the sensor: transitions still reach the tracking policy immediately.
public struct WiFiEvidenceGate: Sendable {
    private var last: SensorObservation?
    private var placeID: String?
    public init() {}
    public mutating func shouldRecord(_ observation: SensorObservation, placeID: String?) -> Bool {
        guard observation.source == .wifi else { return true }
        let changed = last.map {
            $0.ssid != observation.ssid || $0.bssid?.lowercased() != observation.bssid?.lowercased()
                || self.placeID != placeID
                // A newly available coordinate can teach an access point; don't suppress it.
                || ($0.usableCoordinate == nil && observation.usableCoordinate != nil)
                || ($0.usableCoordinate.flatMap { previous in observation.usableCoordinate.map { previous.distance(to: $0) > 60 } } ?? false)
        } ?? true
        guard changed || observation.timestamp.timeIntervalSince(last!.timestamp) >= 300 else { return false }
        last = observation; self.placeID = placeID
        return true
    }
}

public struct EvidenceGroup: Identifiable, Sendable {
    public var observations: [SensorObservation]
    public var id: String { observations[0].id }
    public var first: SensorObservation { observations[0] }

    /// Compact legacy repeated checks without dropping or rewriting any raw evidence.
    public static func make(_ observations: [SensorObservation]) -> [EvidenceGroup] {
        var groups: [EvidenceGroup] = []
        var seen: Set<String> = []
        for observation in observations.sorted(by: { $0.timestamp < $1.timestamp }) where seen.insert(observation.id).inserted {
            if let last = groups.last, last.first.source == .wifi, observation.source == .wifi,
               last.first.ssid == observation.ssid, last.first.bssid?.lowercased() == observation.bssid?.lowercased(),
               observation.timestamp.timeIntervalSince(last.first.timestamp) < 300 {
                groups[groups.count - 1].observations.append(observation)
            } else { groups.append(EvidenceGroup(observations: [observation])) }
        }
        return groups
    }
}
