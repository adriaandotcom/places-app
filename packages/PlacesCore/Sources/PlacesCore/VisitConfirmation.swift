import Foundation

/// The same bounded evidence test is used by history and the live sensor policy.
/// Place membership identifies a candidate; it never establishes a visit by itself.
public struct VisitConfirmation: Sendable {
    public struct Candidate: Sendable {
        public let first: SensorObservation
        public var placeID: String?
        public let walking: Bool
        public var lastMeasuredAt: Date
        public var evidenceIDs: [String]
        public var confirmed: Bool
    }
    public private(set) var candidate: Candidate?
    public init() {}
    public mutating func reset() { candidate = nil }

    public mutating func motionChanged(_ motion: MotionKind) {
        guard let candidate else { return }
        if candidate.walking ? motion != .walking : Self.isMoving(motion) { reset() }
    }
    public static func isMoving(_ motion: MotionKind) -> Bool {
        [.walking, .running, .cycling, .automotive].contains(motion)
    }
    public static func motion(stationary: Bool, walking: Bool, running: Bool, cycling: Bool, automotive: Bool) -> MotionKind {
        // Apple can report stationary AND automotive at a traffic light.
        if automotive { return .automotive }
        if cycling { return .cycling }
        if running { return .running }
        if walking { return .walking }
        return stationary ? .stationary : .unknown
    }

    @discardableResult
    public mutating func observe(_ observation: SensorObservation, place: Place?,
                                 connectedPlace: Place? = nil, motion: MotionKind) -> Candidate? {
        let wifi = observation.source == .wifi && connectedPlace != nil
        if let candidate, candidate.first.source == .wifi, !wifi,
           place?.id == candidate.placeID, !Self.isMoving(motion), (observation.speed ?? -1) < 0.8 {
            // An in-place passive fix must not replace a Wi-Fi-only dwell anchor
            // (which may have no coordinate). Only fresh Wi-Fi reads advance it.
            return candidate.confirmed ? candidate : nil
        }
        if wifi, motion == .walking, let candidate, candidate.walking, candidate.placeID == connectedPlace?.id {
            // A connection read cannot measure a walk, but it also must not
            // discard the GPS evidence for a walk in the same saved area.
            return candidate.confirmed ? candidate : nil
        }
        let walking = place?.countsWalksAsVisits == true && motion == .walking && !wifi
        guard !Self.isMoving(motion) || walking,
              wifi || (observation.usableCoordinate != nil && (observation.horizontalAccuracy ?? .infinity) <= 50),
              !walking || (observation.speed ?? -1) <= 3.5,
              wifi || walking || (observation.speed ?? -1) < 0.8 else { reset(); return nil }
        let measuredAt = wifi ? observation.timestamp : (observation.coordinateTimestamp ?? observation.timestamp)
        let placeID = (connectedPlace ?? place)?.id
        let sameArea: Bool
        if let candidate {
            if walking { sameArea = candidate.placeID == placeID }
            else if wifi, candidate.first.source == .wifi { sameArea = candidate.placeID == placeID }
            else if let a = candidate.first.usableCoordinate, let b = observation.usableCoordinate {
                sameArea = a.distance(to: b) <= 50
            } else { sameArea = false }
        } else { sameArea = false }
        if let candidate, measuredAt <= candidate.lastMeasuredAt {
            return candidate.confirmed && candidate.walking == walking && sameArea ? candidate : nil
        }
        // An ordinary stop is physical dwell, independent of the nearest place
        // label. Walking and Wi-Fi-only candidates require the same saved area.
        guard var pending = candidate, pending.walking == walking, sameArea,
              pending.confirmed || measuredAt.timeIntervalSince(pending.lastMeasuredAt) <= TrackingPolicy.confirmationEvidenceGap else {
            candidate = Candidate(first: observation, placeID: placeID, walking: walking,
                lastMeasuredAt: measuredAt, evidenceIDs: [observation.id], confirmed: false)
            return nil
        }
        pending.placeID = placeID
        pending.lastMeasuredAt = measuredAt
        if !pending.confirmed { pending.evidenceIDs.append(observation.id) }
        let firstTime = pending.first.source == .wifi ? pending.first.timestamp
            : (pending.first.coordinateTimestamp ?? pending.first.timestamp)
        pending.confirmed = measuredAt.timeIntervalSince(firstTime) >= TrackingPolicy.stationaryDuration
        candidate = pending
        return pending.confirmed ? pending : nil
    }
}
