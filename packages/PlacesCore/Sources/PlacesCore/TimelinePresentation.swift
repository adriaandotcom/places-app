import Foundation

/// Groups corrected history without rewriting evidence or claiming an unrecorded route.
public enum TimelinePresentation {
    public static func make(items: [TimelineItem], observations: [SensorObservation], places: [Place],
                            separatedAt: [Date] = []) -> [TimelineItem] {
        let originals = items.flatMap { $0.originalItems ?? [$0] }.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        let fixes = observations.filter { $0.usableCoordinate != nil }.sorted { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) }
        let boundaries = Set(separatedAt)
        var result: [TimelineItem] = []
        var index = 0
        while index < originals.count {
            var members = [originals[index]]
            index += 1
            while index < originals.count {
                let last = members.last!, next = originals[index]
                guard touches(last, next), !boundaries.contains(next.start) else { break }
                if compatible(members[0], next) {
                    members.append(next); index += 1
                } else if next.kind == .gap, !next.isUserEdited, let end = next.end,
                          end.timeIntervalSince(next.start) <= 600, index + 1 < originals.count,
                          touches(next, originals[index + 1]), !boundaries.contains(originals[index + 1].start),
                          members[0].kind == .stay, compatible(members[0], originals[index + 1]),
                          supportsContinuity(members[0], gap: next, observations: observations, places: places) {
                    members.append(contentsOf: [next, originals[index + 1]]); index += 2
                } else { break }
            }
            var combined = members[0]
            if members.count > 1 {
                combined.end = members.last!.end
                combined.lastEvidenceAt = members.map(\.lastEvidenceAt).max()!
                combined.isUserEdited = members.contains(where: \.isUserEdited)
                combined.evidenceIDs = Array(Set(members.flatMap(\.evidenceIDs))).sorted()
                combined.reasons = members.flatMap(\.reasons).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
                combined.originalItems = members
                combined.coordinate = members.compactMap(\.coordinate).first
            }
            combined.isSeparated = boundaries.contains(combined.start) || combined.end.map(boundaries.contains) == true
            if combined.kind != .stay {
                combined.connection = connection(for: combined, originals: originals, fixes: fixes, places: places)
            }
            result.append(combined)
        }
        return result
    }

    private static func touches(_ left: TimelineItem, _ right: TimelineItem) -> Bool {
        guard let end = left.end else { return false }
        return abs(end.timeIntervalSince(right.start)) < 0.001
    }

    private static func compatible(_ left: TimelineItem, _ right: TimelineItem) -> Bool {
        guard left.kind == right.kind else { return false }
        switch left.kind {
        case .stay:
            if let id = left.placeID { return id == right.placeID }
            guard right.placeID == nil, let a = left.coordinate, let b = right.coordinate else { return false }
            return a.distance(to: b) <= TrackingPolicy.stationaryRadius
        case .journey: return left.mode == right.mode
        case .gap: return true
        }
    }

    private static func supportsContinuity(_ stay: TimelineItem, gap: TimelineItem,
                                           observations: [SensorObservation], places: [Place]) -> Bool {
        let place = places.first { $0.id == stay.placeID }
        guard let anchor = place?.coordinate ?? stay.coordinate else { return false }
        let radius = place?.radius ?? TrackingPolicy.stationaryRadius
        // A pause, observed departure, or contradictory fix must remain explicit.
        // A short recovery alone is not proof that someone left this place.
        return !observations.contains { observation in
            guard observation.timestamp >= gap.start, observation.timestamp <= (gap.end ?? gap.start) else { return false }
            if [.paused, .regionExit, .visitDeparture].contains(observation.source) { return true }
            if let motion = observation.motion, [.walking, .running, .cycling, .automotive].contains(motion) { return true }
            if let coordinate = observation.usableCoordinate {
                return anchor.distance(to: coordinate) > radius || (observation.speed ?? -1) >= 0.8
            }
            return false
        }
    }

    private static func connection(for item: TimelineItem, originals: [TimelineItem], fixes: [SensorObservation],
                                   places: [Place]) -> TimelineConnection? {
        let end = item.end ?? item.lastEvidenceAt
        func endpoint(_ stay: TimelineItem?, at time: Date) -> TimelineConnection.Endpoint? {
            guard let stay, let coordinate = places.first(where: { $0.id == stay.placeID })?.coordinate ?? stay.coordinate else { return nil }
            return .init(coordinate: coordinate, placeID: stay.placeID, timestamp: time)
        }
        let previous = originals.last { $0.kind == .stay && $0.end == item.start }
        let following = originals.first { $0.kind == .stay && $0.start == end }
        let within = fixes.filter { $0.timestamp >= item.start && $0.timestamp <= end }
        let from = endpoint(previous, at: item.start) ?? within.first.map {
            TimelineConnection.Endpoint(coordinate: $0.usableCoordinate!, timestamp: $0.timestamp)
        }
        let to = endpoint(following, at: end) ?? within.last.map {
            TimelineConnection.Endpoint(coordinate: $0.usableCoordinate!, timestamp: $0.timestamp)
        }
        guard let from, let to, to.timestamp > from.timestamp else { return nil }
        return TimelineConnection(from: from, to: to)
    }
}
