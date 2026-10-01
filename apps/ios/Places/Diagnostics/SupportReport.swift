import Foundation
import PlacesCore

/// Only these fields can leave the diagnostics store. Never encode an NSError,
/// MetricKit payload, OS log, URL, or arbitrary error description in this report.
struct SupportReport: Codable, Sendable {
    let formatVersion: Int
    let scope: String
    let appVersion: String
    let build: String
    let osVersion: String
    let runtime: SupportRuntime
    let counters: DiagnosticReport?
    let diagnostics: SupportSnapshot
    let history: HistoryArchive?

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

struct SupportRuntime: Codable, Sendable {
    var trackingState: String
    var locationAuthorization: Int
    var preciseLocation: Bool
    var photoLocationsEnabled: Bool
    var photoAuthorization: Int
    var macEnabled: Bool
    var watchEnabled: Bool
    var lowPower: Bool
    var historyAvailable: Bool
}

enum SupportEvent: String, Codable, Sendable {
    case launch, foreground, background, photoScanStarted, photoScanFinished, photoScanFailed
    case photoTaskStarted, photoTaskExpired, photoTaskFinished, photoTaskSchedulingFailed
    case companionDeliveryStarted, companionDeliveryFinished, companionFailed, watchDeliveryFailed
    case historyWriteFailed, historyOpenFailed, locationFailed, mapDownloadFailed, appError
}

struct SupportBreadcrumb: Codable, Equatable, Sendable {
    let event: SupportEvent
    let build: String
    let line: UInt?
    let errorKind: String?
    let errorCode: Int?
    var repetitions = 1

    init(_ event: SupportEvent, error: (any Error)? = nil, line: UInt? = nil,
         build: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown") {
        self.event = event; self.build = build; self.line = line
        // Unknown domains can themselves contain personal data. Only retain codes
        // from known system domains; discard userInfo, messages and nested errors.
        if let error {
            let value = error as NSError
            switch value.domain {
            case NSCocoaErrorDomain: errorKind = "cocoa"; errorCode = value.code
            case NSURLErrorDomain: errorKind = "network"; errorCode = value.code
            case "kCLErrorDomain": errorKind = "location"; errorCode = value.code
            case "CKErrorDomain": errorKind = "cloudKit"; errorCode = value.code
            case "WCErrorDomain": errorKind = "watchConnectivity"; errorCode = value.code
            case "GRDB.DatabaseError": errorKind = "database"; errorCode = value.code
            case "BGTaskSchedulerErrorDomain": errorKind = "backgroundTask"; errorCode = value.code
            default: errorKind = "other"; errorCode = nil
            }
        } else { errorKind = nil; errorCode = nil }
    }
}

struct SupportIncident: Codable, Equatable, Sendable {
    enum Kind: String, Codable { case crash, hang, cpu, diskWrites, launch }
    let kind: Kind
    let appVersion: String?
    let build: String?
    let exceptionType: Int?
    let exceptionCode: UInt64?
    let signal: Int?
    let termination: String?
    let stacks: [SupportStack]

    static func version(_ value: String) -> String? {
        guard !value.isEmpty, value.count <= 32,
              value.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) else { return nil }
        return value
    }
    static func terminationCategory(_ reason: String?) -> String? {
        guard let text = reason?.lowercased() else { return nil }
        if text.contains("0x8badf00d") || text.contains("watchdog") { return "watchdog" }
        if text.contains("0xdead10cc") { return "lockedFile" }
        if text.contains("memory") || text.contains("jetsam") { return "memory" }
        return "other"
    }
}

struct SupportStack: Codable, Equatable, Sendable {
    let attributed: Bool
    let frames: [Frame]
    struct Frame: Codable, Equatable, Sendable {
        // A binary UUID identifies a compiled app/framework, never a device or user.
        let binaryUUID: UUID?
        let offset: UInt64?
        let samples: UInt64?
        let parent: Int?
    }

    static func read(_ data: Data) -> [SupportStack] {
        guard data.count <= 8_000_000,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let tree = object["callStackTree"] as? [String: Any] ?? object
        guard let stacks = tree["callStacks"] as? [[String: Any]] else { return [] }
        // Keep the faulting thread even when a process has many other threads.
        let ordered = stacks.filter { $0["threadAttributed"] as? Bool == true }
            + stacks.filter { $0["threadAttributed"] as? Bool != true }
        var remaining = 512
        return ordered.prefix(32).map { stack in
            var frames: [Frame] = []
            func visit(_ values: [[String: Any]], parent: Int?, depth: Int) {
                guard depth < 64 else { return }
                for value in values.prefix(256) where frames.count < 256 && remaining > 0 {
                    remaining -= 1
                    let index = frames.count
                    frames.append(Frame(binaryUUID: (value["binaryUUID"] as? String).flatMap(UUID.init(uuidString:)),
                        offset: number(value["offsetIntoBinaryTextSegment"]), samples: number(value["sampleCount"]), parent: parent))
                    visit(value["subFrames"] as? [[String: Any]] ?? [], parent: index, depth: depth + 1)
                }
            }
            visit(stack["callStackRootFrames"] as? [[String: Any]] ?? [], parent: nil, depth: 0)
            return SupportStack(attributed: stack["threadAttributed"] as? Bool ?? false, frames: frames)
        }
    }
    private static func number(_ value: Any?) -> UInt64? {
        guard let value = value as? NSNumber, value.doubleValue >= 0 else { return nil }
        return value.uint64Value
    }
}

struct SupportExits: Codable, Equatable, Sendable {
    let build: String?
    let foregroundCrashes: Int
    let foregroundWatchdog: Int
    let foregroundMemoryLimit: Int
    let backgroundCrashes: Int
    let backgroundWatchdog: Int
    let backgroundMemoryLimit: Int
    let backgroundMemoryPressure: Int
    let backgroundCPULimit: Int
    let backgroundLockedFile: Int
    let backgroundTaskTimeout: Int
}

struct SupportSnapshot: Codable, Sendable {
    var breadcrumbs: [SupportBreadcrumb] = []
    var incidents: [SupportIncident] = []
    var exitReports: [SupportExits] = []
    var storageAvailable = true
}
