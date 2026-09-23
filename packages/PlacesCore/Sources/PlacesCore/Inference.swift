import Foundation

public enum InferenceEngine {
    public static func infer(observations: [SensorObservation], places: [Place], networks: [WiFiNetwork] = [],
                             accessPoints: [WiFiAccessPoint] = []) -> [TimelineItem] {
        let sorted = observations.sorted { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) }
        var result: [TimelineItem] = []
        var current: TimelineItem?
        var stationaryAnchor: SensorObservation?
        var latestMotion: MotionKind = .unknown
        var motionTime = Date.distantPast

        func close(at time: Date) {
            guard var item = current else { return }
            item.end = max(item.start, time)
            if time > item.start { result.append(item) }
            current = nil
        }
        func start(_ kind: TimelineKind, at time: Date, observation: SensorObservation, place: Place? = nil,
                   mode: TransportMode = .unknown, reason: String) {
            current = TimelineItem(id: "\(observation.id)-\(kind.rawValue)", kind: kind, start: time,
                                   placeID: place?.id, mode: mode, reasons: [reason], evidenceIDs: [observation.id],
                                   lastEvidenceAt: time, coordinate: observation.usableCoordinate)
        }
        func addEvidence(_ observation: SensorObservation) {
            guard current != nil else { return }
            current?.lastEvidenceAt = observation.timestamp
            if current?.evidenceIDs.contains(observation.id) == false { current?.evidenceIDs.append(observation.id) }
        }

