import Foundation
import PlacesCore
import zlib

/// Reads park outlines from installed PMTiles metadata. No network lookup.
actor MapParkCatalog {
    static let shared = MapParkCatalog()
    struct Nearby: Sendable { var parks: [MapPark]; var available: Bool }
    private struct Metadata: Decodable {
        struct Areas: Decodable { let version: Int; let parks: [MapPark] }
        let places_areas: Areas?
    }
    private var cache: [URL: [MapPark]] = [:]

    func nearby(_ coordinate: Coordinate, files: [URL]) -> Nearby {
        cache = cache.filter { files.contains($0.key) }
        var available = false
        var parks: [String: MapPark] = [:]
        for file in files {
            let catalog: [MapPark]?
            if let saved = cache[file] { catalog = saved }
            else { catalog = try? Self.read(file); if let catalog { cache[file] = catalog } }
            if let catalog {
                available = true
                for park in catalog where park.area.distance(to: coordinate) <= 3_000 { parks[park.id] = park }
            }
        }
        return Nearby(parks: Array(parks.values.sorted {
            let a = $0.area.distance(to: coordinate), b = $1.area.distance(to: coordinate)
            return a == b ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : a < b
        }.prefix(300)), available: available)
    }

    enum Failure: Error { case invalidMetadata }
    static func read(_ file: URL) throws -> [MapPark] {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 127), header.count == 127,
              header.prefix(7) == Data("PMTiles".utf8), header[7] == 3 else { throw Failure.invalidMetadata }
        func number(_ offset: Int) -> UInt64 {
            (0..<8).reduce(0) { $0 | UInt64(header[offset + $1]) << (8 * $1) }
        }
        let offset = number(24), count = number(32), size = try handle.seekToEnd()
        guard offset >= 127, count > 0, count <= 8_000_000, offset <= size, count <= size - offset else { throw Failure.invalidMetadata }
        try handle.seek(toOffset: offset)
        guard let compressed = try handle.read(upToCount: Int(count)), compressed.count == count else { throw Failure.invalidMetadata }
        let data: Data
        switch header[97] {
        case 1: data = compressed
        case 2: data = try inflateMetadata(compressed)
        default: throw Failure.invalidMetadata
        }
        let metadata = try JSONDecoder().decode(Metadata.self, from: data)
        guard let areas = metadata.places_areas, areas.version == 1, areas.parks.count <= 100_000 else { throw Failure.invalidMetadata }
        return areas.parks.filter { !$0.id.isEmpty && !$0.name.isEmpty && $0.coordinate.isValid && $0.area.isValid }
    }
    private static func inflateMetadata(_ compressed: Data) throws -> Data {
        try compressed.withUnsafeBytes { input in
            var stream = z_stream()
            guard inflateInit2_(&stream, MAX_WBITS + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw Failure.invalidMetadata }
            defer { inflateEnd(&stream) }
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            var result = Data(), buffer = [UInt8](repeating: 0, count: 32_768)
            while true {
                let status = buffer.withUnsafeMutableBytes { output -> Int32 in
                    stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(output.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let count = buffer.count - Int(stream.avail_out)
                guard result.count + count <= 32_000_000 else { throw Failure.invalidMetadata }
                result.append(contentsOf: buffer.prefix(count))
                if status == Z_STREAM_END { guard stream.avail_in == 0 else { throw Failure.invalidMetadata }; return result }
                guard status == Z_OK, count > 0 else { throw Failure.invalidMetadata }
            }
        }
    }
}
