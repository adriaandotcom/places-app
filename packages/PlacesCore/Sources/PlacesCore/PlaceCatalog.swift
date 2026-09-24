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
    let aliases: [String]
    let confidence: Double
    let venueReferences: Int
    let contextRadius: Double
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
    public static let localSearchRadius = 15_000.0
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
            guard pack.schemaVersion == 3, pack.count > 0, pack.bounds.count == 4,
                  pack.bounds.allSatisfy(\.isFinite), pack.bounds[0] < pack.bounds[2], pack.bounds[1] < pack.bounds[3],
                  pack.filename == "\(pack.id).sqlite", !pack.id.contains("/"), !pack.id.contains("..") else { throw CatalogError.invalidPack }
            let file = directory.appendingPathComponent(pack.filename)
            let digest = SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
            guard digest == pack.sha256 else { throw CatalogError.invalidPack }
            var config = Configuration(); config.readonly = true
            let db = try DatabaseQueue(path: file.path, configuration: config)
            try db.read { db in
                guard try Int.fetchOne(db, sql: "PRAGMA user_version") == 3,
                      try Int.fetchOne(db, sql: "SELECT count(*) FROM places") == pack.count else { throw CatalogError.invalidPack }
            }
            result.append((pack, db))
        }
        loaded = result
        return result
    }

    public func nearby(_ point: Coordinate, limit: Int = 5) throws -> [CatalogPlace] {
        guard point.isValid else { return [] }
        let bounds = Self.bounds(around: point, radius: 3_000)
        var results: [(CatalogPlace, Double)] = []
        for (pack, queue) in try databases() {
            results += try queue.read { db in
                try Row.fetchAll(db, sql: "SELECT * FROM places WHERE latitude BETWEEN ? AND ? AND longitude BETWEEN ? AND ?",
                    arguments: StatementArguments(bounds)).map { row in (decode(row, pack: pack), 0) }
            }
        }
        // A large venue can have an off-site centroid. Its nearby address
        // references establish a context radius, without privileging named IDs
        // or specific categories. These are suggestions, never inferred visits.
        results = results.filter {
            $0.0.confidence >= 0.6 && $0.0.coordinate.distance(to: point) <=
                max(1_000, $0.0.venueReferences >= 3 ? min(3_000, $0.0.contextRadius + 150) : 0)
        }
        let ranked = Self.ranked(results, query: "", near: point, limit: results.count)
        var unique: [CatalogPlace] = []
        for candidate in ranked {
            if unique.count >= max(0, limit) { break }
            guard !unique.contains(where: {
                !Set($0.aliases.map(Self.normalized)).isDisjoint(with: candidate.aliases.map(Self.normalized)) && $0.coordinate.distance(to: candidate.coordinate) < 150
            }) else { continue }
            unique.append(candidate)
        }
        return Array(unique.prefix(max(0, limit)))
    }

    /// A supplied anchor always means local search. Pass nil only when the user
    /// deliberately searches all downloaded regions or has no location context.
    public func search(_ query: String, near point: Coordinate? = nil, limit: Int = 30) throws -> [CatalogPlace] {
        if let point, !point.isValid { return [] }
        let tokens = Self.normalized(String(query.prefix(200))).split { !$0.isLetter && !$0.isNumber }.prefix(10)
        guard !tokens.isEmpty else { return [] }
        let expression = tokens.map { "\"\($0)\"*" }.joined(separator: " AND ")
        var results: [(CatalogPlace, Double)] = []
        for (pack, queue) in try databases() {
            results += try queue.read { db in
                var sql = """
                    SELECT places.*, bm25(search) AS score FROM search JOIN places ON places.rowid = search.rowid
                    WHERE search MATCH ?
                    """
                var arguments: StatementArguments = [expression]
                if let point {
                    sql += " AND latitude BETWEEN ? AND ? AND longitude BETWEEN ? AND ?"
                    arguments += StatementArguments(Self.bounds(around: point, radius: Self.localSearchRadius))
                }
                // Apply the exact radius and rank before limiting. A text-score
                // prefetch limit can otherwise discard the closest match.
                return try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in (decode(row, pack: pack), row["score"]) }
            }
        }
        if let point { results = results.filter { $0.0.coordinate.distance(to: point) <= Self.localSearchRadius } }
        return Self.ranked(results, query: query, near: point, limit: limit)
    }

    static func ranked(_ results: [(CatalogPlace, Double)], query: String, near point: Coordinate?, limit: Int) -> [CatalogPlace] {
        let query = normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        // Compute expensive name folding and distance once per candidate, rather
        // than on every sort comparison while someone is typing.
        let candidates = results.map { place, textScore in
            let name = normalized(place.name)
            let distance = point.map { place.coordinate.distance(to: $0) } ?? 0
            let supportedArea = place.venueReferences >= 3 && distance <= place.contextRadius + 150
            let venueBoost = supportedArea ? 850 * place.confidence * log2(1 + Double(place.venueReferences)) : 0
            let namePrefix = !query.isEmpty && name.hasPrefix(query)
            let score = distance + (1 - place.confidence) * 200 - venueBoost - (namePrefix ? 100 : 0)
            return (place: place, textScore: textScore, exact: !query.isEmpty && name == query, prefix: namePrefix, score: score)
        }
        return Array(candidates.sorted {
            // An explicit venue name still wins, including a gate or shop.
            if $0.exact != $1.exact { return $0.exact }
            if point != nil {
                if $0.score != $1.score { return $0.score < $1.score }
            } else {
                if $0.place.venueReferences != $1.place.venueReferences { return $0.place.venueReferences > $1.place.venueReferences }
                if $0.place.confidence != $1.place.confidence { return $0.place.confidence > $1.place.confidence }
                if $0.prefix != $1.prefix { return $0.prefix }
            }
            if $0.textScore != $1.textScore { return $0.textScore < $1.textScore }
            return $0.place.id < $1.place.id
        }.prefix(max(0, limit)).map(\.place))
    }

    private static func bounds(around point: Coordinate, radius: Double) -> [Double] {
        let latitudeDelta = radius / 111_000
        let longitudeDelta = latitudeDelta / max(0.01, cos(point.latitude * .pi / 180))
        return [point.latitude - latitudeDelta, point.latitude + latitudeDelta,
                point.longitude - longitudeDelta, point.longitude + longitudeDelta]
    }
    private nonisolated func decode(_ row: Row, pack: PlaceCatalogPack) -> CatalogPlace {
        CatalogPlace(reference: .init(sourceID: row["id"], packID: pack.id, release: pack.release), name: row["name"],
            address: row["address"], coordinate: Coordinate(latitude: row["latitude"], longitude: row["longitude"]),
            category: row["category"], region: pack.name,
            aliases: (try? JSONDecoder().decode([String].self, from: Data((row["aliases"] as String).utf8))) ?? [], confidence: row["confidence"],
            venueReferences: row["venueReferences"], contextRadius: row["contextRadius"])
    }
}
