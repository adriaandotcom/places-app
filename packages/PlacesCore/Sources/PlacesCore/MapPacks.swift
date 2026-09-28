import Foundation

public enum MapProvider: String, Codable, CaseIterable, Sendable {
    case off, apple, onDevice
    public var title: String {
        switch self { case .off: "Off"; case .apple: "Apple Maps"; case .onDevice: "On-device Maps" }
    }
    public static func migrated(stored: String?, appleEnabled: Bool) -> Self {
        stored.flatMap(Self.init(rawValue:)) ?? (appleEnabled ? .apple : .off)
    }
}

public enum MapDetail: String, Codable, CaseIterable, Sendable {
    case tiny, normal, extensive
    public var title: String { rawValue.capitalized }
    public var summary: String {
        switch self {
        case .tiny: "Streets, water & parks"
        case .normal: "Street names, stations & airports"
        case .extensive: "Buildings, addresses & all available places"
        }
    }
    public var maxZoom: Int { switch self { case .tiny: 12; case .normal: 14; case .extensive: 15 } }
}

public struct MapPack: Codable, Equatable, Identifiable, Sendable {
    public struct ID: RawRepresentable, Hashable, Codable, Sendable {
        public let rawValue: String
        public init?(rawValue: String) {
            guard !rawValue.isEmpty, rawValue.count <= 80, rawValue.first != "-", rawValue.last != "-",
                  rawValue.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }) else { return nil }
            self.rawValue = rawValue
        }
        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let id = Self(rawValue: value) else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid country ID") }
            self = id
        }
        public func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
        public static let world = Self(rawValue: "world")!
        public static let netherlands = Self(rawValue: "netherlands")!
        public static let greece = Self(rawValue: "greece")!
        // Bootstrap packs only. The remote catalog can add countries without an app release.
        public static let bootstrapIDs: [Self] = [.world, .netherlands, .greece]
    }
    public let id: ID
    public let name: String
    public let version: String
    public let bytes: Int64
    public let sha256: String
    public let minZoom: Int
    public let maxZoom: Int
    public let url: URL
    public let attribution: String
    public let detail: MapDetail?
    public let updatedAt: String?
    public let sourceDate: String?
    public let bounds: [Double]?
    public var filename: String { "\(id.rawValue)\(detail.map { "-" + $0.rawValue } ?? "")-\(version).pmtiles" }
    public var updatedDate: Date? {
        if let updatedAt { return ISO8601DateFormatter().date(from: updatedAt) }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMdd"
        return formatter.date(from: String(version.prefix(8)))
    }
    public var sizeLabel: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    // Both catalogs use a fixed allowlist and immutable paths. No coordinates,
    // search terms, device identifiers, or history are part of requests.
    public var isValid: Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil, !version.isEmpty, version.count <= 64,
              version.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              bytes > 127, bytes <= (id == .world ? 100_000_000 : 50_000_000_000),
              sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              minZoom == (id == .world ? 0 : 7), maxZoom == (id == .world ? 6 : (detail?.maxZoom ?? 12)) else { return false }
        if let detail {
            return id != .world && url.host == MapCatalog.host
                && url.path == "/maps/\(id.rawValue)/\(version)/\(detail.rawValue).pmtiles"
                && updatedAt.flatMap({ ISO8601DateFormatter().date(from: $0) }) != nil
                && MapCatalog.validBounds(bounds)
        }
        return ID.bootstrapIDs.contains(id) && url.host == "github.com"
            && url.path == "/adriaandotcom/places-app/releases/download/maps-\(version)/\(id.rawValue).pmtiles"
    }
}

public struct MapCountry: Codable, Identifiable, Equatable, Sendable {
    public let id: MapPack.ID
    public let name: String
    public let countryCode: String?
    public let bounds: [Double]
    public let variants: [MapPack]
}

public struct MapCatalog: Codable, Equatable, Sendable {
    public static let host = "places-app.b-cdn.net"
    public static var url: URL {
        var parts = URLComponents(); parts.scheme = "https"; parts.host = host; parts.path = "/maps/metadata.json"
        return parts.url!
    }
    public let schemaVersion: Int
    public let generatedAt: String?
    public let countries: [MapCountry]
    public var packs: [MapPack] { countries.flatMap(\.variants) }
    public var isValid: Bool {
        schemaVersion == 1 && countries.count <= 500 && Set(countries.map(\.id)).count == countries.count
        && countries.allSatisfy { country in
            country.id != .world && !country.name.isEmpty && country.name.count <= 160 && Self.validBounds(country.bounds)
            && (country.variants.isEmpty || Set(country.variants.compactMap(\.detail)) == Set(MapDetail.allCases))
            && Set(country.variants.compactMap(\.detail)).count == country.variants.count
            && Set(country.variants.map(\.version)).count <= 1
            && country.variants.allSatisfy { $0.id == country.id && $0.name == country.name && $0.bounds == country.bounds && $0.isValid }
        }
    }
    public static func validBounds(_ bounds: [Double]?) -> Bool {
        guard let bounds, bounds.count == 4, bounds.allSatisfy(\.isFinite) else { return false }
        return (-180...180).contains(bounds[0]) && (-180...180).contains(bounds[2])
            && (-90...90).contains(bounds[1]) && (-90...90).contains(bounds[3]) && bounds[0] < bounds[2] && bounds[1] < bounds[3]
    }
}

public enum MapDownloadNetwork: Sendable, Equatable {
    case unavailable, unmetered, needsApproval
    public static func classify(connected: Bool, wifiOrEthernet: Bool, expensive: Bool, constrained: Bool) -> Self {
        if !connected { return .unavailable }
        return wifiOrEthernet && !expensive && !constrained ? .unmetered : .needsApproval
    }
}

public enum MapDownloadPolicy {
    public static func canStart(network: MapDownloadNetwork, approvedMetered: Bool) -> Bool {
        network == .unmetered || (network == .needsApproval && approvedMetered)
    }
    public static func remaining(total: Int64, received: Int64) -> Int64 { max(0, total - max(0, received)) }
    public static func hasSpace(available: Int64, packBytes: Int64) -> Bool {
        // Leave room for the temporary transfer, the installed copy and normal app writes.
        available >= packBytes * 2 + 50_000_000
    }
    public static func canSuggest(id: MapPack.ID, zoom: Double, installed: Set<MapPack.ID>, pending: Set<MapPack.ID>,
                                  dismissedAt: Date?, now: Date, offeredThisSession: Set<MapPack.ID>) -> Bool {
        id != .world && zoom >= 8 && !installed.contains(id) && !pending.contains(id) && !offeredThisSession.contains(id)
        && (dismissedAt.map { now.timeIntervalSince($0) >= 7 * 24 * 60 * 60 } ?? true)
    }
}
