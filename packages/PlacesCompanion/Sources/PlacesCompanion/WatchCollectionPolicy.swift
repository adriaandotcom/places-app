import Foundation

/// A live connection is positive evidence of phone availability. Losing live
/// messaging is not proof the phone moved away (watchOS may suspend either app).
public enum WatchCollectionPolicy {
    public enum Decision: Equatable, Sendable {
        case disabled, checkingConnection, phoneAvailable, wifiAvailable, collect
    }

    public static let phoneContactGrace: TimeInterval = 10 * 60

    public static func decision(enabled: Bool, wifiAvailable: Bool?, phoneReachable: Bool,
                                lastPhoneContact: Date?, now: Date = Date()) -> Decision {
        guard enabled else { return .disabled }
        if phoneReachable { return .phoneAvailable }
        if let lastPhoneContact {
            let age = now.timeIntervalSince(lastPhoneContact)
            if age >= 0, age < phoneContactGrace { return .phoneAvailable }
        }
        guard let wifiAvailable else { return .checkingConnection }
        return wifiAvailable ? .wifiAvailable : .collect
    }
}
