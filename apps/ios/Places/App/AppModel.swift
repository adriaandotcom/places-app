import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import PlacesCore

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()
    let tracking = TrackingController()
    private(set) var store: PlacesStore?
    private(set) var ready = false
    private(set) var waitingForUnlock = false
    private(set) var places: [Place] = []
    private(set) var timeline: [TimelineItem] = []
    private(set) var historyRevision = 0
    private(set) var networks: [WiFiNetwork] = []
    private(set) var accessPoints: [WiFiAccessPoint] = []
    private(set) var recentObservations: [SensorObservation] = []
    private(set) var events: [TrackingEvent] = []
    private(set) var routePoints: [RoutePoint] = []
    private(set) var diagnostics: DiagnosticReport?
    private(set) var mapsEnabled = false
    private(set) var mapsChoiceMade = false
    private(set) var nerdMode = false
    private(set) var trackingEnabled = true
    private(set) var onboardingComplete = false
    private(set) var mapPeriod: HistoryPeriod?
    private(set) var mapTimeline: [TimelineItem] = []
    private(set) var mapRoutePoints: [RoutePoint] = []
    private(set) var placeLookupEnabled = false
    private(set) var placeLookupExplained = false
    private(set) var lookingUpRegions = false
    private(set) var regionLookupIssues: [String: String] = [:]
    private let regionLookup = ApplePlaceLookup()
    private var lookupPreference = UUID()
    private var regionRun = UUID()
    private var regionTask: Task<Void, Never>?
    private var regionAttempts: Set<String> = []
    var selectedDay = Date()
    var selectedTab = AppTab.timeline
    var searchText = ""
    var searchResults: [Place] = []
    var errorMessage: String?
    var exportDocument: JSONDocument?
    var exportFilename = "Places"
    var showExporter = false
    private var pendingWrite: Task<Void, Never>?
    private var retryObservations: [SensorObservation] = []
    private var generation = 0
    private var deleting = false
    private var starting = false

    var uiTesting: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--ui-testing")
        #else
        false
        #endif
    }

    func start() {
        guard !starting, store == nil else { return }
        starting = true
        do {
            let opened = try uiTesting ? PlacesStore() : ProtectedStorage.open()
            store = opened; waitingForUnlock = false
            tracking.onObservations = { [weak self] values in self?.enqueue(values) }
            tracking.onEvent = { [weak self] event in self?.enqueue(event) }
            Task {
                do {
                    mapsEnabled = try await opened.setting("mapsEnabled") == "true"
                    mapsChoiceMade = try await opened.setting("mapsChoiceMade") == "true" || mapsEnabled
                    nerdMode = try await opened.setting("nerdMode") == "true"
                    trackingEnabled = try await opened.setting("trackingEnabled") != "false"
                    onboardingComplete = try await opened.setting("onboardingComplete") == "true"
                    #if DEBUG
                    if uiTesting && ProcessInfo.processInfo.arguments.contains("--ui-nearby-wifi") {
                        try await DemoFixtures.seedNearbyWiFi(opened)
                        onboardingComplete = true
                    } else if uiTesting && ProcessInfo.processInfo.arguments.contains("--ui-wifi-recovery") {
                        try await DemoFixtures.seedWiFiRecovery(opened)
                        onboardingComplete = true
                    } else if uiTesting && ProcessInfo.processInfo.arguments.contains("--ui-grouped-history") {
                        try await DemoFixtures.seedGroupedHistory(opened)
                        onboardingComplete = true
                    } else if uiTesting && ProcessInfo.processInfo.arguments.contains("--ui-airport-stay") {
                        try await DemoFixtures.seedUnnamedStay(opened, withSavedPlace: false,
                            coordinate: Coordinate(latitude: 36.8014, longitude: 27.0906))
                        onboardingComplete = true
                    } else if uiTesting && ProcessInfo.processInfo.arguments.contains("--ui-unnamed-stay") {
                        try await DemoFixtures.seedUnnamedStay(opened, withSavedPlace: ProcessInfo.processInfo.arguments.contains("--ui-saved-place"))
                        onboardingComplete = true
                    } else if uiTesting && ProcessInfo.processInfo.arguments.contains("--ui-fixture") {
                        try await DemoFixtures.seed(opened); onboardingComplete = true
                    }
                    #endif
                    let lookupConsent = try await opened.setting("placeLookupEnabled") == "true"
                    placeLookupExplained = try await opened.setting("placeLookupExplained") == "true" || lookupConsent
                    if lookupConsent { try await opened.setSetting("placeLookupExplained", value: "true") }
                    placeLookupEnabled = mapsEnabled && lookupConsent
                    regionLookup.setEnabled(placeLookupEnabled && !uiTesting)
                    await refresh()
                    enrichRegions()
                    ready = true; starting = false
                    if !uiTesting { tracking.configure(places: places, enabled: trackingEnabled) }
                    await tracking.refreshNotifications()
                } catch { store = nil; starting = false; fail("Could not open your history. Your existing data has been kept. Code: \(PlacesStore.failureCode(error)).") }
            }
        } catch is ProtectedStorage.Locked {
            starting = false; waitingForUnlock = true
        } catch { starting = false; fail("Could not open your history. Your existing data has been kept. Code: \(PlacesStore.failureCode(error)).") }
    }

    func refresh() async {
        guard let store else { return }
        let day = selectedDay
        let period = mapPeriod
        let expectedGeneration = generation
        do {
            let newPlaces = try await store.places()
            let newTimeline = try await store.timeline(on: day)
            let calendar = Calendar.current
            let interval = calendar.dateInterval(of: .day, for: day)!
            let newPoints = try await store.routePoints(from: interval.start, to: interval.end)
            let mapItems: [TimelineItem]
            let mapPoints: [RoutePoint]
            if let period {
                mapItems = try await store.timeline(in: period.interval)
                mapPoints = try await store.routePoints(from: period.interval.start, to: period.interval.end)
            } else { mapItems = newTimeline; mapPoints = newPoints }
            let newNetworks = try await store.networks()
            let newAccessPoints = try await store.accessPoints()
            let newDiagnostics = try await store.diagnostics()
            let newObservations = nerdMode ? try await store.observations(limit: 80) : []
            let newEvents = nerdMode ? try await store.trackingEvents(limit: 60) : []
            guard !deleting, generation == expectedGeneration else { return }
            places = newPlaces; networks = newNetworks; accessPoints = newAccessPoints; diagnostics = newDiagnostics
            if !uiTesting { tracking.updateWiFiKnowledge(places: newPlaces, networks: newNetworks, accessPoints: newAccessPoints) }
            if day == selectedDay { timeline = newTimeline; routePoints = newPoints }
            if day == selectedDay && period == mapPeriod { mapTimeline = mapItems; mapRoutePoints = mapPoints }
            recentObservations = nerdMode ? newObservations : []
            events = nerdMode ? newEvents : []
            historyRevision += 1
        } catch { fail("Could not read your history. Please try again.") }
    }
    func selectDay(_ day: Date) {
        selectedDay = min(day, Date()); mapPeriod = nil
        Task { await refresh() }
    }
    func selectPeriod(_ period: HistoryPeriod) {
        mapPeriod = period
        Task { await refresh() }
    }
    func shiftDay(_ offset: Int, fromMap: Bool = false) {
        let anchor = fromMap ? (mapPeriod?.interval.start ?? selectedDay) : selectedDay
        if let day = Calendar.current.date(byAdding: .day, value: offset, to: anchor) { selectDay(day) }
    }
    func split(_ item: TimelineItem, selecting ids: Set<String>) async -> Bool {
        guard let store else { return false }
        do { try await store.split(item, selecting: ids); await refresh(); return true }
        catch { fail("Could not split these entries. Please try again."); return false }
    }
    func place(for item: TimelineItem) -> Place? { places.first { $0.id == item.placeID } }
    func endpointName(_ endpoint: TimelineConnection.Endpoint, fallback: String) -> String {
        places.first { $0.id == endpoint.placeID }?.name ?? fallback
    }

    func setCombined(_ item: TimelineItem, combined: Bool) async -> Bool {
        guard let store else { return false }
        do {
            if combined { try await store.mergeAdjacent(to: item) }
            else { try await store.split(item) }
            await refresh()
            return true
        } catch { fail("Could not update these entries. Please try again."); return false }
    }

    private func enqueue(_ values: [SensorObservation]) {
        guard let store, !deleting, !values.isEmpty else { return }
        let previous = pendingWrite, expectedGeneration = generation
        pendingWrite = Task { [weak self] in
            await previous?.value
            guard let self, self.generation == expectedGeneration, !self.deleting else { return }
            let batch = self.retryObservations + values
            do {
                try await store.append(batch)
                self.retryObservations = []
                await self.refresh()
            } catch {
                self.retryObservations = batch
                self.tracking.configure(places: self.places, enabled: false)
                self.fail("Recording paused because your history could not be saved. Free some storage and tap Retry in Settings. Unsaved observations are kept while the app remains open.")
            }
        }
    }
    private func enqueue(_ event: TrackingEvent) {
        guard let store, !deleting else { return }
        let previous = pendingWrite, expectedGeneration = generation
        pendingWrite = Task { [weak self] in
            await previous?.value
            guard let self, self.generation == expectedGeneration, !self.deleting else { return }
            do { try await store.record(event) }
            catch { self.fail("Some local tracking diagnostics could not be saved.") }
        }
    }
    func retryStorage() async {
        guard let store else { start(); return }
        await pendingWrite?.value
        do {
            try await store.append(retryObservations); retryObservations = []
            if !uiTesting { tracking.configure(places: places, enabled: trackingEnabled) }
            errorMessage = nil; await refresh()
        } catch { fail("Storage is still unavailable. Your history has not been deleted.") }
    }
    func finishOnboarding() async {
        guard let store else { return }
        do {
            try await store.setSetting("onboardingComplete", value: "true")
            await setTrackingEnabled(true)
            onboardingComplete = true
        }
        catch { fail("Could not save onboarding progress. Please try again.") }
    }
    func setMapsEnabled(_ value: Bool) async {
        // Revoke immediately, even when a disk write fails. Only enable after persistence succeeds.
        if !value { mapsEnabled = false; await setPlaceLookupEnabled(false) }
        do {
            guard let store else { return }
            try await store.setSetting("mapsEnabled", value: String(value))
            try await store.setSetting("mapsChoiceMade", value: "true")
            mapsChoiceMade = true; mapsEnabled = value
        }
        catch { fail("Could not save your map preference. Apple Maps remains off for this session."); mapsEnabled = false }
    }
    func setPlaceLookupEnabled(_ value: Bool) async {
        let preference = UUID(); lookupPreference = preference
        if !value {
            placeLookupEnabled = false; regionLookup.setEnabled(false)
            regionRun = UUID(); regionTask?.cancel(); regionTask = nil; lookingUpRegions = false
            regionAttempts = []
        }
        do {
            guard let store, !value || mapsEnabled else { return }
            try await store.setSetting("placeLookupEnabled", value: String(value))
            if value { try await store.setSetting("placeLookupExplained", value: "true") }
            guard lookupPreference == preference, !deleting, !value || mapsEnabled else { return }
            placeLookupEnabled = value
            if value { placeLookupExplained = true }
            regionLookup.setEnabled(value && !uiTesting)
            if value { enrichRegions() }
        } catch { fail("Could not save your city lookup preference.") }
    }
    func enrichRegions() {
        guard placeLookupEnabled, mapsEnabled, !uiTesting, regionTask == nil, let store else { return }
        let expectedGeneration = generation
        lookingUpRegions = true
        let run = UUID(); regionRun = run
        regionTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.regionRun == run { self.lookingUpRegions = false; self.regionTask = nil } }
            // Read the latest list each time so a newly saved place joins this queue.
            while let place = self.places.first(where: { $0.locality == nil && !self.regionAttempts.contains("\($0.id)-\($0.coordinate)") }) {
                guard !Task.isCancelled, self.placeLookupEnabled, self.mapsEnabled, self.generation == expectedGeneration else { return }
                self.regionAttempts.insert("\(place.id)-\(place.coordinate)")
                do {
                    let locality = try await self.regionLookup.lookup(place.coordinate)
                    guard !Task.isCancelled, self.placeLookupEnabled, self.mapsEnabled, self.generation == expectedGeneration else { return }
                    if let locality {
                        do {
                            try await store.saveLocality(locality, for: place.id, at: place.coordinate)
                            self.regionLookupIssues[place.id] = nil
                            await self.refresh()
                        } catch {
                            self.regionLookupIssues[place.id] = "The names were found, but couldn’t be saved. Please try again."
                        }
                    } else {
                        self.regionLookupIssues[place.id] = "Apple couldn’t find a city or country here. You can enter them when editing this place."
                    }
                } catch {
                    guard !Task.isCancelled, self.placeLookupEnabled, self.generation == expectedGeneration else { return }
                    self.regionLookupIssues[place.id] = "The lookup couldn’t finish. Check your connection and try again."
                }
            }
        }
    }
    func retryRegionLookup() {
        guard !lookingUpRegions else { return }
        regionAttempts = []; regionLookupIssues = [:]; enrichRegions()
    }
    func setNerdMode(_ value: Bool) async {
        do { try await store?.setSetting("nerdMode", value: String(value)); nerdMode = value; await refresh() }
        catch { fail("Could not save this setting.") }
    }
    func setTrackingEnabled(_ value: Bool) async {
        if !value { tracking.configure(places: places, enabled: false) }
        do {
            try await store?.setSetting("trackingEnabled", value: String(value)); trackingEnabled = value
            if !uiTesting { tracking.configure(places: places, enabled: value) }
        } catch { fail("Could not save your tracking preference.") }
    }
    func save(_ place: Place, assigning item: TimelineItem? = nil) async -> Bool {
        guard let store else { fail("Your history is not available yet. Please try again."); return false }
        do {
            let edit = item.map {
                UserOverride(start: $0.start, end: max($0.end ?? Date(), $0.start.addingTimeInterval(1)),
                             kind: .stay, placeID: place.id)
            }
            try await store.savePlace(place, assigning: edit); await refresh(); enrichRegions()
            if !uiTesting { tracking.configure(places: places, enabled: trackingEnabled) }
            return true
        } catch let error as PlacesError { fail(error.localizedDescription); return false }
        catch { fail("Could not save this place. Your changes are still in the form."); return false }
    }
    func classify(_ network: WiFiNetwork, as classification: WiFiClassification) async {
        do { try await store?.classifyNetwork(id: network.id, as: classification); await refresh() }
        catch { fail("Could not save the network classification.") }
    }
    func correct(_ item: TimelineItem, kind: TimelineKind, placeID: String? = nil, mode: TransportMode = .unknown) async -> Bool {
        do {
            let end = item.end ?? Date()
            try await store?.correct(UserOverride(start: item.start, end: max(end, item.start.addingTimeInterval(1)),
                                                 kind: kind, placeID: placeID, mode: mode))
            await refresh(); return true
        } catch { fail("Could not save this correction. Please try again."); return false }
    }
    func search() async {
        let query = searchText
        let expectedGeneration = generation
        do {
            let found = try await store?.search(query) ?? []
            if query == searchText, !deleting, generation == expectedGeneration { searchResults = found }
        } catch { fail("Local search is temporarily unavailable.") }
    }
    func export(fullHistory: Bool) async {
        guard let store else { return }
        let expectedGeneration = generation
        await pendingWrite?.value
        do {
            let data = try await (fullHistory ? store.exportHistory() : store.exportDiagnostics())
            guard !deleting, generation == expectedGeneration else { return }
            exportDocument = JSONDocument(data: data)
            exportFilename = fullHistory ? "Places-history" : "Places-diagnostics"
            showExporter = true
        } catch { fail("Could not prepare the export. Your data has not changed.") }
    }
    func exportTestCase() async {
        guard let store else { return }
        let expectedGeneration = generation
        await pendingWrite?.value
        do {
            let data = try await store.exportTestCase()
            guard !deleting, generation == expectedGeneration else { return }
            exportDocument = JSONDocument(data: data)
            exportFilename = "Places-test-case"
            showExporter = true
        } catch { fail("Could not prepare the test case. Your history has not changed.") }
    }
    func deleteAllDataAndRestart() async -> Bool {
        guard let store, !deleting else { return false }
        deleting = true; generation += 1
        mapsEnabled = false; trackingEnabled = false
        lookupPreference = UUID(); regionLookup.setEnabled(false); placeLookupEnabled = false
        placeLookupExplained = false; regionLookupIssues = [:]
        regionRun = UUID(); regionTask?.cancel(); regionTask = nil; regionAttempts = []; lookingUpRegions = false
        mapPeriod = nil; mapTimeline = []; mapRoutePoints = []
        tracking.configure(places: [], enabled: false)
        await pendingWrite?.value
        do {
            try await store.eraseHistory(resetSettings: true)
            retryObservations = []; timeline = []; places = []; networks = []; accessPoints = []
            routePoints = []; recentObservations = []; events = []; searchResults = []; searchText = ""
            showExporter = false; exportDocument = nil; tracking.clearSensitiveState()
            exportFilename = "Places"; pendingWrite = nil; diagnostics = nil; errorMessage = nil
            mapsChoiceMade = false; nerdMode = false; selectedDay = Date(); selectedTab = .timeline
            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
            onboardingComplete = false
            deleting = false; await refresh()
            return true
        } catch {
            deleting = false; fail("Reset could not finish. Recording remains paused. Please try again.")
            return false
        }
    }
    private func fail(_ message: String) { errorMessage = message }
}

struct JSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

enum AppTab: String, CaseIterable {
    case timeline, map, places, search
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self { case .timeline: "list.bullet.below.rectangle"; case .map: "map"; case .places: "mappin.and.ellipse"; case .search: "magnifyingglass" }
    }
}
