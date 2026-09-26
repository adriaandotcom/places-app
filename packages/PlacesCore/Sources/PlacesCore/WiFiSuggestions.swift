import Foundation
import GRDB

/// A name to offer in the editor, not evidence that a network identifies a place.
public struct WiFiSuggestion: Identifiable, Sendable, Equatable {
    public var id: String { ssid }
    public let ssid: String
    public var lastSeen: Date
    public var isConnected: Bool = false
}

/// Rebuildable geographic index of actual observations. Raw evidence stays untouched.
enum WiFiSuggestionIndex {
    static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE wifiObservationLocations (
                observationID TEXT PRIMARY KEY REFERENCES observations(id) ON DELETE CASCADE,
                ssid TEXT NOT NULL, bssid TEXT, timestamp REAL NOT NULL,
                latitude REAL NOT NULL, longitude REAL NOT NULL, accuracy REAL NOT NULL);
            CREATE INDEX wifiObservationLocations_latitude ON wifiObservationLocations(latitude);
            """)
        let cursor = try Data.fetchCursor(db, sql: "SELECT payload FROM observations WHERE source = 'wifi'")
        while let data = try cursor.next() {
            try record(JSONDecoder().decode(SensorObservation.self, from: data), db: db)
        }
    }

    static func record(_ observation: SensorObservation, db: Database) throws {
        guard observation.source == .wifi, let ssid = observation.ssid, !ssid.isEmpty,
              let coordinate = observation.usableCoordinate else { return }
        try db.execute(sql: """
            INSERT INTO wifiObservationLocations(observationID, ssid, bssid, timestamp, latitude, longitude, accuracy)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, arguments: [observation.id, ssid, observation.bssid, observation.timestamp.timeIntervalSince1970,
                             coordinate.latitude, coordinate.longitude, observation.horizontalAccuracy ?? 0])
    }

    static func suggestions(near anchor: Coordinate, placeRadius: Double, connected: SensorObservation?, now: Date,
                            networks: [WiFiNetwork], points: [WiFiAccessPoint], places: [Place], db: Database) throws -> [WiFiSuggestion] {
        guard anchor.isValid, placeRadius.isFinite else { return [] }
        // Generous enough for a hotel complex or neighbourhood; never a global SSID list.
        let radius = max(1_500, min(1_000, max(0, placeRadius)) * 2)
        let excluded = Set(networks.filter { [.portable, .ignored].contains($0.classification) }.map(\.ssid))
        var results: [String: WiFiSuggestion] = [:]
        var nearbyAccessPoints: Set<String> = []
        func key(_ ssid: String, _ bssid: String) -> String { ssid + "\u{0}" + bssid.lowercased() }
        func add(_ ssid: String, at date: Date, bssid: String?) {
            guard !ssid.isEmpty, !excluded.contains(ssid) else { return }
            results[ssid] = WiFiSuggestion(ssid: ssid, lastSeen: max(results[ssid]?.lastSeen ?? .distantPast, date))
            if let bssid { nearbyAccessPoints.insert(key(ssid, bssid)) }
        }
        // Latitude narrows the indexed read; geodesic distance also handles poles and the date line.
        let latitudeSpan = (radius + 250) / 110_000
        let rows = try Row.fetchCursor(db, sql: """
            SELECT ssid, bssid, timestamp, latitude, longitude, accuracy FROM wifiObservationLocations
            WHERE latitude BETWEEN ? AND ?
            """, arguments: [anchor.latitude - latitudeSpan, anchor.latitude + latitudeSpan])
        while let row = try rows.next() {
            let coordinate = Coordinate(latitude: row["latitude"], longitude: row["longitude"])
            let accuracy: Double = row["accuracy"]
            if anchor.distance(to: coordinate) <= radius + accuracy {
                add(row["ssid"], at: Date(timeIntervalSince1970: row["timestamp"]), bssid: row["bssid"])
            }
        }
        // Learned access points remain useful while GPS is intentionally asleep.
        // A manually entered expected SSID alone never qualifies as a sighting.
        let networksByID = Dictionary(uniqueKeysWithValues: networks.map { ($0.id, $0) })
        let placesByID = Dictionary(uniqueKeysWithValues: places.map { ($0.id, $0) })
        for point in points {
            guard let placeID = point.placeID, let place = placesByID[placeID],
                  anchor.distance(to: place.coordinate) <= radius,
                  let network = networksByID[point.networkID] else { continue }
            add(network.ssid, at: point.lastSeen, bssid: point.bssid)
        }
        if let connected, connected.source == .wifi,
           (0...60).contains(now.timeIntervalSince(connected.timestamp)),
           let ssid = connected.ssid, !excluded.contains(ssid) {
            let relevant: Bool
            if let coordinate = connected.usableCoordinate {
                // A fresh fix elsewhere outranks a familiar name/access point.
                relevant = anchor.distance(to: coordinate) <= radius + (connected.horizontalAccuracy ?? 0)
            } else {
                relevant = connected.bssid.map { nearbyAccessPoints.contains(key(ssid, $0)) } ?? false
            }
            if relevant {
                add(ssid, at: connected.timestamp, bssid: connected.bssid)
                results[ssid]?.isConnected = true
            }
        }
        return results.values.sorted {
            if $0.isConnected != $1.isConnected { return $0.isConnected }
            if $0.lastSeen != $1.lastSeen { return $0.lastSeen > $1.lastSeen }
            return $0.ssid < $1.ssid
        }
    }
}
