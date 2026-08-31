import AVFoundation
import Foundation
import UIKit

@MainActor
final class OrganizeCoordinator {
    private struct LibraryStateStorage: Sendable {
        let assetsByID: [String: PhotoAsset]
        let orderedAssets: [PhotoAsset]
        let orderedAssetIDs: [String]
        let albums: [PhotoAlbum]
        let albumIDsByAssetID: [String: [String]]
        let albumTitleByID: [String: String]
        let sourceRevisionByAssetID: [String: String]
        let protectedAssetIDs: Set<String>
        let analysisByAssetID: [String: AssetAnalysisRecord]
        let visualAnalysisByAssetID: [String: VisualAnalysisRecord]
        let visualAnalysisAttemptByAssetID: [String: VisualAnalysisAttemptRecord]
        let analysisRun: AnalysisRunRecord?
        let reviewStateByAssetID: [String: AssetReviewStateRecord]
        let queueByAssetID: [String: DeletionQueueItem]
        let reviewSessionsByID: [UUID: ReviewSession]
        let protectedAlbumIDs: Set<String>
        let deletionBatches: [DeletionBatch]
        let deletedItems: [DeletedItemRecord]
        let deletedItemByID: [UUID: DeletedItemRecord]
    }

    /// Owns every library-sized value crossing the refresh actor boundary. The
    /// local aliases used to install the new generation can then disappear on the
    /// main actor without becoming the final owners of their backing storage.
    /// Main-actor confined while mutable, then consumed by the retirement task.
    /// The detached task never reads or mutates fields; it only owns this box until
    /// deinitialization so all contained collection storage tears down off-main.
    private final class RefreshRetirementStorage: @unchecked Sendable {
        let previous: LibraryStateStorage
        let requestedAssets: [PhotoAsset]
        let requestedAlbums: [PhotoAlbum]
        var storedAnalysis: [String: AssetAnalysisRecord]?
        var storedVisualAnalysis: [String: VisualAnalysisRecord]?
        var storedVisualAnalysisAttempts: [String: VisualAnalysisAttemptRecord]?
        var storedAnalysisRun: AnalysisRunRecord?
        var storedReviewStates: [String: AssetReviewStateRecord]?
        var storedQueue: [DeletionQueueItem]?
        var storedReviewSessions: [ReviewSession]?
        var storedProtectedAlbums: [ProtectedAlbumRecord]?
        var storedDeletionBatches: [DeletionBatch]?
        var storedDeletedItems: [DeletedItemRecord]?
        var indexed: OrganizeIndexedState?
        var indexedVisualAnalysis: [String: VisualAnalysisRecord]?
        var indexedVisualAnalysisAttempts: [String: VisualAnalysisAttemptRecord]?
        var deletedItemIndex: [UUID: DeletedItemRecord]?

        init(
            previous: LibraryStateStorage,
            requestedAssets: [PhotoAsset],
            requestedAlbums: [PhotoAlbum]
        ) {
            self.previous = previous
            self.requestedAssets = requestedAssets
            self.requestedAlbums = requestedAlbums
        }
    }

    private struct AnalysisStateStorage: Sendable {
        let records: [String: AssetAnalysisRecord]
        let run: AnalysisRunRecord?
    }

    private struct ProtectionStateStorage: Sendable {
        let albumIDs: Set<String>
        let assetIDs: Set<String>
    }

    private struct ReviewPersistenceStateStorage: Sendable {
        let reviewStateByAssetID: [String: AssetReviewStateRecord]
        let queueByAssetID: [String: DeletionQueueItem]
        let reviewSessionsByID: [UUID: ReviewSession]
    }

    private struct DeletionHistoryStorage: Sendable {
        let batches: [DeletionBatch]
        let items: [DeletedItemRecord]
        let itemByID: [UUID: DeletedItemRecord]
    }

    private struct DeletedItemStorage: Sendable {
        let items: [DeletedItemRecord]
        let itemByID: [UUID: DeletedItemRecord]
    }

    private struct QueueSynchronizationStorage: Sendable {
        let requestedIDs: Set<String>
        let recommendations: [String: OrganizeRecommendationCategory]
        let assetsByID: [String: PhotoAsset]
        let protectedAssetIDs: Set<String>
        let existing: [String: DeletionQueueItem]
        let activeSession: OrganizeReviewSessionPresentation?
    }

    private struct ProtectionSynchronizationStorage: Sendable {
        let requestedIDs: Set<String>
        let currentIDs: Set<String>
        let albumTitleByID: [String: String]
        let assets: [PhotoAsset]
        let albumIDsByAssetID: [String: [String]]
    }

    /// Mutable only from this coordinator's main-actor deletion operation, then
    /// consumed as one unit so every large request/result buffer is released by a
    /// utility executor even when an intermediate phase throws.
    private final class DeletionOperationRetirementStorage: @unchecked Sendable {
        let requestedAssetIDs: [String]
        var requestQueue: [String: DeletionQueueItem]?
        var requestPlan: OrganizeDeletionRequestPlan?
        var validation: [PhotoAssetRevalidationResult]?
        var validationProtectedAssetIDs: Set<String>?
        var validationAnalysis: [String: AssetAnalysisRecord]?
        var validationPlan: OrganizeDeletionValidationPlan?
        var thumbnailReferences: [String: AuditThumbnailReference]?
        var preparationAnalysis: [String: AssetAnalysisRecord]?
        var preparedPlan: OrganizePreparedDeletionPlan?
        var deletionResult: PhotoLibraryDeletionResult?
        var confirmedRecords: [DeletedItemRecord]?
        var historyInput: DeletionHistoryStorage?
        var historyResult: OrganizeDeletionHistoryState?

        init(requestedAssetIDs: [String]) {
            self.requestedAssetIDs = requestedAssetIDs
        }
    }

    private final class CleanupRetirementStorage: @unchecked Sendable {
        var paths: [String]?
        var replacementItems: [DeletedItemRecord]?
        var replacementIndex: [UUID: DeletedItemRecord]?
    }

    private let ledger: SQLiteLedger
    private let catalog: PhotoKitCatalog
    private let previews: any PhotoPreviewProviding
    private let analyzer: any AssetResourceAnalyzing
    private let visualAnalyzer: (any VisualAssetAnalyzing)?
    private let revalidator: any PhotoAssetRevalidating
    private let deletionService: any PhotoLibraryDeleting
    private let auditThumbnails: any AuditThumbnailStoring
    private let deletionForegroundValidator: PhotoLibraryDeletionForegroundValidator
    private let worker = OrganizeWorker()
    private let continueAnalysisInBackground: @MainActor @Sendable (
        _ runID: UUID,
        _ includeICloudItems: Bool,
        _ origin: AnalysisRunOrigin
    ) -> Void

    private weak var viewModel: OrganizeViewModel?
    private var refreshLibraryHandler: (@MainActor () async -> Void)?
    private var analysisTask: Task<Void, Never>?
    /// Bridges the short handoff where OrganizeWorker has returned its durable
    /// running row but the coordinator has not installed the result yet.
    private var activeCoordinatorAnalysisRunID: UUID?
    private var refreshRequestedAfterAnalysis = false
    private var analysisProgressGeneration: UInt64 = 0
    private var analysisExecutionGeneration: UInt64 = 0
    private var presentationRevision: UInt64 = 0
    private var refreshGeneration: UInt64 = 0
    private var analysisNextPosition = 0

