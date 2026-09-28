import Foundation
import GRDB

public struct PastVisitCandidate: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var city: String?
    public var coordinate: Coordinate?
    public var date: Date?
    public init(id: String, name: String, city: String? = nil, coordinate: Coordinate? = nil, date: Date? = nil) {
        self.id = id; self.name = name; self.city = city; self.coordinate = coordinate; self.date = date
    }
}

public struct PastVisitDraft: Identifiable, Equatable, Sendable {
    public var id: String { candidate.id }
    public var candidate: PastVisitCandidate
    public var selected = true
    public var name: String
    public var placeID: String?
    public var arrival: Date?
    public var departure: Date?
    public var replaceExisting = false
    public init(candidate: PastVisitCandidate, places: [Place], eventDate: DateInterval? = nil,
                fallbackDate: Date? = nil, now: Date = Date()) {
        self.candidate = candidate; name = candidate.name
        arrival = candidate.date ?? eventDate?.start ?? fallbackDate
        if let arrival {
            // An editable default, confirmed by the user before becoming a correction.
            // A suggestion's event end is useful only when it follows this arrival.
            departure = min(eventDate.map { $0.end > arrival ? $0.end : arrival.addingTimeInterval(3600) }
                ?? arrival.addingTimeInterval(3600), now)
        }
        // Suggest a saved place only when the location is unambiguous. The user can change it.
        if let coordinate = candidate.coordinate {
            let nearby = places.filter { $0.coordinate.distance(to: coordinate) <= min(50, $0.radius) }
            if nearby.count == 1 { placeID = nearby[0].id }
        }
    }
}

public struct PastVisitContext: Sendable {
    public var places: [Place]
    public var items: [TimelineItem]
    public var importedIDs: Set<String>
    public init(places: [Place], items: [TimelineItem], importedIDs: Set<String> = []) {
        self.places = places; self.items = items; self.importedIDs = importedIDs
    }
}

public struct PastVisitResolution: Identifiable, Equatable, Sendable {
    public var id: String
    public var place: Place?
    public var intervals: [DateInterval] = []
    public var conflicts: [TimelineItem] = []
    public var issue: String?
    public var alreadyAdded = false
}

public struct PastVisitPlan: Equatable, Sendable {
    public var visits: [PastVisitResolution]
    public var count: Int { visits.reduce(0) { $0 + $1.intervals.count } }
    public var canImport: Bool { count > 0 && visits.allSatisfy { $0.issue == nil } }

    public static func make(drafts: [PastVisitDraft], context: PastVisitContext, now: Date) -> Self {
        var visits: [PastVisitResolution] = []
        var places = context.places
        var selectedIDs: Set<String> = []
        for draft in drafts where draft.selected {
            var result = PastVisitResolution(id: draft.id)
            guard selectedIDs.insert(draft.id).inserted else { continue }
            if context.importedIDs.contains(draft.id) {
                result.alreadyAdded = true; visits.append(result); continue
            }
            guard let start = draft.arrival, let end = draft.departure,
                  start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite, end > start, end <= now else {
                result.issue = "Set an arrival and a later departure, both in the past."
                visits.append(result); continue
            }
            if let id = draft.placeID {
                result.place = places.first { $0.id == id }
            } else if let coordinate = draft.candidate.coordinate, coordinate.isValid,
                      !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                // Reuse the same place across several imported visits in this batch.
                result.place = places.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame && $0.coordinate.distance(to: coordinate) < 30 }
                    ?? Place(id: "journaling-place-" + draft.id, name: name, address: draft.candidate.city ?? "",
                             coordinate: coordinate, symbol: PlaceIconMatcher.suggestedSymbol(name: name) ?? "mappin", createdAt: now)
            }
            guard let place = result.place else {
                result.issue = "Choose a saved place, or give a location from Apple a name."
                visits.append(result); continue
            }
            let interval = DateInterval(start: start, end: end)
            result.conflicts = context.items.filter {
                ($0.kind != .gap || $0.isUserEdited) && $0.start < end && ($0.end ?? now) > start
            }
            var intervals = [interval]
            if !draft.replaceExisting {
                for item in result.conflicts {
                    intervals = intervals.flatMap { subtract(DateInterval(start: item.start, end: max(item.start, item.end ?? now)), from: $0) }
                }
            }
            // Two selected imports must not silently replace one another, even in replace mode.
            let earlier = visits.flatMap(\.intervals)
            if intervals.contains(where: { interval in earlier.contains { $0.start < interval.end && $0.end > interval.start } }) {
                result.issue = "These times overlap another selected visit. Adjust the times or deselect one."
            } else { result.intervals = intervals }
            if !places.contains(where: { $0.id == place.id }) { places.append(place) }
            visits.append(result)
        }
        return Self(visits: visits)
    }

    private static func subtract(_ occupied: DateInterval, from interval: DateInterval) -> [DateInterval] {
        guard occupied.start < interval.end && occupied.end > interval.start else { return [interval] }
        var remaining: [DateInterval] = []
        if interval.start < occupied.start { remaining.append(DateInterval(start: interval.start, end: occupied.start)) }
        if occupied.end < interval.end { remaining.append(DateInterval(start: occupied.end, end: interval.end)) }
        return remaining
    }
}

