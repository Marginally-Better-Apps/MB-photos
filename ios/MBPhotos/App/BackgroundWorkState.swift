import Foundation

enum BackgroundWorkKind: Hashable, Sendable {
    case libraryRefresh
    case libraryMaintenance
    case analysis(runID: UUID?, includeICloudItems: Bool)
    case export(jobID: UUID)
}

enum BackgroundWorkPhase: Equatable, Sendable {
    case submitted
    /// A request exists, but iOS or a declared execution constraint has not
    /// granted runtime yet. Waiting is deliberately distinct from `running` so
    /// presentation code never animates progress for merely scheduled work.
    case waiting
    case running
    case checkpointing
    /// Work made durable progress and stopped at a safe boundary. It can be
    /// resumed by a later foreground action or background-processing grant.
    case paused
    case completed
    case failed
}

enum BackgroundWorkDeferralReason: String, Equatable, Sendable {
    case systemScheduling
    case lowPowerMode
    case thermalFair
    case thermalSerious
    case thermalCritical
    case backgroundRefreshUnavailable
    case systemExpiration

    var isPowerOrThermalConstraint: Bool {
        switch self {
        case .lowPowerMode, .thermalFair, .thermalSerious, .thermalCritical:
            true
        case .systemScheduling, .backgroundRefreshUnavailable, .systemExpiration:
            false
        }
    }
}

struct BackgroundWorkCheckpoint: Equatable, Sendable {
    let date: Date
    let completedUnitCount: Int
    let totalUnitCount: Int
}

/// Immutable worker-to-presentation/background-scheduler boundary. Revisions
/// allow delayed callbacks to be discarded without observing mutable coordinator
/// internals from a background launch handler.
struct BackgroundWorkState: Equatable, Sendable {
    let revision: UInt64
    let kind: BackgroundWorkKind
    let phase: BackgroundWorkPhase
    let completedUnitCount: Int
    let totalUnitCount: Int
    let processingPolicy: BackgroundProcessingPolicy?
    let deferralReason: BackgroundWorkDeferralReason?
    let checkpoint: BackgroundWorkCheckpoint?
}

actor BackgroundWorkStateWorker {
    private var revision: UInt64 = 0
    private var state: BackgroundWorkState?
    private var stateByKind: [BackgroundWorkKind: BackgroundWorkState] = [:]

    func transition(
        kind: BackgroundWorkKind,
        phase: BackgroundWorkPhase,
        completed: Int = 0,
        total: Int = 0,
        policy: BackgroundProcessingPolicy? = nil,
        deferralReason: BackgroundWorkDeferralReason? = nil,
        checkpoint: BackgroundWorkCheckpoint? = nil
    ) -> BackgroundWorkState {
        revision &+= 1
        let previous = stateByKind[kind]
        let boundedTotal = max(total, previous?.totalUnitCount ?? 0)
        let boundedCompleted = min(
            max(completed, previous?.completedUnitCount ?? 0),
            max(boundedTotal, completed)
        )
        let next = BackgroundWorkState(
            revision: revision,
            kind: kind,
            phase: phase,
            completedUnitCount: boundedCompleted,
            totalUnitCount: max(boundedTotal, boundedCompleted),
            processingPolicy: policy ?? previous?.processingPolicy,
            deferralReason: phase == .waiting || phase == .paused
                ? (deferralReason ?? previous?.deferralReason)
                : nil,
            checkpoint: checkpoint ?? previous?.checkpoint
        )
        stateByKind[kind] = next
        state = next
        return next
    }

    /// Progress callbacks are intentionally narrower than lifecycle
    /// transitions. A callback queued before completion may reach this actor
    /// afterward; it must not resurrect terminal work as running.
    func reportProgress(
        kind: BackgroundWorkKind,
        completed: Int,
        total: Int
    ) -> BackgroundWorkState? {
        if let existing = stateByKind[kind] {
            // Every real execution path explicitly transitions to `.running`
            // before publishing progress. A callback delayed behind a pause,
            // deferral, or terminal transition must not manufacture activity.
            guard existing.phase == .running else { return existing }
        }
        return transition(
            kind: kind,
            phase: .running,
            completed: completed,
            total: total
        )
    }


    /// Completes a work item without overwriting a constraint-driven pause that
    /// raced with the worker's final callback.
    func finish(kind: BackgroundWorkKind, success: Bool) -> BackgroundWorkState? {
        if let existing = stateByKind[kind],
           existing.phase == .paused || existing.phase == .waiting {
            return existing
        }
        return transition(
            kind: kind,
            phase: success ? .completed : .failed
        )
    }

    func latest() -> BackgroundWorkState? { state }

    func state(for kind: BackgroundWorkKind) -> BackgroundWorkState? {
        stateByKind[kind]
    }
}
