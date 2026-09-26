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

public struct MapPack: Codable, Equatable, Identifiable, Sendable {
    public enum ID: String, Codable, CaseIterable, Sendable { case world, netherlands, greece }
    public let id: ID
    public let name: String
    public let version: String
    public let bytes: Int64
    public let sha256: String
    public let minZoom: Int
    public let maxZoom: Int
    public let url: URL
    public let attribution: String
    public var filename: String { "\(id.rawValue)-\(version).pmtiles" }
    public var sizeLabel: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    // A bundled manifest is the only source of download URLs. No coordinates,
    // search terms, identifiers, or history can be appended to the request.
    public var isValid: Bool {
        url.scheme == "https" && url.host == "github.com" && url.user == nil && url.password == nil
        && url.query == nil && url.fragment == nil
        && url.path == "/adriaandotcom/places-app/releases/download/maps-\(version)/\(id.rawValue).pmtiles"
        && !version.isEmpty && version.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") }
        && bytes > 127 && (id != .world || bytes <= 100_000_000)
        && sha256.count == 64 && sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase }
        && minZoom == (id == .world ? 0 : 7) && maxZoom == (id == .world ? 6 : 12)
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
                                  dismissedAt: Date?, now: Date, offeredThisSession: Bool) -> Bool {
        id != .world && zoom >= 8 && !installed.contains(id) && !pending.contains(id) && !offeredThisSession
        && (dismissedAt.map { now.timeIntervalSince($0) >= 7 * 24 * 60 * 60 } ?? true)
    }
}
