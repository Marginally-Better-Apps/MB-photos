import AVFoundation
import Foundation
import UIKit

/// Keeps the final release of immutable, potentially library-sized value storage
/// off the main actor. Array/Set/Dictionary assignment is constant-time, but ARC
/// teardown of the replaced buffer is proportional to its element count.
enum PresentationStorageRetirement {
    @MainActor
    static func retire<Storage: Sendable>(_ storage: consuming Storage) {
        Task.detached(priority: .utility) { [storage = consume storage] in
            withExtendedLifetime(storage) {}
        }
    }
}

enum AppStartupState: Equatable {
    case loading
    case ready
    case failed(String)
}

@MainActor
final class TransferPreferences {
    init(defaults: UserDefaults = .standard) {}

    var profileKind: ExportProfileKind {
        get { .portableLibrary }
        set {}
    }
}

enum TransferPresentationPolicy {
    static func clearsQuickSelection(after phase: ExportPhase) -> Bool {
        phase == .completed
    }

    static func shouldInvalidatePreparedTransferForConnection(
        preparedJobID: UUID?,
        frozenResumeJobID: UUID?,
        isPlanning: Bool,
        hasPendingPreflight: Bool
    ) -> Bool {
        let preservesFrozenResume = preparedJobID != nil && preparedJobID == frozenResumeJobID
        return !preservesFrozenResume
            && (preparedJobID != nil || isPlanning || hasPendingPreflight)
    }
}

/// A synchronous MainActor fence for scene callbacks. Async work captures the
/// returned generation and must revalidate it after every suspension point.
@MainActor
final class SceneTransitionGenerationFence {
    private(set) var generation: UInt64 = 0
    private(set) var isInBackground = false
    private var checkpointTasks: [UUID: Task<Void, Never>] = [:]

    @discardableResult
    func enterActive() -> UInt64 {
        cancelCheckpointTasks()
        generation &+= 1
        isInBackground = false
        return generation
    }

    @discardableResult
    func enterBackground() -> UInt64 {
        cancelCheckpointTasks()
        generation &+= 1
        isInBackground = true
        return generation
    }

    func permitsActive(_ generation: UInt64) -> Bool {
        !isInBackground && generation == self.generation
    }

    func permitsBackground(_ generation: UInt64) -> Bool {
        isInBackground && generation == self.generation
    }

