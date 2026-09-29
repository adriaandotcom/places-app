import Foundation

public enum PlaceTripRole: String, Codable, CaseIterable, Sendable {
    case automatic, home, lodging, regular
    public var title: String {
        switch self { case .automatic: "Automatic"; case .home: "Home"; case .lodging: "Lodging"; case .regular: "Regular place" }
    }
    public var explanation: String {
        switch self {
        case .automatic: "Uses the place icon and overnight stays away from home to find trips."
        case .home: "Stays here count as home and help mark the beginning and end of trips."
        case .lodging: "Overnight stays here can start a trip, even when you are close to home."
        case .regular: "Stays here won’t start an automatic trip. Useful for work and other regular stops."
        }
    }

}

extension Place {
    public var resolvedTripRole: PlaceTripRole {
        if let tripRole, tripRole != .automatic { return tripRole }
        if ["house", "house.fill"].contains(symbol) { return .home }
        if ["bed.double", "bed.double.fill", "building.2.crop.circle"].contains(symbol) { return .lodging }
        return .automatic
    }
}

public struct Trip: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date?
    public var personIDs: [String]
    public var automaticAnchor: Date?
    public var datesEdited: Bool
    public var titleEdited: Bool
    public var hidden: Bool
    public init(id: String = UUID().uuidString, title: String, start: Date, end: Date? = nil,
                personIDs: [String] = [], automaticAnchor: Date? = nil,
                datesEdited: Bool = false, titleEdited: Bool = false, hidden: Bool = false) {
        self.id = id; self.title = title; self.start = start; self.end = end; self.personIDs = personIDs
        self.automaticAnchor = automaticAnchor; self.datesEdited = datesEdited; self.titleEdited = titleEdited; self.hidden = hidden
    }
    public func contains(_ date: Date, now: Date = Date()) -> Bool { date >= start && date < (end ?? now) }
    public func interval(now: Date = Date()) -> DateInterval { DateInterval(start: start, end: max(start, end ?? now)) }
}

public struct MemoryPerson: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var detail: String
    public var colorIndex: Int?
    public var avatarJPEG: Data?
    public var mentions: [PersonMention]?
    public var resolvedColorIndex: Int { colorIndex ?? id.utf8.reduce(0) { ($0 + Int($1)) % 6 } }
    public var initials: String { name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first).map(String.init).joined().uppercased() }
    public init(id: String = UUID().uuidString, name: String, detail: String = "", colorIndex: Int = Int.random(in: 0..<6), avatarJPEG: Data? = nil, mentions: [PersonMention]? = nil) {
        self.id = id; self.name = name; self.detail = detail; self.colorIndex = colorIndex
        self.avatarJPEG = avatarJPEG; self.mentions = mentions
    }
}

/// A visit uses a time anchor, never a derived timeline ID that can change after re-inference.
/// General place notes have no visitStart and do not leak into unrelated trips.
public struct PlaceMemory: Codable, Identifiable, Hashable, Sendable {
    public static func suggestionID(_ suggestionID: String, placeID: String) -> String {
        "suggestion-\(suggestionID)-\(placeID)"
    }

    public var id: String
    public var text: String
    public var date: Date
    public var tripID: String?
    public var placeID: String?
    public var visitStart: Date?
    public var personIDs: [String]
    public var photoIDs: [String]
    public var photoDetails: [String: MemoryPhotoDetails]?
    public var photosManuallyOrdered: Bool?
    public var orderedPhotoIDs: [String] {
        guard photosManuallyOrdered != true else { return photoIDs }
        return photoIDs.enumerated().sorted { left, right in
            let a = photoDetails?[left.element]?.createdAt ?? .distantFuture
            let b = photoDetails?[right.element]?.createdAt ?? .distantFuture
            return a == b ? left.offset < right.offset : a < b
        }.map(\.element)
    }
    public var mentions: [PersonMention]?
    public var linkedPersonIDs: [String] { Array(Set(personIDs + (mentions ?? []).map(\.personID))).sorted() }
    public init(id: String = UUID().uuidString, text: String = "", date: Date = Date(), tripID: String? = nil,
                placeID: String? = nil, visitStart: Date? = nil, personIDs: [String] = [], photoIDs: [String] = [], mentions: [PersonMention]? = nil) {
        self.id = id; self.text = text; self.date = date; self.tripID = tripID; self.placeID = placeID
        self.visitStart = visitStart; self.personIDs = personIDs; self.photoIDs = photoIDs
        self.mentions = mentions
    }
    public func belongs(to trip: Trip, now: Date = Date()) -> Bool {
        if let tripID { return tripID == trip.id }
        return visitStart.map { trip.contains($0, now: now) } ?? false
    }
    public func belongs(to visit: TimelineItem, now: Date = Date()) -> Bool {
        guard tripID == nil, let visitStart else { return false }
        return visitStart >= visit.start && visitStart < (visit.end ?? now)
    }
}

