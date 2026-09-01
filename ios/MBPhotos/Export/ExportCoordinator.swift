import Foundation
import Dispatch
import UIKit

enum ExportPhase: String, Sendable {
    case idle
    case planning
    case preparingResource = "Downloading PhotoKit resource"
    case renderingThumbnail = "Creating library thumbnail"
    case hashing = "Checking file"
    case transferring = "Transferring"
    case verifying = "Verifying"
    case paused = "Paused"
    case completed = "Completed"
    case completedWithFailures = "Completed with failures"
    case failed = "Needs attention"
}

struct ExportProgressState: Equatable, Sendable {
    var phase: ExportPhase = .idle
    var currentFilename = ""
    var currentFileIndex = 0
    var totalFileCount = 0
    var currentFileFraction = 0.0
    var acknowledgedBytes: Int64 = 0
    var currentFileBytes: Int64 = 0
    var verifiedFileCount = 0
    var skippedFileCount = 0
    var failedFileCount = 0
    var lastMessage: String?

    var overallFraction: Double {
        if phase == .completed || phase == .completedWithFailures { return 1 }
        guard totalFileCount > 0 else {
            return 0
        }
        let completedBeforeCurrent = max(currentFileIndex - 1, 0)
        return min(
            max(
                (Double(completedBeforeCurrent) + min(max(currentFileFraction, 0), 1))
                    / Double(totalFileCount),
                0
            ),
            1
        )
    }

    mutating func beginFile(index: Int, filename: String) {
        currentFileIndex = index
        currentFilename = filename
        currentFileFraction = 0
        acknowledgedBytes = 0
        currentFileBytes = 0
    }

    mutating func advanceCurrentFile(
        through stage: ExportFileWorkStage,
        phaseFraction: Double
    ) {
        let candidate = stage.start + stage.weight * Self.boundedUnitFraction(phaseFraction)
        currentFileFraction = max(Self.boundedUnitFraction(currentFileFraction), candidate)
    }

    mutating func completeCurrentFile() {
        currentFileFraction = 1
    }

    private static func boundedUnitFraction(_ value: Double) -> Double {
        guard value.isFinite else { return value == .infinity ? 1 : 0 }
        return min(max(value, 0), 1)
    }
}

/// End-to-end progress bands for one file. Preparation and hashing callbacks
/// report work within their own bands, while acknowledged upload bytes occupy
/// most of the estimate. Verification reserves the final portion so an upload
/// never presents an uncommitted file as complete.
enum ExportFileWorkStage: Sendable {
    case preparation
    case hashing
    case transfer
    case verification

    fileprivate var start: Double {
        switch self {
        case .preparation: 0
        case .hashing: 0.15
        case .transfer: 0.25
        case .verification: 0.95
        }
    }

    fileprivate var weight: Double {
        switch self {
        case .preparation: 0.15
        case .hashing: 0.10
        case .transfer: 0.70
        case .verification: 0.05
        }
    }
}

/// Immutable, revision-tagged state emitted by `ExportWorker`.  The stream is
/// buffering-newest, so a slow view can never back-pressure hashing, PhotoKit,
/// or the LAN transfer.
struct ExportEvent: Sendable {
    let revision: UInt64
    let progress: ExportProgressState
    let destination: Destination?
    let isConnected: Bool
    let isRunning: Bool
    let completionReport: CompletionReport?
    let currentPlan: PlannedExport?
    let hasPendingPreflight: Bool
}

/// Deterministic state machine for the export event cadence. Delayed callbacks
/// carry a token so a callback that was already enqueued before cancellation
/// cannot publish after a newer direct publication reset the 10 Hz window.
struct ExportPublicationThrottle: Sendable {
    enum Decision: Equatable, Sendable {
        case publishNow(cancelPending: Bool)
        case schedule(token: UInt64, delayNanoseconds: UInt64)
        case none
    }

    static let tenHertzIntervalNanoseconds: UInt64 = 100_000_000

    let minimumIntervalNanoseconds: UInt64
    private(set) var lastPublicationNanoseconds: UInt64?
    private(set) var pendingToken: UInt64?
    private var nextToken: UInt64 = 0

    init(minimumIntervalNanoseconds: UInt64 = tenHertzIntervalNanoseconds) {
        self.minimumIntervalNanoseconds = max(minimumIntervalNanoseconds, 1)
    }

    mutating func request(at now: UInt64, immediate: Bool) -> Decision {
        let elapsed = elapsedNanoseconds(at: now)
        if immediate || elapsed >= minimumIntervalNanoseconds {
            let cancelPending = pendingToken != nil
            pendingToken = nil
            lastPublicationNanoseconds = now
            return .publishNow(cancelPending: cancelPending)
        }

        guard pendingToken == nil else { return .none }
        nextToken &+= 1
        let token = nextToken
        pendingToken = token
        return .schedule(
            token: token,
            delayNanoseconds: minimumIntervalNanoseconds - elapsed
        )
    }

    mutating func delayedCallbackFired(token: UInt64, at now: UInt64) -> Decision {
        guard pendingToken == token else { return .none }
        let elapsed = elapsedNanoseconds(at: now)
        guard elapsed >= minimumIntervalNanoseconds else {
            return .schedule(
                token: token,
                delayNanoseconds: minimumIntervalNanoseconds - elapsed
            )
        }
        pendingToken = nil
        lastPublicationNanoseconds = now
        return .publishNow(cancelPending: false)
    }

