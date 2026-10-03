import CoreLocation

/// One bounded location request during a system-granted execution opportunity.
@MainActor final class WatchLocationSnapshot: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?
    private var timeout: Task<Void, Never>?
    private var linkID: UUID?
    private let connection = WatchConnectionMonitor()
    private var requested = false
    func capture() async -> CLLocation? {
        guard WatchStorage.enabled, let link = try? WatchStorage.link() else { return nil }
        linkID = link.id
        manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        guard manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways else { return nil }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            connection.onChange = { [weak self] in self?.connectionChanged() }
            connection.start()
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                self?.finish(nil)
            }
        }
    }
    private func connectionChanged() {
        switch connection.decision() {
        case .checkingConnection: break
        case .collect:
            guard !requested, continuation != nil else { return }
            requested = true; manager.requestLocation()
        default: finish(nil)
        }
    }
    func cancel() { finish(nil) }
    private func finish(_ location: CLLocation?) {
        timeout?.cancel(); timeout = nil
        manager.stopUpdatingLocation()
        let stillLinked = WatchStorage.enabled && (try? WatchStorage.link()?.id) == linkID
        let allowed = connection.decision() == .collect
        connection.stop()
        continuation?.resume(returning: stillLinked && allowed ? location : nil); continuation = nil
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) { finish(locations.last) }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) { finish(nil) }
}
