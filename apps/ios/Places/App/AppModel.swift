import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import PlacesCore
import PlacesCompanion

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()
    let tracking = TrackingController()
    let traccar = TraccarController()
    let deleteUndo = DeleteUndo()
    private(set) var store: PlacesStore?
    private(set) var ready = false
    private(set) var waitingForUnlock = false
    private(set) var storageNeedsRetry = false
    private(set) var places: [Place] = []
    private(set) var memories = MemoryLibrary()
    var memoryEpoch: Int { generation }
    private(set) var timeline: [TimelineItem] = []
    private(set) var historyRevision = 0
    private(set) var historyDays: [HistoryDay] = []
    private(set) var firstHistoryDate: Date?
    private(set) var firstTraccarDate: Date?
    var firstMapDate: Date? { nerdMode && showTraccarPoints ? [firstHistoryDate, firstTraccarDate].compactMap { $0 }.min() : firstHistoryDate }
    private(set) var networks: [WiFiNetwork] = []
    private(set) var accessPoints: [WiFiAccessPoint] = []
    private(set) var recentObservations: [SensorObservation] = []
    private(set) var events: [TrackingEvent] = []
    private(set) var routePoints: [RoutePoint] = []
    private(set) var diagnostics: DiagnosticReport?
    private(set) var mapProvider = MapProvider.off
    var mapsEnabled: Bool { mapProvider == .apple }
    var mapsAvailable: Bool { mapProvider != .off }
    let mapDownloads: MapDownloads = {
        #if DEBUG
        MapDownloads(testing: ProcessInfo.processInfo.arguments.contains("--ui-testing"))
        #else
        MapDownloads()
        #endif
    }()
    private var mapPreference = UUID()
    private(set) var mapsChoiceMade = false
    private(set) var nerdMode = false
    private(set) var traccarEnabled = false
    private(set) var showPlacesPoints = true
    private(set) var showTraccarPoints = true
    private(set) var trackingEnabled = true
    private(set) var onboardingComplete = false
    private(set) var replayingOnboarding = false
    private var mapSelectionRequest = UUID()
    private(set) var mapFocusRequest = UUID()
    private(set) var mapViewport: MapViewport?
    private(set) var mapPeriod: HistoryPeriod?
    private(set) var mapTimeline: [TimelineItem] = []
    private(set) var mapRoutePoints: [RoutePoint] = []
    private(set) var mapRawPresentation: MapPresentation?
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
    var librarySection = "Places"
    var navigationRoots: [AppTab: UUID] = [:]
    func openMainTab(_ tab: AppTab) {
        navigationRoots[tab] = UUID()
        selectedTab = tab
    }
    func showPeople() {
        librarySection = "People"
        openMainTab(.places)
    }
    let rewindNotifications = RewindNotifications()
    var rewindRequest: RewindRequest?
    private(set) var monthlyRewindReminders = false
    private(set) var weeklyReviewReminders = false
    var rewindMonths: [Date] {
        let calendar = Calendar.current
        let dates = historyDays.map(\.date) + memories.memories.map(\.date) + memories.trips.filter { !$0.hidden }.map(\.start) + [Date()]
        return Set(dates.filter { $0 <= Date() }.compactMap { calendar.dateInterval(of: .month, for: $0)?.start }).sorted(by: >)
    }
    var defaultRewindMonth: Date {
        let current = Calendar.current.dateInterval(of: .month, for: Date())!.start
        return rewindMonths.first { $0 < current } ?? current
    }
    var searchText = ""
    func offersPastVisits(on day: Date) -> Bool {
        let calendar = Calendar.current
        guard calendar.startOfDay(for: day) < calendar.startOfDay(for: Date()) else { return false }
        return historyDays.first.map { calendar.startOfDay(for: day) < calendar.startOfDay(for: $0.date) } ?? true
    }
    func importPastVisits(_ drafts: [PastVisitDraft], reviewed: PastVisitPlan, at date: Date,
                          memory: PastVisitMemory?, epoch: Int) async throws {
        guard let store, !deleting, epoch == generation else { throw CancellationError() }
        await pendingWrite?.value
        guard epoch == generation, !deleting else { throw PastVisitImportError.invalidSelection }
        try await store.importPastVisits(drafts, reviewed: reviewed, now: date, memory: memory)
        guard epoch == generation, !deleting else { throw CancellationError() }
        if let start = reviewed.visits.flatMap(\.intervals).map(\.start).min() {
            selectedDay = start; mapPeriod = nil; mapSelectionRequest = UUID()
            mapRawPresentation = nil
        }
        await refresh()
    }
    var searchResults: [Place] = []
    var errorMessage: String?
    var exportDocument: HistoryDocument?
    var exportFilename = "Places"
    var showExporter = false
    private var pendingWrite: Task<Void, Never>?
    let companions = PhoneCompanions()
    let photoLibrary: PhotoLibraryEvidence = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") && ProcessInfo.processInfo.arguments.contains("--ui-photo-suggestions") {
            return PhotoLibraryEvidence(currentModel: "Preview iPhone")
        }
        #endif
        return PhotoLibraryEvidence()
    }()
    private var retryObservations: [SensorObservation] = []
    private var generation = 0
    private var deleting = false
    private var starting = false
    private var startupTask: Task<Void, Never>?

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
        rewindNotifications.onOpen = { [weak self] request in self?.rewindRequest = request }
        do {
            let opened = try uiTesting ? PlacesStore() : ProtectedStorage.open()
            try MemoryPhotoDraft.clearAbandonedImports()
            try BackupTransferView.clearAbandonedTransfers()
            store = opened; waitingForUnlock = false
            tracking.onObservations = { [weak self] values in self?.enqueue(values) }
            tracking.onEvent = { [weak self] event in self?.enqueue(event) }
            startupTask = Task {
                do {
                    let legacyMaps = try await opened.setting("mapsEnabled") == "true"
                    let savedProvider = try await opened.setting("mapProvider")
                    mapProvider = MapProvider.migrated(stored: savedProvider, appleEnabled: legacyMaps)
                    try await opened.setSetting("mapProvider", value: mapProvider.rawValue)
                    mapDownloads.start()
                    mapsChoiceMade = try await opened.setting("mapsChoiceMade") == "true" || mapsAvailable
                    nerdMode = try await opened.setting("nerdMode") == "true"
                    traccarEnabled = try await opened.setting("traccarEnabled") == "true"
                    showPlacesPoints = try await opened.setting("showPlacesPoints") != "false"
                    showTraccarPoints = try await opened.setting("showTraccarPoints") != "false"
                    monthlyRewindReminders = try await opened.setting("monthlyRewindReminders") == "true"
                    weeklyReviewReminders = try await opened.setting("weeklyReviewReminders") == "true"
                    trackingEnabled = try await opened.setting("trackingEnabled") != "false"
                    onboardingComplete = try await opened.setting("onboardingComplete") == "true"
                    #if DEBUG
                    if uiTesting && ProcessInfo.processInfo.arguments.contains("--ui-past-visits") {
                        try await DemoFixtures.seed(opened)
                        selectedDay = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
                        onboardingComplete = true
                    } else if uiTesting && ProcessInfo.processInfo.arguments.contains("--ui-rewind") {
                        try await DemoFixtures.seedRewind(opened)
                        onboardingComplete = true
                    } else if uiTesting && ProcessInfo.processInfo.arguments.contains("--ui-photo-browser") {
                        try await DemoFixtures.seedPhotoBrowser(opened)
                        onboardingComplete = true
                    } else if uiTesting && ProcessInfo.processInfo.arguments.contains("--ui-memories") {
                        try await DemoFixtures.seedMemories(opened)
                        onboardingComplete = true
                    } else if uiTesting && ProcessInfo.processInfo.arguments.contains("--ui-map-periods") {
                        try await DemoFixtures.seedMapPeriods(opened)
                        if ProcessInfo.processInfo.arguments.contains("--ui-traccar") {
                            let start = Calendar.current.date(byAdding: .day, value: -2, to: Calendar.current.startOfDay(for: Date()))!
                            for index in 0..<2 {
                                try await opened.appendTraccar(TraccarPoint(timestamp: start.addingTimeInterval(Double(index) * 600 + 60),
                                    coordinate: Coordinate(latitude: 36.82 + Double(index) * 0.01, longitude: 27.10 + Double(index) * 0.02), accuracy: 20))
                            }
                        }
                        onboardingComplete = true
                    } else if uiTesting && ProcessInfo.processInfo.arguments.contains("--ui-transport-choices") {
                        let calendar = Calendar.current
                        let yesterday = calendar.date(byAdding: .day, value: -1, to: Date())!
                        let evening = calendar.date(bySettingHour: 19, minute: 0, second: 0, of: yesterday)!
                        try await DemoFixtures.seed(opened, now: evening)
                        selectedDay = calendar.startOfDay(for: evening)
                        onboardingComplete = true
                    } else if uiTesting && ProcessInfo.processInfo.arguments.contains("--ui-gap-suggestions") {
                        selectedDay = try await DemoFixtures.seedGapSuggestions(opened)
                        onboardingComplete = true
                    } else if uiTesting && ProcessInfo.processInfo.arguments.contains("--ui-history-navigation") {
                        try await DemoFixtures.seedHistoryNavigation(opened)
                        onboardingComplete = true
                    } else if uiTesting && ProcessInfo.processInfo.arguments.contains("--ui-nearby-wifi") {
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
                    #if DEBUG
                    if uiTesting && ProcessInfo.processInfo.arguments.contains("--ui-map-details") {
                        mapDownloads.loadPreviewCatalogForTesting()
                        if ProcessInfo.processInfo.arguments.contains("--ui-installed-map-details") { try await mapDownloads.installPreviewMapForTesting() }
                    }
                    if uiTesting && ProcessInfo.processInfo.arguments.contains("--ui-on-device-map") {
                        mapProvider = .onDevice; mapsChoiceMade = true
                    }
                    #endif
                    let lookupConsent = try await opened.setting("placeLookupEnabled") == "true"
                    placeLookupExplained = try await opened.setting("placeLookupExplained") == "true" || lookupConsent
                    if lookupConsent { try await opened.setSetting("placeLookupExplained", value: "true") }
                    placeLookupEnabled = lookupConsent
                    regionLookup.setEnabled(placeLookupEnabled && !uiTesting)
                    await refresh()
                    enrichRegions()
                    ready = true; starting = false
                    await photoLibrary.start(store: opened)
                    #if DEBUG
                    if uiTesting && ProcessInfo.processInfo.arguments.contains("--ui-photo-suggestions") {
                        selectedDay = try await DemoFixtures.seedPhotoSuggestions(opened, library: photoLibrary)
                        onboardingComplete = true
                        await refresh()
                    }
                    #endif
                    if !uiTesting {
                        tracking.reserveTraccarRegion = traccarEnabled
                        tracking.configure(places: places, enabled: trackingEnabled)
                        await reconcileTraccar()
                        companions.start { [weak self] batch in
                            guard let self else { throw CancellationError() }
                            try await self.importCompanion(batch)
                        }
                    }
                    await tracking.refreshNotifications()
                    #if DEBUG
                    if uiTesting && ProcessInfo.processInfo.arguments.contains("--ui-memory-refresh") {
                        // Exercise picker presentation while real history refreshes update the UI.
                        Task {
                            for _ in 0..<90 {
                                try await Task.sleep(for: .seconds(1))
                                await refresh()
                            }
                        }
                    }
                    #endif
                } catch { LocalDiagnostics.shared.record(.historyOpenFailed, error: error); store = nil; starting = false; fail("Could not open your history. Your existing data has been kept. Code: \(PlacesStore.failureCode(error)).") }
            }
        } catch is ProtectedStorage.Locked {
            starting = false; waitingForUnlock = true
        } catch { LocalDiagnostics.shared.record(.historyOpenFailed, error: error); starting = false; fail("Could not open your history. Your existing data has been kept. Code: \(PlacesStore.failureCode(error)).") }
    }

    func receiveCompanionDelivery() async -> Bool {
        start()
        await startupTask?.value
        guard ready, !uiTesting, !deleting else { return false }
        let previous = companions.lastReceived
        await companions.sync()
        return previous != companions.lastReceived
    }

    func preparePhotoBackgroundScan() async {
        start()
        await startupTask?.value
        guard ready, !uiTesting, !deleting, !Task.isCancelled else { return }
        await photoLibrary.finishBackgroundScan()
    }

    func refresh() async {
        guard let store else { return }
        let day = selectedDay
        let period = mapPeriod
        let selectionRequest = mapSelectionRequest
        let showingRawPoints = nerdMode
        let placesLayer = showPlacesPoints, traccarLayer = showTraccarPoints
        let expectedGeneration = generation
        do {
            let newPlaces = try await store.places()
            let newMemories = try await store.memoryLibrary()
            let newTimeline = try await store.timeline(on: day)
            let newDays = try await store.historyDays()
            let newFirstDate = try await store.firstHistoryDate()
            let newFirstTraccarDate = try await store.firstTraccarDate()
            let calendar = Calendar.current
            let interval = calendar.dateInterval(of: .day, for: day)!
            let newPoints = try await store.routePoints(from: interval.start, to: interval.end)
            let mapItems: [TimelineItem]
            let mapPoints: [RoutePoint]
            if let period {
                mapItems = try await store.timeline(in: period.interval)
                mapPoints = try await store.routePoints(from: period.interval.start, to: period.interval.end)
            } else { mapItems = newTimeline; mapPoints = newPoints }
            let rawMap: MapPresentation?
            if showingRawPoints {
                let range = period?.interval ?? interval
                let observations = placesLayer ? try await store.observations(from: range.start, to: range.end) : []
                let photos = placesLayer ? try await store.photoEvidence(from: range.start, to: range.end) : []
                let traccarPoints = traccarLayer ? try await store.traccarPoints(from: range.start, to: range.end) : []
                rawMap = await Task.detached(priority: .userInitiated) {
                    MapPresentation(observations: observations, photos: photos, traccar: traccarPoints,
                        showPlaces: placesLayer, showTraccar: traccarLayer)
                }.value
            } else { rawMap = nil }
            let newNetworks = try await store.networks()
            let newAccessPoints = try await store.accessPoints()
            let newDiagnostics = try await store.diagnostics()
            let newObservations = showingRawPoints ? try await store.observations(limit: 80) : []
            let newEvents = showingRawPoints ? try await store.trackingEvents(limit: 60) : []
            guard !deleting, generation == expectedGeneration else { return }
            historyDays = newDays
            firstHistoryDate = newFirstDate; firstTraccarDate = newFirstTraccarDate
            memories = newMemories
            places = newPlaces; networks = newNetworks; accessPoints = newAccessPoints; diagnostics = newDiagnostics
            if !uiTesting { tracking.updateWiFiKnowledge(places: newPlaces, networks: newNetworks, accessPoints: newAccessPoints) }
            if day == selectedDay { timeline = newTimeline; routePoints = newPoints }
            if day == selectedDay && period == mapPeriod && selectionRequest == mapSelectionRequest && showingRawPoints == nerdMode && placesLayer == showPlacesPoints && traccarLayer == showTraccarPoints {
                if mapFocusRequest != selectionRequest { mapViewport = nil }
                mapTimeline = mapItems; mapRoutePoints = mapPoints
                mapRawPresentation = rawMap
                // Commit the framing request together with the loaded period, never
                // while the map still contains the previous selection's places.
                mapFocusRequest = selectionRequest
            }
            if showingRawPoints == nerdMode {
                recentObservations = newObservations; events = newEvents
            }
            historyRevision += 1
            await refreshRewindReminders()
        } catch { fail("Could not read your history. Please try again.") }
    }
    func setRewindReminder(_ kind: RewindReminder.Kind, enabled: Bool) async {
        guard let store else { return }
        let epoch = generation
        do {
            let key = kind == .monthly ? "monthlyRewindReminders" : "weeklyReviewReminders"
            try await store.setSetting(key, value: String(enabled))
            guard !deleting, epoch == generation else { return }
            if kind == .monthly { monthlyRewindReminders = enabled } else { weeklyReviewReminders = enabled }
            if enabled && !uiTesting { await tracking.requestNotifications() }
            await refreshRewindReminders()
        } catch { fail("Could not save your reminder preference. Please try again.") }
    }

    private func refreshRewindReminders() async {
        guard !uiTesting, !deleting, let store else { return }
        guard monthlyRewindReminders || weeklyReviewReminders else { rewindNotifications.update([]); return }
        let epoch = generation
        let revision = historyRevision
        let now = Date()
        let calendar = Calendar.current
        do {
            let from = calendar.date(byAdding: .day, value: -7, to: now)!
            let currentMonth = calendar.dateInterval(of: .month, for: now)!.start
            let earliestMonth = calendar.component(.day, from: now) == 1 ? calendar.date(byAdding: .month, value: -1, to: currentMonth)! : currentMonth
            let items = try await store.rewindReminderItems(in: DateInterval(start: monthlyRewindReminders ? min(from, earliestMonth) : from, end: now))
            guard !deleting, epoch == generation, revision == historyRevision else { return }
            var recordedMonths: Set<Date> = []
            if monthlyRewindReminders {
                let current = calendar.dateInterval(of: .month, for: now)!.start
                var candidates = [current]
                if calendar.component(.day, from: now) == 1 { candidates.append(calendar.date(byAdding: .month, value: -1, to: current)!) }
                for month in candidates {
                    if MonthlyRewind(month: month, items: items, places: places, library: memories, now: now).hasHighlights { recordedMonths.insert(month) }
                }
            }
            guard !deleting, epoch == generation, revision == historyRevision else { return }
            let recent = InferenceEngine.within(DateInterval(start: from, end: now), items: items)
            let missing = TimelineReview.items(in: recent, places: places, now: now).filter { $0.kind == .stay }
            rewindNotifications.update(RewindReminder.plan(now: now, monthly: monthlyRewindReminders,
                weekly: weeklyReviewReminders, recordedMonths: recordedMonths, missingPlaces: missing))
        } catch { rewindNotifications.update([]) }
    }

    func rememberMapViewport(_ viewport: MapViewport?, for request: UUID) {
        guard request == mapFocusRequest, !deleting else { return }
        mapViewport = viewport
    }

    func selectDay(_ day: Date) {
        selectedDay = min(day, Date()); mapPeriod = nil; mapSelectionRequest = UUID()
        mapRawPresentation = nil
        Task { await refresh() }
    }
    func selectPeriod(_ period: HistoryPeriod) {
        mapPeriod = period; mapSelectionRequest = UUID()
        mapRawPresentation = nil
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
    func place(for item: TimelineItem) -> Place? { places.first { $0.id == item.placeID || ($0.mergedPlaceIDs ?? []).contains(item.placeID ?? "") } }
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

    private func importCompanion(_ batch: CompanionBatch) async throws {
        guard let store, !deleting else { throw CancellationError() }
        let epoch = generation
        await pendingWrite?.value
        guard !deleting, generation == epoch else { throw CancellationError() }
        let values = batch.samples.map { sample in
            SensorObservation(id: sample.id.uuidString, timestamp: sample.timestamp, source: .location,
                coordinate: Coordinate(latitude: sample.latitude, longitude: sample.longitude),
                horizontalAccuracy: sample.accuracy, speed: sample.speed, timezoneIdentifier: sample.timezone,
                companionDevice: sample.kind == .watch ? .watch : .mac, companionDeviceID: sample.deviceID.uuidString)
        }
        try await store.append(values)
        guard !deleting, generation == epoch else { throw CancellationError() }
        await refresh()
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
                LocalDiagnostics.shared.record(.historyWriteFailed, error: error)
                self.retryObservations = batch
                self.tracking.configure(places: self.places, enabled: false)
                await self.traccar.stop()
                self.storageNeedsRetry = true
                self.fail("Recording paused because your history could not be saved. Free some storage, then try again. Unsaved observations are kept while the app remains open.")
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
            storageNeedsRetry = false; errorMessage = nil; await reconcileTraccar(); await refresh()
        } catch { fail("Storage is still unavailable. Your history has not been deleted.") }
    }
    func restartOnboarding() {
        replayingOnboarding = true
    }

    func finishOnboarding() async {
        if replayingOnboarding {
            replayingOnboarding = false
            return
        }
        guard let store else { return }
        do {
            try await store.setSetting("onboardingComplete", value: "true")
            await setTrackingEnabled(true)
            onboardingComplete = true
        }
        catch { fail("Could not save onboarding progress. Please try again.") }
    }
    func setMapsEnabled(_ value: Bool) async { await setMapProvider(value ? .apple : .off) }
    func setMapProvider(_ provider: MapProvider) async {
        let preference = UUID(); mapPreference = preference
        // Stop an Apple surface immediately, including if saving consent fails.
        if provider != .apple { mapProvider = .off }
        do {
            guard let store else { return }
            try await store.setSetting("mapProvider", value: provider.rawValue)
            try await store.setSetting("mapsChoiceMade", value: "true")
            guard mapPreference == preference, !deleting else { return }
            mapsChoiceMade = true; mapProvider = provider
        } catch {
            guard mapPreference == preference, !deleting else { return }
            fail("Could not save your map preference. Maps remain off for this session."); mapProvider = .off
        }
    }
    func setPlaceLookupEnabled(_ value: Bool) async {
        let preference = UUID(); lookupPreference = preference
        if !value {
            placeLookupEnabled = false; regionLookup.setEnabled(false)
            regionRun = UUID(); regionTask?.cancel(); regionTask = nil; lookingUpRegions = false
            regionAttempts = []
        }
        do {
            guard let store else { return }
            try await store.setSetting("placeLookupEnabled", value: String(value))
            if value { try await store.setSetting("placeLookupExplained", value: "true") }
            guard lookupPreference == preference, !deleting else { return }
            placeLookupEnabled = value
            if value { placeLookupExplained = true }
            regionLookup.setEnabled(value && !uiTesting)
            if value { enrichRegions() }
        } catch { fail("Could not save your city lookup preference.") }
    }
    func enrichRegions() {
        guard placeLookupEnabled, !uiTesting, regionTask == nil, let store else { return }
        let expectedGeneration = generation
        lookingUpRegions = true
        let run = UUID(); regionRun = run
        regionTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.regionRun == run { self.lookingUpRegions = false; self.regionTask = nil } }
            // Read the latest list each time so a newly saved place joins this queue.
            while let place = self.places.first(where: { $0.locality == nil && !self.regionAttempts.contains("\($0.id)-\($0.coordinate)") }) {
                guard !Task.isCancelled, self.placeLookupEnabled, self.generation == expectedGeneration else { return }
                self.regionAttempts.insert("\(place.id)-\(place.coordinate)")
                do {
                    let locality = try await self.regionLookup.lookup(place.coordinate)
                    guard !Task.isCancelled, self.placeLookupEnabled, self.generation == expectedGeneration else { return }
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
    func retryRegionLookup(for placeID: String? = nil) {
        guard !lookingUpRegions else { return }
        if let place = places.first(where: { $0.id == placeID }) {
            regionAttempts.remove("\(place.id)-\(place.coordinate)")
            regionLookupIssues[place.id] = nil
        } else { regionAttempts = []; regionLookupIssues = [:] }
        enrichRegions()
    }
    func setNerdMode(_ value: Bool) async {
        guard let store, !deleting else { return }
        let epoch = generation
        do {
            try await store.setSetting("nerdMode", value: String(value))
            guard !deleting, generation == epoch else { return }
            nerdMode = value; mapRawPresentation = nil; mapSelectionRequest = UUID()
            if !value { recentObservations = []; events = [] }
            await refresh()
        }
        catch { fail("Could not save this setting.") }
    }
    func setComparisonLayer(traccar: Bool, visible: Bool) async {
        guard let store, !deleting else { return }
        let epoch = generation
        do {
            try await store.setSetting(traccar ? "showTraccarPoints" : "showPlacesPoints", value: String(visible))
            guard epoch == generation, !deleting else { return }
            if traccar { showTraccarPoints = visible } else { showPlacesPoints = visible }
            mapSelectionRequest = UUID(); await refresh()
        } catch { fail("Could not save this map setting.") }
    }
    func setTraccarEnabled(_ value: Bool) async {
        guard let store, !deleting else { return }
        let epoch = generation
        if !value { await traccar.stop() }
        do {
            try await store.setSetting("traccarEnabled", value: String(value))
            guard epoch == generation, !deleting else { return }
            traccarEnabled = value
            await reconcileTraccar()
        } catch { fail("Could not save your collector preference.") }
    }
    func reconcileTraccar() async {
        guard !uiTesting else { return }
        tracking.reserveTraccarRegion = traccarEnabled
        guard let store, ready, !deleting, !storageNeedsRetry, traccarEnabled, trackingEnabled,
              tracking.authorization == .authorizedAlways else { await traccar.stop(); return }
        await traccar.start(store: store) { [weak self] in
            guard let self, UIApplication.shared.applicationState == .active,
                  self.selectedTab == .map, self.nerdMode else { return }
            await self.refresh()
        }
    }
    func setTrackingEnabled(_ value: Bool) async {
        if !value { tracking.configure(places: places, enabled: false); await traccar.stop() }
        do {
            try await store?.setSetting("trackingEnabled", value: String(value)); trackingEnabled = value
            if !uiTesting { tracking.configure(places: places, enabled: value) }
            await reconcileTraccar()
        } catch { fail("Could not save your tracking preference.") }
    }
    func save(_ place: Place, assigning item: TimelineItem? = nil) async -> Bool {
        guard let store else { fail("Your history is not available yet. Please try again."); return false }
        do {
            let edit = item.map {
                var edit = UserOverride(start: $0.start, end: max($0.end ?? Date(), $0.start.addingTimeInterval(1)),
                                        kind: .stay, placeID: place.id, mode: $0.kind == .stay ? $0.mode : .unknown)
                edit.coordinate = place.coordinate
                return edit
            }
            try await store.savePlace(place, assigning: edit); await refresh(); enrichRegions()
            if !uiTesting { tracking.configure(places: places, enabled: trackingEnabled) }
            return true
        } catch let error as PlacesError { fail(error.localizedDescription); return false }
        catch { fail("Could not save this place. Your changes are still in the form."); return false }
    }
    func deletePlace(_ id: String) async throws {
        let epoch = generation
        guard let store, !deleting else { throw CancellationError() }
        await pendingWrite?.value
        guard generation == epoch, !deleting else { throw CancellationError() }
        try await store.deletePlace(id: id)
        guard generation == epoch, !deleting else { throw CancellationError() }
        await refresh()
        if !uiTesting { tracking.configure(places: places, enabled: trackingEnabled) }
    }
    func mergePlaces(_ edited: Place, with otherID: String, keeping keptID: String) async throws {
        let epoch = generation
        guard let store, !deleting else { throw CancellationError() }
        await pendingWrite?.value
        guard generation == epoch, !deleting else { throw CancellationError() }
        _ = try await store.mergePlaces(edited: edited, with: otherID, keeping: keptID)
        guard generation == epoch, !deleting else { throw CancellationError() }
        await refresh()
        if !uiTesting { tracking.configure(places: places, enabled: trackingEnabled) }
    }
    func classify(_ network: WiFiNetwork, as classification: WiFiClassification) async {
        do { try await store?.classifyNetwork(id: network.id, as: classification); await refresh() }
        catch { fail("Could not save the network classification.") }
    }
    func correct(_ item: TimelineItem, kind: TimelineKind, placeID: String? = nil, mode: TransportMode = .unknown) async -> Bool {
        do {
            let end = item.end ?? Date()
            try await store?.correct(UserOverride(start: item.start, end: end > item.start ? end : item.start.addingTimeInterval(1),
                                                 kind: kind, placeID: placeID, mode: mode))
            await refresh(); return true
        } catch { fail("Could not save this correction. Please try again."); return false }
    }
    func passingThrough(_ item: TimelineItem) async -> Bool {
        guard let store else { return false }
        do {
            let edit = try await store.passingThrough(item)
            deleteUndo.register("Kept as part of your route") { [weak self] in
                try await store.undoCorrection(id: edit.id)
                await self?.refresh()
            }
            await refresh()
            return true
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
    func export(_ format: HistoryExportFormat, period: DateInterval? = nil, includePhotos: Bool = true) async {
        guard let store else { return }
        let expectedGeneration = generation
        tracking.recordEnergyCheckpoint()
        await pendingWrite?.value
        do {
            let data: Data
            switch format {
            case .history: data = try await store.exportHistory(in: period, includePhotos: includePhotos)
            case .diagnostics: data = try await store.exportDiagnostics()
            case .testCase: data = try await store.exportTestCase(in: period)
            case .gpx: data = try await store.exportGPX(in: period)
            }
            guard !deleting, generation == expectedGeneration else { return }
            exportDocument = HistoryDocument(data: data, contentType: format.contentType)
            exportFilename = format.filename
            showExporter = true
        } catch { fail("Could not prepare the export. Your data has not changed.") }
    }
    func makeBackup(in workspace: URL) async throws -> URL {
        guard let store, !deleting else { throw CancellationError() }
        let epoch = generation
        await pendingWrite?.value
        guard !deleting, generation == epoch else { throw CancellationError() }
        let url = try await store.makeBackup(in: workspace)
        guard !deleting, generation == epoch else { throw CancellationError() }
        return url
    }

    func restoreBackup(_ backup: PreparedBackup) async throws {
        guard let store, !deleting else { throw CancellationError() }
        deleting = true; generation += 1
        await traccar.stop()
        let previousTracking = trackingEnabled, previousLookup = placeLookupEnabled
        let previousProvider = mapProvider
        photoLibrary.reset(); deleteUndo.clear()
        mapPreference = UUID(); mapProvider = .off
        lookupPreference = UUID(); regionLookup.setEnabled(false); placeLookupEnabled = false
        regionRun = UUID(); regionTask?.cancel(); regionTask = nil; lookingUpRegions = false
        tracking.configure(places: [], enabled: false)
        await pendingWrite?.value
        do {
            try await store.restoreBackup(backup)
        } catch {
            deleting = false; mapProvider = previousProvider; placeLookupEnabled = previousLookup
            regionLookup.setEnabled(previousLookup && !uiTesting)
            if !uiTesting { tracking.configure(places: places, enabled: previousTracking) }
            await reconcileTraccar()
            await photoLibrary.start(store: store)
            throw error
        }
        // Nothing below can fail after the durable transaction has committed.
        companions.pauseAfterRestore()
        traccarEnabled = false
        trackingEnabled = false; mapsChoiceMade = false; placeLookupExplained = false
        monthlyRewindReminders = false; weeklyReviewReminders = false; rewindRequest = nil
        rewindNotifications.update([])
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        regionAttempts = []; regionLookupIssues = [:]
        retryObservations = []; pendingWrite = nil; tracking.clearSensitiveState()
        mapPeriod = nil; mapViewport = nil; mapSelectionRequest = UUID()
        mapTimeline = []; mapRoutePoints = []; mapRawPresentation = nil
        recentObservations = []; events = []; searchResults = []; searchText = ""
        places = []; timeline = []; memories = MemoryLibrary(); routePoints = []
        historyDays = []; firstHistoryDate = nil; firstTraccarDate = nil; diagnostics = nil
        showExporter = false; exportDocument = nil; errorMessage = nil; storageNeedsRetry = false
        selectedDay = Date(); selectedTab = .timeline; librarySection = "Places"
        nerdMode = (try? await store.setting("nerdMode")) == "true"
        showPlacesPoints = (try? await store.setting("showPlacesPoints")) != "false"
        showTraccarPoints = (try? await store.setting("showTraccarPoints")) != "false"
        deleting = false
        await photoLibrary.start(store: store)
        await refresh()
    }

    func finishBackupRestore() {
        onboardingComplete = true; replayingOnboarding = false
        navigationRoots = [:]
    }

    func deleteAllDataAndRestart() async -> Bool {
        guard let store, !deleting else { return false }
        deleting = true; generation += 1
        await traccar.stop()
        photoLibrary.reset()
        deleteUndo.clear()
        rewindNotifications.update([])
        monthlyRewindReminders = false; weeklyReviewReminders = false; rewindRequest = nil
        mapPreference = UUID(); mapProvider = .off; trackingEnabled = false; traccarEnabled = false
        lookupPreference = UUID(); regionLookup.setEnabled(false); placeLookupEnabled = false
        placeLookupExplained = false; regionLookupIssues = [:]
        regionRun = UUID(); regionTask?.cancel(); regionTask = nil; regionAttempts = []; lookingUpRegions = false
        mapPeriod = nil; mapTimeline = []; mapRoutePoints = []; mapRawPresentation = nil; mapViewport = nil
        tracking.configure(places: [], enabled: false)
        await pendingWrite?.value
        do {
            if !uiTesting { try await companions.erase() }
            try mapDownloads.deleteAll()
            try MemoryPhotoDraft.clearAbandonedImports()
            try BackupTransferView.clearAbandonedTransfers()
            try await store.eraseHistory(resetSettings: true)
            try await LocalDiagnostics.shared.log.clear()
            retryObservations = []; timeline = []; historyDays = []; firstHistoryDate = nil; firstTraccarDate = nil; places = []; networks = []; accessPoints = []
            memories = MemoryLibrary()
            routePoints = []; recentObservations = []; events = []; searchResults = []; searchText = ""
            showExporter = false; exportDocument = nil; tracking.clearSensitiveState()
            exportFilename = "Places"; pendingWrite = nil; diagnostics = nil; errorMessage = nil; storageNeedsRetry = false
            showPlacesPoints = true; showTraccarPoints = true
            mapsChoiceMade = false; nerdMode = false; selectedDay = Date(); selectedTab = .timeline; librarySection = "Places"; navigationRoots = [:]
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
    private func fail(_ message: String, line: UInt = #line) {
        LocalDiagnostics.shared.record(.appError, line: line)
        errorMessage = message
    }

    func supportReport(includeHistory: Bool, period: DateInterval? = nil, includePhotos: Bool = true) async throws -> Data {
        let epoch = generation
        guard !deleting else { throw CancellationError() }
        let history: HistoryArchive?
        if includeHistory {
            await pendingWrite?.value
            guard let store else { throw CocoaError(.fileReadUnknown) }
            history = try await store.fullHistoryArchive(in: period, includePhotos: includePhotos)
        } else { history = nil }
        // The technical report uses the last refreshed counters. Do not wait for
        // database writes or scan history just to diagnose a storage problem.
        let counters = diagnostics
        let snapshot = await LocalDiagnostics.shared.log.snapshot()
        guard !deleting, generation == epoch else { throw CancellationError() }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return try SupportReport(formatVersion: 1, scope: includeHistory ? "fullHistory" : "technicalOnly",
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            runtime: SupportRuntime(trackingState: tracking.state.rawValue,
                locationAuthorization: Int(tracking.authorization.rawValue), preciseLocation: tracking.accuracy == .fullAccuracy,
                photoLocationsEnabled: photoLibrary.enabled, photoAuthorization: photoLibrary.authorization.rawValue,
                macEnabled: companions.macEnabled, watchEnabled: companions.watchEnabled,
                lowPower: tracking.lowPower, historyAvailable: store != nil),
            counters: counters, diagnostics: snapshot, history: history).encoded()
    }

    func changeMemories(epoch: Int, _ operation: @Sendable (PlacesStore) async throws -> Void) async throws {
        guard let store, !deleting, generation == epoch else { throw CancellationError() }
        try await operation(store)
        guard !deleting, generation == epoch else { throw CancellationError() }
        await refresh()
    }
}

enum HistoryExportFormat {
    case history, diagnostics, testCase, gpx
    var contentType: UTType { self == .gpx ? HistoryDocument.gpxType : .json }
    var filename: String {
        switch self {
        case .history, .gpx: "Places-history"
        case .diagnostics: "Places-diagnostics"
        case .testCase: "Places-test-case"
        }
    }
}

struct HistoryDocument: FileDocument {
    static let gpxType = UTType(importedAs: "com.topografix.gpx", conformingTo: .xml)
    static var readableContentTypes: [UTType] { [.json, gpxType] }
    var data: Data
    var contentType: UTType
    init(data: Data, contentType: UTType) { self.data = data; self.contentType = contentType }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data(); contentType = configuration.contentType
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

enum AppTab: String, CaseIterable {
    case timeline, map, places, search
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self { case .timeline: "list.bullet.below.rectangle"; case .map: "map"; case .places: "mappin.and.ellipse"; case .search: "magnifyingglass" }
    }
}