    private func elapsedNanoseconds(at now: UInt64) -> UInt64 {
        guard let lastPublicationNanoseconds else {
            return minimumIntervalNanoseconds
        }
        guard now >= lastPublicationNanoseconds else {
            // A monotonic clock should not move backwards, but treating an
            // unexpected wrap/reset as a full interval avoids starvation.
            return minimumIntervalNanoseconds
        }
        return now - lastPublicationNanoseconds
    }
}

actor StagedRenditionStore {
    struct Preparation: Sendable {
        let finalURL: URL
        let workingURL: URL
        let markerURL: URL
        let isReady: Bool
    }

    private let root: URL

    init(root: URL) {
        self.root = root
    }

    static func applicationStore() throws -> StagedRenditionStore {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return StagedRenditionStore(root: support.appending(path: "MBPhotos/Staging", directoryHint: .isDirectory))
    }

    func preparation(jobID: UUID, file: ExportFile) throws -> Preparation {
        let directory = root.appending(path: jobID.uuidString.lowercased(), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = (file.proposedRelativePath as NSString).pathExtension
        let finalName = ext.isEmpty ? file.fileId.uuidString.lowercased() : "\(file.fileId.uuidString.lowercased()).\(ext)"
        let final = directory.appending(path: finalName)
        let working = directory.appending(path: "\(finalName).working")
        let marker = directory.appending(path: "\(finalName).ready")
        let expected = file.sourceRevision
        let markerValue = try? String(contentsOf: marker, encoding: .utf8)
        let ready = markerValue == expected && FileManager.default.fileExists(atPath: final.path)
        return Preparation(finalURL: final, workingURL: working, markerURL: marker, isReady: ready)
    }

    func reset(_ preparation: Preparation) throws {
        for url in [preparation.workingURL, preparation.finalURL, preparation.markerURL]
        where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func markReady(_ preparation: Preparation, sourceRevision: String) throws {
        if FileManager.default.fileExists(atPath: preparation.finalURL.path) {
            try FileManager.default.removeItem(at: preparation.finalURL)
        }
        try FileManager.default.moveItem(at: preparation.workingURL, to: preparation.finalURL)
        try Data(sourceRevision.utf8).write(to: preparation.markerURL, options: .atomic)
    }

    func removeCommitted(_ preparation: Preparation) {
        for url in [preparation.workingURL, preparation.finalURL, preparation.markerURL] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func discard(jobID: UUID) throws {
        let directory = root.appending(path: jobID.uuidString.lowercased(), directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// Recovers the narrow crash window between a durable terminal ledger
    /// commit and deletion of its prepared renditions. Unknown and nonterminal
    /// directories are deliberately retained because they may be resumable.
    @discardableResult
    func sweepTerminalJobs(using ledger: SQLiteLedger) async throws -> Int {
        let terminalJobIDs = try await ledger.terminalExportJobIDs()
        guard !terminalJobIDs.isEmpty,
              FileManager.default.fileExists(atPath: root.path) else { return 0 }

        let children = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var removedCount = 0
        var firstError: Error?
        for child in children {
            try Task.checkCancellation()
            guard let jobID = UUID(uuidString: child.lastPathComponent),
                  terminalJobIDs.contains(jobID) else { continue }
            do {
                try FileManager.default.removeItem(at: child)
                removedCount += 1
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
        return removedCount
    }
}

private actor ExportWorker {
    nonisolated let events: AsyncStream<ExportEvent>

    private var progress = ExportProgressState() {
        didSet { schedulePublication() }
    }
    private var destination: Destination? {
        didSet { schedulePublication(immediate: true) }
    }
    private var isConnected = false {
        didSet { schedulePublication(immediate: true) }
    }
    private var isRunning = false {
        didSet { schedulePublication(immediate: !isRunning) }
    }
    private var completionReport: CompletionReport? {
        didSet { schedulePublication(immediate: true) }
    }

    private let ledger: SQLiteLedger
    private let resourceProvider: any PhotoResourceMaterializing
    private let thumbnailRenderer: any ThumbnailRendering
    private let staging: StagedRenditionStore
    private var client: TransferClient?
    private var activeTask: Task<Void, Never>?
    private var pendingPreflightJobID: UUID? {
        didSet { schedulePublication() }
    }
    private var currentPlan: PlannedExport? {
        didSet { schedulePublication() }
    }

    private let eventContinuation: AsyncStream<ExportEvent>.Continuation
    private var eventRevision: UInt64 = 0
    private var publicationThrottle = ExportPublicationThrottle()
    private var pendingPublication: Task<Void, Never>?
    private var fileGeneration: UInt64 = 0
    private var executionGeneration: UInt64 = 0

    init(
        ledger: SQLiteLedger,
        resourceProvider: any PhotoResourceMaterializing = PhotoKitRenditionProvider(),
        thumbnailRenderer: any ThumbnailRendering = PhotoKitThumbnailRenderer(),
        staging: StagedRenditionStore
    ) {
        var continuation: AsyncStream<ExportEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            continuation = $0
        }
        self.eventContinuation = continuation
        self.ledger = ledger
        self.resourceProvider = resourceProvider
        self.thumbnailRenderer = thumbnailRenderer
        self.staging = staging
    }

    deinit {
        pendingPublication?.cancel()
        eventContinuation.finish()
    }

    func publishCurrentState() {
        publish()
    }

    func connect(payload: PairingPayload, instanceID: UUID, appVersion: String) async throws {
        guard !isRunning else { return }
        progress.lastMessage = "Checking receiver identity…"
        let newClient = TransferClient(payload: payload)
        let response = try await newClient.pair(instanceID: instanceID, appVersion: appVersion)
        if let pendingPreflightJobID, let client {
            _ = try? await client.abandonJob(jobID: pendingPreflightJobID, reason: .clientReset)
            try? await ledger.updateJobStatus(.abandoned, jobID: pendingPreflightJobID)
            self.pendingPreflightJobID = nil
        }
        self.client = newClient
        destination = response.destination
        isConnected = true
        progress.lastMessage = "Connected to \(response.destination.displayName)"
    }

    func begin(_ plan: PlannedExport, requestedAt: Date) async {
        guard client != nil, !isRunning else { return }
        executionGeneration &+= 1
        let generation = executionGeneration
        isRunning = true
        pendingPreflightJobID = nil
        currentPlan = plan
        completionReport = nil
        progress = ExportProgressState(
            phase: .planning,
            totalFileCount: plan.job.files.count,
            lastMessage: "Confirming destination paths…"
        )
        publish(immediate: true)

        do {
            try checkExecution(generation)
            let activated = try await ledger.activateJobForTransfer(
                plan.job,
                requestedAt: requestedAt
            )
            try checkExecution(generation)
            guard activated else {
                finishRun(
                    phase: .paused,
                    message: "This export was paused or finished before startup completed."
                )
                return
            }
            activeTask = Task { [weak self] in
                await self?.run(plan, generation: generation)
            }
        } catch is CancellationError {
            _ = try? await ledger.pauseJobIfActive(jobID: plan.job.jobId)
            finishRun(phase: .paused, message: "Paused before transfer startup completed.")
        } catch {
            _ = try? await ledger.pauseJobIfActive(jobID: plan.job.jobId)
            finishRun(phase: .failed, message: error.localizedDescription)
        }
    }

    func reconcilePreflight(_ plan: PlannedExport) async throws -> PlannedExport {
        guard let client else {
            throw TransferError.incompatibleReceiver("pair with the Windows receiver before reviewing the export")
        }
        if let previous = pendingPreflightJobID, previous != plan.job.jobId {
            _ = try? await client.abandonJob(jobID: previous, reason: .clientReset)
        }
        try await ledger.savePlannedJob(plan.job)
        let remotePlan = try await client.createOrReconcileJob(plan.job)
        try await validateDestinationBinding(
            jobID: plan.job.jobId,
            receivedDestinationID: remotePlan.destination.destinationId
        )
        guard remotePlan.state == .planned || remotePlan.state == .transferring || remotePlan.state == .paused else {
            throw TransferError.invalidResponse
        }
        try validateDecisions(remotePlan.decisions, files: plan.job.files)
        try await ledger.attachDestination(remotePlan.destination, to: plan.job.jobId)
        destination = remotePlan.destination
        pendingPreflightJobID = plan.job.jobId
        return PlannedExport(
            job: plan.job,
            sourceResourcesByFileID: plan.sourceResourcesByFileID,
            sourceAssetIDsByFileID: plan.sourceAssetIDsByFileID,
            preflight: plan.preflight.reconciled(with: remotePlan)
        )
    }

    func discardPendingPreflight() async {
        guard !isRunning, let jobID = pendingPreflightJobID else { return }
        await discardPendingPreflight(jobID: jobID)
    }

    /// Abandons only the preflight that produced `jobID`. This lets the
    /// presentation layer clean up a superseded planning generation without
    /// accidentally discarding a newer preflight that reconciled meanwhile.
    func discardPendingPreflight(jobID: UUID) async {
        guard currentPlan?.job.jobId != jobID else { return }
        if pendingPreflightJobID == jobID {
            pendingPreflightJobID = nil
        }
        if let client {
            _ = try? await client.abandonJob(jobID: jobID, reason: .clientReset)
        }
        try? await ledger.updateJobStatus(.abandoned, jobID: jobID)
    }

    func pause(expectedJobID: UUID? = nil) {
        guard isRunning, let currentJobID = currentPlan?.job.jobId else { return }
        guard expectedJobID == nil || expectedJobID == currentJobID else { return }
        executionGeneration &+= 1
        fileGeneration &+= 1
        activeTask?.cancel()
        progress.phase = .paused
        progress.lastMessage = "Paused safely. Pair again if the Windows receiver restarts."
    }

    func checkpointAndPause(expectedJobID: UUID? = nil) async {
        guard !Task.isCancelled else { return }
        guard isRunning, let jobID = currentPlan?.job.jobId else { return }
        guard expectedJobID == nil || expectedJobID == jobID else { return }
        executionGeneration &+= 1
        fileGeneration &+= 1
        activeTask?.cancel()

        // PhotoKit's original-resource writer is not guaranteed to return before
        // the app's finite background time expires. Persist the safe boundary
        // without waiting for that API: only receiver acknowledgements advance
        // the chunk cursor, and the cancelled run remains single-flight until it
        // actually unwinds.
        let didPause = (try? await ledger.pauseJobIfActive(jobID: jobID)) ?? false
        guard didPause, isRunning, currentPlan?.job.jobId == jobID else { return }
        progress.phase = .paused
        progress.lastMessage = "Paused safely after the last receiver-acknowledged chunk."
        publish(immediate: true)
    }

    func retry(requestedAt: Date) async {
        guard let plan = currentPlan, !isRunning else { return }
        await begin(plan, requestedAt: requestedAt)
    }

    func discardCurrentJob(expectedJobID: UUID? = nil) async {
        guard let jobID = currentPlan?.job.jobId else { return }
        guard expectedJobID == nil || expectedJobID == jobID else { return }
        executionGeneration &+= 1
        fileGeneration &+= 1
        let task = activeTask
        task?.cancel()
        if let task { await task.value }
        if let client {
            _ = try? await client.abandonJob(jobID: jobID, reason: .userDiscarded)
        }
        // Publish the terminal allow-list state before best-effort file
        // deletion. A force-quit at any later instruction is recovered by the
        // startup/maintenance staging sweep.
        try? await ledger.updateJobStatus(.abandoned, jobID: jobID)
        try? await staging.discard(jobID: jobID)
        currentPlan = nil
        isRunning = false
        progress.phase = .idle
        progress.lastMessage = "Job discarded. Verified files on the PC were not removed."
        publish(immediate: true)
    }

    func dismissCompletion() {
        guard !isRunning,
              progress.phase == .completed || progress.phase == .completedWithFailures else { return }
        currentPlan = nil
        completionReport = nil
        progress = ExportProgressState()
        publish(immediate: true)
    }

    private func run(_ plan: PlannedExport, generation execution: UInt64) async {
        guard let client else {
            finishRun(phase: .failed, message: "Scan the current receiver QR code first.")
            return
        }
        do {
            try checkExecution(execution)
            let remotePlan = try await client.createOrReconcileJob(plan.job)
            try checkExecution(execution)
            try await validateDestinationBinding(
                jobID: plan.job.jobId,
                receivedDestinationID: remotePlan.destination.destinationId
            )
            try await ledger.attachDestination(remotePlan.destination, to: plan.job.jobId)
            try checkExecution(execution)
            destination = remotePlan.destination
            if remotePlan.state == .completed || remotePlan.state == .completedWithFailures {
                let status = try await client.jobStatus(jobID: plan.job.jobId)
                try checkExecution(execution)
                guard status.jobId == plan.job.jobId,
                      status.destination.destinationId == remotePlan.destination.destinationId,
                      let report = status.report,
                      report.jobId == plan.job.jobId,
                      report.destinationId == remotePlan.destination.destinationId
                else { throw TransferError.invalidResponse }
                let didComplete = try await ledger.completeJob(report)
                guard didComplete else { throw CancellationError() }
                // A remotely terminal job is no longer resumable. Sweep any
                // rendition left by a prior terminal per-file failure before
                // installing the completion report.
                try? await staging.discard(jobID: plan.job.jobId)
                adoptCompletion(report)
                return
            }
            try validateDecisions(remotePlan.decisions, files: plan.job.files)
            let decisions = Dictionary(uniqueKeysWithValues: remotePlan.decisions.map { ($0.fileId, $0) })
            var successfulFileIDs: Set<UUID> = []
            var terminalFailures: [CompletionFailure] = []

            for (index, file) in plan.job.files.enumerated() {
                try checkExecution(execution)
                fileGeneration &+= 1
                let generation = fileGeneration
                guard let decision = decisions[file.fileId] else { throw TransferError.invalidResponse }
                // Keep rollover atomic: the next index and its zero fraction
                // represent the same overall position as the completed file.
                progress.beginFile(index: index + 1, filename: file.originalFilename)

                switch decision.action {
                case .skip:
                    try await ledger.recordFile(
                        file,
                        jobID: plan.job.jobId,
                        status: .skipped,
                        acceptedPath: decision.acceptedRelativePath,
                        digest: nil,
                        acknowledgedChunkCount: decision.nextChunkIndex
                    )
                    successfulFileIDs.insert(file.fileId)
                    progress.skippedFileCount += 1
                    completeCurrentFile(generation: generation)
                case .conflict:
                    let code: APIErrorCode
                    let message: String
                    switch decision.reason {
                    case .masterConflict:
                        code = .masterConflict
                        message = "The existing Master file was changed outside MB Photos and was left untouched."
                    case .sourceUnavailable:
                        code = .unavailableSource
                        message = "The selected Photos resource is no longer available."
                    default:
                        code = .pathConflict
                        message = "The receiver could not allocate a safe destination path."
                    }
                    let failure = CompletionFailure(
                        fileId: file.fileId,
                        code: code,
                        message: message,
                        retryable: false
                    )
                    try await ledger.recordFile(
                        file,
                        jobID: plan.job.jobId,
                        status: .failed,
                        acceptedPath: decision.acceptedRelativePath,
                        digest: nil,
                        acknowledgedChunkCount: 0,
                        error: failure.message
                    )
                    terminalFailures.append(failure)
                    progress.failedFileCount += 1
                    completeCurrentFile(generation: generation)
                case .upload, .resume:
                    guard decision.acceptedRelativePath != nil else {
                        throw TransferError.decisionConflict(file.proposedRelativePath)
                    }
                    do {
                        let prepared = try await prepare(file: file, plan: plan, generation: generation)
                        try checkExecution(execution)
                        // The worker actor owns the file loop. FileDigest checks
                        // cancellation between bounded reads so expiration can
                        // checkpoint before another upload begins.
                        let digest = try await computeDigest(
                            url: prepared.finalURL,
                            generation: generation
                        )
                        try checkExecution(execution)
                        progress.currentFileBytes = digest.byteCount
                        progress.phase = .transferring
                        advanceCurrentFile(
                            through: .transfer,
                            phaseFraction: 0,
                            generation: generation
                        )
                        let acknowledgedChunks = try await client.uploadFile(
                            jobID: plan.job.jobId,
                            fileID: file.fileId,
                            localURL: prepared.finalURL,
                            digest: digest,
                            startingChunkIndex: decision.nextChunkIndex
                        ) { [weak self] bytes in
                            Task {
                                await self?.recordAcknowledgedBytes(
                                    bytes,
                                    total: digest.byteCount,
                                    generation: generation
                                )
                            }
                        }
                        try checkExecution(execution)
                        recordAcknowledgedBytes(
                            digest.byteCount,
                            total: digest.byteCount,
                            generation: generation
                        )
                        progress.phase = .verifying
                        advanceCurrentFile(
                            through: .verification,
                            phaseFraction: 0,
                            generation: generation
                        )
                        let receipt = try await client.commitFile(
                            jobID: plan.job.jobId,
                            fileID: file.fileId,
                            digest: digest
                        )
                        try checkExecution(execution)
                        try await ledger.recordFile(
                            file,
                            jobID: plan.job.jobId,
                            status: .verified,
                            acceptedPath: receipt.relativePath,
                            digest: digest,
                            acknowledgedChunkCount: acknowledgedChunks
                        )
                        await staging.removeCommitted(prepared)
                        successfulFileIDs.insert(file.fileId)
                        progress.verifiedFileCount += 1
                        completeCurrentFile(generation: generation)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        guard let failure = terminalFailure(for: error, fileID: file.fileId) else {
                            // Authentication, network, receiver disk, and other
                            // retryable failures leave the receiver file pending.
                            // The outer handler pauses the whole job for resume.
                            throw error
                        }
                        try await ledger.recordFile(
                            file,
                            jobID: plan.job.jobId,
                            status: .failed,
                            acceptedPath: decision.acceptedRelativePath,
                            digest: nil,
                            acknowledgedChunkCount: decision.nextChunkIndex,
                            error: failure.message
                        )
                        terminalFailures.append(failure)
                        progress.failedFileCount += 1
                        progress.lastMessage = failure.message
                        completeCurrentFile(generation: generation)
                    }
                }
            }

            try checkExecution(execution)
            try await recordVerifiedAssetRevisions(
                job: plan.job,
                destinationID: remotePlan.destination.destinationId,
                successfulFileIDs: successfulFileIDs,
                generation: execution
            )
            try checkExecution(execution)
            let report = try await client.completeJob(
                jobID: plan.job.jobId,
                failures: terminalFailures
            )
            try checkExecution(execution)
            let didComplete = try await ledger.completeJob(report)
            guard didComplete else { throw CancellationError() }
            // Preserve staging only for paused/resumable jobs. Once receiver
            // and ledger completion are durable, terminal failures cannot be
            // retried in this job and their prepared files must not be orphaned.
            try? await staging.discard(jobID: plan.job.jobId)
            adoptCompletion(report)
        } catch is CancellationError {
            _ = try? await ledger.pauseJobIfActive(jobID: plan.job.jobId)
            finishRun(phase: .paused, message: "Paused after the last acknowledged chunk.")
        } catch {
            _ = try? await ledger.pauseJobIfActive(jobID: plan.job.jobId)
            finishRun(phase: .failed, message: error.localizedDescription)
        }
    }

    private func prepare(
        file: ExportFile,
        plan: PlannedExport,
        generation: UInt64
    ) async throws -> StagedRenditionStore.Preparation {
        let preparation = try await staging.preparation(jobID: plan.job.jobId, file: file)
        progress.phase = file.provenance == .exactPhotoKitResource
            ? .preparingResource
            : .renderingThumbnail
        advanceCurrentFile(
            through: .preparation,
            phaseFraction: 0,
            generation: generation
        )
        if preparation.isReady {
            advanceCurrentFile(
                through: .preparation,
                phaseFraction: 1,
                generation: generation
            )
            return preparation
        }
        try await staging.reset(preparation)
        guard let sourceAssetID = plan.sourceAssetIDsByFileID[file.fileId] else {
            throw RenditionError.assetUnavailable(file.assetId.uuidString)
        }
        switch file.provenance {
        case .exactPhotoKitResource:
            guard let descriptor = plan.sourceResourcesByFileID[file.fileId] else {
                throw RenditionError.resourceUnavailable(file.originalFilename)
            }
            try await resourceProvider.materializeResource(
                assetID: sourceAssetID,
                descriptor: descriptor,
                to: preparation.workingURL
            ) { [weak self] fraction in
                Task { await self?.recordPreparationProgress(fraction, generation: generation) }
            }
        case .generatedThumbnail:
            try await thumbnailRenderer.renderThumbnail(
                assetID: sourceAssetID,
                to: preparation.workingURL
            ) { [weak self] fraction in
                Task { await self?.recordPreparationProgress(fraction, generation: generation) }
            }
        }
        try Task.checkCancellation()
        try await staging.markReady(preparation, sourceRevision: file.sourceRevision)
        advanceCurrentFile(
            through: .preparation,
            phaseFraction: 1,
            generation: generation
        )
        return try await staging.preparation(jobID: plan.job.jobId, file: file)
    }

    private func computeDigest(url: URL, generation: UInt64) async throws -> FileDigest {
        progress.phase = .hashing
        advanceCurrentFile(
            through: .hashing,
            phaseFraction: 0,
            generation: generation
        )
        let hashingTask = Task.detached(priority: .utility) {
            try FileDigest.compute(url: url) { [weak self] fraction in
                Task {
                    await self?.recordHashingProgress(fraction, generation: generation)
                }
            }
        }
        let digest = try await withTaskCancellationHandler {
            try await hashingTask.value
        } onCancel: {
            hashingTask.cancel()
        }
        advanceCurrentFile(
            through: .hashing,
            phaseFraction: 1,
            generation: generation
        )
        return digest
    }

    private func recordVerifiedAssetRevisions(
        job: ExportJob,
        destinationID: UUID,
        successfulFileIDs: Set<UUID>,
        generation: UInt64
    ) async throws {
        let batchSize = 256
        var batch: [VerifiedAssetExportRecord] = []
        batch.reserveCapacity(batchSize)

        for (offset, asset) in job.assets.enumerated() {
            if offset.isMultiple(of: 64) { try checkExecution(generation) }
            var hasRequiredArchive = false
            var allRequiredResourcesSucceeded = true
            for file in asset.files where file.provenance == .exactPhotoKitResource
                && file.criticality != .optional {
                hasRequiredArchive = true
                if !successfulFileIDs.contains(file.fileId) {
                    allRequiredResourcesSucceeded = false
                    break
                }
            }
            guard hasRequiredArchive, allRequiredResourcesSucceeded else { continue }
            batch.append(
                VerifiedAssetExportRecord(
                    sourceLocalIdentifier: asset.sourceLocalIdentifier,
                    sourceRevision: asset.sourceRevision,
                    recoveryFingerprint: asset.recoveryFingerprint
                )
            )
            if batch.count == batchSize {
                try checkExecution(generation)
                let submitted = batch
                batch = []
                batch.reserveCapacity(batchSize)
                try await ledger.recordVerifiedAssets(
                    destinationID: destinationID,
                    records: submitted
                )
                try checkExecution(generation)
            }
        }

        if !batch.isEmpty {
            try checkExecution(generation)
            try await ledger.recordVerifiedAssets(
                destinationID: destinationID,
                records: batch
            )
            try checkExecution(generation)
        }
    }

    private func validateDecisions(_ decisions: [FileDecision], files: [ExportFile]) throws {
        let expected = Set(files.map(\.fileId))
        let filesByID = Dictionary(uniqueKeysWithValues: files.map { ($0.fileId, $0) })
        let actual = decisions.map(\.fileId)
        guard Set(actual) == expected, Set(actual).count == actual.count else {
            throw TransferError.invalidResponse
        }
        for decision in decisions {
            guard let file = filesByID[decision.fileId] else {
                throw TransferError.invalidResponse
            }
            guard decision.nextChunkIndex >= 0 else { throw TransferError.invalidResponse }
            if decision.nextChunkIndex == 0 {
                guard decision.acknowledgedChunks.isEmpty else { throw TransferError.invalidResponse }
            } else {
                guard decision.acknowledgedChunks.count == 1,
                      decision.acknowledgedChunks[0].firstIndex == 0,
                      decision.acknowledgedChunks[0].lastIndexInclusive == decision.nextChunkIndex - 1
                else { throw TransferError.invalidResponse }
            }
            if let path = decision.acceptedRelativePath,
               !WindowsPathSanitizer.validateRelativePath(path) {
                throw TransferError.invalidResponse
            }
            switch decision.action {
            case .upload:
                guard decision.nextChunkIndex == 0, decision.acceptedRelativePath != nil else {
                    throw TransferError.invalidResponse
                }
            case .resume:
                guard decision.nextChunkIndex > 0, decision.acceptedRelativePath != nil else {
                    throw TransferError.invalidResponse
                }
            case .skip:
                guard decision.acceptedRelativePath != nil else { throw TransferError.invalidResponse }
            case .conflict:
                break
            }
            if file.availability == .sourceUnavailable {
                guard decision.action == .conflict,
                      decision.reason == .sourceUnavailable else {
                    throw TransferError.invalidResponse
                }
            }
            if decision.reason == .masterConflict,
               decision.action != .conflict {
                throw TransferError.invalidResponse
            }
        }
    }

    private func validateDestinationBinding(jobID: UUID, receivedDestinationID: UUID) async throws {
        if let expectedDestinationID = try await ledger.destinationID(for: jobID),
           expectedDestinationID != receivedDestinationID {
            throw TransferError.destinationMismatch(
                expected: expectedDestinationID,
                actual: receivedDestinationID
            )
        }
    }

    private func terminalFailure(for error: Error, fileID: UUID) -> CompletionFailure? {
        if let renditionError = error as? RenditionError {
            switch renditionError {
            case .assetUnavailable, .resourceUnavailable:
                return CompletionFailure(
                    fileId: fileID,
                    code: .unavailableSource,
                    message: "The selected Photos resource is no longer available.",
                    retryable: false
                )
            case .imageDecodeFailed, .imageEncodeFailed:
                return CompletionFailure(
                    fileId: fileID,
                    code: .unavailableSource,
                    message: "The library thumbnail could not be generated.",
                    retryable: false
                )
            case .cancelled:
                return nil
            }
        }
        guard case let TransferError.receiverRejected(response, _) = error,
              !response.retryable,
              let code = response.knownCode
        else { return nil }
        switch code {
        case .fileConflict, .chunkConflict, .pathConflict, .hashMismatch,
             .unavailableSource, .masterConflict, .archiveIncomplete,
             .changedDestination:
            return CompletionFailure(
                fileId: fileID,
                code: code,
                message: String(response.message.prefix(500)),
                retryable: false
            )
        default:
            return nil
        }
    }

    private func adoptCompletion(_ report: CompletionReport) {
        completionReport = report
        progress.verifiedFileCount = report.counts.filesCommitted
        progress.skippedFileCount = report.counts.filesSkipped
        progress.failedFileCount = report.counts.filesFailed
        progress.currentFileFraction = 1
        let completedPhase: ExportPhase = report.state == .completed
            ? .completed
            : .completedWithFailures
        finishRun(
            phase: completedPhase,
            message: report.state == .completed
                ? "Every planned file is accounted for."
                : "The receiver report contains \(report.counts.filesFailed) failure(s)."
        )
    }

    private func finishRun(phase: ExportPhase, message: String) {
        fileGeneration &+= 1
        activeTask = nil
        isRunning = false
        progress.phase = phase
        progress.lastMessage = message
        publish(immediate: true)
    }

    private func checkExecution(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard generation == executionGeneration else { throw CancellationError() }
    }

    private func recordAcknowledgedBytes(_ bytes: Int64, total: Int64, generation: UInt64) {
        guard generation == fileGeneration else { return }
        progress.acknowledgedBytes = bytes
        let fraction = total == 0
            ? 1
            : min(1, Double(bytes) / Double(total))
        progress.advanceCurrentFile(through: .transfer, phaseFraction: fraction)
    }

    private func recordPreparationProgress(_ fraction: Double, generation: UInt64) {
        guard generation == fileGeneration else { return }
        progress.advanceCurrentFile(through: .preparation, phaseFraction: fraction)
    }

    private func recordHashingProgress(_ fraction: Double, generation: UInt64) {
        guard generation == fileGeneration else { return }
        progress.advanceCurrentFile(through: .hashing, phaseFraction: fraction)
    }

    private func advanceCurrentFile(
        through stage: ExportFileWorkStage,
        phaseFraction: Double,
        generation: UInt64
    ) {
        guard generation == fileGeneration else { return }
        progress.advanceCurrentFile(through: stage, phaseFraction: phaseFraction)
    }

    private func completeCurrentFile(generation: UInt64) {
        guard generation == fileGeneration else { return }
        progress.completeCurrentFile()
    }

    private func schedulePublication(immediate: Bool = false) {
        applyPublicationDecision(
            publicationThrottle.request(
                at: DispatchTime.now().uptimeNanoseconds,
                immediate: immediate
            )
        )
    }

    private func applyPublicationDecision(_ decision: ExportPublicationThrottle.Decision) {
        switch decision {
        case .publishNow:
            // Always clear a delayed publication, even for a non-immediate
            // direct publish at the cadence boundary. The token also rejects
            // a cancelled callback that was already queued on this actor.
            pendingPublication?.cancel()
            pendingPublication = nil
            emitPublication()
        case let .schedule(token, delayNanoseconds):
            pendingPublication = Task { [weak self] in
                do {
                    try await Task.sleep(
                        for: .seconds(Double(delayNanoseconds) / 1_000_000_000)
                    )
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.flushPendingPublication(token: token)
            }
        case .none:
            break
        }
    }

    private func flushPendingPublication(token: UInt64) {
        applyPublicationDecision(
            publicationThrottle.delayedCallbackFired(
                token: token,
                at: DispatchTime.now().uptimeNanoseconds
            )
        )
    }

    private func publish(immediate: Bool = false) {
        schedulePublication(immediate: immediate)
    }

    private func emitPublication() {
        eventRevision &+= 1
        eventContinuation.yield(
            ExportEvent(
                revision: eventRevision,
                progress: progress,
                destination: destination,
                isConnected: isConnected,
                isRunning: isRunning,
                completionReport: completionReport,
                currentPlan: currentPlan,
                hasPendingPreflight: pendingPreflightJobID != nil
            )
        )
    }
}

/// Thin presentation adapter.  It never hashes a file, walks a plan, performs
/// database work, or orchestrates a transfer; it only forwards commands and
/// assigns the newest immutable worker event.
@MainActor
final class ExportCoordinator: ObservableObject {
    @Published private(set) var progress = ExportProgressState()
    @Published private(set) var destination: Destination?
    @Published private(set) var isConnected = false
    @Published private(set) var isRunning = false
    @Published private(set) var completionReport: CompletionReport?
    private(set) var currentPlan: PlannedExport?

    private let worker: ExportWorker
    private var eventTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var startupGeneration: UInt64 = 0
    private var lastEventRevision: UInt64 = 0
    private var pendingPreflight = false

    var hasPendingPreflight: Bool { pendingPreflight }

    init(
        ledger: SQLiteLedger,
        resourceProvider: any PhotoResourceMaterializing = PhotoKitRenditionProvider(),
        thumbnailRenderer: any ThumbnailRendering = PhotoKitThumbnailRenderer(),
        staging: StagedRenditionStore
    ) {
        let worker = ExportWorker(
            ledger: ledger,
            resourceProvider: resourceProvider,
            thumbnailRenderer: thumbnailRenderer,
            staging: staging
        )
        self.worker = worker
        eventTask = Task { [weak self, events = worker.events] in
            for await event in events {
                guard !Task.isCancelled else {
                    PresentationStorageRetirement.retire(consume event)
                    return
                }
                guard let self else {
                    PresentationStorageRetirement.retire(consume event)
                    return
                }
                self.apply(consume event)
            }
        }
    }

    deinit {
        eventTask?.cancel()
    }

    func connect(payload: PairingPayload, instanceID: UUID, appVersion: String) async throws {
        try await worker.connect(payload: payload, instanceID: instanceID, appVersion: appVersion)
    }

    func begin(_ plan: PlannedExport) {
        guard isConnected, !isRunning else { return }
        // Update the two interaction-critical values immediately; the worker's
        // revisioned event remains authoritative for all subsequent updates.
        replaceCurrentPlan(with: plan)
        isRunning = true
        UIApplication.shared.isIdleTimerDisabled = true
        startupGeneration &+= 1
        let requestedAt = Date()
        let task = Task.detached(priority: .userInitiated) { [worker] in
            await worker.begin(plan, requestedAt: requestedAt)
        }
        replaceStartupTask(with: task)
    }

    func reconcilePreflight(_ plan: PlannedExport) async throws -> PlannedExport {
        try await worker.reconcilePreflight(plan)
    }

    func discardPendingPreflight() async {
        await worker.discardPendingPreflight()
    }

    func discardPendingPreflight(jobID: UUID) async {
        await worker.discardPendingPreflight(jobID: jobID)
    }

    func pause() {
        guard isRunning, let jobID = currentPlan?.job.jobId else { return }
        let generation = startupGeneration
        let startupTask = startupTask
        let worker = worker
        Task { @MainActor [weak self, worker, startupTask = consume startupTask] in
            await startupTask?.value
            PresentationStorageRetirement.retire(consume startupTask)
            guard let self,
                  self.startupGeneration == generation,
                  self.currentPlan?.job.jobId == jobID else { return }
            await worker.pause(expectedJobID: jobID)
        }
    }

    /// Used by background-task expiration. Returning guarantees the durable job
    /// cursor is paused at a receiver-acknowledged chunk boundary. The cancelled
    /// task retains the worker's single-flight lease until it fully unwinds.
    func checkpointForBackground(jobID: UUID? = nil) async {
        guard !Task.isCancelled else { return }
        guard let expectedJobID = jobID ?? currentPlan?.job.jobId else { return }
        let generation = startupGeneration
        let startupTask = startupTask
        await startupTask?.value
        guard !Task.isCancelled,
              generation == startupGeneration,
              currentPlan?.job.jobId == expectedJobID else { return }
        await worker.checkpointAndPause(expectedJobID: expectedJobID)
    }

    func retry() {
        guard let currentPlan, !isRunning else { return }
        begin(currentPlan)
    }

    func discardCurrentJob() async {
        guard let jobID = currentPlan?.job.jobId else { return }
        let generation = startupGeneration
        let startupTask = startupTask
        await startupTask?.value
        guard generation == startupGeneration,
              currentPlan?.job.jobId == jobID else { return }
        await worker.discardCurrentJob(expectedJobID: jobID)
    }

    func dismissCompletion() {
        guard !isRunning,
              progress.phase == .completed || progress.phase == .completedWithFailures else { return }
        replaceCurrentPlan(with: nil)
        replaceCompletionReport(with: nil)
        progress = ExportProgressState()
        Task.detached(priority: .userInitiated) { [worker] in
            await worker.dismissCompletion()
        }
    }

    private func apply(_ event: consuming ExportEvent) {
        guard event.revision > lastEventRevision else {
            PresentationStorageRetirement.retire(consume event)
            return
        }
        let previousPhase = progress.phase
        lastEventRevision = event.revision
        progress = event.progress
        destination = event.destination
        isConnected = event.isConnected
        isRunning = event.isRunning
        replaceCompletionReport(with: event.completionReport)
        replaceCurrentPlan(with: event.currentPlan)
        pendingPreflight = event.hasPendingPreflight
        UIApplication.shared.isIdleTimerDisabled = event.isRunning
        if event.progress.phase != previousPhase {
            let level: CrashLogLevel = switch event.progress.phase {
            case .failed, .completedWithFailures: .error
            default: .info
            }
            CrashLogStore.shared.record(
                level,
                category: "Export",
                message: event.progress.lastMessage ?? "Export phase changed",
                metadata: [
                    "phase": event.progress.phase.rawValue,
                    "fileIndex": String(event.progress.currentFileIndex),
                    "totalFiles": String(event.progress.totalFileCount),
                    "failedFiles": String(event.progress.failedFileCount)
                ]
            )
        }
        PresentationStorageRetirement.retire(consume event)
    }

    private func replaceCurrentPlan(with replacement: PlannedExport?) {
        if currentPlan?.job.jobId == replacement?.job.jobId { return }
        let previous = currentPlan
        currentPlan = replacement
        if let previous { PresentationStorageRetirement.retire(consume previous) }
    }

    private func replaceCompletionReport(with replacement: CompletionReport?) {
        if let current = completionReport, let replacement,
           current.jobId == replacement.jobId,
           current.completedAt == replacement.completedAt {
            return
        }
        if completionReport == nil, replacement == nil { return }
        let previous = completionReport
        completionReport = replacement
        if let previous { PresentationStorageRetirement.retire(consume previous) }
    }

    private func replaceStartupTask(with replacement: Task<Void, Never>?) {
        let previous = startupTask
        startupTask = replacement
        if let previous { PresentationStorageRetirement.retire(consume previous) }
    }
}
