import CoreLocation

/// One bounded location request during a system-granted execution opportunity.
@MainActor final class WatchLocationSnapshot: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?
    private var timeout: Task<Void, Never>?
    private var linkID: UUID?
    func capture() async -> CLLocation? {
        guard WatchStorage.enabled, let link = try? WatchStorage.link() else { return nil }
        linkID = link.id
        manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        guard manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways else { return nil }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            manager.requestLocation()
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                self?.finish(nil)
            }
        }
    }
    private func finish(_ location: CLLocation?) {
        timeout?.cancel(); timeout = nil
        manager.stopUpdatingLocation()
        let stillLinked = WatchStorage.enabled && (try? WatchStorage.link()?.id) == linkID
        continuation?.resume(returning: stillLinked ? location : nil); continuation = nil
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) { finish(locations.last) }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) { finish(nil) }
}
