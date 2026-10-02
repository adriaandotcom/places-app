import Foundation
import GRDB

/// Explicit columns keep an archive from supplying SQL or a database schema.
/// JSON Lines lets large histories stream one record at a time. Payloads retain
/// their normal Codable representation, including fractional timestamps.
struct BackupTable: Sendable {
    let name: String
    let columns: [String]
    init(_ name: String, _ columns: String) {
        self.name = name; self.columns = columns.split(separator: ",").map(String.init)
    }
    var path: String { "data/\(name).jsonl" }
    var select: String { "SELECT \(columns.joined(separator: ",")) FROM \(name)" }
    var insert: String {
        "INSERT INTO \(name)(\(columns.joined(separator: ","))) VALUES (\(columns.map { _ in "?" }.joined(separator: ",")))"
    }
    // Parents precede children. Delete in reverse order; never disable foreign keys.
    static let all: [Self] = [
        .init("settings", "key,value"),
        .init("observations", "id,deduplicationKey,timestamp,source,payload"),
        .init("places", "id,name,address,payload"),
        .init("wifiNetworks", "id,ssid,payload"),
        .init("wifiAccessPoints", "id,networkID,bssid,payload"),
        .init("placeWifiLinks", "placeID,networkID"),
        .init("timeline", "id,start,end,payload"),
        .init("evidenceLinks", "timelineID,observationID"),
        .init("routePoints", "id,observationID,timelineID,timestamp,payload"),
        .init("overrides", "id,start,end,createdAt,payload"),
        .init("timelineSeparations", "timestamp"),
        .init("trackingEvents", "id,timestamp,payload"),
        .init("wifiObservationLocations", "observationID,ssid,bssid,timestamp,latitude,longitude,accuracy"),
        .init("people", "id,payload"),
        .init("trips", "id,payload"),
        .init("memories", "id,date,payload"),
        .init("memoryPhotos", "id,memoryID,jpeg,thumbnail"),
        .init("photoEvidence", "id,assetID,capturedAt,active,payload"),
        .init("photoScan", "assetID,fingerprint"),
        .init("photoReview", "assetID")
    ]

    static func checkSchema(_ db: Database) throws {
        let stored = Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
        let derived: Set<String> = ["grdb_migrations", "placeSearch", "placeSearch_data", "placeSearch_idx", "placeSearch_content", "placeSearch_docsize", "placeSearch_config"]
        guard stored.subtracting(derived) == Set(all.map(\.name)) else { throw BackupError.newerVersion }
        for table in all {
            guard Set(try db.columns(in: table.name).map(\.name)) == Set(table.columns) else { throw BackupError.newerVersion }
        }
    }