    private var authorization: PhotoAuthorizationState = .notDetermined
    private var assetsByID: [String: PhotoAsset] = [:]
    private var orderedAssets: [PhotoAsset] = []
    private var orderedAssetIDs: [String] = []
    private var albumIDsByAssetID: [String: [String]] = [:]
    private var albumTitleByID: [String: String] = [:]
    private var sourceRevisionByAssetID: [String: String] = [:]
    private var protectedAssetIDs: Set<String> = []
    private var albums: [PhotoAlbum] = []
    private var analysisByAssetID: [String: AssetAnalysisRecord] = [:]
    private var visualAnalysisByAssetID: [String: VisualAnalysisRecord] = [:]
    private var visualAnalysisAttemptByAssetID: [String: VisualAnalysisAttemptRecord] = [:]
    private var analysisRun: AnalysisRunRecord?
    private var visualAnalysisIsRunning = false
    private var activeAnalysisOrigin: AnalysisRunOrigin?
    private var reviewStateByAssetID: [String: AssetReviewStateRecord] = [:]
    private var queueByAssetID: [String: DeletionQueueItem] = [:]
    private var reviewSessionsByID: [UUID: ReviewSession] = [:]
    private var protectedAlbumIDs: Set<String> = []
    private var deletionBatches: [DeletionBatch] = []
    private var deletedItems: [DeletedItemRecord] = []
    private var deletedItemByID: [UUID: DeletedItemRecord] = [:]
    private var didRecoverInterruptedDeletionBatches = false

    init(
        ledger: SQLiteLedger,
        catalog: PhotoKitCatalog,
        previews: any PhotoPreviewProviding = PhotoKitPreviewProvider(),
        analyzer: any AssetResourceAnalyzing = PhotoKitAssetResourceAnalyzer(),
        visualAnalyzer: (any VisualAssetAnalyzing)? = nil,
        revalidator: any PhotoAssetRevalidating = PhotoKitAssetRevalidator(),
        deletionService: any PhotoLibraryDeleting = PhotoKitDeletionService(),
        auditThumbnails: (any AuditThumbnailStoring)? = nil,
        deletionForegroundValidator: @escaping PhotoLibraryDeletionForegroundValidator = {
            UIApplication.shared.applicationState == .active
        },
        continueAnalysisInBackground: @escaping @MainActor @Sendable (
            _ runID: UUID,
            _ includeICloudItems: Bool,
            _ origin: AnalysisRunOrigin
        ) -> Void = { _, _, _ in }
    ) {
        self.ledger = ledger
        self.catalog = catalog
        self.previews = previews
        self.analyzer = analyzer
        self.visualAnalyzer = visualAnalyzer
        self.revalidator = revalidator
        self.deletionService = deletionService
        self.auditThumbnails = auditThumbnails ?? PhotoKitAuditThumbnailStore(previews: previews)
        self.deletionForegroundValidator = deletionForegroundValidator
        self.continueAnalysisInBackground = continueAnalysisInBackground
    }

    func install(
        on viewModel: OrganizeViewModel,
        refreshLibrary: @escaping @MainActor () async -> Void
    ) {
        self.viewModel = viewModel
        viewModel.installWorker(worker)
        refreshLibraryHandler = refreshLibrary
        viewModel.installCallbacks(
            OrganizeViewModelCallbacks(
                requestAuthorization: { [weak self] in
                    guard let self else { return }
                    _ = await self.catalog.requestAuthorization()
                    await self.refreshLibraryHandler?()
                },
                presentLimitedPicker: { [weak self] in
                    self?.presentLimitedPicker()
                },
                openSettings: {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                },
                refreshLibrary: { [weak self] in
                    await self?.refreshLibraryHandler?()
                },
                loadThumbnail: { [weak self] assetID, size in
                    guard let self else { return nil }
                    if let image = await self.catalog.thumbnail(
                        assetID: assetID,
                        size: size,
                        scale: UIScreen.main.scale
                    ) {
                        return image
                    }
                    return await self.catalog.thumbnail(
                        assetID: assetID,
                        size: size,
                        scale: UIScreen.main.scale,
                        allowsNetworkAccess: true
                    )
                },
                loadVideoPlayer: { [weak self] assetID in
                    guard let self else { return nil }
                    guard let item = try? await self.previews.videoPlayerItem(
                        assetID: assetID,
                        includeNetwork: true,
                        progress: { _ in }
                    ) else { return nil }
                    return AVPlayer(playerItem: item)
                },
                loadLivePhoto: { [weak self] assetID, size in
                    guard let self else { return nil }
                    return try? await self.previews.livePhoto(
                        assetID: assetID,
                        targetSize: size,
                        scale: UIScreen.main.scale,
                        includeNetwork: true,
                        progress: { _ in }
                    )
                },
                loadDeletedThumbnail: { [weak self] recordID, _ in
                    await self?.deletedThumbnail(recordID: recordID)
                },
                startAnalysis: { [weak self] includeICloudItems in
                    await self?.startAnalysis(
                        includeICloudItems: includeICloudItems,
                        origin: .userInitiated
                    )
                },
                persistReviewSession: { [weak self] session in
                    await self?.persistReviewSession(session)
                },
                persistReviewChoice: { [weak self] sessionID, action, cursor, isComplete in
                    await self?.persistReviewChoice(
                        sessionID: sessionID,
                        action: action,
                        resultingCursor: cursor,
                        isComplete: isComplete
                    )
                },
                persistReviewUndo: { [weak self] sessionID, action, cursor in
                    await self?.persistReviewUndo(
                        sessionID: sessionID,
                        removedAction: action,
                        resultingCursor: cursor
                    )
                },
                persistQueue: { [weak self] assetIDs, recommendations in
                    await self?.synchronizeQueue(with: assetIDs, recommendations: recommendations)
                },
                persistQueueDelta: { [weak self] delta in
                    await self?.applyQueueDelta(delta)
                },
                persistProtectedAlbums: { [weak self] albumIDs in
                    await self?.synchronizeProtectedAlbums(with: albumIDs)
                },
                persistProtectedAlbumDelta: { [weak self] delta in
                    await self?.applyProtectedAlbumDelta(delta)
                },
                moveToRecentlyDeleted: { [weak self] assetIDs, intentValidator in
                    guard let self else { throw CancellationError() }
                    return try await self.moveToRecentlyDeleted(
                        assetIDs: assetIDs,
                        intentValidator: intentValidator
                    )
                },
                cleanExpiredThumbnails: { [weak self] in
                    await self?.cleanExpiredThumbnails(reportErrors: true)
                },
                autoAnalyzePreferenceChanged: { [weak self] isEnabled in
                    self?.reconcileAutomaticAnalysis(isEnabled: isEnabled)
                }
            )
        )
    }

