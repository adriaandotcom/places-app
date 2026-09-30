import Foundation

public enum CompanionKind: String, Codable, Sendable { case mac, watch }

/// A companion can contribute location evidence, never timeline edits or phone sensor events.
public struct CompanionSample: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var deviceID: UUID
    public var kind: CompanionKind
    public var timestamp: Date
    public var latitude: Double
    public var longitude: Double
    public var accuracy: Double
    public var speed: Double?
    public var timezone: String

    public init(id: UUID = UUID(), deviceID: UUID, kind: CompanionKind, timestamp: Date,
                latitude: Double, longitude: Double, accuracy: Double, speed: Double? = nil,
                timezone: String = TimeZone.current.identifier) {
        self.id = id; self.deviceID = deviceID; self.kind = kind; self.timestamp = timestamp
        self.latitude = latitude; self.longitude = longitude; self.accuracy = accuracy
        self.speed = speed; self.timezone = timezone
    }

    public func isValid(now: Date = Date()) -> Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude)
            && (-180...180).contains(longitude) && accuracy.isFinite && (0...250).contains(accuracy)
            && timestamp.timeIntervalSince1970.isFinite && timestamp <= now.addingTimeInterval(60)
            && timestamp > Date(timeIntervalSince1970: 0)
            && (speed == nil || (speed!.isFinite && (0...400).contains(speed!)))
            && timezone.count <= 100 && TimeZone(identifier: timezone) != nil
    }
}

public struct CompanionBatch: Codable, Identifiable, Equatable, Sendable {
    public let version: Int
    public let id: UUID
    public let linkID: UUID
    public let samples: [CompanionSample]
    public init(id: UUID = UUID(), linkID: UUID, samples: [CompanionSample]) {
        self.version = 1; self.id = id; self.linkID = linkID; self.samples = samples
    }
    public func validate(linkID: UUID, kind: CompanionKind, now: Date = Date()) throws {
        guard version == 1, self.linkID == linkID, (1...64).contains(samples.count),
              Set(samples.map(\.id)).count == samples.count,
              Set(samples.map(\.deviceID)).count == 1,
              samples.allSatisfy({ $0.kind == kind && $0.isValid(now: now) }) else {
            throw CompanionError.invalidPayload
        }
    }
}

public enum CompanionError: Error, Equatable {
    case invalidPayload, missingKey, keychain(Int32), wrongAccount, notLinked, disabled, unsupportedVersion
}
