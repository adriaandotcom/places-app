import Foundation
import GRDB

public actor PlacesStore {
    private let queue: DatabaseQueue

    /// A support code only: never expose SQLite statements, arguments, or paths.
    public nonisolated static func failureCode(_ error: any Error) -> String {
        if let database = error as? DatabaseError {
            let constraint: String
            if database.message?.contains("UNIQUE constraint failed: timeline.id") == true { constraint = "-timeline" }
            else if database.message?.contains("UNIQUE constraint failed: evidenceLinks") == true { constraint = "-evidence" }
            else if database.message?.contains("UNIQUE constraint failed: routePoints") == true { constraint = "-route" }
            else { constraint = "" }
            return "database-\(database.extendedResultCode.rawValue)\(constraint)"
        }
        if let cocoa = error as? CocoaError { return "file-\(cocoa.code.rawValue)" }
        return "storage-unavailable"
    }

    public init(path: String = ":memory:") throws {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON; PRAGMA secure_delete = ON")
        }
        queue = try DatabaseQueue(path: path, configuration: configuration)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-local-history") { db in
            try db.execute(sql: """
                CREATE TABLE observations (id TEXT PRIMARY KEY, deduplicationKey TEXT NOT NULL UNIQUE,
                    timestamp REAL NOT NULL, source TEXT NOT NULL, payload BLOB NOT NULL);
                CREATE INDEX observations_time ON observations(timestamp);
                CREATE TABLE places (id TEXT PRIMARY KEY, name TEXT NOT NULL, address TEXT NOT NULL, payload BLOB NOT NULL);
                CREATE VIRTUAL TABLE placeSearch USING fts5(placeID UNINDEXED, name, address, tokenize='unicode61 remove_diacritics 2');
                CREATE TABLE wifiNetworks (id TEXT PRIMARY KEY, ssid TEXT NOT NULL UNIQUE, payload BLOB NOT NULL);
                CREATE TABLE wifiAccessPoints (id TEXT PRIMARY KEY, networkID TEXT NOT NULL REFERENCES wifiNetworks(id),
                    bssid TEXT NOT NULL, payload BLOB NOT NULL, UNIQUE(networkID, bssid));
                CREATE TABLE placeWifiLinks (placeID TEXT NOT NULL REFERENCES places(id),
                    networkID TEXT NOT NULL REFERENCES wifiNetworks(id), PRIMARY KEY(placeID, networkID));
                CREATE TABLE timeline (id TEXT PRIMARY KEY, start REAL NOT NULL, end REAL, payload BLOB NOT NULL);
                CREATE INDEX timeline_time ON timeline(start, end);
                CREATE TABLE evidenceLinks (timelineID TEXT NOT NULL REFERENCES timeline(id) ON DELETE CASCADE,
                    observationID TEXT NOT NULL REFERENCES observations(id), PRIMARY KEY(timelineID, observationID));
                CREATE TABLE routePoints (id TEXT PRIMARY KEY, observationID TEXT NOT NULL REFERENCES observations(id),
                    timelineID TEXT NOT NULL REFERENCES timeline(id) ON DELETE CASCADE, timestamp REAL NOT NULL, payload BLOB NOT NULL);
                CREATE INDEX routePoints_time ON routePoints(timestamp);
                CREATE TABLE overrides (id TEXT PRIMARY KEY, start REAL NOT NULL, end REAL NOT NULL,
                    createdAt REAL NOT NULL, payload BLOB NOT NULL);
                CREATE TABLE trackingEvents (id TEXT PRIMARY KEY, timestamp REAL NOT NULL, payload BLOB NOT NULL);
                CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                """)
        }
        migrator.registerMigration("v2-stationary-history") { db in
            // Rebuild derived history only. Raw evidence and durable corrections
            // remain unchanged when installing the improved inference policy.
            for var network in try StoreSQL.decodeAll(WiFiNetwork.self, db: db, sql: "SELECT payload FROM wifiNetworks")
                where network.classification == .unclassified && !network.userClassified {
                network.classification = .fixed
                try StoreSQL.saveNetwork(network, db: db)
            }
            // GRDB disables foreign keys while this migration runs, then checks
            // them before commit. Delete derived children explicitly: ON DELETE
            // CASCADE cannot remove their old timeline IDs during the rebuild.
            try db.execute(sql: "DELETE FROM evidenceLinks; DELETE FROM routePoints")
            try StoreSQL.rebuild(db: db, since: nil)
        }
        migrator.registerMigration("v3-reversible-timeline-grouping") { db in
            try db.execute(sql: "CREATE TABLE timelineSeparations (timestamp REAL PRIMARY KEY)")
        }
        migrator.registerMigration("v4-connected-wifi-evidence") { db in
            try db.execute(sql: "DELETE FROM evidenceLinks; DELETE FROM routePoints")
            try StoreSQL.rebuild(db: db, since: nil)
        }
        migrator.registerMigration("v5-nearby-wifi-suggestions", migrate: WiFiSuggestionIndex.migrate)
        try migrator.migrate(queue)
    }

    public func setting(_ key: String) throws -> String? {
        try queue.read { try String.fetchOne($0, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key]) }
    }
    public func setSetting(_ key: String, value: String) throws {
        try queue.write { try $0.execute(sql: "INSERT INTO settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", arguments: [key, value]) }
    }

    public func places() throws -> [Place] {
        try queue.read { try StoreSQL.decodeAll(Place.self, db: $0, sql: "SELECT payload FROM places ORDER BY name COLLATE NOCASE") }
    }

    public func savePlace(_ place: Place, assigning edit: UserOverride? = nil) throws {
        guard !place.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              place.coordinate.isValid, place.radius.isFinite, (50...1000).contains(place.radius) else { throw PlacesError.invalidPlace }
        try queue.write { db in
            if let edit, edit.kind != .stay || edit.placeID != place.id { throw PlacesError.invalidCorrection }
            try db.execute(sql: "INSERT INTO places(id, name, address, payload) VALUES (?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET name = excluded.name, address = excluded.address, payload = excluded.payload",
                           arguments: [place.id, place.name, place.address, try StoreSQL.encode(place)])
            try db.execute(sql: "DELETE FROM placeSearch WHERE placeID = ?", arguments: [place.id])
            try db.execute(sql: "INSERT INTO placeSearch(placeID, name, address) VALUES (?, ?, ?)", arguments: [place.id, place.name, place.address])
            // User-entered SSIDs remain expectations. They are not verified access points.
            for ssid in place.expectedSSIDs where !ssid.isEmpty {
                let existing: WiFiNetwork? = try StoreSQL.decodeAll(WiFiNetwork.self, db: db,
                    sql: "SELECT payload FROM wifiNetworks WHERE ssid = ?", arguments: [ssid]).first
                let network = existing ?? WiFiNetwork(ssid: ssid, firstSeen: place.createdAt, lastSeen: place.createdAt)
                try StoreSQL.saveNetwork(network, db: db)
                try db.execute(sql: "INSERT OR IGNORE INTO placeWifiLinks(placeID, networkID) VALUES (?, ?)", arguments: [place.id, network.id])
            }
            if let edit { try StoreSQL.saveCorrection(edit, db: db) }
            try StoreSQL.rebuild(db: db, since: nil)
        }
    }

    @discardableResult
    public func append(_ observations: [SensorObservation]) throws -> Int {
        try queue.write { db in
            var inserted = 0
            var earliest: Date?
            var networkEvidenceChanged = false
            let places = try StoreSQL.decodeAll(Place.self, db: db, sql: "SELECT payload FROM places")
            for observation in observations {
                guard observation.timestamp.timeIntervalSince1970.isFinite,
                      observation.coordinate?.isValid != false,
                      observation.horizontalAccuracy?.isFinite != false,
                      observation.speed?.isFinite != false else { throw PlacesError.invalidObservation }
                try db.execute(sql: "INSERT OR IGNORE INTO observations(id, deduplicationKey, timestamp, source, payload) VALUES (?, ?, ?, ?, ?)",
                               arguments: [observation.id, observation.deduplicationKey, observation.timestamp.timeIntervalSince1970,
                                           observation.source.rawValue, try StoreSQL.encode(observation)])
                guard db.changesCount > 0 else { continue }
                inserted += 1
                earliest = min(earliest ?? observation.timestamp, observation.timestamp)
                if observation.source == .wifi {
                    try WiFiSuggestionIndex.record(observation, db: db)
                    networkEvidenceChanged = try StoreSQL.learnWiFi(observation, places: places, db: db) || networkEvidenceChanged
                }
            }
            if let earliest { try StoreSQL.rebuild(db: db, since: networkEvidenceChanged ? nil : earliest) }
            return inserted
        }
    }

    public func timeline(on day: Date, calendar: Calendar = .current) throws -> [TimelineItem] {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return [] }
        return try timeline(in: interval)
    }

    public func timeline(in interval: DateInterval) throws -> [TimelineItem] {
        return try queue.read { db in
            var items = try StoreSQL.decodeAll(TimelineItem.self, db: db,
                sql: "SELECT payload FROM timeline WHERE start < ? AND (end IS NULL OR end > ?) ORDER BY start",
                arguments: [interval.end.timeIntervalSince1970, interval.start.timeIntervalSince1970])
            // A gap spanning midnight needs its neighboring entries before grouping.
            // Clip to the requested day only after preserving that place context.
            if let first = items.first, first.kind == .gap,
               let previous = try StoreSQL.decodeAll(TimelineItem.self, db: db,
                    sql: "SELECT payload FROM timeline WHERE end = ? ORDER BY start DESC LIMIT 1",
                    arguments: [first.start.timeIntervalSince1970]).first {
                items.insert(previous, at: 0)
            }
            if let last = items.last, last.kind == .gap, let end = last.end,
               let following = try StoreSQL.decodeAll(TimelineItem.self, db: db,
                    sql: "SELECT payload FROM timeline WHERE start = ? ORDER BY start LIMIT 1",
                    arguments: [end.timeIntervalSince1970]).first {
                items.append(following)
            }
            let contextStart = min(interval.start, items.first?.start ?? interval.start)
            let contextEnd = max(interval.end, items.last?.end ?? items.last?.lastEvidenceAt ?? interval.end)
            let edits = try StoreSQL.decodeAll(UserOverride.self, db: db,
                sql: "SELECT payload FROM overrides WHERE start < ? AND end > ? ORDER BY createdAt",
                arguments: [max(interval.end, items.last?.end ?? .distantFuture).timeIntervalSince1970,
                            contextStart.timeIntervalSince1970])
            let observations = try StoreSQL.decodeAll(SensorObservation.self, db: db,
                sql: "SELECT payload FROM observations WHERE timestamp >= ? AND timestamp <= ? ORDER BY timestamp",
                arguments: [contextStart.timeIntervalSince1970, contextEnd.timeIntervalSince1970])
            let places = try StoreSQL.decodeAll(Place.self, db: db, sql: "SELECT payload FROM places")
            let separatedAt = try Double.fetchAll(db, sql: "SELECT timestamp FROM timelineSeparations").map(Date.init(timeIntervalSince1970:))
            let presented = TimelinePresentation.make(items: InferenceEngine.applying(edits, to: items),
                observations: observations, places: places, separatedAt: separatedAt)
            return InferenceEngine.within(interval, items: presented)
        }
    }

    public func split(_ item: TimelineItem, selecting ids: Set<String>? = nil) throws {
        guard let originals = item.originalItems, originals.count > 1 else { return }
        let visible = originals.filter { $0.start < (item.end ?? .distantFuture) && ($0.end ?? .distantFuture) > item.start }
        let selected = ids ?? Set(visible.map(\.id))
        // Isolate each chosen original on both sides. Leave other runs combined.
        let boundaries = visible.indices.dropFirst().compactMap { index -> Date? in
            selected.contains(visible[index].id) || selected.contains(visible[index - 1].id) ? visible[index].start : nil
        }
        try queue.write { db in
            for boundary in boundaries {
                try db.execute(sql: "INSERT OR IGNORE INTO timelineSeparations(timestamp) VALUES (?)",
                               arguments: [boundary.timeIntervalSince1970])
            }
        }
    }

    public func historyDays(now: Date = Date(), calendar: Calendar = .current) throws -> [HistoryDay] {
        try queue.read { db in
            let items = try StoreSQL.decodeAll(TimelineItem.self, db: db, sql: "SELECT payload FROM timeline ORDER BY start")
            let edits = try StoreSQL.decodeAll(UserOverride.self, db: db, sql: "SELECT payload FROM overrides ORDER BY createdAt")
            return HistoryDay.summarize(InferenceEngine.applying(edits, to: items), now: now, calendar: calendar)
        }
    }

    public func adjacentPlaces(for item: TimelineItem) throws -> [AdjacentPlaceSuggestion] {
        try queue.read { db in
            let items = try StoreSQL.decodeAll(TimelineItem.self, db: db, sql: "SELECT payload FROM timeline ORDER BY start")
            let edits = try StoreSQL.decodeAll(UserOverride.self, db: db, sql: "SELECT payload FROM overrides ORDER BY createdAt")
            return AdjacentPlaceSuggestion.make(for: item, in: InferenceEngine.applying(edits, to: items))
        }
    }

    public func suggestedPeriods(now: Date = Date()) throws -> [HistoryPeriod] {
        guard let first = try queue.read({ try Double.fetchOne($0, sql: "SELECT MIN(start) FROM timeline") }),
              first < now.timeIntervalSince1970 else { return [] }
        let items = try timeline(in: DateInterval(start: Date(timeIntervalSince1970: first), end: now))
        return HistoryPeriod.visits(items: items, places: try places(), now: now)
    }

    // Merge only metadata into the latest saved place, preserving concurrent edits.
    public func saveLocality(_ locality: PlaceLocality, for id: String, at coordinate: Coordinate) throws {
        try queue.write { db in
            guard var place = try StoreSQL.decodeAll(Place.self, db: db,
                sql: "SELECT payload FROM places WHERE id = ?", arguments: [id]).first,
                place.coordinate == coordinate, place.locality == nil else { return }
            place.locality = locality
            try db.execute(sql: "UPDATE places SET payload = ? WHERE id = ?", arguments: [try StoreSQL.encode(place), id])
        }
    }

    public func mergeAdjacent(to item: TimelineItem) throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM timelineSeparations WHERE timestamp = ? OR timestamp = ?",
                           arguments: [item.start.timeIntervalSince1970, item.end?.timeIntervalSince1970])
        }
    }

    public func correct(_ edit: UserOverride) throws {
        try queue.write { try StoreSQL.saveCorrection(edit, db: $0) }
    }

    public func networks() throws -> [WiFiNetwork] {
        try queue.read { try StoreSQL.decodeAll(WiFiNetwork.self, db: $0, sql: "SELECT payload FROM wifiNetworks ORDER BY ssid") }
    }
    public func wifiSuggestions(near coordinate: Coordinate, placeRadius: Double = 100,
                                connected: SensorObservation? = nil, now: Date = Date()) throws -> [WiFiSuggestion] {
        try queue.read { db in
            try WiFiSuggestionIndex.suggestions(near: coordinate, placeRadius: placeRadius, connected: connected, now: now,
                networks: StoreSQL.decodeAll(WiFiNetwork.self, db: db, sql: "SELECT payload FROM wifiNetworks"),
                points: StoreSQL.decodeAll(WiFiAccessPoint.self, db: db, sql: "SELECT payload FROM wifiAccessPoints"),
                places: StoreSQL.decodeAll(Place.self, db: db, sql: "SELECT payload FROM places"), db: db)
        }
    }
    public func accessPoints() throws -> [WiFiAccessPoint] {
        try queue.read { try StoreSQL.decodeAll(WiFiAccessPoint.self, db: $0, sql: "SELECT payload FROM wifiAccessPoints") }
    }
    public func classifyNetwork(id: String, as classification: WiFiClassification) throws {
        try queue.write { db in
            guard var network = try StoreSQL.decodeAll(WiFiNetwork.self, db: db,
                sql: "SELECT payload FROM wifiNetworks WHERE id = ?", arguments: [id]).first else { return }
            network.classification = classification; network.userClassified = true
            try StoreSQL.saveNetwork(network, db: db)
            try StoreSQL.rebuild(db: db, since: nil)
        }
    }

    public func search(_ text: String) throws -> [Place] {
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(12)
        guard !words.isEmpty else { return [] }
        let query = words.map { "\"\($0)\"*" }.joined(separator: " AND ")
        return try queue.read { db in
            try StoreSQL.decodeAll(Place.self, db: db,
                sql: "SELECT places.payload FROM placeSearch JOIN places ON places.id = placeSearch.placeID WHERE placeSearch MATCH ? ORDER BY rank LIMIT 50",
                arguments: [query])
        }
    }

    public func observations(limit: Int = 100) throws -> [SensorObservation] {
        try queue.read { try StoreSQL.decodeAll(SensorObservation.self, db: $0,
            sql: "SELECT payload FROM observations ORDER BY timestamp DESC LIMIT ?", arguments: [max(0, min(limit, 500))]) }
    }
    public func evidence(for item: TimelineItem) throws -> [SensorObservation] {
        let ids = Array(Set(item.evidenceIDs)).sorted()
        return try queue.read { db in
            var values: [SensorObservation] = []
            // Bound SQLite parameters, not history depth. Old/grouped visits must
            // show their actual evidence, even when it is outside the recent log.
            for start in stride(from: 0, to: ids.count, by: 400) {
                let batch = Array(ids[start..<min(start + 400, ids.count)])
                let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
                values += try StoreSQL.decodeAll(SensorObservation.self, db: db,
                    sql: "SELECT payload FROM observations WHERE id IN (\(placeholders))", arguments: StatementArguments(batch))
            }
            return values.sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
        }
    }
    public func transportSuggestions(for item: TimelineItem) throws -> TransportSuggestions {
        try queue.read { db in
            let values = try StoreSQL.decodeAll(SensorObservation.self, db: db,
                sql: "SELECT payload FROM observations WHERE timestamp >= ? AND timestamp <= ? ORDER BY timestamp",
                arguments: [item.start.timeIntervalSince1970, (item.end ?? item.lastEvidenceAt).timeIntervalSince1970])
            return TransportSuggestions.make(for: item, observations: values)
        }
    }
    public func routePoints(from start: Date, to end: Date) throws -> [RoutePoint] {
        try queue.read { try StoreSQL.decodeAll(RoutePoint.self, db: $0,
            sql: "SELECT payload FROM routePoints WHERE timestamp >= ? AND timestamp <= ? ORDER BY timestamp",
            arguments: [start.timeIntervalSince1970, end.timeIntervalSince1970]) }
    }
    public func record(_ event: TrackingEvent) throws {
        try queue.write { try $0.execute(sql: "INSERT INTO trackingEvents(id, timestamp, payload) VALUES (?, ?, ?)",
            arguments: [event.id, event.timestamp.timeIntervalSince1970, try StoreSQL.encode(event)]) }
    }
    public func trackingEvents(limit: Int = 100) throws -> [TrackingEvent] {
        try queue.read { try StoreSQL.decodeAll(TrackingEvent.self, db: $0,
            sql: "SELECT payload FROM trackingEvents ORDER BY timestamp DESC LIMIT ?", arguments: [limit]) }
    }
    public func diagnostics() throws -> DiagnosticReport {
        try queue.read { db in
            let events = try StoreSQL.decodeAll(TrackingEvent.self, db: db, sql: "SELECT payload FROM trackingEvents ORDER BY timestamp")
            var durations: [String: Double] = [:]
            var activeTime: Double = 0
            for index in events.indices.dropFirst() {
                let previous = events[index - 1], event = events[index]
                // Only count time explicitly measured by this running process; no invented background uptime.
                durations[previous.state.rawValue, default: 0] += event.previousStateDuration
                if previous.standardLocationActive { activeTime += event.previousStateDuration }
            }
            return DiagnosticReport(formatVersion: 1, policyVersion: TrackingPolicy.version,
                observationCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM observations") ?? 0,
                placeCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM places") ?? 0,
                timelineCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM timeline") ?? 0,
                stateDurations: durations,
                locationFixCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM observations WHERE source IN ('location','significantChange')") ?? 0,
                standardLocationSeconds: activeTime,
                energy: EnergySummary(snapshots: events.compactMap(\.energy)),
                note: "Local policy counters, not a measurement of battery drain. No names, coordinates, network identifiers, or raw observations are included.")
        }
    }

    public func exportHistory() throws -> Data {
        try StoreSQL.exportEncoder.encode(historyArchive())
    }
    public func exportTestCase() throws -> Data {
        try InferenceTestCase.redacting(historyArchive()).encoded()
    }
    private func historyArchive() throws -> HistoryArchive {
        try queue.read { db in
            let items = try StoreSQL.decodeAll(TimelineItem.self, db: db, sql: "SELECT payload FROM timeline ORDER BY start")
            let edits = try StoreSQL.decodeAll(UserOverride.self, db: db, sql: "SELECT payload FROM overrides ORDER BY createdAt")
            let places = try StoreSQL.decodeAll(Place.self, db: db, sql: "SELECT payload FROM places")
            let observations = try StoreSQL.decodeAll(SensorObservation.self, db: db, sql: "SELECT payload FROM observations ORDER BY timestamp")
            let separatedAt = try Double.fetchAll(db, sql: "SELECT timestamp FROM timelineSeparations ORDER BY timestamp").map(Date.init(timeIntervalSince1970:))
            return try HistoryArchive(formatVersion: 1, exportedAt: Date(),
                places: places, observations: observations,
                timeline: TimelinePresentation.make(items: InferenceEngine.applying(edits, to: items), observations: observations,
                                                    places: places, separatedAt: separatedAt), corrections: edits,
                networks: StoreSQL.decodeAll(WiFiNetwork.self, db: db, sql: "SELECT payload FROM wifiNetworks"),
                accessPoints: StoreSQL.decodeAll(WiFiAccessPoint.self, db: db, sql: "SELECT payload FROM wifiAccessPoints"),
                routePoints: StoreSQL.decodeAll(RoutePoint.self, db: db, sql: "SELECT payload FROM routePoints ORDER BY timestamp"),
                trackingEvents: StoreSQL.decodeAll(TrackingEvent.self, db: db, sql: "SELECT payload FROM trackingEvents ORDER BY timestamp"),
                separatedAt: separatedAt)
        }
    }
    public func exportDiagnostics() throws -> Data { try StoreSQL.exportEncoder.encode(diagnostics()) }

    public func eraseHistory(resetSettings: Bool = false) throws {
        try queue.write { db in
            try db.execute(sql: """
                DELETE FROM evidenceLinks; DELETE FROM routePoints; DELETE FROM timeline; DELETE FROM overrides; DELETE FROM timelineSeparations;
                DELETE FROM observations; DELETE FROM placeWifiLinks; DELETE FROM wifiAccessPoints;
                DELETE FROM wifiNetworks; DELETE FROM placeSearch; DELETE FROM places; DELETE FROM trackingEvents;
                """)
            if resetSettings {
                try db.execute(sql: "DELETE FROM settings")
                // A relaunch during setup must not resume previously authorized tracking.
                try db.execute(sql: "INSERT INTO settings(key, value) VALUES ('trackingEnabled', 'false')")
            }
        }
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
            _ = try Row.fetchAll(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }
}