    func refresh(
        authorization: PhotoAuthorizationState,
        assets: [PhotoAsset],
        albums: [PhotoAlbum]
    ) async {
        // A normal foreground refresh must not invalidate the live progress stream
        // owned by an active analysis. Scene activation commonly requests the same
        // authorized library again while continued processing is still running.
        // Advancing refreshGeneration in that case makes every subsequent in-app
        // update look stale even though the system progress notification continues
        // to advance from the durable ledger. Coalesce those refreshes and fetch one
        // fresh snapshot as soon as analysis finishes instead.
        //
        // Empty limited-library snapshots are not deferred: AppModel uses them as a
        // privacy fence while a changed limited authorization is being validated.
        if analysisTask != nil,
           authorization == self.authorization,
           authorization == .authorized || authorization == .limited,
           !assets.isEmpty {
            refreshRequestedAfterAnalysis = true
            return
        }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let retirement = RefreshRetirementStorage(
            previous: currentLibraryStateStorage(),
            requestedAssets: assets,
            requestedAlbums: albums
        )
        self.authorization = authorization
        self.albums = albums

        do {
            var interruptedRecovery = InterruptedDeletionRecovery.none
            if !didRecoverInterruptedDeletionBatches {
                interruptedRecovery = try await ledger.recoverInterruptedDeletionBatches()
                didRecoverInterruptedDeletionBatches = true
            }
            let storedAnalysis = try await ledger.analysisRecords()
            retirement.storedAnalysis = storedAnalysis
            let storedVisualAnalysis = try await ledger.visualAnalysisRecords()
            retirement.storedVisualAnalysis = storedVisualAnalysis
            let storedVisualAnalysisAttempts = try await ledger.visualAnalysisAttempts()
            retirement.storedVisualAnalysisAttempts = storedVisualAnalysisAttempts
            let storedAnalysisRun = try await ledger.latestAnalysisRun()
            retirement.storedAnalysisRun = storedAnalysisRun
            let storedAnalysisNextPosition: Int
            if let run = storedAnalysisRun {
                storedAnalysisNextPosition = try await ledger.analysisNextPosition(runID: run.id)
            } else {
                storedAnalysisNextPosition = 0
            }
            let storedReviewStates = try await ledger.reviewStates()
            retirement.storedReviewStates = storedReviewStates
            let storedQueue = try await ledger.recentlyDeletedQueue()
            retirement.storedQueue = storedQueue
            let storedReviewSessions = try await ledger.reviewSessions()
            retirement.storedReviewSessions = storedReviewSessions
            let storedProtectedAlbums = try await ledger.protectedAlbums()
            retirement.storedProtectedAlbums = storedProtectedAlbums
            let storedDeletionBatches = try await ledger.deletionBatches()
            retirement.storedDeletionBatches = storedDeletionBatches
            let storedDeletedItems = try await ledger.deletedItems()
            retirement.storedDeletedItems = storedDeletedItems
            let indexed = try await worker.index(
                assets: assets,
                albums: albums,
                analysisByAssetID: storedAnalysis,
                reviewStateByAssetID: storedReviewStates,
                queueItems: storedQueue,
                reviewSessions: storedReviewSessions,
                protectedAlbums: storedProtectedAlbums,
                requestGeneration: generation
            )
            retirement.indexed = indexed
            let requestedAssetsByID = Dictionary(
                uniqueKeysWithValues: assets.map { ($0.id, $0) }
            )
            let indexedVisualAnalysis = storedVisualAnalysis.filter { assetID, record in
                guard let asset = requestedAssetsByID[assetID] else { return false }
                return record.isValid(for: asset)
            }
            retirement.indexedVisualAnalysis = indexedVisualAnalysis
            let indexedVisualAnalysisAttempts = storedVisualAnalysisAttempts.filter { assetID, attempt in
                guard let asset = requestedAssetsByID[assetID] else { return false }
                return attempt.isValid(for: asset)
            }
            retirement.indexedVisualAnalysisAttempts = indexedVisualAnalysisAttempts
            let deletedItemIndex = await worker.deletedItemIndex(storedDeletedItems)
            retirement.deletedItemIndex = deletedItemIndex
            guard generation == refreshGeneration, !Task.isCancelled else {
                PresentationStorageRetirement.retire(consume retirement)
                return
            }
            assetsByID = indexed.assetsByID
            orderedAssets = indexed.orderedAssets
            orderedAssetIDs = indexed.orderedAssetIDs
            albumIDsByAssetID = indexed.albumIDsByAssetID
            albumTitleByID = indexed.albumTitleByID
            sourceRevisionByAssetID = indexed.sourceRevisionByAssetID
            analysisByAssetID = indexed.analysisByAssetID
            visualAnalysisByAssetID = indexedVisualAnalysis
            visualAnalysisAttemptByAssetID = indexedVisualAnalysisAttempts
            reviewStateByAssetID = indexed.reviewStateByAssetID
            queueByAssetID = indexed.queueByAssetID
            reviewSessionsByID = indexed.reviewSessionsByID
            protectedAlbumIDs = indexed.protectedAlbumIDs
            protectedAssetIDs = indexed.protectedAssetIDs
            analysisRun = storedAnalysisRun
            analysisNextPosition = storedAnalysisNextPosition
            deletionBatches = storedDeletionBatches
            deletedItems = storedDeletedItems
            deletedItemByID = deletedItemIndex
            await renderNow(requiredRefreshGeneration: generation)
            if interruptedRecovery.itemCount > 0 {
                viewModel?.userMessage = OrganizeUserMessage(
                    title: "Check Apple Photos",
                    message: "The app recovered \(interruptedRecovery.itemCount) audit record(s) whose Apple Photos result was not saved before the app closed. They are marked Result Not Recorded and were removed from the staged queue to prevent an automatic retry. Check Recently Deleted in Apple Photos to verify what happened."
                )
            }
            PresentationStorageRetirement.retire(consume retirement)
        } catch {
            PresentationStorageRetirement.retire(consume retirement)
            guard generation == refreshGeneration, !Task.isCancelled else { return }
            viewModel?.userMessage = OrganizeUserMessage(
                title: "Organize History Unavailable",
                message: error.localizedDescription
            )
            viewModel?.applyLibrary(authorization: authorization, assets: assets, albums: albums)
        }
    }

    func pauseAnalysis() {
        analysisTask?.cancel()
        analysisProgressGeneration &+= 1
        // OrganizeWorker owns the durable pause transition. It checkpoints the
        // latest committed cursor while unwinding cancellation, so a detached UI
        // checkpoint can never race afterward and move the cursor backwards.
        guard let viewModel else { return }
        var presentation = viewModel.analysis
        if presentation.phase == .running {
            presentation.phase = .paused
            presentation.currentAssetFraction = 0
            presentation.statusText = "Analysis paused. Resume when the app is active."
            viewModel.setAnalysis(presentation)
        }
    }

    /// Cancels the in-memory work and does not return until its durable pause checkpoint
    /// has completed. Background-task expiration handlers use this before reporting
    /// completion to the OS.
    func checkpointAnalysisForBackground(runID requestedRunID: UUID? = nil) async {
        let checkpointGeneration = analysisExecutionGeneration
        let task = analysisTask
        let runningCoordinatorRunID = analysisRun.flatMap { run in
            run.status == .running ? run.id : nil
        }
        let handedOffCoordinatorRunID = activeCoordinatorAnalysisRunID
        let visualCoordinatorRunID = visualAnalysisIsRunning ? analysisRun?.id : nil
        let activeRunID = await worker.activeAnalysisRunIdentifier()
        guard !Task.isCancelled,
              checkpointGeneration == analysisExecutionGeneration else { return }
        if let requestedRunID,
           activeRunID != requestedRunID,
           runningCoordinatorRunID != requestedRunID,
           handedOffCoordinatorRunID != requestedRunID,
           visualCoordinatorRunID != requestedRunID {
            return
        }
        let checkpointRunID = requestedRunID
            ?? activeRunID
            ?? runningCoordinatorRunID
            ?? handedOffCoordinatorRunID
            ?? visualCoordinatorRunID
        task?.cancel()
        analysisProgressGeneration &+= 1
        await task?.value
        if visualCoordinatorRunID == checkpointRunID,
           let status = analysisRun?.status,
           status != .running,
           status != .paused {
            return
        }
        guard analysisExecutionGeneration == checkpointGeneration,
              let checkpointRunID,
              var run = analysisRun,
              run.id == checkpointRunID,
              run.status == .running else { return }
        run.status = .paused
        run.updatedAt = Date()
        analysisRun = run
        try? await ledger.checkpointAnalysisRun(
            id: run.id,
            status: .paused,
            nextPosition: analysisNextPosition,
            updatedAt: run.updatedAt
        )
    }

