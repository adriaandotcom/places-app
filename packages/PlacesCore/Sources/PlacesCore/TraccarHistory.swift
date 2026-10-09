import Foundation
import CryptoKit
import GRDB

/// Permanent, independent comparison evidence. Never fed to Places inference or companion sync.
public struct TraccarPoint: Codable, Equatable, Identifiable, Sendable {
    public var timestamp: Date
    public var receivedAt: Date
    public var coordinate: Coordinate
    public var accuracy: Double?
    public var altitude: Double?
    public var speed: Double?
    public var bearing: Double?
    public var battery: Int?
    public var charging: Bool?
    public var engineVersion: String

    public init(timestamp: Date, receivedAt: Date = Date(), coordinate: Coordinate, accuracy: Double? = nil,
                altitude: Double? = nil, speed: Double? = nil, bearing: Double? = nil,
                battery: Int? = nil, charging: Bool? = nil, engineVersion: String = "1.1.1-places.1") {
        self.timestamp = timestamp; self.receivedAt = receivedAt; self.coordinate = coordinate
        self.accuracy = accuracy; self.altitude = altitude; self.speed = speed; self.bearing = bearing
        self.battery = battery; self.charging = charging; self.engineVersion = engineVersion
    }
    public var id: String {
        // Redelivery of an identical fix is idempotent, including after a relaunch.
        let values = [timestamp.timeIntervalSince1970, coordinate.latitude, coordinate.longitude,
                      accuracy ?? -1, altitude ?? 0, speed ?? -1, bearing ?? -1]
        return SHA256.hash(data: Data(values.map(String.init(describing:)).joined(separator: ":").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
    public var isValid: Bool {
        coordinate.isValid && timestamp.timeIntervalSince1970.isFinite && receivedAt.timeIntervalSince1970.isFinite
            && [accuracy, altitude, speed, bearing].compactMap { $0 }.allSatisfy(\.isFinite)
            && accuracy.map { $0 >= 0 } != false && speed.map { $0 >= 0 } != false
            && battery.map { (0...100).contains($0) } != false && !engineVersion.isEmpty
    }
}

extension PlacesStore {
    public func appendTraccar(_ point: TraccarPoint) throws {
        guard point.isValid else { throw PlacesError.invalidCorrection }
        try queue.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO traccarPoints(id, timestamp, payload) VALUES (?, ?, ?)",
                arguments: [point.id, point.timestamp.timeIntervalSince1970, try StoreSQL.encode(point)])
        }
    }
    public func traccarPoints(from start: Date, to end: Date) throws -> [TraccarPoint] {
        try queue.read { db in
            try StoreSQL.decodeAll(TraccarPoint.self, db: db,
                sql: "SELECT payload FROM traccarPoints WHERE timestamp >= ? AND timestamp < ? ORDER BY timestamp, id",
                arguments: [start.timeIntervalSince1970, end.timeIntervalSince1970])
        }
    }
    public func firstTraccarDate() throws -> Date? {
        try queue.read { try Double.fetchOne($0, sql: "SELECT MIN(timestamp) FROM traccarPoints").map(Date.init(timeIntervalSince1970:)) }
    }
    public func lastTraccarPoint() throws -> TraccarPoint? {
        try queue.read { try StoreSQL.decodeAll(TraccarPoint.self, db: $0,
            sql: "SELECT payload FROM traccarPoints ORDER BY timestamp DESC, id DESC LIMIT 1").first }
    }
    public func traccarPointCount() throws -> Int {
        try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM traccarPoints") ?? 0 }
    }
}
