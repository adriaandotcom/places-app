import Foundation

/// Local activity measurements, not an estimate of energy or battery attribution.
public struct EnergySnapshot: Codable, Equatable, Sendable {
    public var sessionID: String
    public var timestamp: Date
    public var standardLocationSeconds: TimeInterval
    public var locationStarts: Int
    public var singleLocationRequests: Int
    public var locationCallbacks: Int
    public var locationSamples: Int
    public var wifiReads: Int
    public var motionCallbacks: Int
    public var batteryLevel: Double?
    public var batteryState: String?
    public var lowPower: Bool?
    public var thermalState: String?
    public var foreground: Bool?
}

public struct EnergyCounters: Sendable {
    private let sessionID = UUID().uuidString
    private var activeSince: TimeInterval?
    private var elapsed: TimeInterval = 0
    public private(set) var locationStarts = 0
    public var singleLocationRequests = 0
    public var locationCallbacks = 0
    public var locationSamples = 0
    public var wifiReads = 0
    public var motionCallbacks = 0
    public init() {}
    public mutating func setStandardLocation(active: Bool, uptime: TimeInterval) {
        if active, activeSince == nil { activeSince = uptime; locationStarts += 1 }
        else if !active, let start = activeSince { elapsed += max(0, uptime - start); activeSince = nil }
    }
    public func snapshot(now: Date = Date(), uptime: TimeInterval) -> EnergySnapshot {
        EnergySnapshot(sessionID: sessionID, timestamp: now,
            standardLocationSeconds: elapsed + (activeSince.map { max(0, uptime - $0) } ?? 0),
            locationStarts: locationStarts, singleLocationRequests: singleLocationRequests,
            locationCallbacks: locationCallbacks, locationSamples: locationSamples, wifiReads: wifiReads, motionCallbacks: motionCallbacks)
    }
}

public struct EnergySummary: Codable, Equatable, Sendable {
    public let sessions: Int
    public let standardLocationSeconds: Double
    public let locationStarts: Int
    public let singleLocationRequests: Int
    public let locationCallbacks: Int
    public let locationSamples: Int
    public let wifiReads: Int
    public let motionCallbacks: Int
    public init(snapshots: [EnergySnapshot]) {
        // Counters are cumulative within a launch. Never count a repeated checkpoint twice,
        // or bridge an unobserved termination/relaunch interval.
        let latest = Dictionary(grouping: snapshots, by: \.sessionID).values.compactMap { $0.max { $0.timestamp < $1.timestamp } }
        sessions = latest.count
        standardLocationSeconds = latest.reduce(0) { $0 + $1.standardLocationSeconds }
        locationStarts = latest.reduce(0) { $0 + $1.locationStarts }
        singleLocationRequests = latest.reduce(0) { $0 + $1.singleLocationRequests }
        locationCallbacks = latest.reduce(0) { $0 + $1.locationCallbacks }
        locationSamples = latest.reduce(0) { $0 + $1.locationSamples }
        wifiReads = latest.reduce(0) { $0 + $1.wifiReads }
        motionCallbacks = latest.reduce(0) { $0 + $1.motionCallbacks }
    }
}
