import Foundation
import CryptoKit

/// A bundled public archive descriptor. The URL cannot carry history or query parameters.
public struct RoutingPackDownload: Codable, Equatable, Sendable, Identifiable {
    public let country: String
    public let pack: RoutingPack
    public let bytes: Int64
    public let sha256: String
    public var id: String { country + "/" + pack.version }
    public var url: URL {
        var parts = URLComponents()
        parts.scheme = "https"; parts.host = "places-app.b-cdn.net"
        parts.path = "/maps/routing/\(country)/\(pack.version)/valhalla.zip"
        return parts.url!
    }
    public var requiredStorageBytes: Int64 { isValid ? bytes + Int64(pack.bytes) + 32 * 1024 * 1024 : .max }
    public var isValid: Bool {
        !country.isEmpty && country.count <= 80 && country.first != "-" && country.last != "-"
        && country.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
        && !pack.version.isEmpty && pack.version.count <= 64
        && pack.version.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber }
        }
        && pack.engine == "3.9.1" && pack.bytes > 0 && pack.bytes <= 50_000_000_000
        && bytes > 0 && bytes <= Int64(pack.bytes) + 32 * 1024 * 1024
        && [sha256, pack.sha256].allSatisfy { $0.count == 64 && $0.allSatisfy { $0.isHexDigit && !$0.isUppercase } }
    }
    public static func catalog() throws -> [Self] {
        guard let file = Bundle.module.url(forResource: "downloads", withExtension: "json") else { throw Failure.unavailable }
        let entries = try JSONDecoder().decode([Self].self, from: Data(contentsOf: file))
        let graphs = try RoutingPack.catalog()
        guard entries.count <= 100, Set(entries.map(\.id)).count == entries.count,
              entries.allSatisfy({ $0.isValid && graphs.contains($0.pack) }) else { throw Failure.invalid }
        return entries
    }
    public func validate(_ file: URL) throws {
        guard isValid, file.isFileURL,
              let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size >= 0, Int64(size) == bytes else { throw Failure.invalid }
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var digest = SHA256()
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            digest.update(data: chunk)
        }
        guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == sha256 else { throw Failure.invalid }
    }
    public enum Failure: Error { case invalid, unavailable, notEnoughSpace }
}
