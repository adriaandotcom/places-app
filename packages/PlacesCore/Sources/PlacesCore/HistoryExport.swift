import Foundation

extension HistoryArchive {
    /// Partial exports keep only the selected evidence and its related records.
    /// Saved-place/person metadata and overlapping trip dates keep their meaning.
    func limited(to period: DateInterval?, includePhotos: Bool = true) -> HistoryArchive {
        func contains(_ date: Date) -> Bool { period.map { date >= $0.start && date < $0.end } ?? true }
        func overlaps(_ start: Date, _ end: Date?) -> Bool {
            period.map { start < $0.end && (end ?? .distantFuture) > $0.start } ?? true
        }
        let observations = observations.filter { contains($0.timestamp) }
        let observationIDs = Set(observations.map(\.id))
        func clip(_ item: TimelineItem) -> TimelineItem? {
            guard overlaps(item.start, item.end) else { return nil }
            guard let period else { return item }
            var copy = item
            copy.start = max(item.start, period.start)
            if let end = item.end { copy.end = min(end, period.end) }
            else { copy.end = period.end <= exportedAt ? period.end : nil }
            // Preserve the actual last-evidence time, including boundary context;
            // a clipped date is not a newly measured observation.
            copy.evidenceIDs = item.evidenceIDs.filter { observationIDs.contains($0) }
            copy.originalItems = item.originalItems?.compactMap(clip)
            // An endpoint outside the export is not part of the selected evidence.
            if let connection = copy.connection,
               !contains(connection.from.timestamp) || !contains(connection.to.timestamp) { copy.connection = nil }
            return copy
        }
        let timeline = timeline.compactMap(clip)
        let corrections = corrections.filter { overlaps($0.start, $0.end) }.map { value in
            guard let period else { return value }
            var copy = value; copy.start = max(copy.start, period.start); copy.end = min(copy.end, period.end)
            return copy
        }
        let photos = photoEvidence?.filter { contains($0.capturedAt) }
        let memoryPlaces = memories?.memories.compactMap(\.placeID) ?? []
        let placeIDs = Set(timeline.compactMap(\.placeID) + corrections.compactMap(\.placeID)
            + observations.compactMap(\.monitoredPlaceID) + memoryPlaces)
        let places = places.filter { period == nil || placeIDs.contains($0.id) }.map { value in
            var copy = value
            if !includePhotos { copy.photoJPEG = nil }
            return copy
        }
        let ssids = Set(observations.compactMap(\.ssid) + places.flatMap(\.expectedSSIDs))
        let networks = networks.filter { period == nil || ssids.contains($0.ssid) }
        let networkIDs = Set(networks.map(\.id))
        let bssids = Set(observations.compactMap(\.bssid))
        let points = accessPoints.filter {
            period == nil || (networkIDs.contains($0.networkID) && (bssids.contains($0.bssid) || $0.placeID.map(placeIDs.contains) == true))
        }
        return HistoryArchive(formatVersion: formatVersion, exportedAt: exportedAt,
            places: places, observations: observations, timeline: timeline, corrections: corrections,
            networks: networks, accessPoints: points, routePoints: routePoints.filter { contains($0.timestamp) },
            trackingEvents: trackingEvents.filter { contains($0.timestamp) }, separatedAt: separatedAt?.filter(contains),
            memories: memories, photoEvidence: photos, period: period, includesPhotos: includePhotos)
    }
}
