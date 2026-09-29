import Foundation
import Observation
import Network
import PlacesCore

enum MapPackPhase: String, Codable { case downloading, pausing, paused, verifying, installed, failed }

struct MapPackTransfer: Codable {
    var token: String
    var phase: MapPackPhase
    var received: Int64 = 0
    var approvedMetered = false
    var message: String?
    var pack: MapPack?
}

@MainActor @Observable
final class MapDownloads: NSObject {
    static let sessionID = "com.adriaan.places.offline-maps"
    private(set) var packs: [MapPack]
    private let bundledPacks: [MapPack]
    private(set) var installedPacks: [MapPack.ID: MapPack] = [:]
    private(set) var catalog: MapCatalog?
    private(set) var checkingCatalog = false
    private(set) var catalogIssue: String?
    private var lastCatalogCheck: Date?
    private(set) var transfers: [MapPack.ID: MapPackTransfer] = [:]
    private(set) var installed: [MapPack.ID: URL] = [:]
    private(set) var network: MapDownloadNetwork = .unavailable
    private(set) var ready = false
    private(set) var issue: String?
    private var backgroundCompletions: [String: () -> Void] = [:]
    private let directory: URL?
    private let testing: Bool
    private let background: Bool
    private var sessions: [Bool: URLSession] = [:]
    private var generation = 0
    private var monitor: NWPathMonitor?
    private var tasks: [MapPack.ID: URLSessionDownloadTask] = [:]
    private var finishingEvents: Set<String> = []
    private var validations: [String: Int] = [:]
    private var validatingTokens: Set<String> = []
    private var lastPersisted: [MapPack.ID: Int64] = [:]
    private var dismissed: [String: Date] = [:]

    init(testing: Bool = false, storage: URL? = nil, manifest: [MapPack]? = nil) {
        self.testing = testing
        #if DEBUG
        background = !testing || ProcessInfo.processInfo.arguments.contains("--ui-background-map-downloads")
        #else
        background = !testing
        #endif
        let initial: [MapPack]
        if let manifest, manifest.allSatisfy(\.isValid) { initial = manifest }
        else if let url = Bundle.main.url(forResource: "packs", withExtension: "json", subdirectory: "OfflineMaps"),
           let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([MapPack].self, from: data),
           Set(decoded.map(\.id)).count == MapPack.ID.bootstrapIDs.count, decoded.allSatisfy(\.isValid) {
            initial = decoded
        } else { initial = [] }
        packs = initial; bundledPacks = initial
        directory = storage ?? (try? MapPackFiles.directory(testing: testing))
        super.init()
        if directory == nil { issue = "Map storage is unavailable. Free some storage and reopen Places." }
        if let directory, let data = try? Data(contentsOf: directory.appendingPathComponent("catalog.json")), data.count <= 2_097_152,
           let saved = try? JSONDecoder().decode(MapCatalog.self, from: data), saved.isValid { applyCatalog(saved) }
    }

