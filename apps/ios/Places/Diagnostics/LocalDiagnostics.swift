import Foundation
import MetricKit

/// Use the iOS 26-compatible subscriber API. Callbacks arrive on a background
/// queue: this adapter is deliberately not MainActor-isolated.
final class LocalDiagnostics: NSObject, MXMetricManagerSubscriber, Sendable {
    static let shared = LocalDiagnostics()
    let log: SupportLog

    init(log: SupportLog = SupportLog(directory: SupportLog.directory())) {
        self.log = log
        super.init()
    }
    @MainActor func start() {
        MXMetricManager.shared.add(self)
        didReceive(MXMetricManager.shared.pastDiagnosticPayloads)
        didReceive(MXMetricManager.shared.pastPayloads)
        record(.launch)
    }
    func record(_ event: SupportEvent, error: (any Error)? = nil, line: UInt? = nil) {
        let breadcrumb = SupportBreadcrumb(event, error: error, line: line), receivedAt = Date()
        Task { await log.record(breadcrumb, receivedAt: receivedAt) }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            var incidents: [SupportIncident] = []
            func incident(_ kind: SupportIncident.Kind, _ diagnostic: MXDiagnostic, _ tree: MXCallStackTree,
                          crash: MXCrashDiagnostic? = nil) -> SupportIncident {
                SupportIncident(kind: kind, appVersion: SupportIncident.version(diagnostic.applicationVersion),
                    build: SupportIncident.version(diagnostic.metaData.applicationBuildVersion),
                    exceptionType: crash?.exceptionType?.intValue, exceptionCode: crash?.exceptionCode?.uint64Value,
                    signal: crash?.signal?.intValue, termination: SupportIncident.terminationCategory(crash?.terminationReason),
                    stacks: SupportStack.read(tree.jsonRepresentation()))
            }
            for value in payload.crashDiagnostics ?? [] { incidents.append(incident(.crash, value, value.callStackTree, crash: value)) }
            for value in payload.hangDiagnostics ?? [] { incidents.append(incident(.hang, value, value.callStackTree)) }
            for value in payload.cpuExceptionDiagnostics ?? [] { incidents.append(incident(.cpu, value, value.callStackTree)) }
            for value in payload.diskWriteExceptionDiagnostics ?? [] { incidents.append(incident(.diskWrites, value, value.callStackTree)) }
            for value in payload.appLaunchDiagnostics ?? [] { incidents.append(incident(.launch, value, value.callStackTree)) }
            let values = incidents, begin = payload.timeStampBegin, end = payload.timeStampEnd
            guard !values.isEmpty else { continue }
            Task { await log.receive(incidents: values, begin: begin, end: end) }
        }
    }
    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            guard let exit = payload.applicationExitMetrics else { continue }
            let fg = exit.foregroundExitData, bg = exit.backgroundExitData
            let counts = SupportExits(build: payload.metaData.flatMap { SupportIncident.version($0.applicationBuildVersion) },
                foregroundCrashes: fg.cumulativeBadAccessExitCount + fg.cumulativeAbnormalExitCount + fg.cumulativeIllegalInstructionExitCount,
                foregroundWatchdog: fg.cumulativeAppWatchdogExitCount, foregroundMemoryLimit: fg.cumulativeMemoryResourceLimitExitCount,
                backgroundCrashes: bg.cumulativeBadAccessExitCount + bg.cumulativeAbnormalExitCount + bg.cumulativeIllegalInstructionExitCount,
                backgroundWatchdog: bg.cumulativeAppWatchdogExitCount, backgroundMemoryLimit: bg.cumulativeMemoryResourceLimitExitCount,
                backgroundMemoryPressure: bg.cumulativeMemoryPressureExitCount, backgroundCPULimit: bg.cumulativeCPUResourceLimitExitCount,
                backgroundLockedFile: bg.cumulativeSuspendedWithLockedFileExitCount,
                backgroundTaskTimeout: bg.cumulativeBackgroundTaskAssertionTimeoutExitCount)
            let begin = payload.timeStampBegin, end = payload.timeStampEnd
            Task { await log.receive(exits: [counts], begin: begin, end: end) }
        }
    }
}
