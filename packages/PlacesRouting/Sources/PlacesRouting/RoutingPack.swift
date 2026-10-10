import Foundation
import CryptoKit
import ZIPFoundation

/// Public routing data only. The bundled catalog pins every accepted graph;
/// imported manifests/configuration cannot authorize arbitrary native graph data.
public struct RoutingPack: Codable, Equatable, Sendable {
    public let name: String
    public let version: String
    public let engine: String
    public let bytes: UInt64
    public let sha256: String
    public let south: Double
    public let west: Double
    public let north: Double
    public let east: Double

    public func contains(latitude: Double, longitude: Double) -> Bool {
        (south...north).contains(latitude) && (west...east).contains(longitude)
    }

    public static func catalog() throws -> [Self] {
        guard let url = Bundle.module.url(forResource: "packs", withExtension: "json") else { throw Failure.invalid }
        return try JSONDecoder().decode([Self].self, from: Data(contentsOf: url))
    }

    public static func installed(in directory: URL) -> Self? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("pack.json")),
              let pack = try? JSONDecoder().decode(Self.self, from: data),
              (try? catalog().contains(pack)) == true,
              let values = try? directory.appendingPathComponent("tiles.tar").resourceValues(forKeys: [.fileSizeKey]),
              UInt64(values.fileSize ?? 0) == pack.bytes else { return nil }
        return pack
    }

    /// Stream a validated ZIP into a staging directory. The host replaces the
    /// active directory only after the old native actor has closed its file map.
    public static func prepare(zip: URL, in directory: URL) throws -> Self {
        try prepare(zip: zip, in: directory, acceptedPacks: catalog())
    }

    static func prepare(zip: URL, in directory: URL, acceptedPacks: [Self]) throws -> Self {
        let size = try zip.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard let maximum = acceptedPacks.map(\.bytes).max(), size > 0,
              UInt64(size) <= maximum + 32 * 1024 * 1024 else { throw Failure.invalid }
        let archive = try Archive(url: zip, accessMode: .read)
        var entries: [Entry] = []
        for entry in archive {
            guard entries.count < 3 else { throw Failure.invalid }
            entries.append(entry)
        }
        guard entries.count == 3, Set(entries.map(\.path)) == ["pack.json", "tiles.tar", "README.txt"],
              entries.allSatisfy({ $0.type == .file }),
              let metadata = archive["pack.json"], metadata.uncompressedSize <= 16_384,
              let tiles = archive["tiles.tar"], let notice = archive["README.txt"], notice.uncompressedSize <= 16_384 else {
            throw Failure.invalid
        }
        var data = Data()
        let crc = try archive.extract(metadata) { chunk in
            guard data.count + chunk.count <= 16_384 else { throw Failure.invalid }
            data.append(chunk)
        }
        let pack = try JSONDecoder().decode(Self.self, from: data)
        guard crc == metadata.checksum, data.count == metadata.uncompressedSize,
              acceptedPacks.contains(pack), pack.bytes == tiles.uncompressedSize, pack.engine == "3.9.1" else {
            throw Failure.invalid
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let available = try directory.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity,
           UInt64(max(0, available)) < pack.bytes + 32 * 1024 * 1024 { throw Failure.notEnoughSpace }
        let destination = directory.appendingPathComponent("tiles.tar")
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw Failure.invalid }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var count: UInt64 = 0, digest = SHA256()
        let graphCRC = try archive.extract(tiles) { chunk in
            try Task.checkCancellation()
            guard UInt64(chunk.count) <= pack.bytes - count else { throw Failure.invalid }
            count += UInt64(chunk.count); digest.update(data: chunk)
            try output.write(contentsOf: chunk)
        }
        let checksum = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard graphCRC == tiles.checksum, count == pack.bytes, checksum == pack.sha256 else { throw Failure.invalid }
        try data.write(to: directory.appendingPathComponent("pack.json"), options: .atomic)
        return pack
    }

    public enum Failure: Error { case invalid, notEnoughSpace }
}
