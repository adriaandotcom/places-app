import Foundation

public struct PlaceLocality: Codable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable { case manual, apple }
    public var city: String
    public var country: String
    public var countryCode: String?
    public var source: Source
    public init(city: String = "", country: String = "", countryCode: String? = nil, source: Source = .manual) {
        self.city = city; self.country = country; self.countryCode = countryCode; self.source = source
    }
}

public struct HistoryPeriod: Identifiable, Hashable, Sendable {
    public let title: String
    public let interval: DateInterval
    public let isCountry: Bool
    public var id: String { "\(isCountry)-\(title)-\(interval.start.timeIntervalSince1970)" }
    public init(title: String, interval: DateInterval, isCountry: Bool = false) {
        self.title = title; self.interval = interval; self.isCountry = isCountry
    }

    /// Separate visits to the same region remain separate. Unnamed stops break a visit;
    /// journeys between stops in one region remain visible with their original certainty.
    public static func visits(items: [TimelineItem], places: [Place], now: Date = Date()) -> [HistoryPeriod] {
        let lookup = Dictionary(uniqueKeysWithValues: places.map { ($0.id, $0) })
        let stays = items.filter { $0.kind == .stay }.sorted { $0.start < $1.start }
        func visitsByRegion(country: Bool) -> [HistoryPeriod] {
            var result: [HistoryPeriod] = []
            var currentKey: String?
            for stay in stays {
                guard let id = stay.placeID, let region = lookup[id]?.locality else { currentKey = nil; continue }
                let name = (country ? region.country : region.city).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { currentKey = nil; continue }
                let key = "\(region.countryCode ?? region.country)|\(country ? "" : region.city)".lowercased()
                let end = min(stay.end ?? now, now)
                guard end > stay.start else { continue }
                if currentKey == key, let previous = result.popLast() {
                    result.append(HistoryPeriod(title: name, interval: DateInterval(start: previous.interval.start, end: end), isCountry: country))
                } else {
                    result.append(HistoryPeriod(title: name, interval: DateInterval(start: stay.start, end: end), isCountry: country))
                }
                currentKey = key
            }
            return result
        }
        let result = visitsByRegion(country: true) + visitsByRegion(country: false)
        return result.sorted { $0.interval.start == $1.interval.start ? $0.title < $1.title : $0.interval.start > $1.interval.start }
    }
}


public struct HistoryDay: Identifiable, Equatable, Sendable {
    public let date: Date
    public let placeCount: Int
    public var id: Date { date }

    public static func summarize(_ items: [TimelineItem], now: Date = Date(), calendar: Calendar = .current) -> [Self] {
        var places: [Date: Set<String>] = [:]
        for item in items where item.start <= now && (item.kind != .gap || item.isUserEdited) {
            let end = min(item.end ?? now, now)
            var day = calendar.startOfDay(for: item.start)
            while day <= end {
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                if item.start < next && (end > day || item.start == end && item.start == day) {
                    if places[day] == nil { places[day] = [] }
                    if item.kind == .stay { places[day, default: []].insert(item.placeID ?? item.id) }
                }
                day = next
            }
        }
        return places.keys.sorted().map { Self(date: $0, placeCount: places[$0]!.count) }
    }
}

public struct AdjacentPlaceSuggestion: Identifiable, Equatable, Sendable {
    public let placeID: String
    public let before: Bool
    public let after: Bool
    public var id: String { placeID }
    public var context: String { before && after ? "Before and after this interval" : before ? "Before this interval" : "After this interval" }

    public static func make(for item: TimelineItem, in items: [TimelineItem]) -> [Self] {
        let stays = items.filter { $0.kind == .stay && $0.placeID != nil && $0.id != item.id }
        let before = stays.filter { ($0.end ?? .distantFuture) <= item.start }.max { ($0.end ?? .distantFuture) < ($1.end ?? .distantFuture) }?.placeID
        let after = item.end.flatMap { end in stays.filter { $0.start >= end }.min { $0.start < $1.start }?.placeID }
        return [before, after].compactMap { $0 }.reduce(into: [Self]()) { result, id in
            if !result.contains(where: { $0.placeID == id }) && id != item.placeID {
                result.append(Self(placeID: id, before: id == before, after: id == after))
            }
        }
    }
}
