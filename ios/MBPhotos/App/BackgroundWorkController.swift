@preconcurrency import BackgroundTasks
import Foundation
import UIKit

enum BackgroundTaskIdentifiers {
    static let refresh = "com.marginallybetter.photos.refresh"
    static let analysisProcessing = "com.marginallybetter.photos.analysis.processing"
    static let maintenanceProcessing = "com.marginallybetter.photos.maintenance.processing"
    static let continuedWildcard = "com.marginallybetter.photos.continued.*"
    static let continuedPrefix = "com.marginallybetter.photos.continued."
}

enum BackgroundScheduledTask: String, Equatable, Sendable {
    case metadataRefresh
    case userAnalysis
    case automaticMaintenance
    case continuedAnalysis
    case continuedExport
}

enum BackgroundTaskSchedulingOutcome: Equatable, Sendable {
    /// The scheduler accepted the request. For the three stable identifiers,
    /// BackgroundTasks replaces any older unexecuted request with the same ID,
    /// preserving one-outstanding-request semantics across app launches.
    case scheduled
    /// The request is queued, but policy prevents it from being described as
    /// active until conditions improve and the launch handler revalidates them.
    case scheduledForLater(BackgroundWorkDeferralReason)
    case unavailable
    case tooManyPendingRequests
    case notPermitted
    case immediateRunIneligible
    case unsupportedOS
    case appNotActive
    case registrationFailed
    case unknownFailure

    var acceptedByScheduler: Bool {
        switch self {
        case .scheduled, .scheduledForLater: true
        default: false
        }
    }

    var grantsContinuedExecution: Bool {
        self == .scheduled
    }

    var diagnosticValue: String {
        switch self {
        case .scheduled: "scheduled"
        case let .scheduledForLater(reason): "scheduled-for-later:\(reason.rawValue)"
        case .unavailable: "unavailable"
        case .tooManyPendingRequests: "too-many-pending"
        case .notPermitted: "not-permitted"
        case .immediateRunIneligible: "immediate-run-ineligible"
        case .unsupportedOS: "unsupported-os"
        case .appNotActive: "app-not-active"
        case .registrationFailed: "registration-failed"
        case .unknownFailure: "unknown-failure"
        }
    }

    static func submissionFailure(_ error: any Error) -> Self {
        let nsError = error as NSError
        guard nsError.domain == BGTaskScheduler.errorDomain else {
            return .unknownFailure
        }
        switch nsError.code {
        case 1: return .unavailable
        case 2: return .tooManyPendingRequests
        case 3: return .notPermitted
        case 4: return .immediateRunIneligible
        default: return .unknownFailure
        }
    }
}

enum BackgroundThermalCondition: Int, Comparable, Equatable, Sendable {
    case nominal
    case fair
    case serious
    case critical

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct BackgroundExecutionConstraints: Equatable, Sendable {
    let isLowPowerModeEnabled: Bool
    let thermalCondition: BackgroundThermalCondition
}

protocol BackgroundExecutionConstraintProviding: Sendable {
    func currentConstraints() -> BackgroundExecutionConstraints
}

struct SystemBackgroundExecutionConstraints: BackgroundExecutionConstraintProviding {
    func currentConstraints() -> BackgroundExecutionConstraints {
        let processInfo = ProcessInfo.processInfo
        let thermalCondition: BackgroundThermalCondition = switch processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .serious
        }
        return BackgroundExecutionConstraints(
            isLowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
            thermalCondition: thermalCondition
        )
    }
}

enum BackgroundConstraintDisposition: Equatable, Sendable {
    case run
    case pause(BackgroundWorkDeferralReason)
    case deferUntilLater(BackgroundWorkDeferralReason)

    var deferralReason: BackgroundWorkDeferralReason? {
        switch self {
        case .run: nil
        case let .pause(reason), let .deferUntilLater(reason): reason
        }
    }
}

enum BackgroundExecutionConstraintPolicy {
    static func disposition(
        for policy: BackgroundProcessingPolicy,
        constraints: BackgroundExecutionConstraints
    ) -> BackgroundConstraintDisposition {
        if constraints.isLowPowerModeEnabled {
            return policy.isAutomatic
                ? .deferUntilLater(.lowPowerMode)
                : .pause(.lowPowerMode)
        }

        switch (policy, constraints.thermalCondition) {
        case (.automaticLocalMaintenance, .nominal),
             (.automaticLocalMaintenance, .fair):
            return .run
        case (.automaticLocalMaintenance, .serious):
            return .deferUntilLater(.thermalSerious)
        case (.automaticLocalMaintenance, .critical):
            return .deferUntilLater(.thermalCritical)
        case (.userAnalysis, .nominal), (.userAnalysis, .fair):
            return .run
        case (.userAnalysis, .serious):
            return .pause(.thermalSerious)
        case (.userAnalysis, .critical):
            return .pause(.thermalCritical)
        }
    }
}

struct BackgroundWorkDiagnosticEvent: Equatable, Sendable {
    enum Action: String, Equatable, Sendable {
        case registered
        case registrationFailed
        case scheduling
        case started
        case deferred
        case completed
        case expired
    }

    let task: BackgroundScheduledTask
    let action: Action
    let outcome: String
}

enum BackgroundProcessingPolicy: Equatable, Sendable {
    case automaticLocalMaintenance
    case userAnalysis(includeICloudItems: Bool)

    var requiresExternalPower: Bool {
        if case .automaticLocalMaintenance = self { return true }
        return false
    }

    var requiresNetworkConnectivity: Bool {
        if case let .userAnalysis(includeICloudItems) = self { return includeICloudItems }
        return false
    }

