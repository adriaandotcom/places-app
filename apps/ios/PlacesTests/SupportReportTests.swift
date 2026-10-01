import XCTest
import PlacesCore
@testable import Places

final class SupportReportTests: XCTestCase {
    func testExportPeriodUsesCalendarDaysAcrossDaylightSavingAndClampsDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Amsterdam"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 3, day: 30, hour: 12)))
        var selection = ExportPeriodSelection()
        XCTAssertNil(selection.interval(now: now, calendar: calendar))
        selection.choice = .days; selection.days = 1
        let today = try XCTUnwrap(selection.interval(now: now, calendar: calendar))
        XCTAssertEqual(today.duration, 23 * 3600)
        selection.days = 0
        XCTAssertEqual(selection.interval(now: now, calendar: calendar), today)
        selection.choice = .week
        let week = try XCTUnwrap(selection.interval(now: now, calendar: calendar))
        XCTAssertEqual(calendar.dateComponents([.day], from: week.start, to: week.end).day, 7)
        selection.choice = .dates; selection.start = now; selection.end = now.addingTimeInterval(-86400)
        let reversed = try XCTUnwrap(selection.interval(now: now, calendar: calendar))
        XCTAssertEqual(calendar.dateComponents([.day], from: reversed.start, to: reversed.end).day, 2)
    }

    func testAllowlistDropsPersonalDataAndPreservesSymbolication() throws {
        let privateText = "Private Garden 52.123456 4.987654 user@example.test 192.0.2.1 device-secret"
        let binary = "70B89F27-1634-3580-A695-57CDB41D7743"
        let data = try JSONSerialization.data(withJSONObject: ["callStackTree": [
            "callStacks": [["threadAttributed": true, "deviceIdentifier": privateText, "callStackRootFrames": [[
                "binaryUUID": binary, "binaryName": privateText, "offsetIntoBinaryTextSegment": 123,
                "address": 456, "sampleCount": 2, "subFrames": [["binaryUUID": privateText, "offsetIntoBinaryTextSegment": 99]]
            ]]]], "exceptionReason": privateText, "path": privateText]])
        let stacks = SupportStack.read(data)
        XCTAssertEqual(stacks.first?.frames.count, 2)
        XCTAssertEqual(stacks.first?.frames.first?.binaryUUID?.uuidString, binary)
        XCTAssertEqual(stacks.first?.frames.first?.offset, 123)
        XCTAssertEqual(stacks.first?.frames.last?.parent, 0)
        XCTAssertNil(stacks.first?.frames.last?.binaryUUID)
        let error = NSError(domain: NSCocoaErrorDomain, code: 257,
            userInfo: [NSLocalizedDescriptionKey: privateText, NSFilePathErrorKey: privateText, NSUnderlyingErrorKey: NSError(domain: privateText, code: 1)])
        let breadcrumb = SupportBreadcrumb(.photoScanFailed, error: error, build: "99")
        let unknown = SupportBreadcrumb(.appError, error: NSError(domain: privateText, code: 999), build: "99")
        XCTAssertEqual(breadcrumb.errorCode, 257)
        XCTAssertNil(unknown.errorCode)
        let encoded = String(decoding: try JSONEncoder().encode(stacks), as: UTF8.self)
            + String(decoding: try JSONEncoder().encode([breadcrumb, unknown]), as: UTF8.self)
        XCTAssertFalse(encoded.contains(privateText))
        XCTAssertFalse(encoded.contains("address"))
        XCTAssertFalse(encoded.contains("binaryName"))
        XCTAssertNil(SupportIncident.version(privateText))
        XCTAssertEqual(SupportIncident.terminationCategory(privateText), "other")
    }

    func testStackLimitPrioritizesTheFaultingThread() throws {
        var threads: [[String: Any]] = (0..<40).map { _ in
            ["threadAttributed": false, "callStackRootFrames": (0..<300).map { _ in ["sampleCount": 1] }]
        }
        threads.append(["threadAttributed": true, "callStackRootFrames": [["offsetIntoBinaryTextSegment": 42]]])
        let data = try JSONSerialization.data(withJSONObject: ["callStacks": threads])
        let result = SupportStack.read(data)
        XCTAssertEqual(result.first?.attributed, true)
        XCTAssertEqual(result.first?.frames.first?.offset, 42)
        XCTAssertLessThanOrEqual(result.count, 32)
        XCTAssertLessThanOrEqual(result.flatMap(\.frames).count, 512)
    }

    func testLogPersistsDeduplicatesBoundsAndDoesNotReplayAfterReset() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = SupportLog(directory: directory)
        let begin = Date().addingTimeInterval(-10), end = Date()
        let incident = SupportIncident(kind: .crash, appVersion: "1.0", build: "99", exceptionType: 6,
            exceptionCode: nil, signal: 5, termination: nil, stacks: [])
        for _ in 0..<2 { await log.receive(incidents: [incident], begin: begin, end: end) }
        for index in 0..<205 { await log.record(SupportBreadcrumb(index.isMultiple(of: 2) ? .foreground : .background, build: "99")) }
        let reopened = SupportLog(directory: directory)
        var snapshot = await reopened.snapshot()
        XCTAssertTrue(snapshot.storageAvailable)
        XCTAssertEqual(snapshot.incidents.count, 1)
        XCTAssertEqual(snapshot.breadcrumbs.count, 200)
        await reopened.record(SupportBreadcrumb(.foreground, build: "99"))
        snapshot = await reopened.snapshot()
        XCTAssertEqual(snapshot.breadcrumbs.last?.repetitions, 2)
        let serialized = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        XCTAssertFalse(serialized.contains("clearedAt"))
        XCTAssertFalse(serialized.contains("seen"))
        XCTAssertFalse(serialized.contains("timestamp"))
        let cutoff = Date()
        try await reopened.clear(at: cutoff)
        let afterReset = SupportLog(directory: directory)
        await afterReset.receive(incidents: [incident], begin: begin, end: end)
        await afterReset.record(SupportBreadcrumb(.appError), receivedAt: begin)
        snapshot = await afterReset.snapshot()
        XCTAssertTrue(snapshot.incidents.isEmpty)
        XCTAssertTrue(snapshot.breadcrumbs.isEmpty)
        await afterReset.receive(incidents: [incident], begin: cutoff.addingTimeInterval(1), end: cutoff.addingTimeInterval(2))
        snapshot = await afterReset.snapshot()
        XCTAssertEqual(snapshot.incidents.count, 1)
        let resource = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(resource.isExcludedFromBackup, true)
    }

    func testUnreadableLogIsNotOverwritten() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("support.json"), invalid = Data("invalid".utf8)
        try invalid.write(to: file)
        let log = SupportLog(directory: directory)
        await log.record(SupportBreadcrumb(.launch))
        let snapshot = await log.snapshot()
        XCTAssertFalse(snapshot.storageAvailable)
        XCTAssertEqual(try Data(contentsOf: file), invalid)
    }

    func testTechnicalReportExcludesHistoryAndFullReportIncludesIt() async throws {
        let store = try PlacesStore()
        let place = Place(name: "Private Garden", coordinate: Coordinate(latitude: 12.345678, longitude: 23.456789))
        try await store.savePlace(place)
        let runtime = SupportRuntime(trackingState: "paused", locationAuthorization: 0, preciseLocation: false,
            photoLocationsEnabled: false, photoAuthorization: 0, macEnabled: false, watchEnabled: false,
            lowPower: false, historyAvailable: true)
        let counters = try await store.diagnostics()
        let history = try await store.fullHistoryArchive()
        for full in [false, true] {
            let report = SupportReport(formatVersion: 1, scope: full ? "fullHistory" : "technicalOnly",
                appVersion: "1.0", build: "99", osVersion: "26.0", runtime: runtime,
                counters: counters, diagnostics: SupportSnapshot(), history: full ? history : nil)
            let data = try report.encoded(), string = String(decoding: data, as: UTF8.self)
            XCTAssertEqual(string.contains("Private Garden"), full)
            XCTAssertEqual(string.contains("12.345678"), full)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(json["history"] != nil, full)
        }
    }

    func testBackgroundExpirationCanRunOffMainActorAndCancelsWork() async {
        let work = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
        let handler = AppDelegate.photoTaskExpirationHandler(work)
        await Task.detached { handler() }.value
        XCTAssertTrue(work.isCancelled)
        await work.value
    }
}