    func export(_ row: Row, media: (Data) throws -> String) throws -> Data {
        var object: [String: Any] = [:]
        for column in columns {
            let value: DatabaseValue = row[column]
            switch value.storage {
            case .null: object[column] = NSNull()
            case .int64(let value): object[column] = value
            case .double(let value): object[column] = value
            case .string(let value): object[column] = value
            case .blob(let data):
                object[column] = try column == "payload" ? JSONSerialization.jsonObject(with: data) : media(data)
            }
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    func restore(_ data: Data, root: URL, files: Set<String>, db: Database) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(columns) else { throw BackupError.invalid }
        var values: [DatabaseValue] = []
        for column in columns {
            let value = object[column]!
            if value is NSNull { values.append(.null) }
            else if column == "payload" {
                guard value is [String: Any] else { throw BackupError.invalid }
                let payload = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                try validatePayload(payload, row: object)
                values.append(payload.databaseValue)
            } else if name == "memoryPhotos", ["jpeg", "thumbnail"].contains(column) {
                guard let path = value as? String, path.hasPrefix("photos/"), files.contains(path) else { throw BackupError.invalid }
                let url = root.appendingPathComponent(path)
                let limit = column == "jpeg" ? 450_000 : 50_000
                guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= limit else { throw BackupError.invalid }
                values.append(try Data(contentsOf: url).databaseValue)
            } else if let string = value as? String { values.append(string.databaseValue) }
            else if let number = value as? NSNumber {
                let type = String(cString: number.objCType)
                values.append(type == "d" || type == "f" ? number.doubleValue.databaseValue : number.int64Value.databaseValue)
            } else { throw BackupError.invalid }
        }
        try db.execute(sql: insert, arguments: StatementArguments(values))
    }

    private func validatePayload(_ data: Data, row: [String: Any]) throws {
        let decoder = JSONDecoder()
        func check<T: Decodable & Identifiable>(_ type: T.Type) throws -> T where T.ID == String {
            let value = try decoder.decode(type, from: data)
            guard !value.id.isEmpty, value.id == row["id"] as? String else { throw BackupError.invalid }
            return value
        }
        func photo(_ data: Data?) -> Bool { data.map { !$0.isEmpty && $0.count <= 200_000 } ?? true }
        switch name {
        case "places":
            let value = try check(Place.self)
            guard !value.name.isEmpty, value.coordinate.isValid, (50...1000).contains(value.radius),
                  value.area?.isValid != false, photo(value.photoJPEG), value.name == row["name"] as? String,
                  value.address == row["address"] as? String else { throw BackupError.invalid }
        case "observations":
            let value = try check(SensorObservation.self)
            guard value.coordinate?.isValid != false, value.deduplicationKey == row["deduplicationKey"] as? String,
                  value.timestamp.timeIntervalSince1970 == (row["timestamp"] as? NSNumber)?.doubleValue,
                  value.source.rawValue == row["source"] as? String else { throw BackupError.invalid }
        case "timeline":
            let value = try check(TimelineItem.self)
            guard value.coordinate?.isValid != false, value.end.map({ $0 >= value.start }) != false,
                  value.start.timeIntervalSince1970 == (row["start"] as? NSNumber)?.doubleValue else { throw BackupError.invalid }
        case "overrides":
            let value = try check(UserOverride.self)
            guard value.end > value.start, value.coordinate?.isValid != false,
                  value.start.timeIntervalSince1970 == (row["start"] as? NSNumber)?.doubleValue,
                  value.end.timeIntervalSince1970 == (row["end"] as? NSNumber)?.doubleValue else { throw BackupError.invalid }
        case "wifiNetworks":
            let value = try check(WiFiNetwork.self)
            guard value.ssid == row["ssid"] as? String else { throw BackupError.invalid }
        case "wifiAccessPoints":
            let value = try check(WiFiAccessPoint.self)
            guard value.networkID == row["networkID"] as? String, value.bssid == row["bssid"] as? String else { throw BackupError.invalid }
        case "routePoints":
            let value = try check(RoutePoint.self)
            guard value.coordinate.isValid, value.observationID == row["observationID"] as? String,
                  value.timelineID == row["timelineID"] as? String,
                  value.timestamp.timeIntervalSince1970 == (row["timestamp"] as? NSNumber)?.doubleValue else { throw BackupError.invalid }
        case "trackingEvents":
            let value = try check(TrackingEvent.self)
            guard value.timestamp.timeIntervalSince1970 == (row["timestamp"] as? NSNumber)?.doubleValue else { throw BackupError.invalid }
        case "photoEvidence":
            let value = try check(PhotoLocationEvidence.self)
            guard value.coordinate.isValid, value.assetID == row["assetID"] as? String,
                  value.capturedAt.timeIntervalSince1970 == (row["capturedAt"] as? NSNumber)?.doubleValue else { throw BackupError.invalid }
        case "people":
            let value = try check(MemoryPerson.self)
            guard !value.name.isEmpty, photo(value.avatarJPEG),
                  PersonMentions.valid(value.mentions ?? [], in: value.detail).count == (value.mentions ?? []).count else { throw BackupError.invalid }
        case "trips":
            let value = try check(Trip.self)
            guard !value.title.isEmpty, value.end.map({ $0 > value.start }) != false, photo(value.photoJPEG) else { throw BackupError.invalid }
        case "memories":
            let value = try check(PlaceMemory.self)
            guard Set(value.photoIDs).count == value.photoIDs.count,
                  value.date.timeIntervalSince1970 == (row["date"] as? NSNumber)?.doubleValue,
                  (value.photoDetails ?? [:]).values.allSatisfy({ $0.coordinate?.isValid != false }),
                  PersonMentions.valid(value.mentions ?? [], in: value.text).count == (value.mentions ?? []).count else { throw BackupError.invalid }
        default: throw BackupError.invalid
        }
    }

    static func validateRelationships(_ db: Database) throws {
        let cursor = try Data.fetchCursor(db, sql: "SELECT payload FROM memories")
        while let data = try cursor.next() {
            let memory = try JSONDecoder().decode(PlaceMemory.self, from: data)
            let owned = try String.fetchAll(db, sql: "SELECT id FROM memoryPhotos WHERE memoryID = ?", arguments: [memory.id])
            guard Set(owned) == Set(memory.photoIDs) else { throw BackupError.invalid }
            try MemorySQL.checkPeople(memory.linkedPersonIDs, db: db)
            for (table, id) in [("places", memory.placeID), ("trips", memory.tripID)] {
                if let id, try !Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM \(table) WHERE id = ?)", arguments: [id])! { throw BackupError.invalid }
            }
        }
        let trips = try Data.fetchCursor(db, sql: "SELECT payload FROM trips")
        while let data = try trips.next() {
            try autoreleasepool { try MemorySQL.checkPeople(JSONDecoder().decode(Trip.self, from: data).personIDs, db: db) }
        }
        let people = try Data.fetchCursor(db, sql: "SELECT payload FROM people")
        while let data = try people.next() {
            try autoreleasepool { try MemorySQL.checkPeople((JSONDecoder().decode(MemoryPerson.self, from: data).mentions ?? []).map(\.personID), db: db) }
        }
        guard try Row.fetchOne(db, sql: "PRAGMA foreign_key_check") == nil else { throw BackupError.invalid }
    }
}