    var isAutomatic: Bool {
        if case .automaticLocalMaintenance = self { return true }
        return false
    }
}

/// Describes which foreground worker, if any, an OS-owned execution lease keeps
/// alive. Metadata refresh protects neither analysis nor export; processing and
/// maintenance protect analysis generically, while continued work is ID-specific.
enum BackgroundExecutionScope: Hashable, Sendable {
    case metadataRefresh
    case analysis(runID: UUID?)
    case export(jobID: UUID)
}

struct BackgroundExecutionOwnership: Equatable, Sendable {
    private(set) var counts: [BackgroundExecutionScope: Int] = [:]

    mutating func begin(_ scope: BackgroundExecutionScope) {
        counts[scope, default: 0] += 1
    }

    mutating func end(_ scope: BackgroundExecutionScope) {
        guard let count = counts[scope] else { return }
        if count > 1 { counts[scope] = count - 1 }
        else { counts.removeValue(forKey: scope) }
    }

    func coversAnalysis(runID: UUID?) -> Bool {
        if counts[.analysis(runID: nil), default: 0] > 0 { return true }
        guard let runID else { return false }
        return counts[.analysis(runID: runID), default: 0] > 0
    }

    func coversExport(jobID: UUID) -> Bool {
        counts[.export(jobID: jobID), default: 0] > 0
    }
}

struct BackgroundCheckpointPolicy: Equatable, Sendable {
    let shouldCheckpointAnalysis: Bool
    let shouldCheckpointExport: Bool

    init(
        ownership: BackgroundExecutionOwnership,
        analysisIsRunning: Bool,
        currentAnalysisRunID: UUID?,
        continuedAnalysisRunID: UUID?,
        currentExportJobID: UUID?,
        continuedExportJobID: UUID?
    ) {
        let analysisCovered: Bool = if let currentAnalysisRunID {
            continuedAnalysisRunID == currentAnalysisRunID
                || ownership.coversAnalysis(runID: currentAnalysisRunID)
        } else {
            // A generic processing/maintenance lease covers the transition before
            // a durable run ID is visible. An exact continued ID never does.
            ownership.coversAnalysis(runID: nil)
        }
        shouldCheckpointAnalysis = analysisIsRunning && !analysisCovered

        guard let currentExportJobID else {
            shouldCheckpointExport = false
            return
        }
        let continuedExportCoversCurrent = continuedExportJobID == currentExportJobID
        shouldCheckpointExport = !continuedExportCoversCurrent
            && !ownership.coversExport(jobID: currentExportJobID)
    }
}

enum BackgroundAnalysisSchedulingPolicy {
    static func shouldScheduleUserProcessing(
        phase: OrganizeAnalysisPhase,
        origin: AnalysisRunOrigin?
    ) -> Bool {
        guard origin == .userInitiated else { return false }
        return phase == .running || phase == .paused
    }
}

enum BackgroundAnalysisProgressPolicy {
    /// System/background progress follows the durable traversal cursor. Exact
    /// size coverage can be lower when an item is unavailable or fails, but
    /// those terminal outcomes must still advance the work estimate.
    static func processedUnitCount(from snapshot: AnalysisRunProgressSnapshot) -> Int {
        min(max(snapshot.nextPosition, 0), snapshot.totalAssetCount)
    }
}

enum BackgroundAnalysisWaitingStatus {
    static func message(
        policy: BackgroundProcessingPolicy,
        reason: BackgroundWorkDeferralReason
    ) -> String {
        switch reason {
        case .lowPowerMode:
            return policy.isAutomatic
                ? "Waiting for external power and Low Power Mode to turn off."
                : "Waiting for Low Power Mode to turn off."
        case .thermalFair, .thermalSerious, .thermalCritical:
            return policy.isAutomatic
                ? "Waiting for external power and the device to cool down."
                : "Waiting for the device to cool down."
        case .systemScheduling, .systemExpiration:
            return policy.requiresNetworkConnectivity
                ? "Waiting for iOS and a network connection to continue analysis."
                : "Waiting for iOS to continue analysis."
        case .backgroundRefreshUnavailable:
            return "Background analysis is unavailable. Resume in the app."
        }
    }
}

enum BackgroundAutomaticMaintenanceResubmissionPolicy {
    /// Only an interrupted automatic local run is resubmitted. Discovering new
    /// changed or stale assets remains coordinator-owned when a fresh,
    /// lifecycle-scheduled maintenance task launches.
    static func shouldResubmit(progress: AnalysisRunProgressSnapshot?) -> Bool {
        guard let progress,
              progress.origin == .automaticMaintenance,
              progress.status == .running || progress.status == .paused else { return false }
        return progress.nextPosition < progress.totalAssetCount
    }
}

/// Thread-safe progress bridge for the iOS 26 system UI. It intentionally
/// exposes only scalar progress and text; app state remains actor-owned.
@available(iOS 26.0, *)
final class ContinuedBackgroundProgress: @unchecked Sendable {
    private let task: BGContinuedProcessingTask
    private let lock = NSLock()
    private var lastFraction = 0.0
    private var lastCompletedUnitCount: Int64 = 0
    private var lastTotalUnitCount: Int64

    init(task: BGContinuedProcessingTask, totalUnitCount: Int64 = 1) {
        self.task = task
        lastTotalUnitCount = max(totalUnitCount, 1)
        task.progress.totalUnitCount = lastTotalUnitCount
        task.progress.completedUnitCount = 0
    }