    #if DEBUG
    func installPreviewMapForTesting() async throws {
        guard testing, let directory else { return }
        while !ready { await Task.yield() }
        guard let pack = choices(.netherlands).first(where: { $0.detail == .normal }) else { return }
        let source = OfflineMapStyle.resourceRoot.appendingPathComponent("Previews/amsterdam-normal.pmtiles")
        let target = directory.appendingPathComponent(pack.filename)
        try MapPackFiles.validate(source, pack: pack)
        try FileManager.default.copyItem(at: source, to: target)
        installedPacks[pack.id] = pack; installed[pack.id] = target
        transfers[pack.id] = MapPackTransfer(token: UUID().uuidString, phase: .installed, received: pack.bytes, pack: pack)
        try saveInstalled(); persist()
    }
    func loadPreviewCatalogForTesting() {
        guard testing,
              let url = Bundle.main.url(forResource: "manifest", withExtension: "json", subdirectory: "OfflineMaps/Previews"),
              let data = try? Data(contentsOf: url),
              var entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var variants = entry["variants"] as? [[String: Any]] else { return }
        entry["id"] = "netherlands"; entry["name"] = "Netherlands"
        for index in variants.indices {
            variants[index]["id"] = "netherlands"; variants[index]["name"] = "Netherlands"
            if let url = variants[index]["url"] as? String { variants[index]["url"] = url.replacingOccurrences(of: "/amsterdam/", with: "/netherlands/") }
        }
        entry["variants"] = variants
        if let data = try? JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "countries": [entry]]),
           let catalog = try? JSONDecoder().decode(MapCatalog.self, from: data) { applyCatalog(catalog) }
    }
    #endif

    func start() {
        guard sessions.isEmpty, let directory else { return }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("transfers.json")),
           let saved = try? JSONDecoder().decode([MapPack.ID: MapPackTransfer].self, from: data) {
            transfers = saved
            for (id, var transfer) in transfers {
                // Old app versions did not persist a target descriptor. Bind
                // those tasks to the original release, never a newer catalog.
                if transfer.pack == nil { transfer.pack = bundledPacks.first { $0.id == id } }
                transfers[id] = transfer.pack.map { $0.isValid && $0.id == id } == true ? transfer : nil
            }
        }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("dismissed.json")),
           let saved = try? JSONDecoder().decode([String: Date].self, from: data) { dismissed = saved }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("installed.json")),
           let saved = try? JSONDecoder().decode([MapPack.ID: MapPack].self, from: data) {
            installedPacks = saved.filter { $0.key == $0.value.id && $0.value.isValid }
        }
        // Clean abandoned verification files before reconnecting to background
        // tasks, which may immediately deliver a newly completed download.
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "partial" { try? FileManager.default.removeItem(at: file) }
        }
        for approved in [false, true] {
            let configuration = background ? URLSessionConfiguration.background(withIdentifier: Self.sessionID + (approved ? ".any" : ".wifi")) : .ephemeral
            configuration.waitsForConnectivity = true
            configuration.sessionSendsLaunchEvents = background
            configuration.isDiscretionary = false
            configuration.allowsCellularAccess = approved
            configuration.allowsExpensiveNetworkAccess = approved
            configuration.allowsConstrainedNetworkAccess = approved
            configuration.urlCache = nil; configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            sessions[approved] = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        }
        let monitor = NWPathMonitor(); self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let state = MapDownloadNetwork.classify(connected: path.status == .satisfied,
                wifiOrEthernet: path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet),
                expensive: path.isExpensive, constrained: path.isConstrained)
            Task { @MainActor in self?.networkChanged(state) }
        }
        monitor.start(queue: DispatchQueue(label: "Places.map-download-path"))
        Task { await restore() }
    }

    private func restore() async {
        guard let directory else { return }
        let expectedGeneration = generation
        defer { ready = true }
        var running: [URLSessionTask] = []
        for session in sessions.values { running += await session.allTasks }
        guard generation == expectedGeneration else { return }
        for task in running {
            guard let task = task as? URLSessionDownloadTask, let (id, token) = identity(task),
                  transfers[id]?.token == token, (transfers[id]?.phase == .downloading || transfers[id]?.phase == .pausing) else { task.cancel(); continue }
            guard task.originalRequest?.url == transfers[id]?.pack?.downloadURL else {
                task.cancel(); transfers[id]?.phase = .paused
                transfers[id]?.message = "Download moved to Bunny. Tap Resume to continue."
                if let file = resumeFile(id) { try? FileManager.default.removeItem(at: file) }
                continue
            }
            tasks[id] = task
            if transfers[id]?.phase == .pausing {
                transfers[id]?.phase = .downloading
                pause(id, message: transfers[id]?.message ?? "Paused")
            }
        }
        // A process may have ended after the atomic rename but before recording
        // its new state. Validate final files independently of saved progress.
        var candidates = installedPacks
        for pack in bundledPacks where candidates[pack.id] == nil { candidates[pack.id] = pack }
        for (id, transfer) in transfers {
            if let pack = transfer.pack, pack.isValid, FileManager.default.fileExists(atPath: directory.appendingPathComponent(pack.filename).path) { candidates[id] = pack }
        }
        for pack in candidates.values {
            let file = directory.appendingPathComponent(pack.filename)
            guard FileManager.default.fileExists(atPath: file.path) else {
                installedPacks[pack.id] = nil
                if transfers[pack.id]?.phase == .installed { transfers[pack.id] = nil }
                continue
            }
            let expectedToken = transfers[pack.id]?.token
            let valid = await Task.detached { (try? MapPackFiles.validate(file, pack: pack)) != nil }.value
            guard generation == expectedGeneration else { return }
            guard transfers[pack.id]?.token == expectedToken else { continue }
            if valid {
                installed[pack.id] = file; installedPacks[pack.id] = pack
                if transfers[pack.id] == nil || transfers[pack.id]?.phase == .installed || transfers[pack.id]?.pack == pack {
                    transfers[pack.id] = MapPackTransfer(token: UUID().uuidString, phase: .installed, received: pack.bytes, pack: pack)
                }
            } else {
                // If a replacement was interrupted/corrupted, retain a separately
                // verified installed version rather than losing the working map.
                if let previous = installedPacks[pack.id], previous != pack,
                   (try? MapPackFiles.validate(directory.appendingPathComponent(previous.filename), pack: previous)) != nil {
                    installed[pack.id] = directory.appendingPathComponent(previous.filename)
                } else { installedPacks[pack.id] = nil }
                try? FileManager.default.removeItem(at: file)
                transfers[pack.id] = MapPackTransfer(token: UUID().uuidString, phase: .failed, message: "This map could not be verified. Download it again.", pack: transfers[pack.id]?.pack ?? pack)
            }
        }
        for id in Array(transfers.keys) where tasks[id] == nil && [.downloading, .pausing, .verifying].contains(transfers[id]?.phase)
            && !validatingTokens.contains(transfers[id]?.token ?? "") {
            transfers[id]?.phase = .paused
            transfers[id]?.message = "Download interrupted. Tap Resume to continue."
        }
        try? saveInstalled()
        ready = true; persist(); networkChanged(network)
    }

    func clearIssue() { issue = nil }
    #if DEBUG
    func stopForTesting() {
        guard testing else { return }
        monitor?.cancel()
        for session in sessions.values { session.invalidateAndCancel() }
        sessions = [:]
    }
    #endif
    func showConnectionIssue() { issue = "Connect to the internet to download the World map first." }
    func pack(_ id: MapPack.ID) -> MapPack? {
        let detail = installedPacks[id]?.detail ?? .normal
        return packs.first { $0.id == id && $0.detail == detail } ?? packs.first { $0.id == id }
    }
    func choices(_ id: MapPack.ID) -> [MapPack] { packs.filter { $0.id == id && $0.detail != nil }.sorted { ($0.detail?.maxZoom ?? 0) < ($1.detail?.maxZoom ?? 0) } }
    private func transferPack(_ id: MapPack.ID) -> MapPack? { transfers[id]?.pack ?? pack(id) }
    func update(_ id: MapPack.ID) -> MapPack? {
        guard let installed = installedPacks[id],
              let latest = packs.first(where: { $0.id == id && $0.detail == (installed.detail ?? .normal) }), latest.sha256 != installed.sha256,
              latest.version.compare(installed.version, options: .numeric) == .orderedDescending else { return nil }
        return latest
    }
    var pending: Set<MapPack.ID> { Set(transfers.filter { [.downloading, .pausing, .verifying].contains($0.value.phase) }.keys) }
    var totalInstalledBytes: Int64 { installedPacks.values.reduce(0) { $0 + $1.bytes } }
    func remaining(_ pack: MapPack) -> Int64 {
        let resumable = pack.url == pack.downloadURL && transfers[pack.id]?.pack == pack && (resumeFile(pack.id).map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
        return MapDownloadPolicy.remaining(total: pack.bytes, received: resumable ? (transfers[pack.id]?.received ?? 0) : 0)
    }

    func download(_ pack: MapPack, approvedMetered: Bool = false) {
        guard ready, pack.isValid, (packs.contains(pack) || transferPack(pack.id) == pack), installedPacks[pack.id] != pack, !pending.contains(pack.id),
              let directory, let session = sessions[approvedMetered] else { return }
        guard MapDownloadPolicy.canStart(network: network, approvedMetered: approvedMetered) else {
            issue = network == .unavailable ? "Connect to the internet to download this map." : "Confirm the download size before using this connection."
            return
        }
        do {
            let target = pack.downloadDescriptor
            try MapPackFiles.checkSpace(at: directory, pack: pack)
            let token = UUID().uuidString
            let resumeURL = resumeFile(pack.id)
            let task: URLSessionDownloadTask
            // Separate sessions enforce network restrictions even while the app
            // is suspended. Requests inherit the selected session's permissions.
            if let resumeURL, transfers[pack.id]?.pack == target, let data = try? Data(contentsOf: resumeURL) {
                task = session.downloadTask(withResumeData: data)
            } else {
                var request = URLRequest(url: pack.downloadURL)
                request.httpShouldHandleCookies = false
                task = session.downloadTask(with: request)
                transfers[pack.id]?.received = 0
            }
            transfers[pack.id] = MapPackTransfer(token: token, phase: .downloading,
                received: transfers[pack.id]?.received ?? 0, approvedMetered: approvedMetered, pack: target)
            task.taskDescription = pack.id.rawValue + "|" + token
            tasks[pack.id] = task
            try saveTransfers(); task.resume()
        } catch {
            tasks.removeValue(forKey: pack.id)?.cancel()
            if transfers[pack.id] != nil { transfers[pack.id]?.phase = .failed }
            issue = "There isn’t enough free storage, or the download could not be saved. Free some space and try again."
        }
    }

    func pause(_ id: MapPack.ID, message: String = "Paused") {
        guard let task = tasks.removeValue(forKey: id), let token = transfers[id]?.token else { return }
        transfers[id]?.phase = .pausing; transfers[id]?.message = message; persist()
        task.cancel { [weak self] data in
            Task { @MainActor in
                guard let self, self.transfers[id]?.token == token, self.transfers[id]?.phase == .pausing else { return }
                if let data, let file = self.resumeFile(id) {
                    do { try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
                    catch { self.transfers[id]?.received = 0; try? FileManager.default.removeItem(at: file) }
                } else {
                    self.transfers[id]?.received = 0
                    if let file = self.resumeFile(id) { try? FileManager.default.removeItem(at: file) }
                }
                self.transfers[id]?.phase = .paused
                self.persist()
                self.resumeWaitingOnWiFi()
            }
        }
    }

    func delete(_ pack: MapPack) {
        let previouslyInstalled = installed[pack.id]
        let previousPack = installedPacks[pack.id]
        let pendingPack = transferPack(pack.id)
        // Invalidate callbacks before cancellation or removal.
        transfers[pack.id] = nil; installed[pack.id] = nil; installedPacks[pack.id] = nil
        tasks.removeValue(forKey: pack.id)?.cancel()
        guard let directory else { return }
        do {
            for file in Set([previouslyInstalled, directory.appendingPathComponent(pack.filename), pendingPack.map { directory.appendingPathComponent($0.filename) }, resumeFile(pack.id)].compactMap({ $0 }))
                where FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            try saveTransfers(); try saveInstalled()
        } catch {
            if let file = previouslyInstalled, FileManager.default.fileExists(atPath: file.path) {
                installed[pack.id] = file
                installedPacks[pack.id] = previousPack
                transfers[pack.id] = MapPackTransfer(token: UUID().uuidString, phase: .installed, received: previousPack?.bytes ?? pack.bytes, pack: previousPack)
            }
            issue = "This map could not be deleted. Try again."
        }
    }

    func deleteAll() throws {
        generation += 1
        transfers = [:]; installed = [:]; installedPacks = [:]; dismissed = [:]
        for task in tasks.values { task.cancel() }; tasks = [:]
        guard let directory else { return }
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: file)
        }
    }

    func dismissedAt(_ id: MapPack.ID) -> Date? { dismissed[id.rawValue] }
    func dismissSuggestion(_ id: MapPack.ID) {
        dismissed[id.rawValue] = Date()
        if let directory, let data = try? JSONEncoder().encode(dismissed) {
            try? data.write(to: directory.appendingPathComponent("dismissed.json"), options: .atomic)
        }
    }
    private func networkChanged(_ state: MapDownloadNetwork) {
        #if DEBUG
        let value: MapDownloadNetwork = testing && ProcessInfo.processInfo.arguments.contains("--ui-metered-maps") ? .needsApproval : state
        #else
        let value = state
        #endif
        network = value
        for (id, transfer) in transfers where transfer.phase == .downloading && !transfer.approvedMetered && value != .unmetered {
            pause(id, message: value == .needsApproval ? "Waiting for Wi-Fi or your approval." : "Waiting for a connection.")
        }
        resumeWaitingOnWiFi()
    }
    private func resumeWaitingOnWiFi() {
        guard ready, network == .unmetered else { return }
        for id in Array(transfers.keys) where transfers[id]?.phase == .paused && transfers[id]?.message?.hasPrefix("Waiting for") == true {
            if let pack = transferPack(id) { download(pack) }
        }
    }
    private func resumeFile(_ id: MapPack.ID) -> URL? { directory?.appendingPathComponent(id.rawValue + ".resume") }
    private func saveTransfers() throws {
        guard let directory else { return }
        try JSONEncoder().encode(transfers).write(to: directory.appendingPathComponent("transfers.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func saveInstalled() throws {
        guard let directory else { return }
        try JSONEncoder().encode(installedPacks).write(to: directory.appendingPathComponent("installed.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func cancel(_ id: MapPack.ID) {
        transfers[id] = nil; tasks.removeValue(forKey: id)?.cancel()
        if let file = resumeFile(id) { try? FileManager.default.removeItem(at: file) }
        if let installed = installedPacks[id] { transfers[id] = MapPackTransfer(token: UUID().uuidString, phase: .installed, received: installed.bytes, pack: installed) }
        persist()
    }
    func applyCatalog(_ value: MapCatalog) {
        guard value.isValid else { return }
        catalog = value
        let available = Set(value.packs.map(\.id))
        packs = bundledPacks.filter { !available.contains($0.id) } + value.packs
    }
    func refreshCatalog(force: Bool = false) async {
        guard !testing, !checkingCatalog, (force || (lastCatalogCheck.map({ Date().timeIntervalSince($0) > 3600 }) ?? true)) else { return }
        checkingCatalog = true; catalogIssue = nil
        defer { checkingCatalog = false }
        let epoch = generation
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        defer { session.invalidateAndCancel() }
        do {
            var request = URLRequest(url: MapCatalog.url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.httpShouldHandleCookies = false
            let (bytes, response) = try await session.bytes(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, response.url == MapCatalog.url,
                  response.expectedContentLength <= 2_097_152 else { throw MapPackFiles.Failure.invalidArchive }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 2_097_152 else { throw MapPackFiles.Failure.invalidSize }
                data.append(byte)
            }
            let value = try JSONDecoder().decode(MapCatalog.self, from: data)
            guard value.isValid, generation == epoch, !Task.isCancelled else { throw MapPackFiles.Failure.invalidArchive }
            if let directory { try data.write(to: directory.appendingPathComponent("catalog.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
            applyCatalog(value); lastCatalogCheck = Date()
        } catch {
            if generation == epoch { catalogIssue = "Couldn’t check for new maps. Your downloaded maps still work." }
        }
    }
    func install(_ local: URL, pack: MapPack) throws {
        guard let directory else { throw MapPackFiles.Failure.invalidArchive }
        let previous = installed[pack.id], previousPack = installedPacks[pack.id]
        let file = try MapPackFiles.installValidated(local, pack: pack, directory: directory)
        installedPacks[pack.id] = pack
        do { try saveInstalled() }
        catch {
            installedPacks[pack.id] = previousPack
            if file != previous { try? FileManager.default.removeItem(at: file) }
            throw error
        }
        installed[pack.id] = file
        if let previous, previous != file { try? FileManager.default.removeItem(at: previous) }
    }
    private func persist() { do { try saveTransfers() } catch { issue = "Download progress could not be saved. Free some storage and try again." } }
    private func identity(_ task: URLSessionTask) -> (MapPack.ID, String)? {
        let parts = (task.taskDescription ?? "").split(separator: "|")
        guard parts.count == 2, let id = MapPack.ID(rawValue: String(parts[0])) else { return nil }
        return (id, String(parts[1]))
    }
    func handleBackgroundEvents(identifier: String, completion: @escaping () -> Void) {
        backgroundCompletions[identifier] = completion
        finishBackgroundEvents(identifier)
    }
    private func finishBackgroundEvents(_ identifier: String) {
        guard finishingEvents.contains(identifier), (validations[identifier] ?? 0) == 0,
              let completion = backgroundCompletions.removeValue(forKey: identifier) else { return }
        finishingEvents.remove(identifier); completion()
    }

}

extension MapDownloads: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                               didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            guard let (id, token) = self.identity(downloadTask), self.transfers[id]?.token == token,
                  self.transfers[id]?.phase == .downloading, let pack = self.transferPack(id) else { return }
            guard totalBytesWritten <= pack.bytes, totalBytesExpectedToWrite <= pack.bytes else {
                self.cancel(id); self.issue = "The map download had an unexpected size."; return
            }
            self.transfers[id]?.received = totalBytesWritten
            if totalBytesWritten - (self.lastPersisted[id] ?? 0) >= 1_048_576 {
                self.lastPersisted[id] = totalBytesWritten; self.persist()
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // URLSession removes location as soon as this method returns. Move it
        // synchronously first; never expose it until checksum verification ends.
        let staging = location.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".partial")
        do { try FileManager.default.moveItem(at: location, to: staging) }
        catch { Task { @MainActor in self.issue = "The downloaded map could not be saved." }; return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode
        let accepted: (MapPack.ID, String, MapPack, URL)? = MainActor.assumeIsolated {
            guard let (id, token) = self.identity(downloadTask), self.transfers[id]?.token == token,
                  self.transfers[id]?.phase == .downloading, let pack = self.transferPack(id), let directory = self.directory else { return nil }
            self.tasks[id] = nil; self.transfers[id]?.phase = .verifying; self.persist()
            self.validatingTokens.insert(token)
            self.validations[session.configuration.identifier ?? "test", default: 0] += 1
            return (id, token, pack, directory)
        }
        guard let (id, token, pack, directory) = accepted else { try? FileManager.default.removeItem(at: staging); return }
        Task { @MainActor in
            defer {
                self.validatingTokens.remove(token)
                let identifier = session.configuration.identifier ?? "test"
                self.validations[identifier, default: 1] -= 1; self.finishBackgroundEvents(identifier)
            }
            let local = directory.appendingPathComponent(token + ".partial")
            do {
                guard status == 200 || status == 206 else { throw MapPackFiles.Failure.invalidArchive }
                try FileManager.default.moveItem(at: staging, to: local)
                try await Task.detached(priority: .utility) { try MapPackFiles.validate(local, pack: pack) }.value
                guard self.transfers[id]?.token == token else { try? FileManager.default.removeItem(at: local); return }
                try self.install(local, pack: pack)
                self.transfers[id]?.phase = .installed; self.transfers[id]?.received = pack.bytes
                if let resume = self.resumeFile(id) { try? FileManager.default.removeItem(at: resume) }
            } catch {
                try? FileManager.default.removeItem(at: staging); try? FileManager.default.removeItem(at: local)
                if self.transfers[id]?.token == token {
                    self.transfers[id]?.phase = .failed; self.transfers[id]?.received = 0
                    self.transfers[id]?.message = "This map could not be verified. Please try the download again."
                }
            }
            self.persist()
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        Task { @MainActor in
            guard let (id, token) = self.identity(task), self.transfers[id]?.token == token,
                  self.transfers[id]?.phase == .downloading else { return }
            self.tasks[id] = nil; self.transfers[id]?.phase = .paused
            self.transfers[id]?.message = "Download interrupted. Tap Resume to continue."
            if let file = self.resumeFile(id) {
                do {
                    if let resume { try resume.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
                    else { throw MapPackFiles.Failure.invalidArchive }
                } catch { self.transfers[id]?.received = 0; try? FileManager.default.removeItem(at: file) }
            }
            self.persist()
        }
    }
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            guard let identifier = session.configuration.identifier else { return }
            self.finishingEvents.insert(identifier); self.finishBackgroundEvents(identifier)
        }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                               willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                               completionHandler: @escaping (URLRequest?) -> Void) {
        let original = task.originalRequest?.url
        completionHandler(original?.host == MapCatalog.host && request.url == original ? request : nil)
    }
}