/// Only selected photos' creation time and coordinates are retained, inside the
/// protected memory payload. Re-encoded image files contain no embedded metadata.
public struct MemoryPhotoDetails: Codable, Hashable, Sendable {
    public var createdAt: Date?
    public var utcOffsetSeconds: Int?
    public var coordinate: Coordinate?
    public var caption: String
    public init(createdAt: Date? = nil, utcOffsetSeconds: Int? = nil, coordinate: Coordinate? = nil, caption: String = "") {
        self.createdAt = createdAt; self.utcOffsetSeconds = utcOffsetSeconds
        self.coordinate = coordinate; self.caption = caption
    }
}

public struct MemoryPhoto: Codable, Identifiable, Sendable {
    public var id: String
    public var jpeg: Data
    public var thumbnail: Data
    public var details: MemoryPhotoDetails?
    public init(id: String = UUID().uuidString, jpeg: Data, thumbnail: Data, details: MemoryPhotoDetails? = nil) {
        self.id = id; self.jpeg = jpeg; self.thumbnail = thumbnail
        self.details = details
    }
}
/// Temporary, protected files let a large selection commit without holding every JPEG in RAM.
public struct MemoryPhotoFile: Identifiable, Sendable {
    public let id: String
    public let jpegURL: URL
    public let thumbnailURL: URL
    public let details: MemoryPhotoDetails?
    public init(id: String, jpegURL: URL, thumbnailURL: URL, details: MemoryPhotoDetails? = nil) {
        self.id = id; self.jpegURL = jpegURL; self.thumbnailURL = thumbnailURL
        self.details = details
    }
}
public struct MemoryArchive: Codable, Sendable {
    public let trips: [Trip]
    public let people: [MemoryPerson]
    public let memories: [PlaceMemory]
    public let photos: [MemoryPhoto]
}
public struct MemoryLibrary: Sendable {
    public var trips: [Trip] = []
    public var people: [MemoryPerson] = []
    public var memories: [PlaceMemory] = []
    public init() {}
    /// Only photos already added to shared trips or explicitly linked memories, newest first.
    public func avatarPhotoIDs(for personID: String, now: Date = Date()) -> [String] {
        let shared = trips.filter { !$0.hidden && $0.personIDs.contains(personID) }
        var seen: Set<String> = []
        return memories.filter { memory in
            memory.linkedPersonIDs.contains(personID) || shared.contains { memory.belongs(to: $0, now: now) }
        }.sorted { $0.date > $1.date }.flatMap(\.photoIDs).filter { seen.insert($0).inserted }
    }
}
public enum MemoryError: Error, LocalizedError {
    case invalidTrip, invalidPerson, invalidMemory, invalidPhoto
    public var errorDescription: String? {
        switch self {
        case .invalidTrip: "Give the trip a name and an end after its start."
        case .invalidPerson: "Give this person a name."
        case .invalidMemory: "Add a note, person, or photo to this memory."
        case .invalidPhoto: "This photo couldn’t be saved. Try choosing it again."
        }
    }
}