    private func presentLimitedPicker() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        var presenter = root
        while let presented = presenter.presentedViewController { presenter = presented }
        catalog.presentLimitedLibraryPicker(from: presenter)
    }

    var currentAnalysisOrigin: AnalysisRunOrigin? {
        activeAnalysisOrigin ?? analysisRun?.origin
    }

    private var hasPendingAutomaticLocalVisualAnalysis: Bool {
        pendingVisualAssets(
            includeICloudItems: false,
            origin: .automaticMaintenance
        ).isEmpty == false
    }

    private var hasResumableAutomaticAnalysisRun: Bool {
        guard let run = analysisRun,
              run.origin == .automaticMaintenance else { return false }
        return run.status == .running || run.status == .paused
    }

    private func pendingVisualAssets(
        includeICloudItems: Bool,
        origin: AnalysisRunOrigin
    ) -> [PhotoAsset] {
        orderedAssets.filter { asset in
            guard asset.mediaKind == .photo,
                  visualAnalysisByAssetID[asset.id]?.isValid(for: asset) != true else {
                return false
            }
            guard let attempt = visualAnalysisAttemptByAssetID[asset.id],
                  attempt.isValid(for: asset) else {
                return true
            }
            if includeICloudItems { return true }
            switch attempt.status {
            case .unavailableLocally:
                return false
            case .failed:
                return origin == .userInitiated
            }
        }
    }

    private var analysisNeedsWork: Bool {
        let exactAnalysisNeedsWork = viewModel.map {
            $0.analysis.processedAssetCount < orderedAssetIDs.count
        } ?? true
        return exactAnalysisNeedsWork
            || hasPendingAutomaticLocalVisualAnalysis
            || hasResumableAutomaticAnalysisRun
    }

    func currentAnalysisRunID() async -> UUID? {
        if let activeRunID = await worker.activeAnalysisRunIdentifier() {
            return activeRunID
        }
        if let activeCoordinatorAnalysisRunID { return activeCoordinatorAnalysisRunID }
        if visualAnalysisIsRunning, let runID = analysisRun?.id {
            return runID
        }
        guard let run = analysisRun,
              run.status == .running || run.status == .paused else { return nil }
        return run.id
    }

    private func startAnalysis(
        includeICloudItems: Bool,
        origin: AnalysisRunOrigin
    ) async {
        guard analysisTask == nil else { return }
        analysisExecutionGeneration &+= 1
        let executionGeneration = analysisExecutionGeneration
        activeCoordinatorAnalysisRunID = nil
        activeAnalysisOrigin = origin
        analysisProgressGeneration &+= 1
        let progressGeneration = analysisProgressGeneration
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.runAnalysis(
                includeICloudItems: includeICloudItems,
                origin: origin,
                progressGeneration: progressGeneration
            )
        }
        replaceAnalysisTask(with: task)
        await task.value
        guard executionGeneration == analysisExecutionGeneration else { return }
        activeAnalysisOrigin = nil
        activeCoordinatorAnalysisRunID = nil
        replaceAnalysisTask(with: nil)
        if refreshRequestedAfterAnalysis {
            refreshRequestedAfterAnalysis = false
            await refreshLibraryHandler?()
        }
    }

    /// Used by BGProcessing to resume the latest durable run without requiring a view
    /// or a user gesture. Returns false when there is no resumable run or another run
    /// already owns the single-flight analysis slot.
    func resumeAnalysisInBackground() async -> Bool {
        guard analysisTask == nil,
              let run = analysisRun,
              run.origin == .userInitiated,
              run.status == .paused || run.status == .running else { return false }
        await startAnalysis(
            includeICloudItems: run.includesICloudItems,
            origin: run.origin
        )
        return analysisRun?.status == .complete
    }

    /// Ext-power maintenance entrypoint. It never starts or resumes a run that can
    /// fetch iCloud resources.
    func runAutomaticLocalAnalysisInBackground() async -> Bool {
        guard analysisTask == nil,
              !orderedAssetIDs.isEmpty,
              analysisNeedsWork else { return false }
        if let run = analysisRun,
           run.status == .running || run.status == .paused,
           run.includesICloudItems || run.origin != .automaticMaintenance {
            return false
        }
        await startAnalysis(
            includeICloudItems: false,
            origin: .automaticMaintenance
        )
        return analysisRun?.status == .complete
            && analysisRun?.origin == .automaticMaintenance
            && !hasPendingAutomaticLocalVisualAnalysis
    }

    /// Starts opportunistic, local-only analysis after a foreground library
    /// refresh. User-initiated paused work is left untouched, and disabling the
    /// setting checkpoints an automatically started run instead of continuing it.
    func reconcileAutomaticAnalysis(isEnabled: Bool) {
        guard isEnabled else {
            if activeAnalysisOrigin == .automaticMaintenance {
                pauseAnalysis()
            }
            return
        }
        guard authorization == .authorized || authorization == .limited,
              analysisTask == nil,
              !orderedAssetIDs.isEmpty,
              let presentation = viewModel?.analysis,
              presentation.processedAssetCount < orderedAssetIDs.count
                || hasPendingAutomaticLocalVisualAnalysis
                || hasResumableAutomaticAnalysisRun else { return }
        if let run = analysisRun,
           run.status == .running || run.status == .paused,
           run.origin != .automaticMaintenance {
            return
        }
        Task { @MainActor [weak self] in
            guard let self,
                  self.viewModel?.autoAnalyzeEnabled == true else { return }
            await self.startAnalysis(
                includeICloudItems: false,
                origin: .automaticMaintenance
            )
        }
    }

    private func runAnalysis(
        includeICloudItems: Bool,
        origin: AnalysisRunOrigin,
        progressGeneration: UInt64
    ) async {
        let inputRefreshGeneration = refreshGeneration
        let input = OrganizeAnalysisWorkerInput(
            includeICloudItems: includeICloudItems,
            orderedAssetIDs: orderedAssetIDs,
            assetsByID: assetsByID,
            sourceRevisionByAssetID: sourceRevisionByAssetID,
            albumIDsByAssetID: albumIDsByAssetID,
            analysisByAssetID: analysisByAssetID,
            analysisRun: analysisRun,
            nextPosition: analysisNextPosition,
            origin: origin
        )
        let defersSuccessfulCompletion = visualAnalyzer != nil
            && !pendingVisualAssets(
                includeICloudItems: includeICloudItems,
                origin: origin
            ).isEmpty
        do {
            let result = try await worker.runAnalysis(
                input,
                ledger: ledger,
                analyzer: analyzer,
                deferSuccessfulCompletion: defersSuccessfulCompletion,
                analysisRunIdentified: { [weak self] runID, includesICloudItems, origin in
                    await self?.analysisRunDidStart(
                        runID,
                        includesICloudItems,
                        origin
                    )
                }
            ) { [weak self] update in
                await self?.publishWorkerAnalysisProgress(
                    update,
                    generation: progressGeneration,
                    refreshGeneration: inputRefreshGeneration
                )
            }
            guard inputRefreshGeneration == refreshGeneration else {
                PresentationStorageRetirement.retire(consume input)
                PresentationStorageRetirement.retire(consume result)
                await refreshLibraryHandler?()
                return
            }
            replaceAnalysisState(
                records: result.analysisByAssetID,
                run: result.analysisRun
            )
            analysisNextPosition = result.nextPosition
            viewModel?.setAnalysis(result.presentation)
            if defersSuccessfulCompletion, result.analysisRun.status == .running {
                let visualCompleted = await runVisualAnalysis(
                    includeICloudItems: includeICloudItems,
                    origin: origin,
                    progressGeneration: progressGeneration,
                    expectedRefreshGeneration: inputRefreshGeneration
                )
                await finishDeferredVisualAnalysisRun(
                    runID: result.analysisRun.id,
                    completed: visualCompleted,
                    basePresentation: result.presentation
                )
            }
            guard inputRefreshGeneration == refreshGeneration else {
                PresentationStorageRetirement.retire(consume input)
                PresentationStorageRetirement.retire(consume result)
                await refreshLibraryHandler?()
                return
            }
            await renderNow()
            PresentationStorageRetirement.retire(consume input)
            PresentationStorageRetirement.retire(consume result)
        } catch {
            PresentationStorageRetirement.retire(consume input)
            guard progressGeneration == analysisProgressGeneration,
                  inputRefreshGeneration == refreshGeneration else { return }
            if let viewModel {
                var presentation = viewModel.analysis
                presentation.phase = .failed
                presentation.totalAssetCount = orderedAssetIDs.count
                presentation.currentAssetFraction = 0
                presentation.includesICloudItems = includeICloudItems
                presentation.statusText = error.localizedDescription
                viewModel.setAnalysis(presentation)
            }
        }
    }

    private func analysisRunDidStart(
        _ runID: UUID,
        _ includeICloudItems: Bool,
        _ origin: AnalysisRunOrigin
    ) async {
        activeCoordinatorAnalysisRunID = runID
        await continueAnalysisInBackground(runID, includeICloudItems, origin)
    }

    /// Runs the pixel-based analysis independently from exact resource hashing.
    /// Each completed record is committed on its own, so cancellation, thermal
    /// pressure, or process termination can resume by selecting only missing or
    /// stale asset revisions on the next pass.
    private func runVisualAnalysis(
        includeICloudItems: Bool,
        origin: AnalysisRunOrigin,
        progressGeneration: UInt64,
        expectedRefreshGeneration: UInt64
    ) async -> Bool {
        guard let visualAnalyzer else { return true }
        let pendingAssets = pendingVisualAssets(
            includeICloudItems: includeICloudItems,
            origin: origin
        )
        guard !pendingAssets.isEmpty else { return true }

        visualAnalysisIsRunning = true
        defer { visualAnalysisIsRunning = false }
        var records = visualAnalysisByAssetID
        var attempts = visualAnalysisAttemptByAssetID

        for (index, asset) in pendingAssets.enumerated() {
            guard !Task.isCancelled,
                  progressGeneration == analysisProgressGeneration,
                  expectedRefreshGeneration == refreshGeneration else {
                return false
            }

            if var presentation = viewModel?.analysis {
                presentation.phase = .running
                presentation.currentAssetFraction = 0
                presentation.statusText = "Smart scan \(index + 1) of \(pendingAssets.count)…"
                viewModel?.setAnalysis(presentation)
            }

            do {
                let record = try await visualAnalyzer.analyze(
                    assetID: asset.id,
                    sourceRevision: asset.analysisRevision,
                    includeNetwork: includeICloudItems,
                    progress: { _ in }
                )
                guard !Task.isCancelled,
                      progressGeneration == analysisProgressGeneration,
                      expectedRefreshGeneration == refreshGeneration,
                      let currentAsset = assetsByID[asset.id],
                      currentAsset.analysisRevision == asset.analysisRevision,
                      record.isValid(for: currentAsset) else {
                    return false
                }
                do {
                    try await ledger.saveVisualAnalysisRecord(record)
                } catch {
                    // A durable cache write is part of the visual checkpoint.
                    // Leave the run paused so a later resume can retry it.
                    return false
                }
                guard !Task.isCancelled,
                      progressGeneration == analysisProgressGeneration,
                      expectedRefreshGeneration == refreshGeneration,
                      assetsByID[asset.id]?.analysisRevision == asset.analysisRevision else {
                    try? await ledger.removeVisualAnalysisRecord(assetID: asset.id)
                    return false
                }
                records[asset.id] = record
                attempts.removeValue(forKey: asset.id)
                visualAnalysisByAssetID = records
                visualAnalysisAttemptByAssetID = attempts
            } catch is CancellationError {
                return false
            } catch VisualAnalysisError.assetChanged {
                return false
            } catch {
                // Visual signals are advisory. An unavailable thumbnail or an
                // individual Vision failure must not downgrade exact analysis,
                // hide the library, or weaken the deletion safety boundary.
                guard !Task.isCancelled,
                      progressGeneration == analysisProgressGeneration,
                      expectedRefreshGeneration == refreshGeneration,
                      assetsByID[asset.id]?.analysisRevision == asset.analysisRevision else {
                    return false
                }
                let status: VisualAnalysisAttemptStatus
                if case VisualAnalysisError.networkAccessRequired = error,
                   !includeICloudItems {
                    status = .unavailableLocally
                } else {
                    status = .failed
                }
                let attempt = VisualAnalysisAttemptRecord(
                    assetID: asset.id,
                    sourceRevision: asset.analysisRevision,
                    algorithmVersion: VisualAnalysisAlgorithm.currentVersion,
                    visionRevisions: .pinnedV1,
                    status: status,
                    attemptedAt: Date()
                )
                do {
                    try await ledger.saveVisualAnalysisAttempt(attempt)
                } catch {
                    return false
                }
                guard !Task.isCancelled,
                      progressGeneration == analysisProgressGeneration,
                      expectedRefreshGeneration == refreshGeneration,
                      assetsByID[asset.id]?.analysisRevision == asset.analysisRevision else {
                    try? await ledger.removeVisualAnalysisAttempt(assetID: asset.id)
                    return false
                }
                records.removeValue(forKey: asset.id)
                attempts[asset.id] = attempt
                visualAnalysisByAssetID = records
                visualAnalysisAttemptByAssetID = attempts
                continue
            }
        }

        guard !Task.isCancelled,
              progressGeneration == analysisProgressGeneration,
              expectedRefreshGeneration == refreshGeneration else { return false }
        visualAnalysisByAssetID = records
        visualAnalysisAttemptByAssetID = attempts
        return true
    }

    private func finishDeferredVisualAnalysisRun(
        runID: UUID,
        completed: Bool,
        basePresentation: OrganizeAnalysisPresentation
    ) async {
        guard var run = analysisRun,
              run.id == runID,
              run.status == .running else { return }
        let status: AnalysisRunStatus = completed ? .complete : .paused
        let durableNextPosition = completed
            ? orderedAssetIDs.count
            : max(orderedAssetIDs.count - 1, 0)
        run.status = status
        run.updatedAt = Date()
        run.errorMessage = nil
        do {
            try await ledger.checkpointAnalysisRun(
                id: run.id,
                status: status,
                nextPosition: durableNextPosition,
                completedAssetCount: basePresentation.completedAssetCount,
                updatedAt: run.updatedAt
            )
            analysisRun = run
            var presentation = basePresentation
            presentation.phase = completed ? .complete : .paused
            presentation.currentAssetFraction = 0
            presentation.statusText = completed
                ? "Storage and on-device smart analysis are up to date."
                : "Analysis paused. Resume when the app is active."
            viewModel?.setAnalysis(presentation)
        } catch {
            run.status = .failed
            run.updatedAt = Date()
            run.errorMessage = error.localizedDescription
            analysisRun = run
            try? await ledger.checkpointAnalysisRun(
                id: run.id,
                status: .failed,
                nextPosition: analysisNextPosition,
                completedAssetCount: basePresentation.completedAssetCount,
                updatedAt: run.updatedAt,
                errorMessage: run.errorMessage
            )
            var presentation = basePresentation
            presentation.phase = .failed
            presentation.currentAssetFraction = 0
            presentation.statusText = error.localizedDescription
            viewModel?.setAnalysis(presentation)
        }
    }

    private func publishWorkerAnalysisProgress(
        _ update: OrganizeAnalysisProgressUpdate,
        generation: UInt64,
        refreshGeneration expectedRefreshGeneration: UInt64
    ) {
        guard generation == analysisProgressGeneration,
              expectedRefreshGeneration == refreshGeneration else { return }
        // OrganizeAnalysisProgressPublisher already coalesces resource callbacks to
        // ten updates per second. Apply that stream directly so the breakdown does
        // not incur a second throttle and an avoidable extra frame of latency.
        viewModel?.applyAnalysisProgress(update)
    }

    private func synchronizeQueue(
        with requestedIDs: Set<String>,
        recommendations: [String: OrganizeRecommendationCategory]
    ) async {
        let input = QueueSynchronizationStorage(
            requestedIDs: requestedIDs,
            recommendations: recommendations,
            assetsByID: assetsByID,
            protectedAssetIDs: protectedAssetIDs,
            existing: queueByAssetID,
            activeSession: viewModel?.activeReviewSession
        )
        do {
            let replacement = try await worker.replaceQueue(
                requestedIDs: input.requestedIDs,
                recommendations: input.recommendations,
                assetsByID: input.assetsByID,
                protectedAssetIDs: input.protectedAssetIDs,
                existing: input.existing,
                activeSession: input.activeSession,
                ledger: ledger
            )
            replaceQueue(with: replacement)
            PresentationStorageRetirement.retire(consume input)
        } catch {
            PresentationStorageRetirement.retire(consume input)
            viewModel?.userMessage = OrganizeUserMessage(
                title: "Queue Not Saved",
                message: "The staged queue could not be saved: \(error.localizedDescription)"
            )
        }
    }

    private func applyQueueDelta(_ delta: consuming OrganizeQueuePersistenceDelta) async {
        do {
            let replacement = try await worker.applyQueueDelta(delta, ledger: ledger)
            replaceQueue(with: replacement)
            PresentationStorageRetirement.retire(consume delta)
        } catch {
            PresentationStorageRetirement.retire(consume delta)
            viewModel?.userMessage = OrganizeUserMessage(
                title: "Queue Not Saved",
                message: "The staged queue change could not be saved: \(error.localizedDescription)"
            )
        }
    }

    private func synchronizeProtectedAlbums(with requestedIDs: Set<String>) async {
        let input = ProtectionSynchronizationStorage(
            requestedIDs: requestedIDs,
            currentIDs: protectedAlbumIDs,
            albumTitleByID: albumTitleByID,
            assets: orderedAssets,
            albumIDsByAssetID: albumIDsByAssetID
        )
        do {
            let nextProtectedAssetIDs = try await worker.synchronizeProtectedAlbums(
                requestedIDs: input.requestedIDs,
                currentIDs: input.currentIDs,
                albumTitleByID: input.albumTitleByID,
                assets: input.assets,
                albumIDsByAssetID: input.albumIDsByAssetID,
                ledger: ledger
            )
            let replacement = ProtectionStateStorage(
                albumIDs: requestedIDs,
                assetIDs: nextProtectedAssetIDs
            )
            replaceProtectionState(
                albumIDs: replacement.albumIDs,
                assetIDs: replacement.assetIDs
            )
            await renderNow()
            PresentationStorageRetirement.retire(consume input)
            PresentationStorageRetirement.retire(consume replacement)
        } catch {
            PresentationStorageRetirement.retire(consume input)
            viewModel?.userMessage = OrganizeUserMessage(
                title: "Album Protection Not Saved",
                message: error.localizedDescription
            )
            await renderNow()
        }
    }

    private func applyProtectedAlbumDelta(
        _ delta: consuming OrganizeProtectedAlbumPersistenceDelta
    ) async {
        do {
            let replacement = try await worker.applyProtectedAlbumDelta(delta, ledger: ledger)
            replaceProtectionState(
                albumIDs: replacement.protectedAlbumIDs,
                assetIDs: replacement.protectedAssetIDs
            )
            PresentationStorageRetirement.retire(consume delta)
            PresentationStorageRetirement.retire(consume replacement)
            await renderNow()
        } catch {
            await worker.rejectProtectedAlbumPresentationMutation(delta)
            PresentationStorageRetirement.retire(consume delta)
            viewModel?.userMessage = OrganizeUserMessage(
                title: "Album Protection Not Saved",
                message: error.localizedDescription
            )
            await renderNow()
        }
    }

    private func persistReviewSession(
        _ presentation: consuming OrganizeReviewSessionPresentation
    ) async {
        do {
            let snapshot = try await worker.persistReviewSession(
                from: presentation,
                ledger: ledger
            )
            replaceReviewPersistenceState(with: snapshot)
            PresentationStorageRetirement.retire(consume presentation)
            PresentationStorageRetirement.retire(consume snapshot)
        } catch {
            PresentationStorageRetirement.retire(consume presentation)
            viewModel?.userMessage = OrganizeUserMessage(
                title: "Review Not Saved",
                message: "The latest review decision could not be saved: \(error.localizedDescription)"
            )
        }
    }

    private func persistReviewChoice(
        sessionID: UUID,
        action presentationAction: OrganizeReviewActionPresentation,
        resultingCursor: Int,
        isComplete: Bool
    ) async {
        let assetID = presentationAction.assetID
        let choice = presentationAction.choice
        guard let sourceRevision = sourceRevisionByAssetID[assetID],
              var session = reviewSessionsByID[sessionID] else { return }
        do {
            session.cursor = resultingCursor
            session.status = isComplete ? .completed : .active
            session.updatedAt = Date()
            let domainAction = ReviewAction(
                id: presentationAction.id,
                sessionID: sessionID,
                sequence: max(0, resultingCursor - 1),
                assetID: assetID,
                decision: reviewDecision(choice),
                previousDecision: presentationAction.previousChoice.map(reviewDecision),
                cursorBefore: presentationAction.previousIndex,
                cursorAfter: resultingCursor,
                createdAt: Date(),
                wasQueued: presentationAction.wasQueued,
                wasReviewed: presentationAction.wasReviewed
            )
            let stateMutation: ReviewStatePersistenceMutation
            if let state = reviewDecision(choice).reviewState {
                let record = AssetReviewStateRecord(
                    assetID: assetID,
                    sourceRevision: sourceRevision,
                    state: state,
                    recommendationKind: session.recommendationKind,
                    updatedAt: Date()
                )
                stateMutation = .upsert(record)
            } else {
                stateMutation = .remove(assetID: assetID)
            }
            let queueMutation = reviewQueueMutation(
                assetID: assetID,
                choice: choice,
                session: session
            )
            let snapshot = try await worker.persistReviewMutation(
                session: session,
                action: .append(domainAction),
                state: stateMutation,
                queue: queueMutation,
                ledger: ledger
            )
            replaceReviewPersistenceState(with: snapshot)
            PresentationStorageRetirement.retire(consume snapshot)
        } catch {
            viewModel?.userMessage = OrganizeUserMessage(
                title: "Review Not Saved",
                message: "The latest review decision could not be saved: \(error.localizedDescription)"
            )
        }
    }

    private func persistReviewUndo(
        sessionID: UUID,
        removedAction presentationAction: OrganizeReviewActionPresentation,
        resultingCursor: Int
    ) async {
        let assetID = presentationAction.assetID
        guard var session = reviewSessionsByID[sessionID],
              let sourceRevision = sourceRevisionByAssetID[assetID] else { return }
        do {
            session.cursor = resultingCursor
            session.status = .active
            session.updatedAt = Date()
            let restoredChoice = presentationAction.previousChoice
            let stateMutation: ReviewStatePersistenceMutation
            if let restoredChoice, let state = reviewDecision(restoredChoice).reviewState {
                let record = AssetReviewStateRecord(
                    assetID: assetID,
                    sourceRevision: sourceRevision,
                    state: state,
                    recommendationKind: session.recommendationKind,
                    updatedAt: Date()
                )
                stateMutation = .upsert(record)
            } else {
                stateMutation = .remove(assetID: assetID)
            }
            let queueMutation = reviewQueueMutation(
                assetID: assetID,
                shouldQueue: presentationAction.wasQueued,
                session: session
            )
            let snapshot = try await worker.persistReviewMutation(
                session: session,
                action: .remove(presentationAction.id),
                state: stateMutation,
                queue: queueMutation,
                ledger: ledger
            )
            replaceReviewPersistenceState(with: snapshot)
            PresentationStorageRetirement.retire(consume snapshot)
        } catch {
            viewModel?.userMessage = OrganizeUserMessage(
                title: "Undo Not Saved",
                message: "The restored review state could not be saved: \(error.localizedDescription)"
            )
        }
    }

    private func reviewQueueMutation(
        assetID: String,
        choice: OrganizeReviewChoice,
        session: ReviewSession
    ) -> ReviewQueuePersistenceMutation {
        reviewQueueMutation(
            assetID: assetID,
            shouldQueue: choice == .queueForRecentlyDeleted,
            session: session
        )
    }

    private func reviewQueueMutation(
        assetID: String,
        shouldQueue: Bool,
        session: ReviewSession
    ) -> ReviewQueuePersistenceMutation {
        guard shouldQueue,
              let sourceRevision = sourceRevisionByAssetID[assetID] else {
            return .remove(assetID: assetID)
        }
        let existing = queueByAssetID[assetID]
        let item = DeletionQueueItem(
            assetID: assetID,
            sourceRevision: sourceRevision,
            recommendationKind: session.recommendationKind,
            queuedAt: existing?.queuedAt ?? Date(),
            protectionOverride: existing?.protectionOverride ?? protectedAssetIDs.contains(assetID),
            reviewSessionID: session.id
        )
        return .upsert(item)
    }

    private func moveToRecentlyDeleted(
        assetIDs: [String],
        intentValidator: @escaping OrganizeDeletionIntentValidator
    ) async throws -> OrganizeMoveOutcome {
        let retirement = DeletionOperationRetirementStorage(requestedAssetIDs: assetIDs)
        do {
            let outcome = try await performMoveToRecentlyDeleted(
                retirement: retirement,
                intentValidator: intentValidator
            )
            PresentationStorageRetirement.retire(consume retirement)
            return outcome
        } catch {
            PresentationStorageRetirement.retire(consume retirement)
            throw error
        }
    }

    private func performMoveToRecentlyDeleted(
        retirement: DeletionOperationRetirementStorage,
        intentValidator: @escaping OrganizeDeletionIntentValidator
    ) async throws -> OrganizeMoveOutcome {
        let assetIDs = retirement.requestedAssetIDs
        await refreshLibraryHandler?()
        retirement.requestQueue = queueByAssetID
        let requestPlan = try await worker.deletionRequestPlan(
            assetIDs: assetIDs,
            queueByAssetID: retirement.requestQueue ?? [:]
        )
        retirement.requestPlan = requestPlan
        let validation = await revalidator.revalidate(requestPlan.requests)
        retirement.validation = validation
        retirement.validationProtectedAssetIDs = await worker.presentedProtectedAssetIDs()
        retirement.validationAnalysis = analysisByAssetID
        let validationPlan = try await worker.deletionValidationPlan(
            requestedAssetIDs: assetIDs,
            requestPlan: requestPlan,
            validation: validation,
            protectedAssetIDs: retirement.validationProtectedAssetIDs ?? [],
            analysisByAssetID: retirement.validationAnalysis ?? [:]
        )
        retirement.validationPlan = validationPlan
        if !validationPlan.requiringReviewAssetIDs.isEmpty {
            let replacement = try await worker.removeQueueItems(
                assetIDs: validationPlan.requiringReviewAssetIDs,
                ledger: ledger
            )
            replaceQueue(with: replacement)
            await renderNow()
            return .needsReview(
                missingAssetIDs: validationPlan.missingAssetIDs,
                changedAssetIDs: validationPlan.changedAssetIDs
            )
        }

        let currentAssets = validationPlan.currentAssets
        let requestedAt = Date()
        let batchID = UUID()
        let knownBytes = validationPlan.knownBytes
        let thumbnailByAssetID = try await worker.prepareAuditThumbnails(
            assets: currentAssets,
            batchID: batchID,
            includeNetwork: true,
            now: requestedAt,
            store: auditThumbnails
        )
        retirement.thumbnailReferences = thumbnailByAssetID
        retirement.preparationAnalysis = analysisByAssetID

        let prepared = try await worker.preparedDeletionPlan(
            currentAssets: currentAssets,
            batchID: batchID,
            requestedAt: requestedAt,
            requestPlan: requestPlan,
            thumbnailsByAssetID: thumbnailByAssetID,
            analysisByAssetID: retirement.preparationAnalysis ?? [:],
            knownBytes: knownBytes
        )
        retirement.preparedPlan = prepared
        let preparedRecords = prepared.records
        try await ledger.saveDeletionBatch(prepared.batch, items: preparedRecords)

        // Thumbnail preparation and PhotoKit's own identifier fetch may suspend.
        // Confirm both the scalar UI intent lease and exact worker-owned queue
        // membership before crossing the destructive boundary. The service invokes
        // the scalar validator once more immediately before `performChanges`.
        let intentWasCurrentBeforeQueueCheck = intentValidator()
        let queueStillMatches = intentWasCurrentBeforeQueueCheck
            ? await worker.deletionQueueExactlyMatches(assetIDs: validationPlan.currentAssetIDs)
            : false
        let intentIsCurrentAtBoundary = intentValidator()
        let foregroundIsActive = deletionForegroundValidator()
        guard queueStillMatches,
              intentIsCurrentAtBoundary,
              foregroundIsActive else {
            await worker.removeAuditThumbnails(thumbnailByAssetID, store: auditThumbnails)
            let cancelled = DeletionBatch(
                id: batchID,
                requestedAt: requestedAt,
                completedAt: Date(),
                status: .cancelled,
                itemCount: currentAssets.count,
                knownByteCount: knownBytes,
                errorMessage: intentWasCurrentBeforeQueueCheck
                    && queueStillMatches
                    && intentIsCurrentAtBoundary
                    ? "The app left the foreground before Apple Photos confirmation."
                    : "The staged queue changed before Apple Photos confirmation."
            )
            try? await ledger.saveDeletionBatch(cancelled)
            throw OrganizePhotoServiceError.cancelled
        }

        let result: PhotoLibraryDeletionResult
        do {
            let foregroundValidator = deletionForegroundValidator
            result = try await deletionService.moveToRecentlyDeleted(
                assetIDs: validationPlan.currentAssetIDs,
                foregroundValidator: {
                    foregroundValidator() && intentValidator()
                }
            )
            retirement.deletionResult = result
        } catch {
            await worker.removeAuditThumbnails(thumbnailByAssetID, store: auditThumbnails)
            let cancelled: Bool
            if let serviceError = error as? OrganizePhotoServiceError, case .cancelled = serviceError {
                cancelled = true
            } else {
                cancelled = false
            }
            let failed = DeletionBatch(
                id: batchID,
                requestedAt: requestedAt,
                completedAt: Date(),
                status: cancelled ? .cancelled : .failed,
                itemCount: currentAssets.count,
                knownByteCount: knownBytes,
                errorMessage: error.localizedDescription
            )
            try? await ledger.saveDeletionBatch(failed)
            throw error
        }

        let confirmedRecords = await worker.confirmedDeletionRecords(
            preparedRecords,
            deletedAt: result.completedAt
        )
        retirement.confirmedRecords = confirmedRecords
        let completed = DeletionBatch(
            id: batchID,
            requestedAt: requestedAt,
            completedAt: result.completedAt,
            status: .movedToRecentlyDeleted,
            itemCount: confirmedRecords.count,
            knownByteCount: knownBytes,
            errorMessage: nil
        )
        var auditWarnings: [String] = []
        var auditStatusSaved = false
        do {
            // Commit the single-row PhotoKit result first. The prepared item snapshots
            // are already durable, so this makes the audit visible in the smallest
            // possible transaction before refining their completion timestamps.
            try await ledger.saveDeletionBatch(completed)
            auditStatusSaved = true
        } catch {
            auditWarnings.append("Apple Photos completed the move, but the app could not finalize its audit record: \(error.localizedDescription)")
        }
        if auditStatusSaved {
            let replacementQueue: [String: DeletionQueueItem]
            do {
                try await ledger.saveDeletionBatch(completed, items: confirmedRecords)
            } catch {
                auditWarnings.append("The audit was saved, but some completion metadata could not be refined: \(error.localizedDescription)")
            }
            do {
                replacementQueue = try await worker.removeQueueItems(
                    assetIDs: result.assetIDs,
                    ledger: ledger
                )
            } catch {
                auditWarnings.append("The app could not finish clearing its saved queue: \(error.localizedDescription)")
                replacementQueue = await worker.discardQueueItems(assetIDs: result.assetIDs)
            }
            replaceQueue(with: replacementQueue)
        } else {
            auditWarnings.append("The durable queue was retained so the app can surface this batch again after relaunch.")
            let replacementQueue = await worker.discardQueueItems(assetIDs: result.assetIDs)
            replaceQueue(with: replacementQueue)
        }
        retirement.historyInput = DeletionHistoryStorage(
            batches: deletionBatches,
            items: deletedItems,
            itemByID: deletedItemByID
        )
        let history = await worker.addingDeletionHistory(
            batch: completed,
            records: confirmedRecords,
            batches: retirement.historyInput?.batches ?? [],
            items: retirement.historyInput?.items ?? [],
            itemByID: retirement.historyInput?.itemByID ?? [:]
        )
        retirement.historyResult = history
        replaceDeletionHistory(
            batches: history.batches,
            items: history.items,
            itemByID: history.itemByID
        )
        let presentation = await worker.deletedBatchPresentation(batch: completed, records: confirmedRecords)
        await refreshLibraryHandler?()
        await renderNow()
        return .moved(
            presentation,
            auditWarning: auditWarnings.isEmpty ? nil : auditWarnings.joined(separator: "\n")
        )
    }

    func performBackgroundCacheMaintenance() async {
        await cleanExpiredThumbnails(reportErrors: false)
    }

    private func cleanExpiredThumbnails(reportErrors: Bool) async {
        let retirement = CleanupRetirementStorage()
        do {
            let now = Date()
            let paths = try await ledger.expireDeletedItemThumbnails(asOf: now)
            retirement.paths = paths
            try await worker.cleanAuditThumbnails(
                relativePaths: paths,
                now: now,
                store: auditThumbnails
            )
            let replacementItems = try await ledger.deletedItems()
            retirement.replacementItems = replacementItems
            let replacementIndex = await worker.deletedItemIndex(replacementItems)
            retirement.replacementIndex = replacementIndex
            replaceDeletedItems(replacementItems, itemByID: replacementIndex)
            await renderNow()
            PresentationStorageRetirement.retire(consume retirement)
        } catch {
            PresentationStorageRetirement.retire(consume retirement)
            if reportErrors {
                viewModel?.userMessage = OrganizeUserMessage(
                    title: "Thumbnail Cleanup Failed",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func deletedThumbnail(recordID: UUID) async -> UIImage? {
        guard let item = deletedItemByID[recordID],
              let path = item.thumbnailRelativePath,
              item.thumbnailExpiresAt.map({ $0 > Date() }) == true else { return nil }
        return try? await auditThumbnails.loadThumbnail(relativePath: path)
    }

    private func renderNow(requiredRefreshGeneration: UInt64? = nil) async {
        guard let viewModel else { return }
        let revision = max(presentationRevision, viewModel.presentationRevision) &+ 1
        presentationRevision = revision
        let input = OrganizePresentationInput(
            revision: revision,
            authorization: authorization,
            assets: orderedAssets,
            albums: albums,
            albumIDsByAssetID: albumIDsByAssetID,
            sourceRevisionByAssetID: sourceRevisionByAssetID,
            analysisByAssetID: analysisByAssetID,
            visualAnalysisByAssetID: visualAnalysisByAssetID,
            analysisRun: analysisRun,
            reviewStateByAssetID: reviewStateByAssetID,
            queueByAssetID: queueByAssetID,
            reviewSessionsByID: reviewSessionsByID,
            protectedAlbumIDs: protectedAlbumIDs,
            protectedAssetIDs: protectedAssetIDs,
            deletionBatches: deletionBatches,
            deletedItems: deletedItems,
            // Review and selection presentation state is worker-owned and updated by
            // intent-sized gesture APIs. Never retain the ViewModel's live COW buffers
            // across this suspension point.
            activeReviewSessionOverride: nil,
            analysisOverride: viewModel.analysis,
            selectedAssetIDs: []
        )
        do {
            let snapshot = try await worker.presentation(for: input)
            guard revision == presentationRevision,
                  requiredRefreshGeneration.map({ $0 == refreshGeneration }) != false else {
                PresentationStorageRetirement.retire(consume input)
                PresentationStorageRetirement.retire(consume snapshot)
                return
            }
            viewModel.apply(snapshot: consume snapshot)
            PresentationStorageRetirement.retire(consume input)
        } catch is CancellationError {
            let shouldRetry = !Task.isCancelled
                && revision == presentationRevision
                && requiredRefreshGeneration.map({ $0 == refreshGeneration }) != false
            PresentationStorageRetirement.retire(consume input)
            // A worker-owned review/queue delta may invalidate a build without
            // starting its own whole-library render. Retry only while this request
            // still owns the coordinator generation; a newer render needs no help.
            if shouldRetry { await renderNow(requiredRefreshGeneration: requiredRefreshGeneration) }
        } catch {
            PresentationStorageRetirement.retire(consume input)
            viewModel.userMessage = OrganizeUserMessage(
                title: "Organizer Update Failed",
                message: error.localizedDescription
            )
        }
    }

    private func currentLibraryStateStorage() -> LibraryStateStorage {
        LibraryStateStorage(
            assetsByID: assetsByID,
            orderedAssets: orderedAssets,
            orderedAssetIDs: orderedAssetIDs,
            albums: albums,
            albumIDsByAssetID: albumIDsByAssetID,
            albumTitleByID: albumTitleByID,
            sourceRevisionByAssetID: sourceRevisionByAssetID,
            protectedAssetIDs: protectedAssetIDs,
            analysisByAssetID: analysisByAssetID,
            visualAnalysisByAssetID: visualAnalysisByAssetID,
            visualAnalysisAttemptByAssetID: visualAnalysisAttemptByAssetID,
            analysisRun: analysisRun,
            reviewStateByAssetID: reviewStateByAssetID,
            queueByAssetID: queueByAssetID,
            reviewSessionsByID: reviewSessionsByID,
            protectedAlbumIDs: protectedAlbumIDs,
            deletionBatches: deletionBatches,
            deletedItems: deletedItems,
            deletedItemByID: deletedItemByID
        )
    }

    private func replaceAnalysisState(
        records: [String: AssetAnalysisRecord],
        run: AnalysisRunRecord?
    ) {
        let previous = AnalysisStateStorage(records: analysisByAssetID, run: analysisRun)
        analysisByAssetID = records
        analysisRun = run
        PresentationStorageRetirement.retire(consume previous)
    }

    private func replaceQueue(with replacement: [String: DeletionQueueItem]) {
        let previous = queueByAssetID
        queueByAssetID = replacement
        PresentationStorageRetirement.retire(consume previous)
    }

    private func replaceReviewPersistenceState(
        with replacement: OrganizeReviewPersistenceSnapshot
    ) {
        let previous = ReviewPersistenceStateStorage(
            reviewStateByAssetID: reviewStateByAssetID,
            queueByAssetID: queueByAssetID,
            reviewSessionsByID: reviewSessionsByID
        )
        reviewStateByAssetID = replacement.reviewStateByAssetID
        queueByAssetID = replacement.queueByAssetID
        reviewSessionsByID = replacement.reviewSessionsByID
        PresentationStorageRetirement.retire(consume previous)
    }

    private func replaceProtectionState(
        albumIDs: Set<String>,
        assetIDs: Set<String>
    ) {
        let previous = ProtectionStateStorage(
            albumIDs: protectedAlbumIDs,
            assetIDs: protectedAssetIDs
        )
        protectedAlbumIDs = albumIDs
        protectedAssetIDs = assetIDs
        PresentationStorageRetirement.retire(consume previous)
    }

    private func replaceDeletionHistory(
        batches: [DeletionBatch],
        items: [DeletedItemRecord],
        itemByID: [UUID: DeletedItemRecord]
    ) {
        let previous = DeletionHistoryStorage(
            batches: deletionBatches,
            items: deletedItems,
            itemByID: deletedItemByID
        )
        deletionBatches = batches
        deletedItems = items
        deletedItemByID = itemByID
        PresentationStorageRetirement.retire(consume previous)
    }

    private func replaceDeletedItems(
        _ replacement: [DeletedItemRecord],
        itemByID replacementIndex: [UUID: DeletedItemRecord]
    ) {
        let previous = DeletedItemStorage(items: deletedItems, itemByID: deletedItemByID)
        deletedItems = replacement
        deletedItemByID = replacementIndex
        PresentationStorageRetirement.retire(consume previous)
    }

    private func replaceAnalysisTask(with replacement: Task<Void, Never>?) {
        let previous = analysisTask
        analysisTask = replacement
        if let previous {
            PresentationStorageRetirement.retire(consume previous)
        }
    }

    private func reviewDecision(_ choice: OrganizeReviewChoice) -> ReviewDecision {
        switch choice {
        case .keep: .keep
        case .queueForRecentlyDeleted: .moveToRecentlyDeleted
        case .later: .later
        }
    }

}
