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
    private(set) var trackingEnabled = true
    private(set) var onboardingComplete = false
    private(set) var replayingOnboarding = false
    private var mapSelectionRequest = UUID()
    private(set) var mapFocusRequest = UUID()
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
                        try await DemoFixtures.seedPhotoSuggestions(opened, library: photoLibrary)
                        onboardingComplete = true
                        await refresh()
                    }
                    #endif
                    if !uiTesting {
                        tracking.configure(places: places, enabled: trackingEnabled)
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
                } catch { store = nil; starting = false; fail("Could not open your history. Your existing data has been kept. Code: \(PlacesStore.failureCode(error)).") }
            }
        } catch is ProtectedStorage.Locked {
            starting = false; waitingForUnlock = true
        } catch { starting = false; fail("Could not open your history. Your existing data has been kept. Code: \(PlacesStore.failureCode(error)).") }
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
        let expectedGeneration = generation
        do {
            let newPlaces = try await store.places()
            let newMemories = try await store.memoryLibrary()
            let newTimeline = try await store.timeline(on: day)
            let newDays = try await store.historyDays()
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
            historyDays = newDays
            memories = newMemories
            places = newPlaces; networks = newNetworks; accessPoints = newAccessPoints; diagnostics = newDiagnostics
            if !uiTesting { tracking.updateWiFiKnowledge(places: newPlaces, networks: newNetworks, accessPoints: newAccessPoints) }
            if day == selectedDay { timeline = newTimeline; routePoints = newPoints }
            if day == selectedDay && period == mapPeriod && selectionRequest == mapSelectionRequest {
                mapTimeline = mapItems; mapRoutePoints = mapPoints
                // Commit the framing request together with the loaded period, never
                // while the map still contains the previous selection's places.
                mapFocusRequest = selectionRequest
            }
            recentObservations = nerdMode ? newObservations : []
            events = nerdMode ? newEvents : []
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

    func selectDay(_ day: Date) {
        selectedDay = min(day, Date()); mapPeriod = nil; mapSelectionRequest = UUID()
        Task { await refresh() }
    }
    func selectPeriod(_ period: HistoryPeriod) {
        mapPeriod = period; mapSelectionRequest = UUID()
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
                self.retryObservations = batch
                self.tracking.configure(places: self.places, enabled: false)
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
            storageNeedsRetry = false; errorMessage = nil; await refresh()
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
                var edit = UserOverride(start: $0.start, end: max($0.end ?? Date(), $0.start.addingTimeInterval(1)),
                                        kind: .stay, placeID: place.id)
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
    func export(_ format: HistoryExportFormat) async {
        guard let store else { return }
        let expectedGeneration = generation
        tracking.recordEnergyCheckpoint()
        await pendingWrite?.value
        do {
            let data: Data
            switch format {
            case .history: data = try await store.exportHistory()
            case .diagnostics: data = try await store.exportDiagnostics()
            case .testCase: data = try await store.exportTestCase()
            case .gpx: data = try await store.exportGPX()
            }
            guard !deleting, generation == expectedGeneration else { return }
            exportDocument = HistoryDocument(data: data, contentType: format.contentType)
            exportFilename = format.filename
            showExporter = true
        } catch { fail("Could not prepare the export. Your data has not changed.") }
    }
    func deleteAllDataAndRestart() async -> Bool {
        guard let store, !deleting else { return false }
        deleting = true; generation += 1
        photoLibrary.reset()
        deleteUndo.clear()
        rewindNotifications.update([])
        monthlyRewindReminders = false; weeklyReviewReminders = false; rewindRequest = nil
        mapPreference = UUID(); mapProvider = .off; trackingEnabled = false
        lookupPreference = UUID(); regionLookup.setEnabled(false); placeLookupEnabled = false
        placeLookupExplained = false; regionLookupIssues = [:]
        regionRun = UUID(); regionTask?.cancel(); regionTask = nil; regionAttempts = []; lookingUpRegions = false
        mapPeriod = nil; mapTimeline = []; mapRoutePoints = []
        tracking.configure(places: [], enabled: false)
        await pendingWrite?.value
        do {
            if !uiTesting { try await companions.erase() }
            try mapDownloads.deleteAll()
            try MemoryPhotoDraft.clearAbandonedImports()
            try await store.eraseHistory(resetSettings: true)
            retryObservations = []; timeline = []; historyDays = []; places = []; networks = []; accessPoints = []
            memories = MemoryLibrary()
            routePoints = []; recentObservations = []; events = []; searchResults = []; searchText = ""
            showExporter = false; exportDocument = nil; tracking.clearSensitiveState()
            exportFilename = "Places"; pendingWrite = nil; diagnostics = nil; errorMessage = nil; storageNeedsRetry = false
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
    private func fail(_ message: String) { errorMessage = message }

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
