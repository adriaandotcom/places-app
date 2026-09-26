import Foundation
import PlacesCore

@MainActor enum OfflineMapStyle {
    static let resourceRoot = Bundle.main.url(forResource: "OfflineMaps", withExtension: nil)!
    static let empty = ##"{"version":8,"sources":{},"layers":[{"id":"background","type":"background","paint":{"background-color":"#c6d9d4"}}]}"##

    static func geometry(_ id: MapPack.ID) -> [String: Any]? {
        guard id != .world, let data = try? Data(contentsOf: resourceRoot.appendingPathComponent(id.rawValue + ".geojson")),
              let collection = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = collection["features"] as? [[String: Any]] else { return nil }
        return features.first?["geometry"] as? [String: Any]
    }

    static func make(installed: [MapPack.ID: URL], dark: Bool) throws -> String {
        let data = try Data(contentsOf: resourceRoot.appendingPathComponent(dark ? "style-dark.json" : "style-light.json"))
        guard var style = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let template = style["layers"] as? [[String: Any]] else { return empty }
        var sources: [String: Any] = [:]
        var layers = template.filter { $0["type"] as? String == "background" }
        for id in MapPack.ID.allCases {
            guard let url = installed[id], url.isFileURL else { continue }
            sources[id.rawValue] = ["type": "vector", "url": "pmtiles://" + url.absoluteString,
                "attribution": "© OpenStreetMap contributors · Natural Earth · Protomaps"]
            for var layer in template where layer["source"] != nil {
                let originalID = layer["id"] as? String ?? ""
                layer["id"] = id.rawValue + "-" + originalID; layer["source"] = id.rawValue
                if originalID == "settlements" {
                    var filters: [Any] = ["all", layer["filter"] ?? ["has", "name"]]
                    if id == .world {
                        // Country packs begin at z7. Keep World labels in an
                        // overview, then replace them with local detail at z7+.
                        var overview = layer
                        overview["id"] = "world-settlements-overview"
                        overview["maxzoom"] = 7
                        layers.append(overview)
                        layer["minzoom"] = 7
                        for country in MapPack.ID.allCases where country != .world && installed[country] != nil {
                            if let polygon = geometry(country) { filters.append(["!", ["within", polygon]]) }
                        }
                    } else if let polygon = geometry(id) { filters.append(["within", polygon]) }
                    layer["filter"] = filters
                }
                layers.append(layer)
            }
        }
        // Put labels above every pack's geometry, so country land fills never
        // cover the World labels just outside its boundaries.
        layers = layers.filter { $0["type"] as? String != "symbol" } + layers.filter { $0["type"] as? String == "symbol" }
        style["sources"] = sources; style["layers"] = layers
        style["glyphs"] = resourceRoot.appendingPathComponent("fonts").absoluteString + "/{fontstack}/{range}.pbf"
        return String(decoding: try JSONSerialization.data(withJSONObject: style, options: [.sortedKeys]), as: UTF8.self)
    }
}

// Point-in-polygon on bundled country boundaries. Map browsing never calls a
// geocoder to decide which download to suggest; islands and holes are retained.
@MainActor enum OfflineMapCoverage {
    private static let boundaries: [MapPack.ID: [[[[Double]]]]] = Dictionary(uniqueKeysWithValues: MapPack.ID.allCases.filter { $0 != .world }.compactMap { id in
        guard let geometry = OfflineMapStyle.geometry(id), let raw = geometry["coordinates"] else { return nil }
        let polygons = geometry["type"] as? String == "Polygon" ? [(raw as? [[[Double]]]) ?? []] : (raw as? [[[[Double]]]]) ?? []
        return (id, polygons)
    })

    static func countries(in viewport: MapViewport) -> [MapPack.ID] {
        let south = viewport.center.latitude - viewport.latitudeSpan / 2
        let north = viewport.center.latitude + viewport.latitudeSpan / 2
        let west = viewport.center.longitude - viewport.longitudeSpan / 2
        let east = viewport.center.longitude + viewport.longitudeSpan / 2
        let corners = [Coordinate(latitude: south, longitude: west), Coordinate(latitude: south, longitude: east),
                       Coordinate(latitude: north, longitude: west), Coordinate(latitude: north, longitude: east)]
        let centerCountry = country(at: viewport.center)
        return MapPack.ID.allCases.filter { id in
            guard id != .world else { return false }
            if id == centerCountry || corners.contains(where: { country(at: $0) == id }) { return true }
            return boundaries[id, default: []].contains { polygon in
                guard let ring = polygon.first else { return false }
                // A country island can be visible even when the camera centre is at sea.
                return ring.contains { point in point.count >= 2 && (west...east).contains(point[0]) && (south...north).contains(point[1]) }
            }
        }.sorted { $0 == centerCountry && $1 != centerCountry }
    }

    static func country(at coordinate: Coordinate) -> MapPack.ID? {
        for id in MapPack.ID.allCases where id != .world {
            for polygon in boundaries[id, default: []] {
                guard let outer = polygon.first, contains(coordinate, ring: outer) else { continue }
                if !polygon.dropFirst().contains(where: { contains(coordinate, ring: $0) }) { return id }
            }
        }
        return nil
    }
    private static func contains(_ point: Coordinate, ring: [[Double]]) -> Bool {
        guard ring.count > 2 else { return false }
        var inside = false, previous = ring.last!
        for next in ring {
            guard previous.count >= 2, next.count >= 2 else { return false }
            if (next[1] > point.latitude) != (previous[1] > point.latitude),
               point.longitude < (previous[0] - next[0]) * (point.latitude - next[1]) / (previous[1] - next[1]) + next[0] { inside.toggle() }
            previous = next
        }
        return inside
    }
}
