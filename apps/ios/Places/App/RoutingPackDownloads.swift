import Foundation
import Observation
import PlacesCore
import PlacesRouting

struct RoutingPackTransfer: Codable {
    var token: String
    var source: RoutingPackDownload
    var phase: MapPackPhase
    var received: Int64 = 0
    var approvedMetered = false
    var waitingForWiFi = false
    var message: String?
}

/// Explicit public-data downloads only. Rendering/matching never creates a request.
@MainActor @Observable
final class RoutingPackDownloads: NSObject {
    static let sessionID = "com.adriaan.places.routing-packs"
    let catalog: [RoutingPackDownload]
    private(set) var transfer: RoutingPackTransfer?
    private(set) var ready = false
    private(set) var issue: String?
    private(set) var network: MapDownloadNetwork = .unavailable
    private let directory: URL?
    private let testing: Bool
    private let installer: @MainActor (URL) async throws -> RoutingPack
    private var sessions: [Bool: URLSession] = [:]
    private var task: URLSessionDownloadTask?
    private var work: [String: Task<Void, Never>] = [:]
    private var checks: [String: Task<Void, Error>] = [:]
    private var completions: [String: () -> Void] = [:]
    private var finishedEvents: Set<String> = []
    private var validations: [String: Int] = [:]
    private var lastPersisted: Int64 = 0

