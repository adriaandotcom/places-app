import Foundation

public enum InferenceEngine {
    public static func infer(observations: [SensorObservation], places: [Place], networks: [WiFiNetwork] = [],
                             accessPoints: [WiFiAccessPoint] = []) -> [TimelineItem] {
        let sorted = CompanionEvidence.selected(observations, places: places, networks: networks, accessPoints: accessPoints)
        // Older observations stored the two CLVisit boundaries separately.
        var arrivals: [String: SensorObservation] = [:]
        var reportedDurations: [String: TimeInterval] = [:]
        for observation in sorted where observation.source == .visitArrival || observation.source == .visitDeparture {
            guard let coordinate = observation.usableCoordinate else { continue }
            let key = "\(observation.companionDeviceID ?? "iphone")-\(coordinate.latitude)-\(coordinate.longitude)"
            if observation.source == .visitArrival { arrivals[key] = observation }
            else if let arrival = arrivals.removeValue(forKey: key) {
                reportedDurations[arrival.id] = observation.timestamp.timeIntervalSince(arrival.timestamp)
            }
        }
        var result: [TimelineItem] = []
        var current: TimelineItem?
        var stationaryAnchor: SensorObservation?
        var departureCandidate: SensorObservation?
        var stationaryEvidence: [SensorObservation] = []
        var latestMotion: MotionKind = .unknown
        var motionTime = Date.distantPast
        var activeDevice: String?
        var confirmation = VisitConfirmation()

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
                                   lastEvidenceAt: time, coordinate: observation.usableCoordinate ?? place?.coordinate)
        }
        func addEvidence(_ observation: SensorObservation) {
            guard current != nil else { return }
            let lastEvidenceAt = max(current!.lastEvidenceAt, observation.timestamp)
            current?.lastEvidenceAt = lastEvidenceAt
            if current?.evidenceIDs.contains(observation.id) == false { current?.evidenceIDs.append(observation.id) }
        }

        let aliases = places.reduce(into: [String: String]()) { result, place in
            for id in place.mergedPlaceIDs ?? [] { result[id] = place.id }
        }
        for var observation in sorted {
            // Resolve a merged region ID in memory; never rewrite raw evidence.
            if let id = observation.monitoredPlaceID, let target = aliases[id] { observation.monitoredPlaceID = target }
            let time = observation.timestamp
            let wifiPlace = TrackingPolicy.connectedPlace(for: observation, places: places, networks: networks, accessPoints: accessPoints)
            let device = observation.companionDevice.map { $0.rawValue + ":" + (observation.companionDeviceID ?? "") } ?? "iphone"
            if observation.usableCoordinate != nil || wifiPlace != nil {
                if let previous = activeDevice, previous != device {
                    // Locations from different physical devices cannot establish a connecting route.
                    if let item = current {
                        let boundary = item.lastEvidenceAt
                        close(at: boundary)
                        start(.gap, at: boundary, observation: observation,
                              reason: "The evidence changes device; no route establishes this interval.")
                    }
                    stationaryAnchor = nil; departureCandidate = nil; stationaryEvidence = []; confirmation.reset()
                    latestMotion = .unknown; motionTime = .distantPast
                }
                activeDevice = device
            }
            // Phone motion does not describe a Mac or Watch location.
            if observation.usableCoordinate == nil && wifiPlace == nil && observation.companionDevice == nil,
               activeDevice != nil && activeDevice != "iphone" { continue }
            if let motion = observation.motion { latestMotion = motion; motionTime = time; confirmation.motionChanged(motion) }
            let motion = time.timeIntervalSince(motionTime) <= 300 ? latestMotion : .unknown

            if [.recovery, .paused, .resumed].contains(observation.source) {
                if let item = current, item.kind != .gap {
                    let boundary = observation.source == .paused ? time : item.lastEvidenceAt
                    close(at: boundary)
                    start(.gap, at: boundary, observation: observation, reason: "No observations establish this interval.")
                } else if current == nil {
                    start(.gap, at: time, observation: observation, reason: "Waiting for location evidence.")
                }
                stationaryAnchor = nil; departureCandidate = nil; stationaryEvidence = []; confirmation.reset()
                continue
            }

            if observation.source == .regionExit || observation.source == .visitDeparture {
                if observation.source == .regionExit,
                   places.contains(where: { $0.id == observation.monitoredPlaceID && $0.area != nil }) {
                    // A historical circular boundary is not a polygon departure.
                    continue
                }
                if observation.source == .regionExit, let item = current, item.kind == .stay,
                   item.placeID != observation.monitoredPlaceID {
                    // Nearby or overlapping monitored regions are not proof of leaving this stay.
                    continue
                }
                if current?.kind == .journey { addEvidence(observation); continue }
                close(at: time)
                start(.journey, at: time, observation: observation, mode: TrackingPolicy.mode(for: motion),
                      reason: "A departure was observed; the route is recorded only where fixes are available.")
                stationaryAnchor = nil; departureCandidate = nil; stationaryEvidence = []; confirmation.reset()
                continue
            }

            guard observation.usableCoordinate != nil || wifiPlace != nil else { continue }

            if let item = current, item.kind == .stay, item.placeID == nil,
               time.timeIntervalSince(item.lastEvidenceAt) > TrackingPolicy.evidenceGap,
               let anchor = stationaryAnchor, !TrackingPolicy.sameStationaryArea(anchor, observation) {
                // A fix somewhere else after a long silence cannot establish when
                // the unnamed stop ended. Retain the unrecorded interval as a gap.
                let boundary = item.lastEvidenceAt
                close(at: boundary)
                start(.gap, at: boundary, observation: observation, reason: "No observations establish this interval.")
                stationaryAnchor = nil; departureCandidate = nil; stationaryEvidence = []; confirmation.reset()
            }

            if let item = current, item.kind != .stay,
               time.timeIntervalSince(item.lastEvidenceAt) > TrackingPolicy.evidenceGap {
                // Keep one gap open while the next fix is still unconfirmed.
                // Closing it here and starting another gap from the same fix
                // would reuse its identifier and make persistence fail.
                if item.kind == .journey {
                    let boundary = item.lastEvidenceAt
                    close(at: boundary)
                    start(.gap, at: boundary, observation: observation, reason: "No observations establish this interval.")
                }
                stationaryAnchor = nil; departureCandidate = nil; stationaryEvidence = []; confirmation.reset()
            }

            let place = wifiPlace ?? TrackingPolicy.matchingPlace(for: observation, places: places)
            let wifiReason = "Connected to an access point previously learned at this place."

            let drivingOrCycling = [.cycling, .automotive].contains(motion)
            if let place, current?.kind == .stay, current?.placeID == place.id, !drivingOrCycling {
                addEvidence(observation)
                if wifiPlace != nil, current?.reasons.contains(wifiReason) == false { current?.reasons.append(wifiReason) }
                continue
            }

            if current?.kind == .stay, current?.placeID == nil, place == nil, !drivingOrCycling,
               let anchor = stationaryAnchor, TrackingPolicy.sameStationaryArea(anchor, observation) {
                addEvidence(observation)
                continue
            }
            let confirmed = confirmation.observe(observation, place: place, connectedPlace: wifiPlace, motion: motion)
            let reportedVisit = observation.source == .visitArrival
                && max(observation.systemVisitDuration ?? 0, reportedDurations[observation.id] ?? 0) >= TrackingPolicy.stationaryDuration
            if reportedVisit || confirmed != nil {
                let first = confirmed?.first ?? observation
                let boundary = max(current?.start ?? first.timestamp, first.timestamp)
                close(at: boundary)
                start(.stay, at: boundary, observation: first, place: place,
                    mode: confirmed?.walking == true ? .walking : .unknown,
                    reason: reportedVisit ? "iOS reported a visit lasting at least three minutes."
                        : confirmed?.walking == true ? "Walking inside this place for at least three minutes. The walking route is retained."
                        : "Fresh observations support at least three minutes with little movement.")
                current?.evidenceIDs = confirmed?.evidenceIDs ?? [observation.id]
                addEvidence(observation)
                stationaryAnchor = first; stationaryEvidence = [first]; departureCandidate = nil
                confirmation.reset()
                continue
            }
            guard let coordinate = observation.usableCoordinate else {
                // Fresh connected-network evidence advances confirmation even when
                // GPS is unavailable; it cannot establish a measured route.
                if current == nil {
                    start(.gap, at: time, observation: observation, reason: "Waiting for enough evidence to confirm a stop.")
                } else {
                    addEvidence(observation)
                }
                continue
            }

            if current == nil,
               VisitConfirmation.isMoving(motion) || (observation.speed ?? -1) >= 0.8 {
                close(at: time)
                start(.journey, at: time, observation: observation, mode: TrackingPolicy.mode(for: motion),
                      reason: "Movement evidence supports travel; nearby places do not establish a stop.")
                stationaryAnchor = observation; stationaryEvidence = [observation]; departureCandidate = nil
                continue
            }

            if current?.kind == .stay, drivingOrCycling, (observation.speed ?? 0) >= 0.8 {
                close(at: time)
                start(.journey, at: time, observation: observation, mode: TrackingPolicy.mode(for: motion),
                      reason: "Cycling or driving continues through this place.")
                stationaryAnchor = observation; stationaryEvidence = [observation]; departureCandidate = nil
                continue
            }

            if let item = current, item.kind == .stay, item.placeID != nil,
               let previous = item.coordinate, previous.distance(to: coordinate) > 250,
               observation.speed.map({ $0 >= 0.8 }) == true || [.walking, .running, .cycling, .automotive].contains(motion) {
                close(at: time)
                start(.journey, at: time, observation: observation, mode: TrackingPolicy.mode(for: motion),
                      reason: "Location and movement evidence establish departure from the saved place.")
                stationaryAnchor = observation; stationaryEvidence = [observation]; departureCandidate = nil
                continue
            }

            // Lack of speed or motion is not evidence of travel. In particular,
            // connected Wi-Fi samples must not reset a stop or create a journey.
            if stationaryAnchor == nil {
                stationaryAnchor = observation
                stationaryEvidence = [observation]
            }
            let anchor = stationaryAnchor!
            let inSameArea = TrackingPolicy.sameStationaryArea(anchor, observation)
            if inSameArea {
                departureCandidate = nil
                stationaryEvidence.append(observation)
                if current?.kind == .stay {
                    addEvidence(observation)
                } else if current?.kind == .journey {
                    addEvidence(observation)
                } else if current?.kind == .gap {
                    addEvidence(observation)
                } else {
                    close(at: time)
                    start(.gap, at: time, observation: observation,
                          reason: "Waiting for enough locations to distinguish a stop from travel.")
                }
            } else {
                // Ignore a lone drifting fix. Require a second displaced sample,
                // or a clear displacement with independent movement evidence.
                let distance = anchor.usableCoordinate!.distance(to: coordinate)
                let strongMovement = distance > 250 && (observation.speed.map { $0 >= 0.8 } == true
                    || [.walking, .running, .cycling, .automotive].contains(motion))
                let repeatedDeparture = departureCandidate.map {
                    (observation.coordinateTimestamp ?? time).timeIntervalSince($0.coordinateTimestamp ?? $0.timestamp) >= 15
                        && !TrackingPolicy.sameStationaryArea(anchor, $0)
                } ?? false
                if current?.kind == .journey || strongMovement || repeatedDeparture {
                    let departure = departureCandidate ?? observation
                    if current?.kind != .journey {
                        close(at: departure.timestamp)
                        start(.journey, at: departure.timestamp, observation: departure,
                              mode: TrackingPolicy.mode(for: motion), reason: "Successive locations establish movement beyond the stop’s accuracy range.")
                    }
                    addEvidence(observation)
                    if current?.mode == .unknown { current?.mode = TrackingPolicy.mode(for: motion) }
                    stationaryAnchor = observation; stationaryEvidence = [observation]; departureCandidate = nil
                } else {
                    if departureCandidate == nil { departureCandidate = observation }
                }
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
                if edit.kind == .stay, let coordinate = edit.coordinate { changed.coordinate = coordinate }
                changed.mode = edit.kind == .journey ? edit.mode : .unknown
                changed.isUserEdited = true; changed.reasons = ["You corrected this interval."]
                if edit.importedVisitID == nil { updated.append(changed) }
                if upper < end {
                    var after = item; after.start = upper; after.id += "-after-\(edit.id)"; updated.append(after)
                }
            }
            if edit.importedVisitID != nil {
                updated.append(TimelineItem(id: edit.id, kind: .stay, start: edit.start, end: edit.end,
                    placeID: edit.placeID, reasons: ["Added from Apple Journaling Suggestions. Times confirmed by you."],
                    isUserEdited: true, lastEvidenceAt: edit.start, coordinate: edit.coordinate))
            }
            result = updated
        }
        return result.sorted { $0.start < $1.start }
    }

    public static func onDay(_ day: Date, calendar: Calendar = .current, items: [TimelineItem]) -> [TimelineItem] {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return [] }
        return within(interval, items: items)
    }

    public static func within(_ interval: DateInterval, items: [TimelineItem], now: Date = Date()) -> [TimelineItem] {
        return items.compactMap { item in
            guard item.start < interval.end, (item.end ?? .distantFuture) > interval.start else { return nil }
            var clipped = item
            clipped.start = max(item.start, interval.start)
            if let end = item.end { clipped.end = min(end, interval.end) }
            else if interval.end <= now { clipped.end = interval.end }
            return clipped
        }
    }
}