    /// Owns checkpoint work started by a background-execution expiration
    /// callback. The callback's task is independent of `sceneTransitionTask`,
    /// so keeping a child here lets a newer scene generation cancel it too.
    func runBackgroundCheckpoint(
        generation: UInt64,
        operation: @escaping @MainActor @Sendable () async -> Void
    ) async {
        guard permitsBackground(generation), !Task.isCancelled else { return }

        let identifier = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self,
                  self.permitsBackground(generation),
                  !Task.isCancelled else { return }
            await operation()
        }
        checkpointTasks[identifier] = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        checkpointTasks[identifier] = nil
    }

    private func cancelCheckpointTasks() {
        let tasks = checkpointTasks.values
        checkpointTasks.removeAll(keepingCapacity: true)
        for task in tasks {
            task.cancel()
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    let diagnostics: CrashLogStore
    let catalog: PhotoKitCatalog
    let organizeViewModel: OrganizeViewModel

    @Published private(set) var startupState: AppStartupState = .loading
    @Published private(set) var ledger: SQLiteLedger?
    @Published private(set) var coordinator: ExportCoordinator?
    @Published private(set) var authorization: PhotoAuthorizationState = .notDetermined
    @Published private(set) var assets: [PhotoAsset] = []
    @Published private(set) var albums: [PhotoAlbum] = []
    @Published private(set) var isLoadingLibrary = false
    @Published var selectionKind: SelectionKind = .manual {
        didSet {
            if oldValue != selectionKind { invalidatePreflight() }
        }
    }
    @Published private(set) var selectedAssetIDs: Set<String> = []
    @Published private(set) var selectedAlbumIDs: Set<String> = []
    @Published private(set) var selectionPreviewAssets: [PhotoAsset] = []
    @Published var rangeStart = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date() {
        didSet {
            if oldValue != rangeStart { invalidatePreflight() }
        }
    }
    @Published var rangeEnd = Date() {
        didSet {
            if oldValue != rangeEnd { invalidatePreflight() }
        }
    }
    @Published private(set) var profileKind: ExportProfileKind = .portableLibrary
    @Published private(set) var plannedExport: PlannedExport?
    @Published private(set) var isPlanning = false
    @Published private(set) var history: [ExportHistoryEntry] = []
    @Published var alertMessage: String? {
        didSet {
            guard let alertMessage, alertMessage != oldValue else { return }
            diagnostics.record(.warning, category: "User Message", message: alertMessage)
        }
    }

    private struct BootstrapResources: Sendable {
        let ledger: SQLiteLedger
        let staging: StagedRenditionStore
    }

    private struct LibraryPresentationStorage: Sendable {
        let assets: [PhotoAsset]
        let albums: [PhotoAlbum]

        var isEmpty: Bool { assets.isEmpty && albums.isEmpty }
    }

    private let preflightWorker = PreflightWorker()
    private let transferPreferences: TransferPreferences
    private var organizeCoordinator: OrganizeCoordinator?
    private var libraryIndexWorker: LibraryIndexWorker?
    private var stagingStore: StagedRenditionStore?
    private var bootstrapTask: Task<Void, Never>?
    private var lastCatalogRevision: UInt64?
    private var lastAppliedLibraryGeneration: UInt64 = 0
    private var libraryPresentationRevision: UInt64 = 0
    private var activeLibraryLoads = 0
    private var backgroundExecutionOwnership = BackgroundExecutionOwnership()
    /// Accepted scheduler requests that have not yet entered their launch
    /// handlers. These are bookkeeping only, never proof of an execution lease.
    private var pendingContinuedAnalysisRunID: UUID?
    private var pendingContinuedExportJobID: UUID?
    private var preflightRevision: UInt64 = 0
    private var preflightTask: Task<Void, Never>?
    private var selectionRevision: UInt64 = 0
    private var selectionMutationTask: Task<Void, Never>?
    private var frozenResumeJobID: UUID?
    private let sceneTransitionFence = SceneTransitionGenerationFence()
    private var sceneTransitionTask: Task<Void, Never>?
    private var backgroundConstraintTask: Task<Void, Never>?

    var startupError: String? {
        guard case let .failed(message) = startupState else { return nil }
        return message
    }

    init(
        diagnostics: CrashLogStore = .shared,
        transferPreferences: TransferPreferences = TransferPreferences()
    ) {
        self.diagnostics = diagnostics
        self.transferPreferences = transferPreferences
        profileKind = transferPreferences.profileKind
        let catalog = PhotoKitCatalog()
        self.catalog = catalog
        let initialAuthorization = catalog.authorizationState()
        authorization = initialAuthorization
        organizeViewModel = OrganizeViewModel(authorization: initialAuthorization)

        let resourceTask = Task.detached(priority: .userInitiated) { () throws -> BootstrapResources in
            let ledger = try SQLiteLedger.applicationLedger()
            let staging = try StagedRenditionStore.applicationStore()
            // Completion is committed before rendition cleanup. If the process
            // was killed in that narrow window, recover it before services are
            // published without delaying the first lightweight loading view.
            _ = try? await staging.sweepTerminalJobs(using: ledger)
            return BootstrapResources(ledger: ledger, staging: staging)
        }
        bootstrapTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let resources = try await resourceTask.value
                await self.finishBootstrap(resources)
            } catch {
                self.diagnostics.record(error: error, category: "Startup")
                self.startupState = .failed(error.localizedDescription)
            }
        }
    }

    var instanceID: UUID {
        let key = "client-instance-id"
        if let value = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: value) {
            return id
        }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString.lowercased(), forKey: key)
        return id
    }

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    func authorizeAndLoad() async {
        diagnostics.record(.info, category: "Photo Library", message: "Photo access requested")
        authorization = await catalog.requestAuthorization()
        diagnostics.record(
            .info,
            category: "Photo Library",
            message: "Photo authorization updated",
            metadata: ["authorization": String(describing: authorization)]
        )
        await refreshLibrary(force: true)
    }

    func refreshLibrary(force: Bool = false) async {
        await awaitBootstrap()
        guard startupState == .ready, let libraryIndexWorker else { return }

        let previousAuthorization = authorization
        let currentAuthorization = catalog.authorizationState()
        authorization = currentAuthorization
        if previousAuthorization != currentAuthorization || (currentAuthorization == .limited && force) {
            // Authorization transitions are privacy boundaries. Never keep an
            // authorized snapshot—or a previously valid limited scope—visible
            // while the current scope fingerprint is being validated.
            clearSelectedItems()
            replaceLibraryPresentation(assets: [], albums: [])
            lastCatalogRevision = nil
            await organizeCoordinator?.refresh(
                authorization: currentAuthorization,
                assets: [],
                albums: []
            )
        }
        guard currentAuthorization == .authorized || currentAuthorization == .limited else {
            await libraryIndexWorker.clearCache()
            replaceLibraryPresentation(assets: [], albums: [])
            lastCatalogRevision = nil
            await organizeCoordinator?.refresh(
                authorization: currentAuthorization,
                assets: [],
                albums: []
            )
            return
        }

        let revision = catalog.catalogRevision
        guard force || lastCatalogRevision != revision || assets.isEmpty else { return }
        activeLibraryLoads += 1
        isLoadingLibrary = true
        defer {
            activeLibraryLoads -= 1
            isLoadingLibrary = activeLibraryLoads > 0
        }

        do {
            let result = try await libraryIndexWorker.snapshot(
                revision: revision,
                authorization: currentAuthorization,
                force: force
            )
            guard !Task.isCancelled else {
                PresentationStorageRetirement.retire(consume result)
                throw CancellationError()
            }
            guard result.generation >= lastAppliedLibraryGeneration else {
                PresentationStorageRetirement.retire(consume result)
                return
            }
            guard catalog.authorizationState() == currentAuthorization else {
                PresentationStorageRetirement.retire(consume result)
                Task { @MainActor [weak self] in await self?.refreshLibrary(force: true) }
                return
            }
            lastAppliedLibraryGeneration = result.generation
            applyLibrarySnapshot(result.snapshot, authorization: currentAuthorization)
            if result.source == .fallback, let message = result.refreshErrorDescription {
                alertMessage = "The saved library index is being shown because Photos could not be refreshed: \(message)"
            }
            await organizeCoordinator?.refresh(
                authorization: currentAuthorization,
                assets: result.snapshot.assets,
                albums: result.snapshot.albums
            )
            if UIApplication.shared.applicationState == .active {
                organizeCoordinator?.reconcileAutomaticAnalysis(
                    isEnabled: organizeViewModel.autoAnalyzeEnabled
                )
            }
            PresentationStorageRetirement.retire(consume result)
        } catch is CancellationError {
            // A newer scene/revision request owns presentation.
        } catch {
            diagnostics.record(error: error, category: "Photo Library")
            alertMessage = error.localizedDescription
        }
    }

    func connect(pairingText: String) async {
        guard let coordinator else { return }
        diagnostics.record(.info, category: "Receiver", message: "Pairing started")
        do {
            let payload = try PairingPayload(string: pairingText)
            if TransferPresentationPolicy.shouldInvalidatePreparedTransferForConnection(
                preparedJobID: plannedExport?.job.jobId,
                frozenResumeJobID: frozenResumeJobID,
                isPlanning: isPlanning,
                hasPendingPreflight: coordinator.hasPendingPreflight
            ) {
                invalidatePreflight()
                await preflightTask?.value
            }
            try await coordinator.connect(payload: payload, instanceID: instanceID, appVersion: appVersion)
            diagnostics.record(.info, category: "Receiver", message: "Pairing completed")
        } catch {
            diagnostics.record(error: error, category: "Receiver")
            alertMessage = error.localizedDescription
        }
    }

    func buildPreflight() async {
        guard let coordinator else { return }
        diagnostics.record(
            .info,
            category: "Export",
            message: "Export review started",
            metadata: ["selection": selectionKind.label]
        )
        preflightRevision &+= 1
        let revision = preflightRevision
        let request = preflightRequest(revision: revision)
        let previous = preflightTask
        let selectionSynchronization = selectionMutationTask
        previous?.cancel()
        replacePlannedExport(with: nil)
        isPlanning = true
        let operation = Task { @MainActor [
            weak self,
            previous = consume previous,
            selectionSynchronization = consume selectionSynchronization
        ] in
            await previous?.value
            PresentationStorageRetirement.retire(consume previous)
            await selectionSynchronization?.value
            PresentationStorageRetirement.retire(consume selectionSynchronization)
            guard let self else { return }
            await self.runPreflight(
                revision: revision,
                request: request,
                coordinator: coordinator
            )
        }
        preflightTask = operation
        await withTaskCancellationHandler {
            await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    func startExport() {
        guard !isPlanning,
              let plannedExport,
              let coordinator,
              coordinator.isConnected,
              !coordinator.isRunning else { return }
        coordinator.begin(plannedExport)
        // `begin` publishes the interaction-critical running flag
        // synchronously. Do not submit a background continuation if another
        // state check caused the foreground start to be rejected.
        guard coordinator.isRunning else { return }
        frozenResumeJobID = nil
        let fileCount = plannedExport.job.files.count
        let jobID = plannedExport.job.jobId
        let continuedOutcome = BackgroundWorkController.shared.beginUserInitiatedExport(
            jobID: jobID,
            fileCount: fileCount
        )
        let continued = continuedOutcome.acceptedForContinuedExecution
        pendingContinuedExportJobID = continued ? jobID : nil
        diagnostics.record(
            .info,
            category: "Export",
            message: "Verified export started",
            metadata: ["fileCount": String(fileCount), "continuedInBackground": continued ? "true" : "false"]
        )
    }

    func invalidatePreflight() {
        guard plannedExport != nil || isPlanning || coordinator?.hasPendingPreflight == true else { return }
        frozenResumeJobID = nil
        preflightRevision &+= 1
        let revision = preflightRevision
        let previous = preflightTask
        previous?.cancel()
        replacePlannedExport(with: nil)
        isPlanning = true
        let cleanup = Task { @MainActor [weak self, previous = consume previous] in
            await previous?.value
            PresentationStorageRetirement.retire(consume previous)
            guard let self else { return }
            await self.coordinator?.discardPendingPreflight()
            self.finishPreflightOperation(revision: revision)
        }
        preflightTask = cleanup
    }

    func toggleSelectedAssetID(_ id: String) {
        setSelectedAssetID(id, isSelected: !selectedAssetIDs.contains(id))
    }

    func setSelectedAssetID(_ id: String, isSelected: Bool) {
        applyAssetSelection([id], isSelected: isSelected)
    }

    func setSelectedAssetIDs(_ ids: [String], isSelected: Bool) {
        applyAssetSelection(ids, isSelected: isSelected)
    }

    func setAllAssetsSelected(_ isSelected: Bool) {
        let changedIDs: [String]
        if isSelected {
            changedIDs = assets.lazy
                .map(\.id)
                .filter { !selectedAssetIDs.contains($0) }
        } else {
            changedIDs = Array(selectedAssetIDs)
        }
        applyAssetSelection(changedIDs, isSelected: isSelected)
    }

    private func applyAssetSelection(_ ids: [String], isSelected: Bool) {
        let changedIDs = ids.filter { selectedAssetIDs.contains($0) != isSelected }
        guard !changedIDs.isEmpty else { return }
        if selectionKind != .manual { selectionKind = .manual }
        if isSelected {
            selectedAssetIDs.formUnion(changedIDs)
        } else {
            selectedAssetIDs.subtract(changedIDs)
        }
        selectionRevision &+= 1
        if changedIDs.count == 1, let id = changedIDs.first {
            enqueueSelectionDelta(
                .asset(revision: selectionRevision, id: id, isSelected: isSelected)
            )
        } else {
            enqueueSelectionDelta(
                .assets(revision: selectionRevision, ids: changedIDs, isSelected: isSelected)
            )
        }
        refreshSelectionPreviews()
        invalidatePreflight()
    }

    func toggleSelectedAlbumID(_ id: String) {
        setSelectedAlbumID(id, isSelected: !selectedAlbumIDs.contains(id))
    }

    func setSelectedAlbumID(_ id: String, isSelected: Bool) {
        applyAlbumSelection([id], isSelected: isSelected)
    }

    func setAllAlbumsSelected(_ isSelected: Bool) {
        let changedIDs: [String]
        if isSelected {
            changedIDs = albums.lazy
                .map(\.id)
                .filter { !selectedAlbumIDs.contains($0) }
        } else {
            changedIDs = Array(selectedAlbumIDs)
        }
        applyAlbumSelection(changedIDs, isSelected: isSelected)
    }

    private func applyAlbumSelection(_ ids: [String], isSelected: Bool) {
        let changedIDs = ids.filter { selectedAlbumIDs.contains($0) != isSelected }
        guard !changedIDs.isEmpty else { return }
        if selectionKind != .manual { selectionKind = .manual }
        if isSelected {
            selectedAlbumIDs.formUnion(changedIDs)
        } else {
            selectedAlbumIDs.subtract(changedIDs)
        }
        selectionRevision &+= 1
        if changedIDs.count == 1, let id = changedIDs.first {
            enqueueSelectionDelta(
                .album(revision: selectionRevision, id: id, isSelected: isSelected)
            )
        } else {
            enqueueSelectionDelta(
                .albums(revision: selectionRevision, ids: changedIDs, isSelected: isSelected)
            )
        }
        refreshSelectionPreviews()
        invalidatePreflight()
    }

    func clearSelectedItems() {
        guard !selectedAssetIDs.isEmpty || !selectedAlbumIDs.isEmpty else { return }
        selectedAssetIDs.removeAll(keepingCapacity: false)
        selectedAlbumIDs.removeAll(keepingCapacity: false)
        selectionPreviewAssets.removeAll(keepingCapacity: false)
        selectionRevision &+= 1
        enqueueSelectionDelta(.clear(revision: selectionRevision))
        invalidatePreflight()
    }

    @discardableResult
    func loadResume(jobID: UUID) async -> Bool {
        guard let ledger else { return false }
        do {
            await refreshLibrary(force: true)
            let job = try await ledger.loadJob(jobID)
            replacePlannedExport(with: try await preflightWorker.rehydrate(job: job, assets: assets))
            frozenResumeJobID = jobID
            alertMessage = coordinator?.isConnected == true
                ? "The frozen transfer is ready to review on Home."
                : "The frozen transfer is ready. Connect to the current Windows receiver, then review it on Home."
            return true
        } catch is CancellationError {
            return false
        } catch {
            diagnostics.record(error: error, category: "Export Resume")
            alertMessage = error.localizedDescription
            return false
        }
    }

    func refreshHistory() async {
        await awaitBootstrap()
        do { replaceHistory(with: try await ledger?.history() ?? []) }
        catch {
            diagnostics.record(error: error, category: "Export History")
            alertMessage = error.localizedDescription
        }
    }

    func presentLimitedPicker() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        var presenter = root
        while let presented = presenter.presentedViewController { presenter = presented }
        catalog.presentLimitedLibraryPicker(from: presenter)
    }

    func pauseOrganizeAnalysis() {
        organizeCoordinator?.pauseAnalysis()
    }

    func pauseAnalysisForBackgroundConstraint(
        policy: BackgroundProcessingPolicy,
        reason: BackgroundWorkDeferralReason
    ) {
        // This synchronous cancellation is intentionally performed inside the
        // worker's run-identified callback. The worker checks cancellation at
        // position zero immediately after that callback, before asking PhotoKit
        // to stream the first resource. A separate task can then await the same
        // worker and finish its durable pause without self-awaiting here.
        organizeCoordinator?.pauseAnalysis()
        if !policy.isAutomatic { pendingContinuedAnalysisRunID = nil }
        presentAnalysisWaiting(policy: policy, reason: reason)
    }

    func presentAnalysisWaiting(
        policy: BackgroundProcessingPolicy,
        reason: BackgroundWorkDeferralReason
    ) {
        var presentation = organizeViewModel.analysis
        guard presentation.phase == .running || presentation.phase == .paused else { return }
        presentation.phase = .paused
        presentation.currentAssetFraction = 0
        presentation.statusText = BackgroundAnalysisWaitingStatus.message(
            policy: policy,
            reason: reason
        )
        organizeViewModel.setAnalysis(presentation)
    }

    func sceneDidBecomeActive() {
        diagnostics.record(.info, category: "Lifecycle", message: "App became active")
        let generation = sceneTransitionFence.enterActive()
        sceneTransitionTask?.cancel()
        sceneTransitionTask = Task { @MainActor [weak self] in
            guard let self,
                  self.sceneTransitionFence.permitsActive(generation),
                  !Task.isCancelled else { return }
            await self.refreshLibrary(force: true)
        }
    }

    func backgroundExecutionConstraintsDidChange() {
        let constraints = BackgroundWorkController.shared.currentConstraints()
        diagnostics.record(
            .info,
            category: "Background Work",
            message: "Power or thermal constraints changed",
            metadata: [
                "lowPowerMode": constraints.isLowPowerModeEnabled ? "true" : "false",
                "thermalCondition": String(describing: constraints.thermalCondition)
            ]
        )
        // Serialize notifications instead of cancelling an in-flight durable
        // checkpoint. Each operation reads the latest constraints when it
        // begins, so a rapid blocked -> allowed transition safely finishes the
        // pause before the newer operation queues the appropriate resume lease.
        let previous = backgroundConstraintTask
        backgroundConstraintTask = Task { @MainActor [weak self] in
            await previous?.value
            await self?.reconcileBackgroundAnalysisConstraints()
        }
    }

    func recordBackgroundWorkDiagnostic(_ event: BackgroundWorkDiagnosticEvent) {
        let level: CrashLogLevel = switch event.action {
        case .registrationFailed: .warning
        case .registered, .scheduling, .started, .deferred, .completed, .expired: .info
        }
        diagnostics.record(
            level,
            category: "Background Work",
            message: "Background task lifecycle event",
            // These values come only from closed enums/scheduler outcomes. Never
            // include PhotoKit identifiers, file names, hashes, or album names.
            metadata: [
                "task": event.task.rawValue,
                "action": event.action.rawValue,
                "outcome": event.outcome
            ]
        )
    }

    /// `.inactive` is intentionally ignored by MBPhotosApp. Control Center,
    /// permission sheets, and other brief interruptions must not cancel work.
    func sceneDidEnterBackground() {
        diagnostics.record(.info, category: "Lifecycle", message: "App entered background")
        let generation = sceneTransitionFence.enterBackground()
        sceneTransitionTask?.cancel()
        sceneTransitionTask = Task { @MainActor [weak self] in
            await self?.handleSceneDidEnterBackground(generation: generation)
        }
    }

    private func handleSceneDidEnterBackground(generation: UInt64) async {
        guard isCurrentBackgroundSceneTransition(generation) else { return }
        BackgroundWorkController.shared.scheduleRefresh()
        BackgroundWorkController.shared.scheduleAutomaticLocalMaintenance()
        let analysis = organizeViewModel.analysis
        var userProcessingOutcome: BackgroundTaskSchedulingOutcome?
        if BackgroundAnalysisSchedulingPolicy.shouldScheduleUserProcessing(
            phase: analysis.phase,
            origin: organizeCoordinator?.currentAnalysisOrigin
        ) {
            userProcessingOutcome = BackgroundWorkController.shared.scheduleUserAnalysisProcessing(
                includeICloudItems: analysis.includesICloudItems
            )
        }
        guard isCurrentBackgroundSceneTransition(generation) else { return }
        // Keep the launch-handler handshake or durable checkpoint alive during
        // the scene transition. On iOS 26 the continued task owns subsequent
        // execution only after its handler actually starts; on older releases
        // this finite lease exists solely to unwind to a safe checkpoint.
        let lease = SceneBackgroundCheckpointLease()
        await lease.run { [weak self] in
            await self?.checkpointForSceneBackground(sceneGeneration: generation)
        }
        guard isCurrentBackgroundSceneTransition(generation) else { return }
        if let userProcessingOutcome,
           organizeViewModel.analysis.phase == .paused {
            let reason: BackgroundWorkDeferralReason = switch userProcessingOutcome {
            case let .scheduledForLater(reason): reason
            case .scheduled: .systemScheduling
            case .unavailable, .tooManyPendingRequests, .notPermitted,
                    .immediateRunIneligible, .unsupportedOS, .appNotActive,
                    .registrationFailed, .unknownFailure:
                .backgroundRefreshUnavailable
            }
            presentAnalysisWaiting(
                policy: .userAnalysis(includeICloudItems: analysis.includesICloudItems),
                reason: reason
            )
        }
    }

    private func reconcileBackgroundAnalysisConstraints() async {
        guard startupState == .ready,
              let organizeCoordinator,
              let origin = organizeCoordinator.currentAnalysisOrigin else { return }

        let presentation = organizeViewModel.analysis
        let policy: BackgroundProcessingPolicy = switch origin {
        case .userInitiated:
            .userAnalysis(includeICloudItems: presentation.includesICloudItems)
        case .automaticMaintenance:
            .automaticLocalMaintenance
        }
        let controller = BackgroundWorkController.shared
        let runID = await organizeCoordinator.currentAnalysisRunID()
        guard !Task.isCancelled else { return }
        let kind: BackgroundWorkKind = switch origin {
        case .userInitiated:
            .analysis(runID: runID, includeICloudItems: presentation.includesICloudItems)
        case .automaticMaintenance:
            .libraryMaintenance
        }

        switch controller.constraintDisposition(for: policy) {
        case .run:
            // Only requeue work that this power policy paused. A user's manual
            // pause remains paused until the user chooses Resume.
            guard presentation.phase == .paused,
                  let state = await controller.currentState(for: kind),
                  state.deferralReason?.isPowerOrThermalConstraint == true else { return }
            switch origin {
            case .userInitiated:
                _ = controller.scheduleUserAnalysisProcessing(
                    includeICloudItems: presentation.includesICloudItems
                )
            case .automaticMaintenance:
                if await shouldResubmitAutomaticMaintenance() {
                    _ = controller.scheduleAutomaticLocalMaintenance()
                }
            }

        case let .pause(reason), let .deferUntilLater(reason):
            guard presentation.phase == .running else { return }
            controller.markConstraintPause(
                kind: kind,
                policy: policy,
                reason: reason,
                completed: presentation.processedAssetCount,
                total: presentation.totalAssetCount
            )
            if origin == .userInitiated { pendingContinuedAnalysisRunID = nil }

            // Cancels the coordinator worker and waits until its last committed
            // cursor is durably marked paused. This is the action that actually
            // stops hashing/resource reads when constraints change mid-run.
            await organizeCoordinator.checkpointAnalysisForBackground(runID: runID)
            guard !Task.isCancelled else { return }

            // Re-read the durable cursor after cancellation so the background
            // state reflects every item committed while the worker unwound.
            if let runID,
               let progress = try? await ledger?.analysisRunProgress(id: runID) {
                controller.markConstraintPause(
                    kind: kind,
                    policy: policy,
                    reason: reason,
                    completed: progress.nextPosition,
                    total: progress.totalAssetCount
                )
            }
            // The worker's terminal callback may replace the specific power or
            // thermal explanation with a generic paused message while it
            // unwinds. Restore the actionable, non-running waiting status only
            // after the durable checkpoint has completed.
            presentAnalysisWaiting(policy: policy, reason: reason)
            switch origin {
            case .userInitiated:
                _ = controller.scheduleUserAnalysisProcessing(
                    includeICloudItems: presentation.includesICloudItems
                )
            case .automaticMaintenance:
                if await shouldResubmitAutomaticMaintenance() {
                    _ = controller.scheduleAutomaticLocalMaintenance()
                }
            }
        }
    }

    func backgroundExecutionDidBegin(scope: BackgroundExecutionScope) {
        backgroundExecutionOwnership.begin(scope)
    }

    func continuedExecutionHandlerDidStart(scope: BackgroundExecutionScope) {
        switch scope {
        case let .analysis(runID):
            if pendingContinuedAnalysisRunID == runID {
                pendingContinuedAnalysisRunID = nil
            }
        case let .export(jobID):
            if pendingContinuedExportJobID == jobID {
                pendingContinuedExportJobID = nil
            }
        case .metadataRefresh:
            break
        }
    }

    func backgroundExecutionDidEnd(scope: BackgroundExecutionScope) async {
        backgroundExecutionOwnership.end(scope)
        let generation = sceneTransitionFence.generation
        guard sceneTransitionFence.permitsBackground(generation),
              UIApplication.shared.applicationState == .background else { return }
        await sceneTransitionFence.runBackgroundCheckpoint(generation: generation) { [weak self] in
            await self?.checkpointForSceneBackground(sceneGeneration: generation)
        }
    }

    func performBackgroundRefresh() async -> Bool {
        await awaitBootstrap()
        guard !Task.isCancelled, startupState == .ready else { return false }
        await refreshLibrary(force: true)
        return !Task.isCancelled
    }

    func performBackgroundMaintenance() async -> Bool {
        guard await performBackgroundRefresh(), !Task.isCancelled else { return false }
        if let stagingStore, let ledger {
            _ = try? await stagingStore.sweepTerminalJobs(using: ledger)
        }
        guard !Task.isCancelled else { return false }
        await catalog.clearThumbnailCache()
        guard !Task.isCancelled else { return false }
        await organizeCoordinator?.performBackgroundCacheMaintenance()
        guard !Task.isCancelled else { return false }
        guard organizeViewModel.autoAnalyzeEnabled else { return true }
        let completed = await organizeCoordinator?.runAutomaticLocalAnalysisInBackground() ?? false
        return completed || assets.isEmpty
    }

    func performBackgroundAnalysis() async -> Bool {
        await awaitBootstrap()
        guard !Task.isCancelled, startupState == .ready else { return false }
        await refreshLibrary(force: true)
        guard !Task.isCancelled else { return false }
        return await organizeCoordinator?.resumeAnalysisInBackground() ?? false
    }

    func checkpointForBackgroundExpiration() async {
        await checkpointExportForBackgroundExpiration()
        await checkpointAnalysisForBackgroundExpiration()
    }

    func checkpointExportForBackgroundExpiration(jobID: UUID? = nil) async {
        await coordinator?.checkpointForBackground(jobID: jobID)
    }

    func checkpointAnalysisForBackgroundExpiration(runID: UUID? = nil) async {
        await organizeCoordinator?.checkpointAnalysisForBackground(runID: runID)
    }

    func shouldResubmitAutomaticMaintenance() async -> Bool {
        await awaitBootstrap()
        guard organizeViewModel.autoAnalyzeEnabled,
              organizeCoordinator?.currentAnalysisOrigin == .automaticMaintenance,
              let runID = await organizeCoordinator?.currentAnalysisRunID(),
              let progress = try? await ledger?.analysisRunProgress(id: runID) else {
            return false
        }
        return BackgroundAutomaticMaintenanceResubmissionPolicy.shouldResubmit(
            progress: progress
        )
    }

    @available(iOS 26.0, *)
    func waitForContinuedAnalysis(
        runID: UUID,
        progress: ContinuedBackgroundProgress
    ) async -> Bool {
        defer {
            if pendingContinuedAnalysisRunID == runID {
                pendingContinuedAnalysisRunID = nil
            }
        }
        var missingRunAttempts = 0
        while !Task.isCancelled {
            guard let run = try? await ledger?.analysisRunProgress(id: runID) else {
                guard missingRunAttempts < 20 else { return false }
                missingRunAttempts += 1
                try? await Task.sleep(for: .milliseconds(250))
                continue
            }
            missingRunAttempts = 0
            let processed = BackgroundAnalysisProgressPolicy.processedUnitCount(from: run)
            progress.update(
                completed: processed,
                total: run.totalAssetCount,
                title: "Analyzing photo library",
                subtitle: "\(processed) of \(run.totalAssetCount) items processed"
            )
            BackgroundWorkController.shared.reportProgress(
                kind: .analysis(runID: run.id, includeICloudItems: run.includesICloudItems),
                completed: processed,
                total: run.totalAssetCount
            )
            switch run.status {
            case .complete: return true
            case .failed, .paused: return false
            case .running: break
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    @available(iOS 26.0, *)
    func waitForContinuedExport(
        jobID: UUID,
        progress: ContinuedBackgroundProgress
    ) async -> Bool {
        defer {
            if pendingContinuedExportJobID == jobID {
                pendingContinuedExportJobID = nil
            }
        }
        var planPublicationAttempts = 0
        while !Task.isCancelled {
            guard let coordinator else { return false }
            guard let currentPlan = coordinator.currentPlan else {
                guard coordinator.isRunning, planPublicationAttempts < 20 else { return false }
                planPublicationAttempts += 1
                try? await Task.sleep(for: .milliseconds(100))
                continue
            }
            guard currentPlan.job.jobId == jobID else { return false }
            let state = coordinator.progress
            let completed = BackgroundExportProgressPolicy.completedUnitCount(from: state)
            progress.update(
                completed: completed,
                total: BackgroundExportProgressPolicy.totalUnitCount,
                title: "Exporting photos",
                subtitle: BackgroundExportProgressPolicy.subtitle(from: state)
            )
            BackgroundWorkController.shared.reportProgress(
                kind: .export(jobID: jobID),
                completed: completed,
                total: BackgroundExportProgressPolicy.totalUnitCount
            )
            switch state.phase {
            case .completed, .completedWithFailures: return true
            case .failed, .paused: return false
            default: break
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    private func finishBootstrap(_ resources: BootstrapResources) async {
        ledger = resources.ledger
        stagingStore = resources.staging
        coordinator = ExportCoordinator(ledger: resources.ledger, staging: resources.staging)
        let persistentLoader = PersistentLibrarySnapshotLoader(
            store: resources.ledger,
            changeLoader: PhotoKitPersistentChangeLoader()
        )
        let indexWorker = LibraryIndexWorker(loader: persistentLoader)
        libraryIndexWorker = indexWorker

        let organizer = OrganizeCoordinator(
            ledger: resources.ledger,
            catalog: catalog,
            visualAnalyzer: PhotoKitVisualAnalysisService(),
            continueAnalysisInBackground: { [weak self] runID, includeICloudItems, origin in
                guard let self else { return }
                guard origin == .userInitiated else { return }
                let continuedOutcome = BackgroundWorkController.shared.beginUserInitiatedAnalysis(
                    runID: runID,
                    includeICloudItems: includeICloudItems
                )
                self.pendingContinuedAnalysisRunID = continuedOutcome.acceptedForContinuedExecution
                    ? runID
                    : nil
                if case let .scheduledForLater(reason) = continuedOutcome {
                    let policy = BackgroundProcessingPolicy.userAnalysis(
                        includeICloudItems: includeICloudItems
                    )
                    // Synchronously sets cancellation before this callback
                    // returns, so the worker's position-zero cancellation check
                    // wins the race with the first PhotoKit resource read.
                    self.pauseAnalysisForBackgroundConstraint(
                        policy: policy,
                        reason: reason
                    )
                    // Avoid awaiting the coordinator's own analysis task from
                    // inside its worker callback. The independent task runs
                    // after this callback returns and checkpoints the durable
                    // cursor without deadlocking the current analysis call.
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.checkpointAnalysisForBackgroundExpiration(
                            runID: runID
                        )
                        self.presentAnalysisWaiting(policy: policy, reason: reason)
                    }
                }
            }
        )
        organizeCoordinator = organizer
        organizer.install(on: organizeViewModel) { [weak self] in
            await self?.refreshLibrary(force: true)
        }

        if authorization == .authorized || authorization == .limited,
           let cached = try? await indexWorker.loadCachedSnapshot(
               revision: catalog.catalogRevision,
               authorization: authorization
           ) {
            applyLibrarySnapshot(cached, authorization: authorization)
            await organizer.refresh(
                authorization: authorization,
                assets: cached.assets,
                albums: cached.albums
            )
            if UIApplication.shared.applicationState == .active {
                organizer.reconcileAutomaticAnalysis(
                    isEnabled: organizeViewModel.autoAnalyzeEnabled
                )
            }
            PresentationStorageRetirement.retire(consume cached)
        }
        startupState = .ready
        diagnostics.record(.info, category: "Startup", message: "App services are ready")
        Task { @MainActor [weak self] in await self?.refreshLibrary(force: true) }
    }

    private func checkpointForSceneBackground(sceneGeneration: UInt64) async {
        guard isCurrentBackgroundSceneTransition(sceneGeneration) else { return }
        let analysisIsRunning = organizeViewModel.analysis.phase == .running
        let currentAnalysisRunID: UUID? = if analysisIsRunning {
            await organizeCoordinator?.currentAnalysisRunID()
        } else {
            nil
        }
        // Resolving the actor-owned run identity is a suspension point. A newer
        // active phase must invalidate this handler before it can pause either
        // the analysis or an export from the old background event.
        guard isCurrentBackgroundSceneTransition(sceneGeneration) else { return }
        let currentExportJobID: UUID? = if coordinator?.isRunning == true {
            coordinator?.currentPlan?.job.jobId
        } else {
            nil
        }
        await awaitPendingContinuedExecutionHandshake(
            analysisRunID: currentAnalysisRunID,
            exportJobID: currentExportJobID,
            sceneGeneration: sceneGeneration
        )
        guard isCurrentBackgroundSceneTransition(sceneGeneration) else { return }
        let policy = BackgroundCheckpointPolicy(
            ownership: backgroundExecutionOwnership,
            analysisIsRunning: analysisIsRunning,
            currentAnalysisRunID: currentAnalysisRunID,
            currentExportJobID: currentExportJobID
        )
        if policy.shouldCheckpointExport {
            guard isCurrentBackgroundSceneTransition(sceneGeneration) else { return }
            await coordinator?.checkpointForBackground(jobID: currentExportJobID)
            if pendingContinuedExportJobID == currentExportJobID {
                pendingContinuedExportJobID = nil
            }
        }
        if policy.shouldCheckpointAnalysis {
            guard isCurrentBackgroundSceneTransition(sceneGeneration) else { return }
            await organizeCoordinator?.checkpointAnalysisForBackground(
                runID: currentAnalysisRunID
            )
            if pendingContinuedAnalysisRunID == currentAnalysisRunID {
                pendingContinuedAnalysisRunID = nil
            }
        }
    }

    private func isCurrentBackgroundSceneTransition(_ generation: UInt64) -> Bool {
        sceneTransitionFence.permitsBackground(generation) && !Task.isCancelled
    }

    private func awaitPendingContinuedExecutionHandshake(
        analysisRunID: UUID?,
        exportJobID: UUID?,
        sceneGeneration: UInt64
    ) async {
        let hasPendingAnalysis = analysisRunID != nil
            && pendingContinuedAnalysisRunID == analysisRunID
        let hasPendingExport = exportJobID != nil
            && pendingContinuedExportJobID == exportJobID
        guard hasPendingAnalysis || hasPendingExport else { return }

        // `.fail` requests are expected to launch immediately, but submission
        // acceptance and the MainActor launch callback are separate events. Give
        // that callback a short protected window instead of either trusting a
        // pending ID forever or pausing a task whose handler is already queued.
        for _ in 0..<20 {
            guard isCurrentBackgroundSceneTransition(sceneGeneration) else { return }
            let exportIsCovered = exportJobID.map {
                backgroundExecutionOwnership.coversExport(jobID: $0)
            } ?? false
            let analysisStillPending = analysisRunID != nil
                && pendingContinuedAnalysisRunID == analysisRunID
                && !backgroundExecutionOwnership.coversAnalysis(runID: analysisRunID)
            let exportStillPending = exportJobID != nil
                && pendingContinuedExportJobID == exportJobID
                && !exportIsCovered
            guard analysisStillPending || exportStillPending else { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        diagnostics.record(
            .warning,
            category: "Background Work",
            message: "Continued task launch handler did not start before scene checkpoint",
            metadata: [
                "analysisPending": analysisRunID != nil
                    && pendingContinuedAnalysisRunID == analysisRunID ? "true" : "false",
                "exportPending": exportJobID != nil
                    && pendingContinuedExportJobID == exportJobID ? "true" : "false"
            ]
        )
    }

    private func runPreflight(
        revision: UInt64,
        request: PreflightRequest,
        coordinator: ExportCoordinator
    ) async {
        defer { finishPreflightOperation(revision: revision) }

        // A completed older review owns a receiver-side planned job. Remove it
        // before computing the next generation; future generations await this
        // task, so remote reconciliation remains single-flight as well.
        await coordinator.discardPendingPreflight()
        guard isCurrentPreflight(revision: revision, request: request) else { return }

        var reconciledJobID: UUID?
        do {
            if request.kind == .newOrChanged, coordinator.destination == nil {
                throw AppModelError.connectBeforeIncremental
            }
            let localPlan = try await preflightWorker.plan(
                request: request,
                assets: assets,
                albums: albums
            )
            guard isCurrentPreflight(revision: revision, request: request) else {
                PresentationStorageRetirement.retire(consume localPlan)
                throw CancellationError()
            }
            reconciledJobID = localPlan.job.jobId
            let reconciled: PlannedExport
            do {
                reconciled = try await coordinator.reconcilePreflight(localPlan)
            } catch {
                PresentationStorageRetirement.retire(consume localPlan)
                throw error
            }
            PresentationStorageRetirement.retire(consume localPlan)
            guard isCurrentPreflight(revision: revision, request: request) else {
                PresentationStorageRetirement.retire(consume reconciled)
                throw CancellationError()
            }
            replacePlannedExport(with: reconciled)
            diagnostics.record(
                .info,
                category: "Export",
                message: "Export review completed",
                metadata: [
                    "assets": String(reconciled.preflight.assetCount),
                    "masterFiles": String(reconciled.preflight.masterFileCount),
                    "archiveFiles": String(reconciled.preflight.archiveFileCount),
                    "thumbnails": String(reconciled.preflight.thumbnailFileCount)
                ]
            )
            PresentationStorageRetirement.retire(consume reconciled)
        } catch {
            if let reconciledJobID {
                await coordinator.discardPendingPreflight(jobID: reconciledJobID)
            }
            guard isCurrentPreflight(revision: revision, request: request) else { return }
            diagnostics.record(error: error, category: "Export Review")
            alertMessage = error.localizedDescription
        }
    }

    private func finishPreflightOperation(revision: UInt64) {
        guard preflightRevision == revision else { return }
        isPlanning = false
        preflightTask = nil
    }

    private func awaitBootstrap() async {
        let task = bootstrapTask
        await task?.value
    }

    private func applyLibrarySnapshot(
        _ snapshot: PhotoLibrarySnapshot,
        authorization: PhotoAuthorizationState
    ) {
        self.authorization = authorization
        replaceLibraryPresentation(assets: snapshot.assets, albums: snapshot.albums)
        lastCatalogRevision = snapshot.revision
    }

    private func replaceLibraryPresentation(
        assets replacementAssets: [PhotoAsset],
        albums replacementAlbums: [PhotoAlbum]
    ) {
        let previous = LibraryPresentationStorage(assets: assets, albums: albums)
        assets = replacementAssets
        albums = replacementAlbums
        refreshSelectionPreviews()
        libraryPresentationRevision &+= 1
        if !previous.isEmpty {
            PresentationStorageRetirement.retire(consume previous)
        }
        invalidatePreflight()
    }

    private func replacePlannedExport(with replacement: PlannedExport?) {
        let previous = plannedExport
        plannedExport = replacement
        if let previous {
            PresentationStorageRetirement.retire(consume previous)
        }
    }

    private func replaceHistory(with replacement: [ExportHistoryEntry]) {
        let previous = history
        history = replacement
        if !previous.isEmpty {
            PresentationStorageRetirement.retire(consume previous)
        }
    }

    private func preflightRequest(revision: UInt64) -> PreflightRequest {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: rangeStart)
        let nextDay = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: rangeEnd)
        ) ?? rangeEnd
        return PreflightRequest(
            revision: revision,
            selectionRevision: selectionRevision,
            libraryRevision: libraryPresentationRevision,
            kind: selectionKind,
            rangeStart: start,
            rangeEnd: nextDay.addingTimeInterval(-0.001),
            profile: ExportProfile()
        )
    }

    private func isCurrentPreflight(
        revision: UInt64,
        request: PreflightRequest
    ) -> Bool {
        !Task.isCancelled
            && preflightRevision == revision
            && request.revision == revision
            && request.libraryRevision == libraryPresentationRevision
            && request.selectionRevision == selectionRevision
    }

    private func enqueueSelectionDelta(_ delta: PreflightSelectionDelta) {
        let previous = selectionMutationTask
        let worker = preflightWorker
        let operation = Task.detached(priority: .userInitiated) {
            [previous = consume previous] in
            await previous?.value
            await worker.applySelectionDelta(delta)
        }
        selectionMutationTask = operation
    }

    private func refreshSelectionPreviews() {
        var candidateIDs: [String] = []
        var seen: Set<String> = []

        for id in selectedAssetIDs where seen.insert(id).inserted {
            candidateIDs.append(id)
            if candidateIDs.count == 3 { break }
        }
        if candidateIDs.count < 3 {
            for album in albums where selectedAlbumIDs.contains(album.id) {
                for id in album.assetIDs where seen.insert(id).inserted {
                    candidateIDs.append(id)
                    if candidateIDs.count == 3 { break }
                }
                if candidateIDs.count == 3 { break }
            }
        }

        selectionPreviewAssets = candidateIDs.compactMap { id in
            assets.first(where: { $0.id == id })
        }
    }
}

@MainActor
private final class SceneBackgroundCheckpointLease {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var work: Task<Void, Never>?

    func run(
        operation: @escaping @MainActor @Sendable () async -> Void
    ) async {
        let task = Task { @MainActor in await operation() }
        work = task
        identifier = UIApplication.shared.beginBackgroundTask(
            withName: "Checkpoint photo work"
        ) { [weak self] in
            Task { @MainActor in await self?.expire() }
        }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            // This inner task lets the UIKit expiration callback await the same
            // checkpoint. A newer foreground scene must explicitly cancel it.
            task.cancel()
        }
        finish()
    }

    private func expire() async {
        // UIKit expiration is not foreground supersession. Leave this task
        // uncancelled so it can cancel the underlying analysis/export and
        // persist the last safe boundary. A newer active scene cancels the
        // outer lease and that path explicitly propagates cancellation here.
        await work?.value
        finish()
    }

    private func finish() {
        work = nil
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

enum AppModelError: LocalizedError {
    case connectBeforeIncremental

    var errorDescription: String? {
        switch self {
        case .connectBeforeIncremental:
            "Connect to the destination first so its export history can be checked."
        }
    }
}