    init(testing: Bool = false, storage: URL? = nil, manifest: [RoutingPackDownload]? = nil,
         installer: @escaping @MainActor (URL) async throws -> RoutingPack) {
        self.testing = testing; self.installer = installer
        catalog = testing ? (manifest ?? (try? RoutingPackDownload.catalog()) ?? []) : ((try? RoutingPackDownload.catalog()) ?? [])
        directory = storage ?? (try? Self.storage(testing: testing))
        super.init()
        if directory == nil { issue = "Routing storage is unavailable. Free some storage and reopen Places." }
    }
    private static func storage(testing: Bool) throws -> URL {
        let parent = testing ? FileManager.default.temporaryDirectory : try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var folder = parent.appendingPathComponent(testing ? "RoutingDownloads-QA" : "PlacesRoutingDownloads", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        return folder
    }
    var pending: Bool { transfer.map { [.downloading, .pausing, .verifying].contains($0.phase) } ?? false }
    func remaining(_ source: RoutingPackDownload) -> Int64 {
        let resumable = transfer?.source == source && resumeFile.map { FileManager.default.fileExists(atPath: $0.path) } == true
        return MapDownloadPolicy.remaining(total: source.bytes, received: resumable ? (transfer?.received ?? 0) : 0)
    }
    private var resumeFile: URL? { directory?.appendingPathComponent("routing.resume") }
    private var stateFile: URL? { directory?.appendingPathComponent("transfer.json") }
    func clearIssue() { issue = nil }

    func start() {
        guard sessions.isEmpty, let directory else { return }
        if let file = stateFile, let data = try? Data(contentsOf: file), data.count <= 16_384,
           let saved = try? JSONDecoder().decode(RoutingPackTransfer.self, from: data),
           UUID(uuidString: saved.token) != nil, saved.source.isValid, catalog.contains(saved.source), saved.phase != .installed {
            transfer = saved
        }
        for approved in [false, true] {
            let configuration = testing ? URLSessionConfiguration.ephemeral : .background(withIdentifier: Self.sessionID + (approved ? ".any" : ".wifi"))
            configuration.waitsForConnectivity = true; configuration.sessionSendsLaunchEvents = !testing
            configuration.isDiscretionary = false
            configuration.allowsCellularAccess = approved
            configuration.allowsExpensiveNetworkAccess = approved
            configuration.allowsConstrainedNetworkAccess = approved
            configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
            configuration.httpAdditionalHeaders = ["User-Agent": "Places"]
            sessions[approved] = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        }
        Task {
            let expected = transfer?.token
            var running: [URLSessionTask] = []
            for session in sessions.values { running += await session.allTasks }
            guard expected == transfer?.token else { for task in running { task.cancel() }; ready = true; return }
            for runningTask in running {
                guard let download = runningTask as? URLSessionDownloadTask, let current = transfer,
                      download.taskDescription == current.token, download.originalRequest?.url == current.source.url,
                      [.downloading, .pausing].contains(current.phase) else { runningTask.cancel(); continue }
                task = download
                if current.phase == .pausing { transfer?.phase = .downloading; pause(waitingForWiFi: current.waitingForWiFi) }
            }
            if let current = transfer, current.phase == .verifying, work[current.token] == nil,
               FileManager.default.fileExists(atPath: directory.appendingPathComponent(current.token + ".partial").path) {
                verify(directory.appendingPathComponent(current.token + ".partial"), token: current.token, session: "restored")
            } else if task == nil, transfer?.phase == .downloading || transfer?.phase == .pausing || transfer?.phase == .verifying {
                transfer?.phase = .paused; transfer?.message = "Download interrupted. Tap Resume to continue."
            }
            for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
                where file.pathExtension == "partial" && file.lastPathComponent != (transfer?.token ?? "") + ".partial" {
                try? FileManager.default.removeItem(at: file)
            }
            ready = true; persist(); networkChanged(network)
        }
    }
    func networkChanged(_ value: MapDownloadNetwork) {
        network = value
        if transfer?.phase == .downloading, transfer?.approvedMetered != true, value != .unmetered {
            pause(waitingForWiFi: true)
        } else if ready, value == .unmetered, let current = transfer, current.phase == .paused, current.waitingForWiFi {
            download(current.source)
        }
    }
    func download(_ source: RoutingPackDownload, approvedMetered: Bool = false) {
        guard ready, source.isValid, catalog.contains(source), !pending,
              let directory, let session = sessions[approvedMetered] else { return }
        guard MapDownloadPolicy.canStart(network: network, approvedMetered: approvedMetered) else {
            issue = network == .unavailable ? "Connect to the internet to download routing data." : "Confirm the download size before using this connection."
            return
        }
        do {
            if let available = try directory.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity,
               available < source.requiredStorageBytes { throw RoutingPackDownload.Failure.notEnoughSpace }
            let token = UUID().uuidString
            let download: URLSessionDownloadTask
            if transfer?.source == source, let file = resumeFile, let data = try? Data(contentsOf: file) {
                download = session.downloadTask(withResumeData: data)
            } else {
                if let file = resumeFile { try? FileManager.default.removeItem(at: file) }
                var request = URLRequest(url: source.url, cachePolicy: .reloadIgnoringLocalCacheData)
                request.httpShouldHandleCookies = false
                download = session.downloadTask(with: request)
                transfer?.received = 0
            }
            lastPersisted = 0
            transfer = RoutingPackTransfer(token: token, source: source, phase: .downloading,
                received: transfer?.received ?? 0, approvedMetered: approvedMetered)
            download.taskDescription = token; task = download; try save(); download.resume()
        } catch {
            task?.cancel(); task = nil; transfer?.phase = .failed
            issue = "There isn’t enough free storage, or this download could not be saved. Free some space and try again."
        }
    }
    func pause(waitingForWiFi: Bool = false) {
        guard let task, let token = transfer?.token else { return }
        self.task = nil; transfer?.phase = .pausing; transfer?.waitingForWiFi = waitingForWiFi
        transfer?.message = waitingForWiFi ? "Waiting for Wi-Fi" : "Paused"; persist()
        task.cancel { [weak self] data in
            Task { @MainActor in
                guard let self, self.transfer?.token == token, self.transfer?.phase == .pausing else { return }
                if let data, let file = self.resumeFile {
                    do { try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
                    catch { self.transfer?.received = 0; try? FileManager.default.removeItem(at: file) }
                } else {
                    self.transfer?.received = 0
                    if let file = self.resumeFile { try? FileManager.default.removeItem(at: file) }
                }
                self.transfer?.phase = .paused; self.persist(); self.networkChanged(self.network)
            }
        }
    }
    func cancel() {
        let previous = transfer?.token
        transfer = nil; task?.cancel(); task = nil
        Task { for session in sessions.values { for task in await session.allTasks where task.taskDescription == previous { task.cancel() } } }
        for job in work.values { job.cancel() }; for check in checks.values { check.cancel() }
        if let file = resumeFile { try? FileManager.default.removeItem(at: file) }
        persist()
    }
    func erase() throws {
        cancel()
        guard let directory else { return }
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: file)
        }
    }
    private func save() throws {
        guard let file = stateFile else { return }
        if let transfer { try JSONEncoder().encode(transfer).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        else if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
    private func persist() { do { try save() } catch { issue = "Download progress could not be saved. Free some storage and try again." } }

    // Keeping validation separate also lets tests exercise stale/corrupt delivery without a network request.
    func receive(_ file: URL, token: String, responseURL: URL?, status: Int?, session: String) {
        guard let current = transfer, current.token == token, current.phase == .downloading else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        guard responseURL == current.source.url, status == 200 || status == 206 else {
            try? FileManager.default.removeItem(at: file)
            if transfer?.token == token { task = nil; transfer?.phase = .failed; transfer?.message = "Routing data is unavailable. Try the download again."; persist() }
            return
        }
        task = nil; transfer?.phase = .verifying; persist(); verify(file, token: token, session: session)
    }
    private func verify(_ file: URL, token: String, session: String) {
        guard let source = transfer?.source, transfer?.token == token else { return }
        validations[session, default: 0] += 1
        work[token] = Task {
            defer {
                try? FileManager.default.removeItem(at: file)
                self.checks[token] = nil; self.work[token] = nil
                self.validations[session, default: 1] -= 1; self.finish(session)
            }
            do {
                let check = Task.detached(priority: .utility) { try source.validate(file) }
                checks[token] = check; try await check.value
                try Task.checkCancellation()
                guard transfer?.token == token else { return }
                let installed = try await installer(file)
                guard transfer?.token == token, !Task.isCancelled else { return }
                guard installed == source.pack else { throw RoutingPackDownload.Failure.invalid }
                transfer?.phase = .installed; transfer?.received = source.bytes; transfer?.message = nil
                if let resumeFile { try? FileManager.default.removeItem(at: resumeFile) }
            } catch {
                if transfer?.token == token {
                    transfer?.phase = .failed; transfer?.received = 0
                    transfer?.message = "This routing pack could not be verified or installed. Please try again."
                    if let resumeFile { try? FileManager.default.removeItem(at: resumeFile) }
                }
            }
            persist()
        }
    }
    func handleBackgroundEvents(identifier: String, completion: @escaping () -> Void) {
        completions[identifier] = completion; finish(identifier)
    }
    private func finish(_ identifier: String) {
        guard finishedEvents.contains(identifier), validations[identifier, default: 0] == 0,
              let completion = completions.removeValue(forKey: identifier) else { return }
        finishedEvents.remove(identifier); completion()
    }
    #if DEBUG
    func prepareDeliveryForTesting(_ source: RoutingPackDownload, token: String) {
        guard testing, catalog.contains(source) else { return }
        transfer = RoutingPackTransfer(token: token, source: source, phase: .downloading)
    }
    func stopForTesting() { if testing { for session in sessions.values { session.invalidateAndCancel() }; sessions = [:] } }
    #endif
}

extension RoutingPackDownloads: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            guard self.transfer?.token == downloadTask.taskDescription, self.transfer?.phase == .downloading,
                  let source = self.transfer?.source else { return }
            guard totalBytesWritten <= source.bytes, totalBytesExpectedToWrite <= source.bytes else {
                self.cancel(); self.issue = "The routing download had an unexpected size."; return
            }
            self.transfer?.received = totalBytesWritten
            if totalBytesWritten - self.lastPersisted >= 1_048_576 { self.lastPersisted = totalBytesWritten; self.persist() }
        }
    }
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // This delegate uses the main operation queue; move the temporary file before returning.
        MainActor.assumeIsolated {
            guard let directory = self.directory, let token = downloadTask.taskDescription, UUID(uuidString: token) != nil else { return }
            let local = directory.appendingPathComponent(token + ".partial")
            do {
                try FileManager.default.moveItem(at: location, to: local)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: local.path)
                self.receive(local, token: token, responseURL: downloadTask.response?.url,
                    status: (downloadTask.response as? HTTPURLResponse)?.statusCode, session: session.configuration.identifier ?? "test")
            } catch {
                try? FileManager.default.removeItem(at: local)
                if self.transfer?.token == token { self.task = nil; self.transfer?.phase = .failed; self.persist() }
                self.issue = "Routing data could not be saved. Free some storage and try again."
            }
        }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        Task { @MainActor in
            guard self.transfer?.token == task.taskDescription, self.transfer?.phase == .downloading else { return }
            self.task = nil; self.transfer?.phase = .paused
            self.transfer?.waitingForWiFi = !self.transfer!.approvedMetered && self.network != .unmetered
            self.transfer?.message = self.transfer?.waitingForWiFi == true ? "Waiting for Wi-Fi" : "Download interrupted. Tap Resume to continue."
            if let resume, let file = self.resumeFile {
                do { try resume.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
                catch { self.transfer?.received = 0; try? FileManager.default.removeItem(at: file) }
            } else {
                self.transfer?.received = 0
                if let file = self.resumeFile { try? FileManager.default.removeItem(at: file) }
            }
            self.persist()
        }
    }
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            guard let id = session.configuration.identifier else { return }
            self.finishedEvents.insert(id); self.finish(id)
        }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void) {
        let original = task.originalRequest?.url
        let allowed = original?.scheme == "https" && original?.host == "places-app.b-cdn.net"
            && original?.path.hasPrefix("/maps/routing/") == true && original?.query == nil
        completionHandler(allowed && request.url == original ? request : nil)
    }
}