public struct PastVisitMemory: Sendable {
    public let visitID: String
    public let suggestionID: String
    public let photos: [MemoryPhotoFile]
    public init(visitID: String, suggestionID: String, photos: [MemoryPhotoFile]) {
        self.visitID = visitID; self.suggestionID = suggestionID; self.photos = photos
    }
}

public enum PastVisitImportError: Error { case invalidSelection, timelineChanged }

extension PlacesStore {
    public func pastVisitContext() throws -> PastVisitContext {
        try queue.read { try StoreSQL.pastVisitContext(db: $0) }
    }

    /// Check overlaps again and commit the entire reviewed batch in one transaction.
    public func importPastVisits(_ drafts: [PastVisitDraft], reviewed: PastVisitPlan, now: Date, memory: PastVisitMemory? = nil) throws {
        try queue.write { db in
            let context = try StoreSQL.pastVisitContext(db: db)
            let current = PastVisitPlan.make(drafts: drafts, context: context, now: now)
            guard current == reviewed else { throw PastVisitImportError.timelineChanged }
            guard current.canImport else { throw PastVisitImportError.invalidSelection }
            if let memory {
                guard !memory.photos.isEmpty,
                      current.visits.contains(where: { $0.id == memory.visitID && !$0.intervals.isEmpty })
                else { throw PastVisitImportError.invalidSelection }
            }
            var saved = Set(context.places.map(\.id))
            for visit in current.visits where !visit.intervals.isEmpty {
                guard let place = visit.place else { throw PastVisitImportError.invalidSelection }
                if saved.insert(place.id).inserted { try StoreSQL.savePlace(place, db: db) }
                for (index, interval) in visit.intervals.enumerated() {
                    try StoreSQL.saveCorrection(UserOverride(id: "journaling-\(visit.id)-\(index)",
                        start: interval.start, end: interval.end, kind: .stay, placeID: place.id,
                        importedVisitID: visit.id), db: db)
                }
                if let memory, memory.visitID == visit.id, let start = visit.intervals.first?.start {
                    let imported = PlaceMemory(id: PlaceMemory.suggestionID(memory.suggestionID, placeID: place.id),
                        date: start, placeID: place.id, visitStart: start, photoIDs: memory.photos.map(\.id))
                    // Reopening a suggestion must never overwrite an already edited memory.
                    if try !Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM memories WHERE id = ?)", arguments: [imported.id])! {
                        try MemorySQL.saveMemoryWithPhotos(imported, importing: memory.photos, db: db)
                    }
                }
            }
        }
    }
}

extension StoreSQL {
    static func pastVisitContext(db: Database) throws -> PastVisitContext {
        let items = try decodeAll(TimelineItem.self, db: db, sql: "SELECT payload FROM timeline ORDER BY start")
        let edits = try decodeAll(UserOverride.self, db: db, sql: "SELECT payload FROM overrides ORDER BY createdAt")
        return PastVisitContext(places: try decodeAll(Place.self, db: db, sql: "SELECT payload FROM places ORDER BY name COLLATE NOCASE"),
            items: InferenceEngine.applying(edits, to: items), importedIDs: Set(edits.compactMap(\.importedVisitID)))
    }
}