    func update(completed: Int, total: Int, title: String, subtitle: String) {
        lock.lock()
        let incomingTotal = Int64(max(total, 1))
        let incomingCompleted = Int64(min(max(completed, 0), max(total, 1)))
        let incomingFraction = min(
            max(Double(incomingCompleted) / Double(incomingTotal), 0),
            1
        )
        lastFraction = max(lastFraction, incomingFraction)
        lastTotalUnitCount = max(lastTotalUnitCount, incomingTotal)
        let fractionCount = Int64(ceil(lastFraction * Double(lastTotalUnitCount)))
        lastCompletedUnitCount = min(
            max(lastCompletedUnitCount, max(incomingCompleted, fractionCount)),
            lastTotalUnitCount
        )
        task.progress.totalUnitCount = lastTotalUnitCount
        task.progress.completedUnitCount = lastCompletedUnitCount
        task.updateTitle(title, subtitle: subtitle)
        lock.unlock()
    }

    func complete() {
        lock.lock()
        lastFraction = 1
        lastCompletedUnitCount = lastTotalUnitCount
        task.progress.totalUnitCount = lastTotalUnitCount
        task.progress.completedUnitCount = lastCompletedUnitCount
        lock.unlock()
    }
}

enum BackgroundTaskLaunchBridge {
    /// BGTaskScheduler may invoke launch handlers on an arbitrary queue, so the
    /// callback itself must be nonisolated and hop before touching app state.
    nonisolated static func makeMainActorCallback<Value: Sendable>(
        _ operation: @escaping @MainActor @Sendable (Value) -> Void
    ) -> @Sendable (Value) -> Void {
        { value in
            Task { @MainActor in
                operation(value)
            }
        }
    }
}

@MainActor
final class BackgroundWorkController {
    static let shared = BackgroundWorkController()

    private enum ContinuedKind: Sendable {
        case analysis(runID: UUID, includeICloudItems: Bool)
        case export(jobID: UUID)
    }

    private weak var model: AppModel?
    private let stateWorker = BackgroundWorkStateWorker()
    private let constraintProvider: any BackgroundExecutionConstraintProviding
    private var registered = false
    private var pendingContinuedWork: [String: ContinuedKind] = [:]
    private var diagnosticHandler: (@MainActor @Sendable (BackgroundWorkDiagnosticEvent) -> Void)?
    private var bufferedDiagnostics: [BackgroundWorkDiagnosticEvent] = []

    init(
        constraintProvider: any BackgroundExecutionConstraintProviding = SystemBackgroundExecutionConstraints()
    ) {
        self.constraintProvider = constraintProvider
    }

    func attach(model: AppModel) {
        self.model = model
        diagnosticHandler = { [weak model] event in
            model?.recordBackgroundWorkDiagnostic(event)
        }
        let buffered = bufferedDiagnostics
        bufferedDiagnostics.removeAll(keepingCapacity: true)
        for event in buffered { diagnosticHandler?(event) }
    }

    func currentState() async -> BackgroundWorkState? {
        await stateWorker.latest()
    }

    func currentState(for kind: BackgroundWorkKind) async -> BackgroundWorkState? {
        await stateWorker.state(for: kind)
    }

    func reportProgress(kind: BackgroundWorkKind, completed: Int, total: Int) {
        Task { [stateWorker] in
            _ = await stateWorker.reportProgress(
                kind: kind,
                completed: completed,
                total: total
            )
        }
    }

    func currentConstraints() -> BackgroundExecutionConstraints {
        constraintProvider.currentConstraints()
    }

    func constraintDisposition(
        for policy: BackgroundProcessingPolicy
    ) -> BackgroundConstraintDisposition {
        BackgroundExecutionConstraintPolicy.disposition(
            for: policy,
            constraints: currentConstraints()
        )
    }

    func markConstraintPause(
        kind: BackgroundWorkKind,
        policy: BackgroundProcessingPolicy,
        reason: BackgroundWorkDeferralReason,
        completed: Int,
        total: Int
    ) {
        model?.pauseAnalysisForBackgroundConstraint(policy: policy, reason: reason)
        Task { [stateWorker] in
            _ = await stateWorker.transition(
                kind: kind,
                phase: policy.isAutomatic ? .waiting : .paused,
                completed: completed,
                total: total,
                policy: policy,
                deferralReason: reason,
                checkpoint: policy.isAutomatic ? nil : BackgroundWorkCheckpoint(
                    date: Date(),
                    completedUnitCount: completed,
                    totalUnitCount: total
                )
            )
        }
        emitDiagnostic(
            task: policy.isAutomatic ? .automaticMaintenance : .userAnalysis,
            action: .deferred,
            outcome: reason.rawValue
        )
    }

    /// Must be called during application construction, before launch finishes.
    func register() {
        guard !registered else { return }
        registered = true
        let scheduler = BGTaskScheduler.shared
        let refreshLaunchHandler = BackgroundTaskLaunchBridge.makeMainActorCallback {
            [weak self] (task: BGTask) in
            self?.handleRefresh(task)
        }
        let refreshRegistered = scheduler.register(
            forTaskWithIdentifier: BackgroundTaskIdentifiers.refresh,
            using: nil,
            launchHandler: refreshLaunchHandler
        )
        let analysisLaunchHandler = BackgroundTaskLaunchBridge.makeMainActorCallback {
            [weak self] (task: BGTask) in
            self?.handleProcessing(task)
        }
        let analysisRegistered = scheduler.register(
            forTaskWithIdentifier: BackgroundTaskIdentifiers.analysisProcessing,
            using: nil,
            launchHandler: analysisLaunchHandler
        )
        let maintenanceLaunchHandler = BackgroundTaskLaunchBridge.makeMainActorCallback {
            [weak self] (task: BGTask) in
            self?.handleMaintenance(task)
        }
        let maintenanceRegistered = scheduler.register(
            forTaskWithIdentifier: BackgroundTaskIdentifiers.maintenanceProcessing,
            using: nil,
            launchHandler: maintenanceLaunchHandler
        )
        emitRegistrationDiagnostic(.metadataRefresh, registered: refreshRegistered)
        emitRegistrationDiagnostic(.userAnalysis, registered: analysisRegistered)
        emitRegistrationDiagnostic(.automaticMaintenance, registered: maintenanceRegistered)
    }

