import Foundation

/// Ranks manual correction choices. Never changes inferred history or hides a mode.
public struct TransportSuggestions: Equatable, Sendable {
    public let suggested: [TransportMode]
    public let estimatedSpeedKilometersPerHour: Double?
    public var otherModes: [TransportMode] { TransportMode.choiceOrder.filter { !suggested.contains($0) } }
    public static let none = Self(suggested: [], estimatedSpeedKilometersPerHour: nil)

    public static func make(for item: TimelineItem, observations: [SensorObservation]) -> Self {
        // An open interval only has evidence through its last sample, not through now.
        let end = item.end ?? item.lastEvidenceAt
        let duration = end.timeIntervalSince(item.start)
        guard duration.isFinite, duration >= 60 else { return .none }
        let values = observations.filter { $0.timestamp >= item.start && $0.timestamp <= end }
            .sorted { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) }
        guard !values.contains(where: {
            [.recovery, .paused, .resumed].contains($0.source) && $0.timestamp > item.start && $0.timestamp < end
        }) else { return .none }

        // Use actual location fixes, not cached Wi-Fi coordinates or visit centroids.
        // Thin very dense samples to reduce the effect of GPS jitter on distance.
        var fixes: [SensorObservation] = []
        for value in values where [.location, .significantChange].contains(value.source) {
            guard value.usableCoordinate != nil, (value.horizontalAccuracy ?? .infinity) <= 100,
                  value.coordinateTimestamp == value.timestamp else { continue }
            if let previous = fixes.last, value.timestamp.timeIntervalSince(previous.timestamp) < 20 { continue }
            fixes.append(value)
        }
        guard fixes.count >= 3, let first = fixes.first, let last = fixes.last else { return .none }
        let span = last.timestamp.timeIntervalSince(first.timestamp)
        guard span >= max(60, duration * 0.6) else { return .none }

        var distance = 0.0
        var speeds: [Double] = []
        for (a, b) in zip(fixes, fixes.dropFirst()) {
            let seconds = b.timestamp.timeIntervalSince(a.timestamp)
            // Do not join endpoints across a recording gap to invent a route or speed.
            guard seconds <= 300 else { return .none }
            let metres = a.coordinate!.distance(to: b.coordinate!)
            speeds.append(metres / seconds * 3.6)
            distance += metres
        }
        let uncertainty = fixes.map { $0.horizontalAccuracy! }.max()!
        let displacement = fixes.map { first.coordinate!.distance(to: $0.coordinate!) }.max()!
        guard displacement >= max(100, uncertainty * 4) else { return .none }
        let sortedSpeeds = speeds.sorted()
        let medianSpeed = sortedSpeeds[sortedSpeeds.count / 2]
        // A lone implausible jump must not turn a walk into a flight recommendation.
        guard speeds.allSatisfy({ $0 <= 1_200 && $0 <= max(60, medianSpeed * 4) }) else { return .none }
        let speed = distance / span * 3.6
        guard speed >= 1 else { return .none }

        // Broad ranking bands, not transport identification. Car, bus, train and
        // ferry speeds overlap; the user always has the final say.
        var modes: [TransportMode]
        switch speed {
        case ..<8: modes = [.walking, .cycling]
        case ..<35: modes = [.cycling, .driving, .train]
        case ..<140: modes = [.driving, .train]
        case ..<300: modes = [.train, .driving]
        default:
            guard distance >= 20_000, span >= 180, fixes.count >= 5 else { return .none }
            modes = [.plane, .train]
        }

        // Only use recent motion within this interval when it agrees with speed.
        if let motion = values.last(where: { $0.motion != nil && $0.timestamp >= end.addingTimeInterval(-300) })?.motion {
            let preferred: TransportMode? = switch motion {
            case .walking, .running: speed < 15 ? .walking : nil
            case .cycling: speed < 60 ? .cycling : nil
            case .automotive: speed < 180 ? .driving : nil
            default: nil
            }
            if let preferred { modes.removeAll { $0 == preferred }; modes.insert(preferred, at: 0) }
        }
        return Self(suggested: modes, estimatedSpeedKilometersPerHour: speed)
    }
}
