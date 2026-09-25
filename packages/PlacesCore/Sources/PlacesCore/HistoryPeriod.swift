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