    @discardableResult
    func scheduleRefresh() -> BackgroundTaskSchedulingOutcome {
        let request = BGAppRefreshTaskRequest(identifier: BackgroundTaskIdentifiers.refresh)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        return submit(
            request,
            task: .metadataRefresh,
            stateKind: .libraryRefresh,
            policy: nil,
            disposition: .run
        )
    }

    @discardableResult
    func scheduleUserAnalysisProcessing(
        includeICloudItems: Bool
    ) -> BackgroundTaskSchedulingOutcome {
        let request = BGProcessingTaskRequest(identifier: BackgroundTaskIdentifiers.analysisProcessing)
        let policy = BackgroundProcessingPolicy.userAnalysis(includeICloudItems: includeICloudItems)
        let disposition = constraintDisposition(for: policy)
        request.earliestBeginDate = Date(
            timeIntervalSinceNow: disposition == .run ? 60 : 15 * 60
        )
        request.requiresExternalPower = policy.requiresExternalPower
        request.requiresNetworkConnectivity = policy.requiresNetworkConnectivity
        return submit(
            request,
            task: .userAnalysis,
            stateKind: .analysis(runID: nil, includeICloudItems: includeICloudItems),
            policy: policy,
            disposition: disposition
        )
    }

    /// Reserved for automatic cache/index upkeep. It is deliberately not used
    /// to start a new user analysis and runs only under power-friendly policy.
    @discardableResult
    func scheduleAutomaticLocalMaintenance() -> BackgroundTaskSchedulingOutcome {
        let request = BGProcessingTaskRequest(identifier: BackgroundTaskIdentifiers.maintenanceProcessing)
        let policy = BackgroundProcessingPolicy.automaticLocalMaintenance
        let disposition = constraintDisposition(for: policy)
        request.earliestBeginDate = Date(
            timeIntervalSinceNow: disposition == .run ? 30 * 60 : 60 * 60
        )
        request.requiresExternalPower = policy.requiresExternalPower
        request.requiresNetworkConnectivity = policy.requiresNetworkConnectivity
        return submit(
            request,
            task: .automaticMaintenance,
            stateKind: .libraryMaintenance,
            policy: policy,
            disposition: disposition
        )
    }

