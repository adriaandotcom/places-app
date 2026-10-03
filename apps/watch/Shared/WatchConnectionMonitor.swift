import Foundation
import Network
import PlacesCompanion

/// Observes route changes without probing a server, reading network names or polling.
/// Each process (app / complication) checks its own current route before using GPS.
@MainActor final class WatchConnectionMonitor {
    private var monitor: NWPathMonitor?
    private(set) var wifiAvailable: Bool?
    var onChange: (() -> Void)?

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self, weak monitor] path in
            // Also rest on a Wi-Fi route that needs a connection; don't wake it.
            let available = path.status != .unsatisfied || path.usesInterfaceType(.wifi)
            Task { @MainActor in
                guard let self, let monitor, self.monitor === monitor else { return }
                self.wifiAvailable = available
                self.onChange?()
            }
        }
        monitor.start(queue: DispatchQueue(label: "Places.WatchConnection"))
    }

    func stop() {
        monitor?.pathUpdateHandler = nil
        monitor?.cancel(); monitor = nil; wifiAvailable = nil
    }

    func decision(phoneReachable: Bool = false) -> WatchCollectionPolicy.Decision {
        WatchCollectionPolicy.decision(enabled: WatchStorage.enabled, wifiAvailable: wifiAvailable,
            phoneReachable: phoneReachable, lastPhoneContact: WatchStorage.lastPhoneContact)
    }
}
