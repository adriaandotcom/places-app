import Foundation
import CryptoKit
import GRDB

public struct PlaceCatalogReference: Codable, Hashable, Sendable {
    public let sourceID: String
    public let packID: String
    public let release: String
    public init(sourceID: String, packID: String, release: String) {
        self.sourceID = sourceID; self.packID = packID; self.release = release
    }
    public func savedPlace(in places: [Place]) -> Place? {
        places.first { $0.catalogReference?.sourceID == sourceID }
    }
}

public struct PlaceCatalogPack: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    /// West, south, east, north. Regional coverage, not a claim of complete POI coverage.
    public let bounds: [Double]
    public let schemaVersion: Int
    public let release: String
    public let count: Int
    public let filename: String
    public let sha256: String
    public func contains(_ coordinate: Coordinate) -> Bool {
        bounds.count == 4 && coordinate.isValid && bounds[0] <= coordinate.longitude
            && coordinate.longitude <= bounds[2] && bounds[1] <= coordinate.latitude && coordinate.latitude <= bounds[3]
    }
}

public struct CatalogPlace: Identifiable, Sendable {
    public let reference: PlaceCatalogReference
    public var id: String { reference.sourceID }
    public let name: String
    public let address: String
    public let coordinate: Coordinate
    public let category: String
    public let region: String
    public var categoryTitle: String { category.replacingOccurrences(of: "_", with: " ").capitalized }
    public var symbol: String {
        let mappings = [("airport", "airplane"), ("hotel", "bed.double.fill"), ("resort", "bed.double.fill"),
                        ("cafe", "cup.and.saucer.fill"), ("coffee", "cup.and.saucer.fill"),
                        ("restaurant", "fork.knife"), ("bar", "wineglass.fill"), ("bakery", "birthday.cake.fill"),
                        ("museum", "building.columns.fill"), ("beach", "beach.umbrella.fill"),
                        ("park", "tree.fill"), ("supermarket", "cart.fill"), ("pharmacy", "pills.fill"),
                        ("hospital", "cross.case.fill"), ("shop", "bag.fill"), ("store", "bag.fill"),
                        ("gym", "dumbbell.fill"), ("school", "graduationcap.fill"), ("ferry", "ferry.fill")]
        return mappings.first { category.contains($0.0) }?.1 ?? "mappin"
    }
}

/// Read-only public data, isolated from the private history database. All I/O stays on this actor.
public actor PlaceCatalog {
    public static let shared = PlaceCatalog()
    private let directory: URL?
    private var loaded: [(PlaceCatalogPack, DatabaseQueue)]?
    public init(directory: URL? = nil) {
        self.directory = directory ?? Bundle.module.url(forResource: "PlaceCatalog", withExtension: nil)
    }
    public enum CatalogError: Error { case unavailable, invalidPack }

    public static func normalized(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased().replacingOccurrences(of: "ς", with: "σ").replacingOccurrences(of: "ß", with: "ss")
    }
    public func packs() throws -> [PlaceCatalogPack] { try databases().map(\.0) }
    public func covers(_ point: Coordinate) throws -> Bool { try packs().contains { $0.contains(point) } }
    public func attribution() throws -> String {
        guard let directory else { throw CatalogError.unavailable }
        return try String(contentsOf: directory.appendingPathComponent("LICENSES.txt"), encoding: .utf8)
    }

    private func databases() throws -> [(PlaceCatalogPack, DatabaseQueue)] {
        if let loaded { return loaded }
        guard let directory else { throw CatalogError.unavailable }
        let packs = try JSONDecoder().decode([PlaceCatalogPack].self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        guard !packs.isEmpty else { throw CatalogError.invalidPack }
        var result: [(PlaceCatalogPack, DatabaseQueue)] = []
        for pack in packs {
            guard pack.schemaVersion == 1, pack.count > 0, pack.bounds.count == 4,
                  pack.bounds.allSatisfy(\.isFinite), pack.bounds[0] < pack.bounds[2], pack.bounds[1] < pack.bounds[3],
                  pack.filename == "\(pack.id).sqlite", !pack.id.contains("/"), !pack.id.contains("..") else { throw CatalogError.invalidPack }
            let file = directory.appendingPathComponent(pack.filename)
            let digest = SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
            guard digest == pack.sha256 else { throw CatalogError.invalidPack }
            var config = Configuration(); config.readonly = true
            let db = try DatabaseQueue(path: file.path, configuration: config)
            try db.read { db in
                guard try Int.fetchOne(db, sql: "PRAGMA user_version") == 1,
                      try Int.fetchOne(db, sql: "SELECT count(*) FROM places") == pack.count else { throw CatalogError.invalidPack }
            }
            result.append((pack, db))
        }
        loaded = result
        return result
    }

    public func nearby(_ point: Coordinate, limit: Int = 5) throws -> [CatalogPlace] {
        guard point.isValid else { return [] }
        let latitudeDelta = 1_000.0 / 111_000
        let longitudeDelta = latitudeDelta / max(0.01, cos(point.latitude * .pi / 180))
        var results: [CatalogPlace] = []
        for (pack, queue) in try databases() where pack.contains(point) {
            results += try queue.read { db in
                try Row.fetchAll(db, sql: "SELECT * FROM places WHERE latitude BETWEEN ? AND ? AND longitude BETWEEN ? AND ?",
                    arguments: [point.latitude - latitudeDelta, point.latitude + latitudeDelta,
                                point.longitude - longitudeDelta, point.longitude + longitudeDelta]).map { row in decode(row, pack: pack) }
            }
        }
        return Array(results.filter { $0.coordinate.distance(to: point) <= 1_000 }.sorted {
            let a = $0.coordinate.distance(to: point), b = $1.coordinate.distance(to: point)
            return a == b ? $0.id < $1.id : a < b
        }.prefix(max(0, limit)))
    }

    public func search(_ query: String, near point: Coordinate? = nil, limit: Int = 30) throws -> [CatalogPlace] {
        let tokens = Self.normalized(String(query.prefix(200))).split { !$0.isLetter && !$0.isNumber }.prefix(10)
        guard !tokens.isEmpty else { return [] }
        let expression = tokens.map { "\"\($0)\"*" }.joined(separator: " AND ")
        var results: [(CatalogPlace, Double)] = []
        for (pack, queue) in try databases() {
            results += try queue.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT places.*, bm25(search) AS score FROM search JOIN places ON places.rowid = search.rowid
                    WHERE search MATCH ? ORDER BY score, places.id LIMIT 100
                    """, arguments: [expression]).map { row in (decode(row, pack: pack), row["score"]) }
            }
        }
        let normalized = Self.normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        return Array(results.sorted {
            let a = Self.normalized($0.0.name), b = Self.normalized($1.0.name)
            let aRank = a == normalized ? 0 : a.hasPrefix(normalized) ? 1 : 2
            let bRank = b == normalized ? 0 : b.hasPrefix(normalized) ? 1 : 2
            if aRank != bRank { return aRank < bRank }
            if let point, point.isValid {
                let da = $0.0.coordinate.distance(to: point), db = $1.0.coordinate.distance(to: point)
                if da != db { return da < db }
            }
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.0.id < $1.0.id
        }.prefix(max(0, limit)).map(\.0))
    }
    private nonisolated func decode(_ row: Row, pack: PlaceCatalogPack) -> CatalogPlace {
        CatalogPlace(reference: .init(sourceID: row["id"], packID: pack.id, release: pack.release), name: row["name"],
            address: row["address"], coordinate: Coordinate(latitude: row["latitude"], longitude: row["longitude"]),
            category: row["category"], region: pack.name)
    }
}