    /// Attempts the iOS 26 immediate continued-processing grant at the moment a
    /// user-started analysis is accepted. A non-grant outcome is an intentional
    /// checkpointed/deferred fallback, not an analysis failure.
    func beginUserInitiatedAnalysis(
        runID: UUID,
        includeICloudItems: Bool
    ) -> BackgroundTaskSchedulingOutcome {
        guard UIApplication.shared.applicationState == .active else {
            return diagnosticOutcome(.appNotActive, task: .continuedAnalysis)
        }
        guard #available(iOS 26.0, *) else {
            return diagnosticOutcome(.unsupportedOS, task: .continuedAnalysis)
        }
        let policy = BackgroundProcessingPolicy.userAnalysis(
            includeICloudItems: includeICloudItems
        )
        if case let .pause(reason) = constraintDisposition(for: policy) {
            markConstraintPause(
                kind: .analysis(runID: runID, includeICloudItems: includeICloudItems),
                policy: policy,
                reason: reason,
                completed: model?.organizeViewModel.analysis.processedAssetCount ?? 0,
                total: model?.organizeViewModel.analysis.totalAssetCount ?? 0
            )
            let deferred = scheduleUserAnalysisProcessing(
                includeICloudItems: includeICloudItems
            )
            let outcome: BackgroundTaskSchedulingOutcome = deferred.acceptedByScheduler
                ? .scheduledForLater(reason)
                : deferred
            return diagnosticOutcome(outcome, task: .continuedAnalysis)
        }
        return submitContinued(
            kind: .analysis(runID: runID, includeICloudItems: includeICloudItems),
            title: "Analyzing photo library",
            subtitle: includeICloudItems ? "Including iCloud items" : "Using items on this device"
        )
    }

    func beginUserInitiatedExport(
        jobID: UUID,
        fileCount: Int
    ) -> BackgroundTaskSchedulingOutcome {
        guard UIApplication.shared.applicationState == .active else {
            return diagnosticOutcome(.appNotActive, task: .continuedExport)
        }
        guard #available(iOS 26.0, *) else {
            return diagnosticOutcome(.unsupportedOS, task: .continuedExport)
        }
        return submitContinued(
            kind: .export(jobID: jobID),
            title: "Exporting photos",
            subtitle: "0 of \(fileCount) files"
        )
    }

    private func submit(
        _ request: BGTaskRequest,
        task: BackgroundScheduledTask,
        stateKind: BackgroundWorkKind,
        policy: BackgroundProcessingPolicy?,
        disposition: BackgroundConstraintDisposition
    ) -> BackgroundTaskSchedulingOutcome {
        let outcome: BackgroundTaskSchedulingOutcome
        do {
            // Each deferred request uses a stable identifier. BackgroundTasks
            // atomically replaces an older unexecuted request with that ID, so
            // callers can safely resubmit on lifecycle/constraint changes.
            try BGTaskScheduler.shared.submit(request)
            if let reason = disposition.deferralReason {
                outcome = .scheduledForLater(reason)
            } else {
                outcome = .scheduled
            }
        } catch {
            outcome = .submissionFailure(error)
        }

        let phase: BackgroundWorkPhase
        let reason: BackgroundWorkDeferralReason?
        switch outcome {
        case .scheduled:
            phase = .waiting
            reason = .systemScheduling
        case let .scheduledForLater(deferralReason):
            phase = policy?.isAutomatic == true ? .waiting : .paused
            reason = deferralReason
        case .unavailable:
            phase = policy?.isAutomatic == false ? .paused : .waiting
            reason = .backgroundRefreshUnavailable
        default:
            phase = .failed
            reason = nil
        }
        Task { [stateWorker] in
            _ = await stateWorker.transition(
                kind: stateKind,
                phase: phase,
                policy: policy,
                deferralReason: reason
            )
        }
        emitDiagnostic(task: task, action: .scheduling, outcome: outcome.diagnosticValue)
        return outcome
    }

    private func emitRegistrationDiagnostic(
        _ task: BackgroundScheduledTask,
        registered: Bool
    ) {
        emitDiagnostic(
            task: task,
            action: registered ? .registered : .registrationFailed,
            outcome: registered ? "registered" : "identifier-not-permitted"
        )
    }

    private func diagnosticOutcome(
        _ outcome: BackgroundTaskSchedulingOutcome,
        task: BackgroundScheduledTask
    ) -> BackgroundTaskSchedulingOutcome {
        emitDiagnostic(task: task, action: .scheduling, outcome: outcome.diagnosticValue)
        return outcome
    }

    private func emitDiagnostic(
        task: BackgroundScheduledTask,
        action: BackgroundWorkDiagnosticEvent.Action,
        outcome: String
    ) {
        let event = BackgroundWorkDiagnosticEvent(
            task: task,
            action: action,
            outcome: outcome
        )
        if let diagnosticHandler {
            diagnosticHandler(event)
        } else {
            bufferedDiagnostics.append(event)
        }
    }

    private func deferProcessingTask(
        _ task: BGTask,
        model: AppModel,
        kind: BackgroundWorkKind,
        policy: BackgroundProcessingPolicy,
        reason: BackgroundWorkDeferralReason
    ) {
        let completion = BackgroundTaskCompletion(task: task)
        let operation = Task { @MainActor in
            model.pauseAnalysisForBackgroundConstraint(policy: policy, reason: reason)
            let processed = model.organizeViewModel.analysis.processedAssetCount
            let total = model.organizeViewModel.analysis.totalAssetCount
            _ = await self.stateWorker.transition(
                kind: kind,
                phase: .paused,
                completed: processed,
                total: total,
                policy: policy,
                deferralReason: reason,
                checkpoint: BackgroundWorkCheckpoint(
                    date: Date(),
                    completedUnitCount: processed,
                    totalUnitCount: total
                )
            )
            self.emitDiagnostic(
                task: .userAnalysis,
                action: .deferred,
                outcome: reason.rawValue
            )
            await model.checkpointAnalysisForBackgroundExpiration()
            model.presentAnalysisWaiting(policy: policy, reason: reason)
            _ = self.scheduleUserAnalysisProcessing(
                includeICloudItems: policy.requiresNetworkConnectivity
            )
        }
        task.expirationHandler = {
            guard completion.beginExpiration() else { return }
            operation.cancel()
            completion.finishAfterExpiration(success: false)
        }
        Task { @MainActor in
            await operation.value
            guard completion.beginCompletion() else { return }
            completion.finishClaimed(success: true)
        }
    }

    private func deferMaintenanceTask(
        _ task: BGTask,
        model: AppModel,
        reason: BackgroundWorkDeferralReason
    ) {
        let completion = BackgroundTaskCompletion(task: task)
        let operation = Task { @MainActor in
            model.pauseAnalysisForBackgroundConstraint(
                policy: .automaticLocalMaintenance,
                reason: reason
            )
            _ = await self.stateWorker.transition(
                kind: .libraryMaintenance,
                phase: .waiting,
                policy: .automaticLocalMaintenance,
                deferralReason: reason
            )
            self.emitDiagnostic(
                task: .automaticMaintenance,
                action: .deferred,
                outcome: reason.rawValue
            )
            if await model.shouldResubmitAutomaticMaintenance() {
                _ = self.scheduleAutomaticLocalMaintenance()
            }
        }
        task.expirationHandler = {
            guard completion.beginExpiration() else { return }
            operation.cancel()
            completion.finishAfterExpiration(success: false)
        }
        Task { @MainActor in
            await operation.value
            guard completion.beginCompletion() else { return }
            completion.finishClaimed(success: true)
        }
    }

    private func handleRefresh(_ task: BGTask) {
        guard let model else {
            task.setTaskCompleted(success: false)
            return
        }
        let executionScope = BackgroundExecutionScope.metadataRefresh
        model.backgroundExecutionDidBegin(scope: executionScope)
        let completion = BackgroundTaskCompletion(task: task)
        let work = Task { @MainActor [weak model] in
            _ = await self.stateWorker.transition(kind: .libraryRefresh, phase: .running)
            self.emitDiagnostic(task: .metadataRefresh, action: .started, outcome: "running")
            let success = await model?.performBackgroundRefresh() ?? false
            _ = await self.stateWorker.finish(kind: .libraryRefresh, success: success)
            self.emitDiagnostic(
                task: .metadataRefresh,
                action: .completed,
                outcome: success ? "success" : "failure"
            )
            return success
        }
        task.expirationHandler = {
            guard completion.beginExpiration() else { return }
            work.cancel()
            Task { @MainActor in
                _ = await work.value
                _ = await self.stateWorker.transition(
                    kind: .libraryRefresh,
                    phase: .waiting,
                    deferralReason: .systemExpiration
                )
                self.emitDiagnostic(
                    task: .metadataRefresh,
                    action: .expired,
                    outcome: BackgroundWorkDeferralReason.systemExpiration.rawValue
                )
                await model.backgroundExecutionDidEnd(scope: executionScope)
                completion.finishAfterExpiration(success: false)
            }
        }
        Task { @MainActor in
            let success = await work.value
            guard completion.beginCompletion() else { return }
            // Claim the entire completion path before releasing the execution
            // scope. Releasing can suspend while another worker checkpoints;
            // an expiration arriving during that suspension must not release
            // the same reference-counted scope a second time.
            await model.backgroundExecutionDidEnd(scope: executionScope)
            completion.finishClaimed(success: success)
        }
    }

    private func handleProcessing(_ task: BGTask) {
        guard let model else {
            task.setTaskCompleted(success: false)
            return
        }
        let includeICloudItems = model.organizeViewModel.analysis.includesICloudItems
        let policy = BackgroundProcessingPolicy.userAnalysis(
            includeICloudItems: includeICloudItems
        )
        let kind = BackgroundWorkKind.analysis(
            runID: nil,
            includeICloudItems: includeICloudItems
        )
        if let reason = constraintDisposition(for: policy).deferralReason {
            deferProcessingTask(
                task,
                model: model,
                kind: kind,
                policy: policy,
                reason: reason
            )
            return
        }

        let executionScope = BackgroundExecutionScope.analysis(runID: nil)
        model.backgroundExecutionDidBegin(scope: executionScope)
        let completion = BackgroundTaskCompletion(task: task)
        let work = Task { @MainActor [weak model] in
            _ = await self.stateWorker.transition(
                kind: kind,
                phase: .running,
                policy: policy
            )
            self.emitDiagnostic(task: .userAnalysis, action: .started, outcome: "running")
            let success = await model?.performBackgroundAnalysis() ?? false
            _ = await self.stateWorker.finish(
                kind: kind,
                success: success
            )
            self.emitDiagnostic(
                task: .userAnalysis,
                action: .completed,
                outcome: success ? "success" : "incomplete"
            )
            return success
        }
        task.expirationHandler = {
            guard completion.beginExpiration() else { return }
            work.cancel()
            Task { @MainActor in
                _ = await self.stateWorker.transition(
                    kind: kind,
                    phase: .checkpointing,
                    checkpoint: BackgroundWorkCheckpoint(
                        date: Date(),
                        completedUnitCount: model.organizeViewModel.analysis.processedAssetCount,
                        totalUnitCount: model.organizeViewModel.analysis.totalAssetCount
                    )
                )
                await model.checkpointAnalysisForBackgroundExpiration()
                model.presentAnalysisWaiting(
                    policy: policy,
                    reason: .systemExpiration
                )
                _ = await work.value
                _ = await self.stateWorker.transition(
                    kind: kind,
                    phase: .paused,
                    completed: model.organizeViewModel.analysis.processedAssetCount,
                    total: model.organizeViewModel.analysis.totalAssetCount,
                    policy: policy,
                    deferralReason: .systemExpiration,
                    checkpoint: BackgroundWorkCheckpoint(
                        date: Date(),
                        completedUnitCount: model.organizeViewModel.analysis.processedAssetCount,
                        totalUnitCount: model.organizeViewModel.analysis.totalAssetCount
                    )
                )
                self.emitDiagnostic(
                    task: .userAnalysis,
                    action: .expired,
                    outcome: BackgroundWorkDeferralReason.systemExpiration.rawValue
                )
                _ = self.scheduleUserAnalysisProcessing(
                    includeICloudItems: includeICloudItems
                )
                await model.backgroundExecutionDidEnd(scope: executionScope)
                completion.finishAfterExpiration(success: false)
            }
        }
        Task { @MainActor in
            let success = await work.value
            guard completion.beginCompletion() else { return }
            await model.backgroundExecutionDidEnd(scope: executionScope)
            completion.finishClaimed(success: success)
        }
    }

    private func handleMaintenance(_ task: BGTask) {
        guard let model else {
            task.setTaskCompleted(success: false)
            return
        }
        let policy = BackgroundProcessingPolicy.automaticLocalMaintenance
        if let reason = constraintDisposition(for: policy).deferralReason {
            deferMaintenanceTask(
                task,
                model: model,
                reason: reason
            )
            return
        }

        let executionScope = BackgroundExecutionScope.analysis(runID: nil)
        model.backgroundExecutionDidBegin(scope: executionScope)
        let completion = BackgroundTaskCompletion(task: task)
        let work = Task { @MainActor [weak model] in
            _ = await self.stateWorker.transition(
                kind: .libraryMaintenance,
                phase: .running,
                policy: policy
            )
            self.emitDiagnostic(task: .automaticMaintenance, action: .started, outcome: "running")
            let success = await model?.performBackgroundMaintenance() ?? false
            _ = await self.stateWorker.finish(
                kind: .libraryMaintenance,
                success: success
            )
            self.emitDiagnostic(
                task: .automaticMaintenance,
                action: .completed,
                outcome: success ? "success" : "incomplete"
            )
            return success
        }
        task.expirationHandler = {
            guard completion.beginExpiration() else { return }
            work.cancel()
            Task { @MainActor in
                await model.checkpointAnalysisForBackgroundExpiration()
                model.presentAnalysisWaiting(
                    policy: policy,
                    reason: .systemExpiration
                )
                _ = await work.value
                _ = await self.stateWorker.transition(
                    kind: .libraryMaintenance,
                    phase: .waiting,
                    completed: model.organizeViewModel.analysis.processedAssetCount,
                    total: model.organizeViewModel.analysis.totalAssetCount,
                    policy: policy,
                    deferralReason: .systemExpiration,
                    checkpoint: BackgroundWorkCheckpoint(
                        date: Date(),
                        completedUnitCount: model.organizeViewModel.analysis.processedAssetCount,
                        totalUnitCount: model.organizeViewModel.analysis.totalAssetCount
                    )
                )
                self.emitDiagnostic(
                    task: .automaticMaintenance,
                    action: .expired,
                    outcome: BackgroundWorkDeferralReason.systemExpiration.rawValue
                )
                if await model.shouldResubmitAutomaticMaintenance() {
                    _ = self.scheduleAutomaticLocalMaintenance()
                }
                await model.backgroundExecutionDidEnd(scope: executionScope)
                completion.finishAfterExpiration(success: false)
            }
        }
        Task { @MainActor in
            let success = await work.value
            guard completion.beginCompletion() else { return }
            await model.backgroundExecutionDidEnd(scope: executionScope)
            completion.finishClaimed(success: success)
        }
    }

    @available(iOS 26.0, *)
    private func deferContinuedAnalysisTask(
        _ task: BGContinuedProcessingTask,
        model: AppModel,
        runID: UUID,
        policy: BackgroundProcessingPolicy,
        reason: BackgroundWorkDeferralReason
    ) {
        let completion = BackgroundTaskCompletion(task: task)
        let operation = Task { @MainActor in
            model.pauseAnalysisForBackgroundConstraint(policy: policy, reason: reason)
            let processed = model.organizeViewModel.analysis.processedAssetCount
            let total = model.organizeViewModel.analysis.totalAssetCount
            _ = await self.stateWorker.transition(
                kind: .analysis(
                    runID: runID,
                    includeICloudItems: policy.requiresNetworkConnectivity
                ),
                phase: .paused,
                completed: processed,
                total: total,
                policy: policy,
                deferralReason: reason,
                checkpoint: BackgroundWorkCheckpoint(
                    date: Date(),
                    completedUnitCount: processed,
                    totalUnitCount: total
                )
            )
            self.emitDiagnostic(
                task: .continuedAnalysis,
                action: .deferred,
                outcome: reason.rawValue
            )
            await model.checkpointAnalysisForBackgroundExpiration(runID: runID)
            model.presentAnalysisWaiting(policy: policy, reason: reason)
            _ = self.scheduleUserAnalysisProcessing(
                includeICloudItems: policy.requiresNetworkConnectivity
            )
        }
        task.expirationHandler = {
            guard completion.beginExpiration() else { return }
            operation.cancel()
            completion.finishAfterExpiration(success: false)
        }
        Task { @MainActor in
            await operation.value
            guard completion.beginCompletion() else { return }
            completion.finishClaimed(success: true)
        }
    }

    @available(iOS 26.0, *)
    private func submitContinued(
        kind: ContinuedKind,
        title: String,
        subtitle: String
    ) -> BackgroundTaskSchedulingOutcome {
        let diagnosticTask: BackgroundScheduledTask = switch kind {
        case .analysis: .continuedAnalysis
        case .export: .continuedExport
        }
        let suffix: String = switch kind {
        case let .analysis(runID, _):
            "analysis-\(runID.uuidString.lowercased())-\(UUID().uuidString.lowercased())"
        case let .export(jobID):
            "export-\(jobID.uuidString.lowercased())-\(UUID().uuidString.lowercased())"
        }
        let identifier = BackgroundTaskIdentifiers.continuedPrefix + suffix
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: title,
            subtitle: subtitle
        )
        request.strategy = .fail
        pendingContinuedWork[identifier] = kind
        // The Info.plist advertises the wildcard, but iOS expects each
        // continued-processing instance to register its concrete identifier.
        // These registrations are explicitly exempt from the pre-launch
        // registration deadline. The UUID suffix guarantees register-once.
        let launchHandler = BackgroundTaskLaunchBridge.makeMainActorCallback {
            [weak self] (task: BGTask) in
            self?.handleContinued(task)
        }
        let didRegister = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: nil,
            launchHandler: launchHandler
        )
        guard didRegister else {
            pendingContinuedWork.removeValue(forKey: identifier)
            return diagnosticOutcome(.registrationFailed, task: diagnosticTask)
        }
        do {
            try BGTaskScheduler.shared.submit(request)
            let stateKind: BackgroundWorkKind = switch kind {
            case let .analysis(runID, includeICloudItems):
                .analysis(runID: runID, includeICloudItems: includeICloudItems)
            case let .export(jobID): .export(jobID: jobID)
            }
            Task { [stateWorker] in
                _ = await stateWorker.transition(
                    kind: stateKind,
                    phase: .waiting,
                    deferralReason: .systemScheduling
                )
            }
            return diagnosticOutcome(.scheduled, task: diagnosticTask)
        } catch {
            pendingContinuedWork.removeValue(forKey: identifier)
            return diagnosticOutcome(.submissionFailure(error), task: diagnosticTask)
        }
    }

    @available(iOS 26.0, *)
    private func handleContinued(_ genericTask: BGTask) {
        guard let task = genericTask as? BGContinuedProcessingTask,
              let model,
              let kind = pendingContinuedWork.removeValue(forKey: task.identifier) else {
            genericTask.setTaskCompleted(success: false)
            return
        }
        let diagnosticTask: BackgroundScheduledTask = switch kind {
        case .analysis: .continuedAnalysis
        case .export: .continuedExport
        }
        if case let .analysis(runID, includeICloudItems) = kind {
            let policy = BackgroundProcessingPolicy.userAnalysis(
                includeICloudItems: includeICloudItems
            )
            if let reason = constraintDisposition(for: policy).deferralReason {
                deferContinuedAnalysisTask(
                    task,
                    model: model,
                    runID: runID,
                    policy: policy,
                    reason: reason
                )
                return
            }
        }
        let executionScope: BackgroundExecutionScope = switch kind {
        case let .analysis(runID, _): .analysis(runID: runID)
        case let .export(jobID): .export(jobID: jobID)
        }
        model.backgroundExecutionDidBegin(scope: executionScope)
        let completion = BackgroundTaskCompletion(task: task)
        let progress = ContinuedBackgroundProgress(task: task)
        let work = Task { @MainActor [weak model] in
            guard let model else { return false }
            let stateKind: BackgroundWorkKind = switch kind {
            case let .analysis(runID, includeICloudItems):
                .analysis(runID: runID, includeICloudItems: includeICloudItems)
            case let .export(jobID): .export(jobID: jobID)
            }
            _ = await self.stateWorker.transition(kind: stateKind, phase: .running)
            self.emitDiagnostic(
                task: diagnosticTask,
                action: .started,
                outcome: "running"
            )
            let success: Bool
            switch kind {
            case let .analysis(runID, _):
                success = await model.waitForContinuedAnalysis(
                    runID: runID,
                    progress: progress
                )
            case let .export(jobID):
                success = await model.waitForContinuedExport(jobID: jobID, progress: progress)
            }
            _ = await self.stateWorker.finish(
                kind: stateKind,
                success: success
            )
            self.emitDiagnostic(
                task: diagnosticTask,
                action: .completed,
                outcome: success ? "success" : "incomplete"
            )
            return success
        }
        task.expirationHandler = {
            guard completion.beginExpiration() else { return }
            work.cancel()
            Task { @MainActor in
                switch kind {
                case let .analysis(runID, _):
                    await model.checkpointAnalysisForBackgroundExpiration(runID: runID)
                    model.presentAnalysisWaiting(
                        policy: .userAnalysis(
                            includeICloudItems: model.organizeViewModel.analysis.includesICloudItems
                        ),
                        reason: .systemExpiration
                    )
                    _ = await self.stateWorker.transition(
                        kind: .analysis(
                            runID: runID,
                            includeICloudItems: model.organizeViewModel.analysis.includesICloudItems
                        ),
                        phase: .paused,
                        completed: model.organizeViewModel.analysis.processedAssetCount,
                        total: model.organizeViewModel.analysis.totalAssetCount,
                        policy: .userAnalysis(
                            includeICloudItems: model.organizeViewModel.analysis.includesICloudItems
                        ),
                        deferralReason: .systemExpiration,
                        checkpoint: BackgroundWorkCheckpoint(
                            date: Date(),
                            completedUnitCount: model.organizeViewModel.analysis.processedAssetCount,
                            totalUnitCount: model.organizeViewModel.analysis.totalAssetCount
                        )
                    )
                    _ = self.scheduleUserAnalysisProcessing(
                        includeICloudItems: model.organizeViewModel.analysis.includesICloudItems
                    )
                case let .export(jobID):
                    await model.checkpointExportForBackgroundExpiration(jobID: jobID)
                }
                self.emitDiagnostic(
                    task: diagnosticTask,
                    action: .expired,
                    outcome: BackgroundWorkDeferralReason.systemExpiration.rawValue
                )
                _ = await work.value
                await model.backgroundExecutionDidEnd(scope: executionScope)
                completion.finishAfterExpiration(success: false)
            }
        }
        Task { @MainActor in
            let success = await work.value
            guard completion.beginCompletion() else { return }
            await model.backgroundExecutionDidEnd(scope: executionScope)
            if success { progress.complete() }
            completion.finishClaimed(success: success)
        }
    }
}

