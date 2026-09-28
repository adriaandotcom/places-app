import Foundation

/// A view of corrected history, never additional location inference.
public struct MonthlyRewind: Sendable {
    public struct FrequentPlace: Identifiable, Sendable {
        public let place: Place
        public let days: Int
        public var id: String { place.id }
    }
    public let interval: DateInterval
    public let recordedDays: Int
    public let places: [FrequentPlace]
    public let cities: [String]
    public let countries: [String]
    public let journeys: [TransportMode: TimeInterval]
    public let trips: [Trip]
    public let people: [MemoryPerson]
    public let memories: [PlaceMemory]
    public let photoIDs: [String]
    public let reviewItems: [TimelineItem]
    public var hasHighlights: Bool { recordedDays > 0 || !memories.isEmpty || !trips.isEmpty }

    public init(month: Date, items: [TimelineItem], places: [Place], library: MemoryLibrary,
                now: Date = Date(), calendar: Calendar = .current) {
        let interval = calendar.dateInterval(of: .month, for: month)!
        self.interval = interval
        let upper = min(interval.end, now)
        let bounded = items.map { item in
            var item = item
            if item.end == nil && !item.isUserEdited { item.end = max(item.start, item.lastEvidenceAt) }
            return item
        }
        let clipped = upper > interval.start ? InferenceEngine.within(DateInterval(start: interval.start, end: upper), items: bounded) : []
        let lookup = Dictionary(uniqueKeysWithValues: places.map { ($0.id, $0) })
        var recorded: Set<Date> = []
        var placeDays: [String: Set<Date>] = [:]
        var travel: [TransportMode: TimeInterval] = [:]
        for item in clipped {
            let end = min(item.end ?? now, upper)
            guard end > item.start, item.kind != .gap else { continue }
            // A presented stay can include unknown spans. Only its known pieces
            // contribute days; grouping must not manufacture recorded coverage.
            let pieces = item.originalItems ?? [item]
            for piece in pieces where piece.kind != .gap {
                let start = max(item.start, piece.start)
                let supportedEnd = piece.end ?? (piece.isUserEdited ? now : piece.lastEvidenceAt)
                let pieceEnd = min(end, supportedEnd)
                guard pieceEnd > start else { continue }
                var day = calendar.startOfDay(for: start)
                while day < pieceEnd {
                    recorded.insert(day)
                    if item.kind == .stay, let id = item.placeID, lookup[id] != nil {
                        placeDays[id, default: []].insert(day)
                    }
                    guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
                    day = next
                }
            }
            if item.kind == .journey, item.mode != .unknown {
                let supportedEnd = end
                let duration = max(0, supportedEnd.timeIntervalSince(item.start))
                if duration > 0 { travel[item.mode, default: 0] += duration }
            }
        }
        recordedDays = recorded.count
        self.places = placeDays.map { FrequentPlace(place: lookup[$0.key]!, days: $0.value.count) }
            .sorted { $0.days == $1.days ? $0.id < $1.id : $0.days > $1.days }
        func unique(_ values: [String]) -> [String] {
            var seen: Set<String> = []
            return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }.sorted()
        }
        cities = unique(self.places.compactMap { $0.place.locality?.city })
        countries = unique(self.places.compactMap { $0.place.locality?.country })
        journeys = travel
        let monthMemories = library.memories.filter { $0.date >= interval.start && $0.date < upper }.sorted { $0.date < $1.date }
        memories = monthMemories
        trips = library.trips.filter { trip in
            upper > interval.start && !trip.hidden && trip.start < upper && (trip.end ?? now) > interval.start &&
                (trip.automaticAnchor == nil || !recorded.isEmpty || monthMemories.contains { $0.tripID == trip.id })
        }.sorted { $0.start < $1.start }
        let ids = Set(trips.flatMap(\.personIDs) + memories.flatMap(\.linkedPersonIDs))
        people = library.people.filter { ids.contains($0.id) }.sorted { $0.name < $1.name }
        var seenPhotos: Set<String> = []
        photoIDs = memories.flatMap(\.orderedPhotoIDs).filter { seenPhotos.insert($0).inserted }
        reviewItems = TimelineReview.items(in: clipped, places: places, now: now)
    }
}

public enum TimelineReview {
    public static func items(in items: [TimelineItem], places: [Place], now: Date = Date()) -> [TimelineItem] {
        let ids = Set(places.map(\.id))
        return items.filter { item in
            // Deliberately unknown intervals are already reviewed. Journeys with
            // an unknown transport mode are not missing places.
            guard !item.isUserEdited else { return false }
            if item.kind == .stay { return item.placeID.map { !ids.contains($0) } ?? true }
            return item.kind == .gap && item.duration(until: now) >= 15 * 60
        }.sorted { $0.start < $1.start }
    }
}

/// One upcoming request per type, recomputed when local history changes.
/// No repeating notification can nag about a week we have never inspected.
public struct RewindReminder: Equatable, Sendable {
    public enum Kind: String, Sendable { case monthly, weekly }
    public let kind: Kind
    public let fireAt: Date
    public let periodStart: Date

    public static func plan(now: Date, calendar: Calendar = .current, monthly: Bool, weekly: Bool,
                            recordedMonths: Set<Date>, missingPlaces: [TimelineItem]) -> [Self] {
        var result: [Self] = []
        let month = calendar.dateInterval(of: .month, for: now)!
        if monthly {
            // At 18:00 on the first, the entire previous month is available.
            let thisFirst = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: month.start)!
            let previous = calendar.date(byAdding: .month, value: -1, to: month.start)!
            if thisFirst > now && recordedMonths.contains(previous) {
                result.append(Self(kind: .monthly, fireAt: thisFirst, periodStart: previous))
            } else if recordedMonths.contains(month.start) {
                let nextFirst = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: month.end)!
                result.append(Self(kind: .monthly, fireAt: nextFirst, periodStart: month.start))
            }
        }
        if weekly, let sunday = calendar.nextDate(after: now, matching: DateComponents(hour: 18, minute: 0, weekday: 1), matchingPolicy: .nextTime),
           let from = calendar.date(byAdding: .day, value: -7, to: sunday),
           missingPlaces.contains(where: { $0.kind == .stay && !$0.isUserEdited && min($0.end ?? $0.lastEvidenceAt, $0.lastEvidenceAt) > from && $0.start < now.addingTimeInterval(-30 * 60) }) {
            // A monthly invitation already includes review; don't send two nudges that evening.
            if !result.contains(where: { abs($0.fireAt.timeIntervalSince(sunday)) < 24 * 3600 }) {
                result.append(Self(kind: .weekly, fireAt: sunday, periodStart: from))
            }
        }
        return result
    }
}

extension PlacesStore {
    public func monthlyRewind(for month: Date, now: Date = Date(), calendar: Calendar = .current) throws -> MonthlyRewind {
        let interval = calendar.dateInterval(of: .month, for: month)!
        return try MonthlyRewind(month: month, items: timeline(in: interval, throughLastEvidence: true), places: places(),
                                 library: memoryLibrary(now: now), now: now, calendar: calendar)
    }
}
