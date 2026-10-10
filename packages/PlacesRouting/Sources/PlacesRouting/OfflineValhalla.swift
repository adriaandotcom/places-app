import Foundation
import PlacesRoutingNative

/// Confine an instance to one worker. All native work is synchronous and local.
public final class OfflineValhalla {
    private let native: PLPlacesValhalla

    public init(tileExtract: URL, workspace: URL) throws {
        guard tileExtract.isFileURL, workspace.isFileURL,
              let template = Bundle.module.url(forResource: "config", withExtension: "json"),
              let timezone = Bundle.module.url(forResource: "tzdata", withExtension: nil),
              var config = try JSONSerialization.jsonObject(with: Data(contentsOf: template)) as? [String: Any],
              var mjolnir = config["mjolnir"] as? [String: Any] else { throw Failure.unavailable }
        // Never accept routing configuration from an imported file. No tile_url,
        // remote elevation, telemetry or HTTP client can be supplied by the host.
        mjolnir["tile_extract"] = tileExtract.path
        config["mjolnir"] = mjolnir
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let path = workspace.appendingPathComponent("config.json")
        try JSONSerialization.data(withJSONObject: config).write(to: path, options: .atomic)
        native = try PLPlacesValhalla(configPath: path.path, timezonePath: timezone.path)
    }

    public func traceAttributes(request: String) throws -> String {
        guard request.utf8.count <= 1_000_000 else { throw Failure.invalidRequest }
        return try native.traceAttributes(request)
    }
    public func close() { native.close() }
    public enum Failure: Error { case unavailable, invalidRequest }
}