/// Arbitrates ownership of the complete BGTask teardown path. The winning path
/// owns checkpointing (when applicable), execution-scope release, and the sole
/// `setTaskCompleted` call, even when any of those operations suspend.
final class BackgroundTaskCompletionArbiter: @unchecked Sendable {
    enum Path: Equatable, Sendable {
        case normal
        case expiration
    }

    private enum State {
        case unclaimed
        case claimed(Path)
        case finished(Path)
    }

    private let lock = NSLock()
    private var state = State.unclaimed

    func claim(_ path: Path) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .unclaimed = state else { return false }
        state = .claimed(path)
        return true
    }

    func finish(_ path: Path) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case let .claimed(claimedPath) = state,
              claimedPath == path else { return false }
        state = .finished(path)
        return true
    }
}

private final class BackgroundTaskCompletion: @unchecked Sendable {
    private let task: BGTask
    private let arbiter = BackgroundTaskCompletionArbiter()

    init(task: BGTask) {
        self.task = task
    }

    /// Claims normal completion before async lease cleanup. The claim remains
    /// held across suspension through the sole `setTaskCompleted` call.
    func beginCompletion() -> Bool {
        arbiter.claim(.normal)
    }

    func finishClaimed(success: Bool) {
        guard arbiter.finish(.normal) else { return }
        task.setTaskCompleted(success: success)
    }

    /// Claims completion for the expiration path before cancellation begins so
    /// a normal result cannot race ahead of its durable worker checkpoint.
    func beginExpiration() -> Bool {
        arbiter.claim(.expiration)
    }

    func finishAfterExpiration(success: Bool) {
        guard arbiter.finish(.expiration) else { return }
        task.setTaskCompleted(success: success)
    }
}
