import Foundation
import GRDB

/// Photo metadata is supporting evidence, never a GPS fix with invented accuracy.
/// It is deliberately excluded from route construction and automatic visit durations.
public struct PhotoLocationEvidence: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var assetID: String
    public var capturedAt: Date
    public var coordinate: Coordinate
    public var cameraModel: String
    public init(id: String, assetID: String, capturedAt: Date, coordinate: Coordinate, cameraModel: String) {
        self.id = id; self.assetID = assetID; self.capturedAt = capturedAt
        self.coordinate = coordinate; self.cameraModel = cameraModel
    }
}

public struct PhotoVisitSuggestion: Identifiable, Hashable, Sendable {
    public var photos: [PhotoLocationEvidence]
    public var id: String { photos[0].assetID }
    public var coordinate: Coordinate { photos[0].coordinate }
    public var start: Date { photos[0].capturedAt }
    public var end: Date { photos.last!.capturedAt }
    public func place(in places: [Place]) -> Place? {
        places.filter { place in photos.allSatisfy { place.contains($0.coordinate) && (place.area != nil || place.coordinate.distance(to: $0.coordinate) <= 200) } }
            .min { $0.coordinate.distance(to: coordinate) < $1.coordinate.distance(to: coordinate) }
    }
    public func relates(to item: TimelineItem) -> Bool {
        photos.contains { photo in
            photo.capturedAt >= item.start && photo.capturedAt <= (item.end ?? .distantFuture)
                && (item.kind == .gap || item.coordinate.map { $0.distance(to: photo.coordinate) <= 200 } == true)
        }
    }
}

public enum PhotoEvidence {
    public static func matches(cameraMake: String?, cameraModel: String?, currentModel: String?) -> Bool {
        guard let cameraMake, let cameraModel, let currentModel, !currentModel.isEmpty else { return false }
        func normalized(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return normalized(cameraMake) == "apple" && normalized(cameraModel) == normalized(currentModel)
    }
    public static func suggestions(_ photos: [PhotoLocationEvidence], calendar: Calendar = .current) -> [PhotoVisitSuggestion] {
        var groups: [PhotoVisitSuggestion] = []
        // Stable order; a cluster cannot grow by chaining distant neighboring points.
        for photo in photos.sorted(by: { ($0.capturedAt, $0.assetID) < ($1.capturedAt, $1.assetID) }) {
            if let last = groups.last, calendar.isDate(last.start, inSameDayAs: photo.capturedAt),
               photo.capturedAt.timeIntervalSince(last.end) <= 90 * 60,
               last.photos.allSatisfy({ $0.coordinate.distance(to: photo.coordinate) <= 120 }) {
                groups[groups.count - 1].photos.append(photo)
            } else { groups.append(PhotoVisitSuggestion(photos: [photo])) }
        }
        return groups.reversed()
    }
}

extension PlacesStore {
    public func photoScanFingerprints() throws -> [String: String] {
        try queue.read { db in Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT assetID, fingerprint FROM photoScan").map { ($0["assetID"] as String, $0["fingerprint"] as String) }) }
    }
    /// Revision history is retained; only the latest accessible metadata is suggested.
    public func indexPhoto(assetID: String, fingerprint: String, evidence: PhotoLocationEvidence?) throws {
        if let evidence {
            guard evidence.assetID == assetID, evidence.coordinate.isValid, evidence.capturedAt.timeIntervalSince1970.isFinite,
                  !evidence.cameraModel.isEmpty else { throw PlacesError.invalidObservation }
        }
        try queue.write { db in
            // Checking persisted consent in the transaction prevents a finishing scan
            // from repopulating evidence after opt-out or erase.
            guard try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = 'photoEvidenceEnabled'") == "true" else { return }
            try db.execute(sql: "UPDATE photoEvidence SET active = 0 WHERE assetID = ?", arguments: [assetID])
            if let evidence {
                try db.execute(sql: "INSERT INTO photoEvidence(id, assetID, capturedAt, active, payload) VALUES (?, ?, ?, 1, ?) ON CONFLICT(id) DO UPDATE SET active = 1",
                    arguments: [evidence.id, assetID, evidence.capturedAt.timeIntervalSince1970, try StoreSQL.encode(evidence)])
            }
            try db.execute(sql: "INSERT INTO photoScan(assetID, fingerprint) VALUES (?, ?) ON CONFLICT(assetID) DO UPDATE SET fingerprint = excluded.fingerprint", arguments: [assetID, fingerprint])
        }
    }
    public func reconcilePhotoAccess(accessibleIDs: Set<String>, since: Date) throws {
        try queue.write { db in
            let rows = try Row.fetchAll(db, sql: "SELECT DISTINCT assetID FROM photoEvidence WHERE active = 1 AND capturedAt >= ?", arguments: [since.timeIntervalSince1970])
            for row in rows {
                let id: String = row["assetID"]
                if !accessibleIDs.contains(id) {
                    try db.execute(sql: "UPDATE photoEvidence SET active = 0 WHERE assetID = ?", arguments: [id])
                    try db.execute(sql: "DELETE FROM photoScan WHERE assetID = ?", arguments: [id])
                }
            }
        }
    }
    public func photoEvidence(since: Date = .distantPast, includeHistory: Bool = false) throws -> [PhotoLocationEvidence] {
        try queue.read { db in
            try StoreSQL.decodeAll(PhotoLocationEvidence.self, db: db, sql: "SELECT payload FROM photoEvidence WHERE capturedAt >= ?" + (includeHistory ? "" : " AND active = 1 AND assetID NOT IN (SELECT assetID FROM photoReview)") + " ORDER BY capturedAt", arguments: [since.timeIntervalSince1970])
        }
    }
    public func dismissPhotoSuggestions(assetIDs: [String]) throws {
        try queue.write { db in
            for id in assetIDs { try db.execute(sql: "INSERT OR IGNORE INTO photoReview(assetID) VALUES (?)", arguments: [id]) }
        }
    }
    public func erasePhotoEvidence() throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM photoEvidence; DELETE FROM photoScan; DELETE FROM photoReview")
        }
    }
}
