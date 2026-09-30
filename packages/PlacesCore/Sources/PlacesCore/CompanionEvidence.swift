import Foundation

public enum CompanionEvidence {
    /// A nearby phone fix wins; Watch evidence then wins over a Mac left elsewhere.
    /// Raw evidence is retained, so later phone delivery can revise this projection.
    public static let primaryWindow: TimeInterval = 300

    public static func selected(_ observations: [SensorObservation], places: [Place] = [],
                                networks: [WiFiNetwork] = [], accessPoints: [WiFiAccessPoint] = []) -> [SensorObservation] {
        let sorted = observations.sorted { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) }
        let phone = sorted.filter { $0.companionDevice == nil && ($0.usableCoordinate != nil
            || TrackingPolicy.connectedPlace(for: $0, places: places, networks: networks, accessPoints: accessPoints) != nil) }.map(\.timestamp)
        let watch = sorted.filter { $0.companionDevice == .watch && $0.usableCoordinate != nil }.map(\.timestamp)
        func nearby(_ times: [Date], _ date: Date) -> Bool {
            var low = 0, high = times.count
            let start = date.addingTimeInterval(-primaryWindow)
            while low < high {
                let mid = (low + high) / 2
                if times[mid] < start { low = mid + 1 } else { high = mid }
            }
            return low < times.count && times[low] <= date.addingTimeInterval(primaryWindow)
        }
        return sorted.filter { observation in
            guard let device = observation.companionDevice else { return true }
            guard observation.source == .location, observation.usableCoordinate != nil,
                  observation.companionDeviceID != nil else { return false }
            return !nearby(phone, observation.timestamp)
                && (device != .mac || !nearby(watch, observation.timestamp))
        }
    }
}
