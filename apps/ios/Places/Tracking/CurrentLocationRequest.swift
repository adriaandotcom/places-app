import CoreLocation
import Observation
import Foundation

// A user-initiated, bounded location request, independent of passive history
// tracking. Opening the editor does not start a sensor or request permission.
@MainActor @Observable
final class CurrentLocationRequest: NSObject, @preconcurrency CLLocationManagerDelegate {
    enum Failure: Error, LocalizedError {
        case permission, precision, unavailable
        var errorDescription: String? {
            switch self {
            case .permission: "Allow location access in Settings, then try again."
            case .precision: "Turn on Precise Location in Settings, then try again."
            case .unavailable: "Couldn’t get a clear location. Try again near a window, or choose the location yourself."
            }
        }
    }
    private var manager: CLLocationManager?
    private var continuation: CheckedContinuation<CLLocation, Error>?
    private var timeout: Task<Void, Never>?
    private(set) var isRequesting = false
    private(set) var needsSettings = false
    private var requestedFix = false

    func request() async throws -> CLLocation {
        cancel()
        needsSettings = false; requestedFix = false
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                isRequesting = true
                let manager = CLLocationManager()
                self.manager = manager
                manager.delegate = self
                manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
                requestIfAuthorized(manager)
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }
    func cancel() { finish(.failure(CancellationError())) }
    private func requestIfAuthorized(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            guard manager.accuracyAuthorization == .fullAccuracy else {
                needsSettings = true; finish(.failure(Failure.precision)); return
            }
            if !requestedFix {
                requestedFix = true
                // Core Location can first deliver an old cached sample. Keep this
                // explicit acquisition bounded, and stop at the first usable fix.
                manager.startUpdatingLocation()
                timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(20))
                    guard !Task.isCancelled else { return }
                    self?.finish(.failure(Failure.unavailable))
                }
            }
        case .notDetermined: manager.requestWhenInUseAuthorization()
        default: needsSettings = true; finish(.failure(Failure.permission))
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager === self.manager, continuation != nil else { return }
        // The initial not-determined callback should not launch a second prompt.
        if manager.authorizationStatus != .notDetermined { requestIfAuthorized(manager) }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard manager === self.manager else { return }
        if let location = locations.filter({ $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= 100
            && abs($0.timestamp.timeIntervalSinceNow) <= 30 }).max(by: { $0.timestamp < $1.timestamp }) {
            finish(.success(location))
        }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard manager === self.manager else { return }
        if (error as? CLError)?.code == .locationUnknown { return }
        needsSettings = (error as? CLError)?.code == .denied
        finish(.failure(needsSettings ? Failure.permission : Failure.unavailable))
    }
    private func finish(_ result: Result<CLLocation, Error>) {
        timeout?.cancel(); timeout = nil
        manager?.stopUpdatingLocation(); manager?.delegate = nil; manager = nil
        isRequesting = false
        let pending = continuation; continuation = nil
        pending?.resume(with: result)
    }
}