        for observation in sorted {
            let time = observation.timestamp
            if let motion = observation.motion { latestMotion = motion; motionTime = time }
            let motion = time.timeIntervalSince(motionTime) <= 300 ? latestMotion : .unknown

            if [.recovery, .paused, .resumed].contains(observation.source) {
                if let item = current, item.kind != .gap {
                    let boundary = observation.source == .paused ? time : item.lastEvidenceAt
                    close(at: boundary)
                    start(.gap, at: boundary, observation: observation, reason: "No observations establish this interval.")
                } else if current == nil {
                    start(.gap, at: time, observation: observation, reason: "Waiting for location evidence.")
                }
                stationaryAnchor = nil
                continue
            }

            if observation.source == .regionExit || observation.source == .visitDeparture {
                if observation.source == .regionExit, let item = current, item.kind == .stay,
                   item.placeID != observation.monitoredPlaceID {
                    // Nearby or overlapping monitored regions are not proof of leaving this stay.
                    continue
                }
                if current?.kind == .journey { addEvidence(observation); continue }
                close(at: time)
                start(.journey, at: time, observation: observation, mode: TrackingPolicy.mode(for: motion),
                      reason: "A departure was observed; the route is recorded only where fixes are available.")
                stationaryAnchor = nil
                continue
            }

            guard let coordinate = observation.usableCoordinate else { continue }

            if let item = current, item.kind == .journey,
               time.timeIntervalSince(item.lastEvidenceAt) > TrackingPolicy.evidenceGap {
                let boundary = item.lastEvidenceAt
                close(at: boundary)
                start(.gap, at: boundary, observation: observation, reason: "No observations establish this interval.")
                close(at: time)
                stationaryAnchor = nil
            }

            var place = TrackingPolicy.matchingPlace(for: observation, places: places)
            var wifiMatched = false
            if let ssid = observation.ssid, let bssid = observation.bssid,
               let network = networks.first(where: { $0.ssid == ssid }),
               [.fixed, .shared].contains(network.classification),
               let accessPoint = accessPoints.first(where: { $0.networkID == network.id && $0.bssid == bssid }),
               let wifiPlace = places.first(where: { $0.id == accessPoint.placeID }),
               coordinate.distance(to: wifiPlace.coordinate) <= wifiPlace.radius,
               (observation.horizontalAccuracy ?? .infinity) <= min(100, wifiPlace.radius) {
                place = wifiPlace; wifiMatched = true
            }

            if let place {
                stationaryAnchor = nil
                if current?.kind == .stay && current?.placeID == place.id {
                    addEvidence(observation)
                    if wifiMatched, current?.reasons.contains("Connected fixed-place Wi-Fi agrees with your location.") == false {
                        current?.reasons.append("Connected fixed-place Wi-Fi agrees with your location.")
                    }
                } else {
                    close(at: time)
                    start(.stay, at: time, observation: observation, place: place,
                          reason: "Location observations fall inside this place. Arrival and departure boundaries are estimates.")
                }
                continue
            }

            let isStill = observation.source == .visitArrival || motion == .stationary
                || (observation.speed.map { $0 < 0.8 } ?? false)
            if isStill {
                if stationaryAnchor?.usableCoordinate?.distance(to: coordinate) ?? .infinity > TrackingPolicy.stationaryRadius {
                    stationaryAnchor = observation
                }
            } else { stationaryAnchor = nil }
            let anchor = stationaryAnchor
            let stationary = observation.source == .visitArrival
                || (anchor.map { time.timeIntervalSince($0.timestamp) >= TrackingPolicy.stationaryDuration } ?? false)

            if stationary {
                if current?.kind == .stay && current?.placeID == nil {
                    addEvidence(observation)
                } else {
                    let boundary = max(current?.start ?? time, anchor?.timestamp ?? time)
                    close(at: boundary)
                    start(.stay, at: boundary, observation: anchor ?? observation,
                          reason: "Stationary observations indicate a stop. This place has not been named.")
                    addEvidence(observation)
                }
            } else if current?.kind == .stay, current?.placeID == nil, isStill,
                      let stopCoordinate = current?.coordinate,
                      stopCoordinate.distance(to: coordinate) <= TrackingPolicy.stationaryRadius {
                addEvidence(observation)
            } else if current?.kind == .journey {
                addEvidence(observation)
                if current?.mode == .unknown { current?.mode = TrackingPolicy.mode(for: motion) }
            } else {
                close(at: time)
                start(.journey, at: time, observation: observation, mode: TrackingPolicy.mode(for: motion),
                      reason: "Location fixes indicate movement or an unconfirmed stop. The route joins recorded samples.")
            }
        }
        if let current { result.append(current) }
        return result
    }

    // Apply interval edits after inference. They never rewrite raw observations and later edits win.
    public static func applying(_ overrides: [UserOverride], to items: [TimelineItem]) -> [TimelineItem] {
        var result = items
        for edit in overrides.sorted(by: { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }) {
            var updated: [TimelineItem] = []
            for item in result {
                let end = item.end ?? .distantFuture
                guard item.start < edit.end && end > edit.start else { updated.append(item); continue }
                let lower = max(item.start, edit.start), upper = min(end, edit.end)
                if item.start < lower {
                    var before = item; before.end = lower; before.id += "-before-\(edit.id)"; updated.append(before)
                }
                var changed = item
                changed.id = "\(edit.id)-\(lower.timeIntervalSince1970)"
                changed.start = lower; changed.end = upper; changed.kind = edit.kind
                changed.placeID = edit.kind == .stay ? edit.placeID : nil
                changed.mode = edit.kind == .journey ? edit.mode : .unknown
                changed.isUserEdited = true; changed.reasons = ["You corrected this interval."]
                updated.append(changed)
                if upper < end {
                    var after = item; after.start = upper; after.id += "-after-\(edit.id)"; updated.append(after)
                }
            }
            result = updated
        }
        return result.sorted { $0.start < $1.start }
    }

    public static func onDay(_ day: Date, calendar: Calendar = .current, items: [TimelineItem]) -> [TimelineItem] {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return [] }
        return items.compactMap { item in
            guard item.start < interval.end, (item.end ?? .distantFuture) > interval.start else { return nil }
            var clipped = item
            clipped.start = max(item.start, interval.start)
            if let end = item.end { clipped.end = min(end, interval.end) }
            else if interval.end <= Date() { clipped.end = interval.end }
            return clipped
        }
    }
}