/// Groups history for browsing only. It never writes visits, fills gaps or invents routes.
public enum TripDetection {
    public static func detect(items: [TimelineItem], places: [Place], timeZones: [String: String] = [:],
                              now: Date = Date()) -> [Trip] {
        let placesByID = Dictionary(uniqueKeysWithValues: places.map { ($0.id, $0) })
        let homes = places.filter { $0.resolvedTripRole == .home }
        let sorted = items.filter { $0.start <= now }.sorted { $0.start < $1.start }
        // Gaps between two stays at the same place can suggest an overnight trip,
        // without claiming the intervening time was recorded at that place.
        var stays: [TimelineItem] = []
        var canJoin = false
        for item in sorted {
            if item.kind == .gap { continue }
            guard item.kind == .stay, item.placeID != nil || item.coordinate != nil else { canJoin = false; continue }
            if canJoin, let last = stays.last, samePlace(last, item),
               item.start.timeIntervalSince(last.lastEvidenceAt) <= 14 * 3600 {
                stays[stays.count - 1].end = item.end
                stays[stays.count - 1].lastEvidenceAt = max(last.lastEvidenceAt, item.lastEvidenceAt)
            } else { stays.append(item) }
            canJoin = true
        }
        func isHome(_ item: TimelineItem) -> Bool { item.placeID.flatMap { placesByID[$0] }?.resolvedTripRole == .home }
        func recordedEnd(_ item: TimelineItem) -> Date { min(now, item.isUserEdited ? (item.end ?? item.lastEvidenceAt) : item.lastEvidenceAt) }
        let nights = stays.filter { item in
            let place = item.placeID.flatMap { placesByID[$0] }
            guard place?.resolvedTripRole != .home, place?.resolvedTripRole != .regular,
                  let coordinate = place?.coordinate ?? item.coordinate else { return false }
            let away = !homes.isEmpty && homes.allSatisfy { $0.coordinate.distance(to: coordinate) >= 50_000 }
            guard place?.resolvedTripRole == .lodging || away else { return false }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: timeZones[item.id] ?? "") ?? .current
            let end = recordedEnd(item)
            guard end > item.start else { return false }
            var day = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: item.start))!
            while day < end {
                let nightStart = calendar.date(bySettingHour: 22, minute: 0, second: 0, of: day)!
                let morning = calendar.date(bySettingHour: 8, minute: 0, second: 0,
                    of: calendar.date(byAdding: .day, value: 1, to: day)!)!
                if min(end, morning).timeIntervalSince(max(item.start, nightStart)) >= 3 * 3600 { return true }
                day = calendar.date(byAdding: .day, value: 1, to: day)!
            }
            return false
        }
        var groups: [[TimelineItem]] = []
        for night in nights {
            if let previous = groups.last?.last,
               night.start.timeIntervalSince(recordedEnd(previous)) <= 48 * 3600,
               !stays.contains(where: { isHome($0) && $0.start > previous.start && $0.start < night.start }) {
                groups[groups.count - 1].append(night)
            } else { groups.append([night]) }
        }
        return groups.compactMap { group in
            guard let first = group.first, let last = group.last else { return nil }
            let base = first.placeID.flatMap { placesByID[$0] }
            let departure = stays.last { isHome($0) && $0.start < first.start && first.start.timeIntervalSince(recordedEnd($0)) <= 48 * 3600 }
            let start = departure.map { min(first.start, $0.end ?? $0.lastEvidenceAt) } ?? first.start
            let home = stays.first { isHome($0) && $0.start > last.start }
            let nextNight = nights.first { $0.start > last.start }
            let bound = min(home?.start ?? .distantFuture, nextNight?.start ?? .distantFuture)
            var latest = recordedEnd(last)
            for item in sorted where item.start >= last.start && item.start < bound && item.kind != .gap {
                guard item.start.timeIntervalSince(latest) <= 48 * 3600 else { break }
                latest = max(latest, recordedEnd(item))
            }
            let returnHome = home.flatMap { item in
                item.start < (nextNight?.start ?? .distantFuture) && item.start.timeIntervalSince(latest) <= 48 * 3600 ? item.start : nil
            }
            let end: Date? = returnHome ?? (now.timeIntervalSince(latest) <= 48 * 3600 && nextNight == nil ? nil : latest)
            let region = base?.locality.map { [$0.city, $0.country].filter { !$0.isEmpty }.joined(separator: ", ") } ?? ""
            let title = region.isEmpty ? base.map { "Stay at \($0.name)" } ?? "Time away" : region
            return Trip(title: title, start: start, end: end, automaticAnchor: first.start)
        }
    }

    private static func samePlace(_ lhs: TimelineItem, _ rhs: TimelineItem) -> Bool {
        if let id = lhs.placeID { return id == rhs.placeID }
        guard rhs.placeID == nil, let a = lhs.coordinate, let b = rhs.coordinate else { return false }
        return a.distance(to: b) <= 150
    }

    public static func reconcile(_ candidates: [Trip], existing: [Trip]) -> [Trip] {
        var result = existing
        for candidate in candidates {
            guard let anchor = candidate.automaticAnchor else { continue }
            if let index = result.firstIndex(where: { trip in
                guard let oldAnchor = trip.automaticAnchor else { return false }
                return oldAnchor == anchor || (oldAnchor >= candidate.start && oldAnchor < (candidate.end ?? .distantFuture))
            }) {
                if !result[index].datesEdited { result[index].start = candidate.start; result[index].end = candidate.end }
                if !result[index].titleEdited { result[index].title = candidate.title }
            } else if !result.contains(where: { $0.automaticAnchor == nil && $0.contains(anchor, now: .distantFuture) }) {
                result.append(candidate)
            }
        }
        return result.sorted { $0.start > $1.start }
    }
}
