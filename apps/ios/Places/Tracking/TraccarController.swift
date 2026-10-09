import Foundation
import Observation
import UIKit
import CoreLocation
import PlacesCore
@preconcurrency import TraccarClientSDK

/// The SDK's only output is this local store adapter. It has no companion or network access.
@MainActor @Observable
final class TraccarController {
    private(set) var running = false
    private(set) var paused = false
    private(set) var storageFailed = false
    private(set) var lastRecorded: Date?
    private(set) var count = 0
    @ObservationIgnored private var tracker: OfflineTracker?
    @ObservationIgnored private var output: TraccarLocalOutput?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var wanted = false

    func start(store: PlacesStore, changed: @escaping @MainActor () async -> Void) async {
        wanted = true
        let previous = operation
        let next = Task { @MainActor in
            await previous?.value
            guard wanted, tracker == nil else { return }
            do {
                let last = try await store.lastTraccarPoint()
                let wasPaused = try await store.setting("traccarPaused") == "true"
                let total = try await store.traccarPointCount()
                guard wanted else { return }
                let sink = TraccarLocalOutput(store: store, onPoint: { [weak self] point in
                    self?.lastRecorded = point.timestamp
                    self?.count = (try? await store.traccarPointCount()) ?? self?.count ?? 0
                    await changed()
                }, onPause: { [weak self] value in self?.paused = value }, onFailure: { [weak self] in
                    self?.storageFailed = true; self?.running = false
                    Task { await self?.stop() }
                })
                let engine = OfflineTracker(output: sink, lastPosition: last?.sdkPosition, initiallyPaused: wasPaused)
                output = sink; tracker = engine; count = total; lastRecorded = last?.timestamp
                paused = wasPaused && last != nil; storageFailed = false
                let error: Error? = await withCheckedContinuation { continuation in
                    engine.start { continuation.resume(returning: $0) }
                }
                running = error == nil
                if error != nil { storageFailed = true }
            } catch { storageFailed = true; running = false }
        }
        operation = next
        await next.value
    }

    /// Wait for every accepted SQLite write before reset/restore can replace the database.
    func stop() async {
        wanted = false
        let previous = operation
        let next = Task { @MainActor in
            await previous?.value
            output?.accepting = false
            if let tracker {
                await withCheckedContinuation { continuation in
                    tracker.close { _ in continuation.resume() }
                }
            }
            await output?.drain()
            tracker = nil; output = nil; running = false
            // Region registrations survive process termination. Clean only our
            // region even if the previous process died before an engine was restored.
            let cleanup = CLLocationManager()
            for region in cleanup.monitoredRegions where region.identifier == "traccar.stationary" {
                cleanup.stopMonitoring(for: region)
            }
        }
        operation = next
        await next.value
    }
}

// Kotlin scope and native delegates run on Dispatchers.Main.immediate. The protocol
// predates Swift concurrency; the adapter is main-actor isolated and never crosses it.
@MainActor
final class TraccarLocalOutput: NSObject, @preconcurrency OfflineOutput {
    let store: PlacesStore
    var accepting = true
    var writes: [UUID: Task<Void, Never>] = [:]
    let onPoint: @MainActor (TraccarPoint) async -> Void
    let onPause: @MainActor (Bool) -> Void
    let onFailure: @MainActor () -> Void
    init(store: PlacesStore, onPoint: @escaping @MainActor (TraccarPoint) async -> Void,
         onPause: @escaping @MainActor (Bool) -> Void, onFailure: @escaping @MainActor () -> Void) {
        self.store = store; self.onPoint = onPoint; self.onPause = onPause; self.onFailure = onFailure
    }
    func save(position: Position, completion: @escaping (KotlinBoolean) -> Void) {
        guard accepting, let latitude = position.latitude?.doubleValue, let longitude = position.longitude?.doubleValue else {
            completion(KotlinBoolean(bool: false)); return
        }
        let point = TraccarPoint(timestamp: Date(timeIntervalSince1970: Double(position.time) / 1_000),
            coordinate: Coordinate(latitude: latitude, longitude: longitude), accuracy: position.accuracy?.doubleValue,
            altitude: position.altitude?.doubleValue, speed: position.speed?.doubleValue, bearing: position.bearing?.doubleValue,
            battery: position.battery?.intValue, charging: position.charging?.boolValue)
        let id = UUID()
        let lease = TraccarWriteLease { [weak self] in self?.accepting = false; self?.onFailure() }
        writes[id] = Task { @MainActor in
            defer { writes[id] = nil; lease.end() }
            do {
                try await store.appendTraccar(point)
                lease.end()
                completion(KotlinBoolean(bool: true))
                await onPoint(point)
            } catch { completion(KotlinBoolean(bool: false)); onFailure() }
        }
    }
    func stateChanged(paused: Bool) {
        guard accepting else { return }
        onPause(paused)
        let id = UUID()
        let lease = TraccarWriteLease { [weak self] in self?.accepting = false; self?.onFailure() }
        writes[id] = Task { @MainActor in
            defer { writes[id] = nil; lease.end() }
            do { try await store.setSetting("traccarPaused", value: String(paused)) }
            catch { onFailure() }
        }
    }
    func storageFailed() { onFailure() }
    func drain() async { for task in writes.values { await task.value } }
}

private extension TraccarPoint {
    var sdkPosition: Position {
        Position(latitude: KotlinDouble(double: coordinate.latitude), longitude: KotlinDouble(double: coordinate.longitude),
            accuracy: accuracy.map { KotlinDouble(double: $0) }, time: Int64(timestamp.timeIntervalSince1970 * 1_000),
            altitude: altitude.map { KotlinDouble(double: $0) }, speed: speed.map { KotlinDouble(double: $0) },
            bearing: bearing.map { KotlinDouble(double: $0) }, battery: battery.map { KotlinInt(int: Int32($0)) },
            charging: charging.map { KotlinBoolean(bool: $0) }, alarm: nil)
    }
}

/// Finish a bounded local commit after GPS pauses; never use background time to poll.
@MainActor private final class TraccarWriteLease {
    private var identifier = UIBackgroundTaskIdentifier.invalid
    init(expired: @escaping @MainActor () -> Void) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Save offline comparison") { [weak self] in
            Task { @MainActor in self?.end(); expired() }
        }
    }
    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier); identifier = .invalid
    }
}
