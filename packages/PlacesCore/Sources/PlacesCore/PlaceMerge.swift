import Foundation
import GRDB

/// Keeps the most recently personalized place. Older versions did not record
/// edit times, so prefer their explicit customizations and attached memories.
public struct PlaceMergePlan: Equatable, Sendable {
    public let kept: Place
    public let removed: Place
    public init(_ first: Place, _ second: Place, memories: [PlaceMemory] = []) {
        func investment(_ place: Place) -> Int {
            (place.id.hasPrefix("journaling-place-") ? 0 : 4)
            + (place.symbol != (PlaceIconMatcher.suggestedSymbol(name: place.name) ?? "mappin") ? 4 : 0)
            + (place.customColorHex != nil || place.colorIndex != 0 ? 3 : 0)
            + (place.area != nil ? 4 : 0)
            + (place.expectedSSIDs.isEmpty ? 0 : 3)
            + (place.address.isEmpty ? 0 : 1)
            + (place.tripRole != nil && place.tripRole != .automatic ? 2 : 0)
            + min(5, memories.filter { $0.placeID == place.id }.count)
        }
        let firstWins: Bool
        if first.userEditedAt != second.userEditedAt {
            firstWins = (first.userEditedAt ?? .distantPast) > (second.userEditedAt ?? .distantPast)
        } else if investment(first) != investment(second) {
            firstWins = investment(first) > investment(second)
        } else if first.createdAt != second.createdAt {
            firstWins = first.createdAt < second.createdAt
        } else { firstWins = first.id < second.id }
        kept = firstWins ? first : second; removed = firstWins ? second : first
    }
    public var combined: Place {
        var place = kept
        place.expectedSSIDs = Array(Set(kept.expectedSSIDs + removed.expectedSSIDs)).sorted()
        place.mergedPlaceIDs = Array(Set((kept.mergedPlaceIDs ?? []) + (removed.mergedPlaceIDs ?? []) + [removed.id])).sorted()
        place.createdAt = min(kept.createdAt, removed.createdAt)
        if place.address.isEmpty { place.address = removed.address }
        if place.locality == nil { place.locality = removed.locality }
        return place
    }
}

extension PlacesStore {
    /// Merge in one transaction, including unsaved edits from the place editor.
    /// Photos, people, raw observations and their IDs remain intact.
    public func mergePlaces(edited: Place, with otherID: String, keeping expectedID: String, now: Date = Date()) throws -> Place {
        guard !edited.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              edited.coordinate.isValid, edited.radius.isFinite, (50...1000).contains(edited.radius),
              edited.area?.isValid != false else { throw PlacesError.invalidPlace }
        return try queue.write { db in
            let places = try StoreSQL.decodeAll(Place.self, db: db, sql: "SELECT payload FROM places")
            guard otherID != edited.id, places.contains(where: { $0.id == edited.id }),
                  let other = places.first(where: { $0.id == otherID }) else { throw PlacesError.invalidPlace }
            let memories = try MemorySQL.memories(db)
            let plan = PlaceMergePlan(edited, other, memories: memories)
            guard plan.kept.id == expectedID else { throw PlacesError.invalidPlace }
            let place = plan.combined, removedID = plan.removed.id
            let context = try StoreSQL.pastVisitContext(db: db)
            try StoreSQL.savePlace(place, db: db)
            for var edit in try StoreSQL.decodeAll(UserOverride.self, db: db, sql: "SELECT payload FROM overrides") where edit.placeID == removedID {
                edit.placeID = place.id
                try db.execute(sql: "UPDATE overrides SET payload = ? WHERE id = ?", arguments: [try StoreSQL.encode(edit), edit.id])
            }
            // Preserve existing visits even if the kept place has a smaller or
            // moved recognition area. This is the user's explicit merge correction.
            for item in context.items where item.placeID == removedID && !item.isUserEdited {
                let end = item.end ?? now
                guard end > item.start else { continue }
                try StoreSQL.saveCorrection(UserOverride(id: "place-merge-\(removedID)-\(item.id)",
                    start: item.start, end: end, kind: .stay, placeID: place.id, createdAt: now), db: db)
            }
            for var point in try StoreSQL.decodeAll(WiFiAccessPoint.self, db: db, sql: "SELECT payload FROM wifiAccessPoints") where point.placeID == removedID {
                point.placeID = place.id
                try db.execute(sql: "UPDATE wifiAccessPoints SET payload = ? WHERE id = ?", arguments: [try StoreSQL.encode(point), point.id])
            }
            for var memory in memories where memory.placeID == removedID {
                memory.placeID = place.id
                try MemorySQL.saveMemory(memory, db: db)
            }
            try db.execute(sql: "INSERT OR IGNORE INTO placeWifiLinks(placeID, networkID) SELECT ?, networkID FROM placeWifiLinks WHERE placeID = ?", arguments: [place.id, removedID])
            for ssid in place.expectedSSIDs where !ssid.isEmpty {
                let existing = try StoreSQL.decodeAll(WiFiNetwork.self, db: db, sql: "SELECT payload FROM wifiNetworks WHERE ssid = ?", arguments: [ssid]).first
                let network = existing ?? WiFiNetwork(ssid: ssid, firstSeen: now, lastSeen: now)
                try StoreSQL.saveNetwork(network, db: db)
                try db.execute(sql: "INSERT OR IGNORE INTO placeWifiLinks(placeID, networkID) VALUES (?, ?)", arguments: [place.id, network.id])
            }
            try db.execute(sql: "DELETE FROM placeWifiLinks WHERE placeID = ?", arguments: [removedID])
            try db.execute(sql: "DELETE FROM placeSearch WHERE placeID = ?", arguments: [removedID])
            try db.execute(sql: "DELETE FROM places WHERE id = ?", arguments: [removedID])
            try StoreSQL.rebuild(db: db, since: nil)
            return place
        }
    }
}