private enum StoreSQL {
    static func saveCorrection(_ edit: UserOverride, db: Database) throws {
        guard edit.end > edit.start, edit.end.timeIntervalSince1970.isFinite,
              edit.start.timeIntervalSince1970.isFinite else { throw PlacesError.invalidCorrection }
        if let placeID = edit.placeID,
           try !Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM places WHERE id = ?)", arguments: [placeID])! {
            throw PlacesError.invalidCorrection
        }
        try db.execute(sql: "INSERT INTO overrides(id, start, end, createdAt, payload) VALUES (?, ?, ?, ?, ?)",
                       arguments: [edit.id, edit.start.timeIntervalSince1970, edit.end.timeIntervalSince1970,
                                   edit.createdAt.timeIntervalSince1970, try encode(edit)])
    }
    static var exportEncoder: JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return encoder
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }
    static func decodeAll<T: Decodable>(_ type: T.Type, db: Database, sql: String,
                                        arguments: StatementArguments = []) throws -> [T] {
        try Data.fetchAll(db, sql: sql, arguments: arguments).map { try JSONDecoder().decode(type, from: $0) }
    }
    static func saveNetwork(_ network: WiFiNetwork, db: Database) throws {
        try db.execute(sql: "INSERT INTO wifiNetworks(id, ssid, payload) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload",
                       arguments: [network.id, network.ssid, try encode(network)])
    }

    static func learnWiFi(_ observation: SensorObservation, places: [Place], db: Database) throws -> Bool {
        guard let ssid = observation.ssid, !ssid.isEmpty else { return false }
        var network = try decodeAll(WiFiNetwork.self, db: db,
            sql: "SELECT payload FROM wifiNetworks WHERE ssid = ?", arguments: [ssid]).first
            ?? WiFiNetwork(ssid: ssid, firstSeen: observation.timestamp, lastSeen: observation.timestamp)
        let previousClassification = network.classification
        network.firstSeen = min(network.firstSeen, observation.timestamp)
        network.lastSeen = max(network.lastSeen, observation.timestamp)
        let place = TrackingPolicy.matchingPlace(for: observation, places: places)
        var points = try decodeAll(WiFiAccessPoint.self, db: db,
            sql: "SELECT payload FROM wifiAccessPoints WHERE networkID = ?", arguments: [network.id])
        if !network.userClassified, let bssid = observation.bssid,
           let previous = points.first(where: { $0.bssid == bssid }), let previousID = previous.placeID,
           let previousPlace = places.first(where: { $0.id == previousID }), let coordinate = observation.usableCoordinate,
           coordinate.distance(to: previousPlace.coordinate) > max(1_000, previousPlace.radius * 3) {
            network.classification = .portable
        } else if !network.userClassified, let place, ![.portable, .ignored].contains(network.classification) {
            let hasOtherPlace = points.contains { $0.placeID != nil && $0.placeID != place.id }
            network.classification = hasOtherPlace || network.classification == .shared ? .shared : .fixed
        }
        try saveNetwork(network, db: db)
        guard let bssid = observation.bssid, !bssid.isEmpty else { return previousClassification != network.classification }
        var point = points.first { $0.bssid == bssid }
            ?? WiFiAccessPoint(id: UUID().uuidString, networkID: network.id, bssid: bssid, placeID: nil, lastSeen: observation.timestamp)
        let previousPlaceID = point.placeID
        point.lastSeen = max(point.lastSeen, observation.timestamp)
        if [.fixed, .shared].contains(network.classification), let place {
            // Contradictory observations cannot silently move an access point.
            if point.placeID == nil || point.placeID == place.id {
                point.placeID = place.id
                try db.execute(sql: "INSERT OR IGNORE INTO placeWifiLinks(placeID, networkID) VALUES (?, ?)", arguments: [place.id, network.id])
            }
        }
        try db.execute(sql: "INSERT INTO wifiAccessPoints(id, networkID, bssid, payload) VALUES (?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload",
                       arguments: [point.id, point.networkID, point.bssid, try encode(point)])
        points.removeAll()
        return previousClassification != network.classification || previousPlaceID != point.placeID
    }

    static func rebuild(db: Database, since earliest: Date?) throws {
        var start: Date?
        if let earliest {
            // Rewind to a stay: a journey needs its preceding location anchor to
            // distinguish genuine departure from an initial stationary candidate.
            let cutoff = earliest.addingTimeInterval(-TrackingPolicy.evidenceGap)
            if let prior = try Double.fetchOne(db, sql: "SELECT start FROM timeline WHERE start <= ? AND json_extract(payload, '$.kind') = 'stay' ORDER BY start DESC LIMIT 1", arguments: [cutoff.timeIntervalSince1970]) {
                start = Date(timeIntervalSince1970: prior)
            }
        }
        var observations = try decodeAll(SensorObservation.self, db: db,
            sql: start == nil ? "SELECT payload FROM observations ORDER BY timestamp" : "SELECT payload FROM observations WHERE timestamp >= ? ORDER BY timestamp",
            arguments: start.map { StatementArguments([$0.timeIntervalSince1970]) } ?? [])
        if let start {
            // A motion transition just before this segment still informs its transport mode.
            // Motion-only context cannot create a segment or invent location evidence.
            let context = try decodeAll(SensorObservation.self, db: db,
                sql: "SELECT payload FROM observations WHERE source = 'motion' AND timestamp < ? AND timestamp >= ? ORDER BY timestamp DESC LIMIT 1",
                arguments: [start.timeIntervalSince1970, start.addingTimeInterval(-300).timeIntervalSince1970])
            observations.insert(contentsOf: context, at: 0)
        }
        let places = try decodeAll(Place.self, db: db, sql: "SELECT payload FROM places")
        let networks = try decodeAll(WiFiNetwork.self, db: db, sql: "SELECT payload FROM wifiNetworks")
        let accessPoints = try decodeAll(WiFiAccessPoint.self, db: db, sql: "SELECT payload FROM wifiAccessPoints")
        let items = InferenceEngine.infer(observations: observations, places: places, networks: networks, accessPoints: accessPoints)
        if let start { try db.execute(sql: "DELETE FROM timeline WHERE start >= ?", arguments: [start.timeIntervalSince1970]) }
        else { try db.execute(sql: "DELETE FROM timeline") }
        for item in items {
            try db.execute(sql: "INSERT INTO timeline(id, start, end, payload) VALUES (?, ?, ?, ?)",
                           arguments: [item.id, item.start.timeIntervalSince1970, item.end?.timeIntervalSince1970, try encode(item)])
            for observationID in item.evidenceIDs {
                try db.execute(sql: "INSERT OR IGNORE INTO evidenceLinks(timelineID, observationID) VALUES (?, ?)", arguments: [item.id, observationID])
            }
        }
        // Associate measured route samples with inferred journeys, never manufacture coordinates.
        var itemIndex = 0
        for observation in observations {
            guard let coordinate = observation.usableCoordinate, [.location, .significantChange].contains(observation.source), !items.isEmpty else { continue }
            while itemIndex + 1 < items.count, items[itemIndex + 1].start <= observation.timestamp { itemIndex += 1 }
            let item = items[itemIndex]
            guard item.kind == .journey, observation.timestamp >= item.start,
                  observation.timestamp <= (item.end ?? .distantFuture) else { continue }
            let point = RoutePoint(id: observation.id, observationID: observation.id, timelineID: item.id,
                timestamp: observation.timestamp, coordinate: coordinate, horizontalAccuracy: observation.horizontalAccuracy ?? 0)
            try db.execute(sql: "INSERT INTO routePoints(id, observationID, timelineID, timestamp, payload) VALUES (?, ?, ?, ?, ?)",
                           arguments: [point.id, point.observationID, point.timelineID, point.timestamp.timeIntervalSince1970, try encode(point)])
        }
    }
}
