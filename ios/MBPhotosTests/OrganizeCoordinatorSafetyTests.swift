@testable import MBPhotos
import AVFoundation
import UIKit
import XCTest

@MainActor
final class OrganizeCoordinatorSafetyTests: XCTestCase {
    func testEnabledAutoAnalyzeStartsLocalOnlyAnalysisAfterRefresh() async throws {
        let source = asset(id: "automatic-analysis")
        let ledger = try makeLedger()
        let analyzer = RecordingCoordinatorAnalyzer(byteCount: 1_024)
        let suiteName = "OrganizeCoordinatorSafetyTests.autoAnalyze.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = OrganizeViewModel(
            authorization: .authorized,
            settingsDefaults: defaults
        )
        let coordinator = OrganizeCoordinator(
            ledger: ledger,
            catalog: PhotoKitCatalog(),
            previews: StubPreviewProvider(),
            analyzer: analyzer,
            revalidator: StubRevalidator(currentAssets: [source.id: source]),
            deletionService: StubDeletionService(behavior: .succeed),
            auditThumbnails: StubAuditThumbnailStore()
        )
        coordinator.install(on: model, refreshLibrary: {})
        await coordinator.refresh(authorization: .authorized, assets: [source], albums: [])

        coordinator.reconcileAutomaticAnalysis(isEnabled: true)
        for _ in 0..<100 where model.analysis.phase != .complete {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(model.analysis.phase, .complete)
        let includeNetworkValues = await analyzer.includeNetworkValues()
        let run = try await ledger.latestAnalysisRun()
        XCTAssertEqual(includeNetworkValues, [false])
        XCTAssertEqual(run?.origin, .automaticMaintenance)
    }

    func testDurableAnalysisResultUpdatesStorageBreakdownBeforeRunCompletes() async throws {
        let first = asset(id: "first-incremental")
        let second = asset(id: "second-blocked")
        let ledger = try makeLedger()
        let analyzer = FirstThenBlockingCoordinatorAnalyzer(byteCount: 2_048)
        let model = OrganizeViewModel(authorization: .authorized)
        let coordinator = OrganizeCoordinator(
            ledger: ledger,
            catalog: PhotoKitCatalog(),
            previews: StubPreviewProvider(),
            analyzer: analyzer,
            revalidator: StubRevalidator(currentAssets: [first.id: first, second.id: second]),
            deletionService: StubDeletionService(behavior: .succeed),
            auditThumbnails: StubAuditThumbnailStore()
        )
        coordinator.install(on: model, refreshLibrary: {})
        await coordinator.refresh(authorization: .authorized, assets: [first, second], albums: [])

        let analysis = Task { await model.startAnalysis(includeICloudItems: false) }
        await analyzer.waitUntilSecondRequestStarts()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(model.analysis.phase, .running)
        XCTAssertEqual(model.analysis.processedAssetCount, 1)
        XCTAssertEqual(model.analysis.completedAssetCount, 1)
        XCTAssertEqual(model.totalKnownBytes, 2_048)
        XCTAssertEqual(model.analyzedItemCount, 1)
        let photos = model.primaryBreakdown.first { $0.id == "photos" }
        XCTAssertEqual(photos?.knownBytes, 2_048)
        XCTAssertEqual(photos?.processedAssetCount, 1)
        XCTAssertEqual(photos?.analyzedAssetCount, 1)
        XCTAssertEqual(photos?.pendingAssetCount, 1)

        await analyzer.releaseSecondRequest()
        await analysis.value

        XCTAssertEqual(model.analysis.phase, .complete)
        XCTAssertEqual(model.totalKnownBytes, 4_096)
        let completedPhotos = model.primaryBreakdown.first { $0.id == "photos" }
        XCTAssertEqual(completedPhotos?.knownBytes, 4_096)
        XCTAssertEqual(completedPhotos?.processedAssetCount, 2)
        XCTAssertEqual(completedPhotos?.analyzedAssetCount, 2)
        XCTAssertEqual(completedPhotos?.pendingAssetCount, 0)
    }

    func testForegroundLibraryRefreshDoesNotDisconnectLiveAnalysisProgress() async throws {
        let first = asset(id: "foreground-refresh-first")
        let second = asset(id: "foreground-refresh-second")
        let ledger = try makeLedger()
        let analyzer = FirstThenBlockingCoordinatorAnalyzer(byteCount: 4_096)
        let model = OrganizeViewModel(authorization: .authorized)
        var deferredRefreshCount = 0
        let coordinator = OrganizeCoordinator(
            ledger: ledger,
            catalog: PhotoKitCatalog(),
            previews: StubPreviewProvider(),
            analyzer: analyzer,
            revalidator: StubRevalidator(currentAssets: [first.id: first, second.id: second]),
            deletionService: StubDeletionService(behavior: .succeed),
            auditThumbnails: StubAuditThumbnailStore()
        )
        coordinator.install(on: model) {
            deferredRefreshCount += 1
        }
        await coordinator.refresh(authorization: .authorized, assets: [first, second], albums: [])

        let analysis = Task { await model.startAnalysis(includeICloudItems: false) }
        await analyzer.waitUntilSecondRequestStarts()

        // Becoming active asks for a forced library refresh. The same authorized
        // snapshot must be deferred rather than fencing off the running UI stream.
        await coordinator.refresh(authorization: .authorized, assets: [first, second], albums: [])
        XCTAssertEqual(deferredRefreshCount, 0)

        await analyzer.releaseSecondRequest()
        await analysis.value

        XCTAssertEqual(model.analysis.phase, .complete)
        XCTAssertEqual(model.analysis.processedAssetCount, 2)
        XCTAssertEqual(model.totalKnownBytes, 8_192)
        XCTAssertEqual(model.analyzedItemCount, 2)
        let photos = model.primaryBreakdown.first { $0.id == "photos" }
        XCTAssertEqual(photos?.knownBytes, 8_192)
        XCTAssertEqual(photos?.processedAssetCount, 2)
        XCTAssertEqual(photos?.analyzedAssetCount, 2)
        XCTAssertEqual(deferredRefreshCount, 1)
    }

    func testPauseCancelsPendingThrottledRunningPublication() async throws {
        let source = asset(id: "pause-progress")
        let ledger = try makeLedger()
        let analyzer = PauseBlockingAnalyzer()
        let model = OrganizeViewModel(authorization: .authorized)
        let coordinator = OrganizeCoordinator(
            ledger: ledger,
            catalog: PhotoKitCatalog(),
            previews: StubPreviewProvider(),
            analyzer: analyzer,
            revalidator: StubRevalidator(currentAssets: [source.id: source]),
            deletionService: StubDeletionService(behavior: .succeed),
            auditThumbnails: StubAuditThumbnailStore()
        )
        coordinator.install(on: model, refreshLibrary: {})
        await coordinator.refresh(authorization: .authorized, assets: [source], albums: [])

        let analysis = Task { await model.startAnalysis(includeICloudItems: false) }
        await analyzer.waitUntilStarted()
        coordinator.pauseAnalysis()

        try await Task.sleep(for: .milliseconds(175))
        XCTAssertEqual(model.analysis.phase, .paused)
        XCTAssertEqual(model.analysis.statusText, "Analysis paused. Resume when the app is active.")

        await analyzer.release()
        await analysis.value
        XCTAssertEqual(model.analysis.phase, .paused)
    }

    func testExpiredOlderContinuedRunCannotCheckpointCurrentAnalysis() async throws {
        let source = asset(id: "newer-active-run")
        let ledger = try makeLedger()
        let analyzer = PauseBlockingAnalyzer()
        let model = OrganizeViewModel(authorization: .authorized)
        let coordinator = OrganizeCoordinator(
            ledger: ledger,
            catalog: PhotoKitCatalog(),
            previews: StubPreviewProvider(),
            analyzer: analyzer,
            revalidator: StubRevalidator(currentAssets: [source.id: source]),
            deletionService: StubDeletionService(behavior: .succeed),
            auditThumbnails: StubAuditThumbnailStore()
        )
        coordinator.install(on: model, refreshLibrary: {})
        await coordinator.refresh(authorization: .authorized, assets: [source], albums: [])

        let analysis = Task { await model.startAnalysis(includeICloudItems: false) }
        await analyzer.waitUntilStarted()
        let staleCheckpointReturned = expectation(description: "stale checkpoint is a no-op")
        let staleCheckpoint = Task {
            await coordinator.checkpointAnalysisForBackground(runID: UUID())
            staleCheckpointReturned.fulfill()
        }
        await fulfillment(of: [staleCheckpointReturned], timeout: 0.5)
        await staleCheckpoint.value

        await analyzer.release()
        await analysis.value
    }

    func testOnlyFinalActionInvokesOneDeletionBatchAndCreatesAudit() async throws {
        let source = asset(id: "photo")
        let ledger = try makeLedger()
        let revalidator = StubRevalidator(currentAssets: [source.id: source])
        let deletion = StubDeletionService(behavior: .succeed)
        let thumbnails = StubAuditThumbnailStore()
        let model = OrganizeViewModel(authorization: .authorized)
        let coordinator = OrganizeCoordinator(
            ledger: ledger,
            catalog: PhotoKitCatalog(),
            previews: StubPreviewProvider(),
            analyzer: StubAnalyzer(),
            revalidator: revalidator,
            deletionService: deletion,
            auditThumbnails: thumbnails,
            deletionForegroundValidator: { true }
        )
        coordinator.install(on: model, refreshLibrary: {})
        await coordinator.refresh(authorization: .authorized, assets: [source], albums: [])

        let protected = await model.queueAssets(
            [source.id],
            recommendationKind: .screenshots
        )
        XCTAssertTrue(protected.isEmpty)
        try await waitForQueueCount(1, ledger: ledger)
        let callsBeforeFinal = await deletion.callCount()
        let auditBeforeFinal = try await ledger.deletedItems()
        XCTAssertEqual(callsBeforeFinal, 0)
        XCTAssertTrue(auditBeforeFinal.isEmpty)

        await model.moveQueueToRecentlyDeleted()

        let successCallCount = await deletion.callCount()
        let submittedIDs = await deletion.lastAssetIDs()
        let remainingQueue = try await ledger.recentlyDeletedQueue()
        XCTAssertEqual(successCallCount, 1)
        XCTAssertEqual(submittedIDs, [source.id])
        XCTAssertTrue(remainingQueue.isEmpty)
        let audit = try await ledger.deletedItems()
        XCTAssertEqual(audit.count, 1)
        XCTAssertEqual(audit.first?.sourceLocalIdentifier, source.id)
        XCTAssertEqual(audit.first?.recommendationKind, .screenshots)
        XCTAssertEqual(audit.first?.result, .movedToRecentlyDeleted)
        let successfulBatches = try await ledger.deletionBatches()
        XCTAssertEqual(successfulBatches.first?.status, .movedToRecentlyDeleted)
    }

    func testPhotoKitCancellationRetainsQueueAndHidesPreparedAudit() async throws {
        let source = asset(id: "cancelled")
        let ledger = try makeLedger()
        let deletion = StubDeletionService(behavior: .cancel)
        let thumbnails = StubAuditThumbnailStore()
        let model = OrganizeViewModel(authorization: .authorized)
        let coordinator = OrganizeCoordinator(
            ledger: ledger,
            catalog: PhotoKitCatalog(),
            previews: StubPreviewProvider(),
            analyzer: StubAnalyzer(),
            revalidator: StubRevalidator(currentAssets: [source.id: source]),
            deletionService: deletion,
            auditThumbnails: thumbnails,
            deletionForegroundValidator: { true }
        )
        coordinator.install(on: model, refreshLibrary: {})
        await coordinator.refresh(authorization: .authorized, assets: [source], albums: [])
        let protected = await model.queueAssets([source.id])
        XCTAssertTrue(protected.isEmpty)
        try await waitForQueueCount(1, ledger: ledger)

        await model.moveQueueToRecentlyDeleted()

        let cancellationCallCount = await deletion.callCount()
        let retainedQueue = try await ledger.recentlyDeletedQueue()
        let hiddenAudit = try await ledger.deletedItems()
        let cancelledBatches = try await ledger.deletionBatches()
        XCTAssertEqual(cancellationCallCount, 1)
        XCTAssertEqual(model.queuedAssetIDs, [source.id])
        XCTAssertEqual(retainedQueue.map(\.assetID), [source.id])
        XCTAssertTrue(hiddenAudit.isEmpty)
        XCTAssertEqual(cancelledBatches.first?.status, .cancelled)
        XCTAssertEqual(thumbnails.removedPaths.count, 1)
        XCTAssertEqual(model.userMessage?.title, "Nothing Was Moved")
    }

    func testLeavingForegroundDuringDeletionPreparationCancelsBeforeChangeRequest() async throws {
        let source = asset(id: "backgrounded-before-confirmation")
        let ledger = try makeLedger()
        let foreground = DeletionForegroundProbe()
        let deletion = ForegroundRevalidatingDeletionService()
        let thumbnails = StubAuditThumbnailStore()
        let model = OrganizeViewModel(authorization: .authorized)
        let coordinator = OrganizeCoordinator(
            ledger: ledger,
            catalog: PhotoKitCatalog(),
            previews: StubPreviewProvider(),
            analyzer: StubAnalyzer(),
            revalidator: StubRevalidator(currentAssets: [source.id: source]),
            deletionService: deletion,
            auditThumbnails: thumbnails,
            deletionForegroundValidator: { foreground.isActive }
        )
        coordinator.install(on: model, refreshLibrary: {})
        await coordinator.refresh(authorization: .authorized, assets: [source], albums: [])
        let protected = await model.queueAssets([source.id])
        XCTAssertTrue(protected.isEmpty)
        try await waitForQueueCount(1, ledger: ledger)

        let move = Task { await model.moveQueueToRecentlyDeleted() }
        await deletion.waitUntilPrepared()
        foreground.isActive = false
        await deletion.releasePreparation()
        await move.value

        let retainedQueue = try await ledger.recentlyDeletedQueue()
        let batches = try await ledger.deletionBatches()
        let didPerformChangeRequest = await deletion.didPerformChangeRequest()
        XCTAssertFalse(didPerformChangeRequest)
        XCTAssertEqual(retainedQueue.map(\.assetID), [source.id])
        XCTAssertEqual(model.queuedAssetIDs, [source.id])
        XCTAssertEqual(batches.first?.status, .cancelled)
        XCTAssertEqual(thumbnails.removedPaths.count, 1)
        XCTAssertEqual(model.userMessage?.title, "Nothing Was Moved")
    }

    func testQueueMutationsDuringBlockedDeletionInvalidatePhotoKitBoundary() async throws {
        let keepAsset = asset(id: "keep-during-delete")
        let removeAsset = asset(id: "remove-during-delete")
        let ledger = try makeLedger()
        let deletion = ForegroundRevalidatingDeletionService()
        let thumbnails = StubAuditThumbnailStore()
        let model = OrganizeViewModel(authorization: .authorized)
        let coordinator = OrganizeCoordinator(
            ledger: ledger,
            catalog: PhotoKitCatalog(),
            previews: StubPreviewProvider(),
            analyzer: StubAnalyzer(),
            revalidator: StubRevalidator(currentAssets: [
                keepAsset.id: keepAsset,
                removeAsset.id: removeAsset
            ]),
            deletionService: deletion,
            auditThumbnails: thumbnails,
            deletionForegroundValidator: { true }
        )
        coordinator.install(on: model, refreshLibrary: {})
        await coordinator.refresh(
            authorization: .authorized,
            assets: [keepAsset, removeAsset],
            albums: []
        )
        let protected = await model.queueAssets([keepAsset.id, removeAsset.id])
        XCTAssertTrue(protected.isEmpty)
        try await waitForQueueCount(2, ledger: ledger)

        let move = Task { await model.moveQueueToRecentlyDeleted() }
        await deletion.waitUntilPrepared()
        XCTAssertTrue(model.isMovingToRecentlyDeleted)

        // These hidden/programmatic calls are rejected while the move owns the
        // queue, but each still revokes the scalar lease captured by the batch.
        await model.keepQueuedAsset(keepAsset.id)
        await model.removeFromQueue(removeAsset.id)
        XCTAssertEqual(model.queuedAssetIDs, [keepAsset.id, removeAsset.id])

        await deletion.releasePreparation()
        await move.value

        let retainedQueue = try await ledger.recentlyDeletedQueue()
        let hiddenAudit = try await ledger.deletedItems()
        let batches = try await ledger.deletionBatches()
        let didPerformChangeRequest = await deletion.didPerformChangeRequest()
        XCTAssertFalse(didPerformChangeRequest)
        XCTAssertEqual(Set(retainedQueue.map(\.assetID)), [keepAsset.id, removeAsset.id])
        XCTAssertEqual(model.queuedAssetIDs, [keepAsset.id, removeAsset.id])
        XCTAssertTrue(hiddenAudit.isEmpty)
        XCTAssertEqual(batches.first?.status, .cancelled)
        XCTAssertEqual(thumbnails.removedPaths.count, 2)
        XCTAssertEqual(model.userMessage?.title, "Nothing Was Moved")
    }

    func testOrganizerICloudThumbnailFallbackUsesBoundedSingleFlightPipeline() async throws {
        let client = LocalMissNetworkThumbnailClient()
        let decoder = TestThumbnailDecoder()
        let pipeline = PhotoThumbnailPipeline(
            client: client,
            decoder: decoder,
            maximumConcurrentRequests: 1,
            maximumPendingRequests: 4,
            maximumEntryCount: 8,
            maximumByteCount: 1_024
        )
        let catalog = PhotoKitCatalog(thumbnailPipeline: pipeline)
        let model = OrganizeViewModel(authorization: .authorized)
        let coordinator = OrganizeCoordinator(
            ledger: try makeLedger(),
            catalog: catalog,
            previews: StubPreviewProvider(),
            analyzer: StubAnalyzer(),
            revalidator: StubRevalidator(currentAssets: [:]),
            deletionService: StubDeletionService(behavior: .succeed),
            auditThumbnails: StubAuditThumbnailStore()
        )
        coordinator.install(on: model, refreshLibrary: {})

        let requests = (0..<12).map { _ in
            Task { await model.thumbnail(assetID: "icloud-grid-cell", size: CGSize(width: 60, height: 60)) }
        }
        var loadedCount = 0
        for request in requests {
            if await request.value != nil { loadedCount += 1 }
        }

        let keys = await client.requestedKeys()
        let decodeCount = await decoder.callCount()
        let state = await pipeline.workState()
        XCTAssertEqual(loadedCount, requests.count)
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys.map(\.allowsNetworkAccess), [false, true])
        XCTAssertEqual(decodeCount, 1)
        XCTAssertLessThanOrEqual(state.admittedDataRequestCount, 2)
        XCTAssertLessThanOrEqual(state.admittedDecodedRequestCount, 2)
    }

    func testNewFavoriteStatusRequiresFreshOverrideWithoutDeletion() async throws {
        let queuedVersion = asset(id: "new-favorite", isFavorite: false)
        let currentFavorite = asset(id: "new-favorite", isFavorite: true)
        XCTAssertEqual(queuedVersion.sourceRevision, currentFavorite.sourceRevision)

        let ledger = try makeLedger()
        let deletion = StubDeletionService(behavior: .succeed)
        let model = OrganizeViewModel(authorization: .authorized)
        let coordinator = OrganizeCoordinator(
            ledger: ledger,
            catalog: PhotoKitCatalog(),
            previews: StubPreviewProvider(),
            analyzer: StubAnalyzer(),
            revalidator: StubRevalidator(currentAssets: [currentFavorite.id: currentFavorite]),
            deletionService: deletion,
            auditThumbnails: StubAuditThumbnailStore()
        )
        coordinator.install(on: model, refreshLibrary: {})
        await coordinator.refresh(authorization: .authorized, assets: [queuedVersion], albums: [])
        let protected = await model.queueAssets([queuedVersion.id])
        XCTAssertTrue(protected.isEmpty)
        try await waitForQueueCount(1, ledger: ledger)

        await model.moveQueueToRecentlyDeleted()

        let protectedCallCount = await deletion.callCount()
        let queueAfterProtectionChange = try await ledger.recentlyDeletedQueue()
        let auditAfterProtectionChange = try await ledger.deletedItems()
        XCTAssertEqual(protectedCallCount, 0)
        XCTAssertTrue(model.queuedAssetIDs.isEmpty)
        XCTAssertTrue(queueAfterProtectionChange.isEmpty)
        XCTAssertTrue(auditAfterProtectionChange.isEmpty)
        XCTAssertEqual(model.userMessage?.title, "Review Queue Again")
    }

    func testThumbnailPreflightFailureRetainsQueueWithoutCallingDeletion() async throws {
        let source = asset(id: "thumbnail-failure")
        let ledger = try makeLedger()
        let deletion = StubDeletionService(behavior: .succeed)
        let model = OrganizeViewModel(authorization: .authorized)
        let coordinator = OrganizeCoordinator(
            ledger: ledger,
            catalog: PhotoKitCatalog(),
            previews: StubPreviewProvider(),
            analyzer: StubAnalyzer(),
            revalidator: StubRevalidator(currentAssets: [source.id: source]),
            deletionService: deletion,
            auditThumbnails: StubAuditThumbnailStore(shouldFailPreparation: true)
        )
        coordinator.install(on: model, refreshLibrary: {})
        await coordinator.refresh(authorization: .authorized, assets: [source], albums: [])
        let protected = await model.queueAssets([source.id])
        XCTAssertTrue(protected.isEmpty)
        try await waitForQueueCount(1, ledger: ledger)

        await model.moveQueueToRecentlyDeleted()

        let callCount = await deletion.callCount()
        let retainedQueue = try await ledger.recentlyDeletedQueue()
        let audit = try await ledger.deletedItems()
        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(retainedQueue.map(\.assetID), [source.id])
        XCTAssertTrue(audit.isEmpty)
        XCTAssertEqual(model.userMessage?.title, "Nothing Was Moved")
    }

    func testUndoAfterRelaunchRestoresExactPreDecisionQueueState() async throws {
        let first = asset(id: "first", subtypes: [.screenshot])
        let second = asset(id: "second", subtypes: [.screenshot])
        let allAssets = [first, second]
        let currentAssets = Dictionary(uniqueKeysWithValues: allAssets.map { ($0.id, $0) })
        let ledger = try makeLedger()

        let firstModel = OrganizeViewModel(authorization: .authorized)
        let firstCoordinator = OrganizeCoordinator(
            ledger: ledger,
            catalog: PhotoKitCatalog(),
            previews: StubPreviewProvider(),
            analyzer: StubAnalyzer(),
            revalidator: StubRevalidator(currentAssets: currentAssets),
            deletionService: StubDeletionService(behavior: .succeed),
            auditThumbnails: StubAuditThumbnailStore()
        )
        firstCoordinator.install(on: firstModel, refreshLibrary: {})
        await firstCoordinator.refresh(authorization: .authorized, assets: allAssets, albums: [])
        let recommendation = firstModel.reviewRecommendations.first { $0.kind == .screenshots }!
        let firstReviewedID = recommendation.assetIDs[0]
        let protected = await firstModel.queueAssets([firstReviewedID])
        XCTAssertTrue(protected.isEmpty)
        try await waitForQueueCount(1, ledger: ledger)
        await firstModel.beginReview(recommendation)
        let accepted = await firstModel.applyReviewChoice(.later)
        XCTAssertTrue(accepted)
        try await waitForReviewAction(ledger: ledger)

        let relaunchedModel = OrganizeViewModel(authorization: .authorized)
        let relaunchedCoordinator = OrganizeCoordinator(
            ledger: ledger,
            catalog: PhotoKitCatalog(),
            previews: StubPreviewProvider(),
            analyzer: StubAnalyzer(),
            revalidator: StubRevalidator(currentAssets: currentAssets),
            deletionService: StubDeletionService(behavior: .succeed),
            auditThumbnails: StubAuditThumbnailStore()
        )
        relaunchedCoordinator.install(on: relaunchedModel, refreshLibrary: {})
        await relaunchedCoordinator.refresh(authorization: .authorized, assets: allAssets, albums: [])

        XCTAssertEqual(relaunchedModel.activeReviewSession?.currentIndex, 1)
        await relaunchedModel.undoLastReviewChoice()
        XCTAssertTrue(relaunchedModel.queuedAssetIDs.contains(firstReviewedID))
        XCTAssertEqual(relaunchedModel.activeReviewSession?.currentIndex, 0)
    }

    private func makeLedger() throws -> SQLiteLedger {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        return try SQLiteLedger(url: directory.appending(path: "ledger.sqlite"))
    }

    private func waitForQueueCount(_ expected: Int, ledger: SQLiteLedger) async throws {
        for _ in 0..<100 {
            if try await ledger.recentlyDeletedQueue().count == expected { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for queue persistence")
    }

    private func waitForReviewAction(ledger: SQLiteLedger) async throws {
        for _ in 0..<100 {
            if try await ledger.reviewSessions().contains(where: { !$0.actions.isEmpty }) { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for review-session persistence")
    }

    private func asset(
        id: String,
        subtypes: Set<AssetMediaSubtype> = [],
        isFavorite: Bool = false
    ) -> PhotoAsset {
        PhotoAsset(
            id: id,
            mediaKind: .photo,
            mediaSubtypes: subtypes,
            creationDate: Date(timeIntervalSince1970: 1_000),
            modificationDate: nil,
            pixelWidth: 1_600,
            pixelHeight: 1_200,
            durationMilliseconds: nil,
            location: nil,
            isFavorite: isFavorite,
            isEdited: false,
            resources: [
                PhotoResourceDescriptor(
                    id: "\(id)-resource",
                    kind: .photo,
                    originalFilename: "\(id).heic",
                    uniformTypeIdentifier: "public.heic"
                )
            ]
        )
    }
}

private actor StubRevalidator: PhotoAssetRevalidating {
    let currentAssets: [String: PhotoAsset]

    init(currentAssets: [String: PhotoAsset]) {
        self.currentAssets = currentAssets
    }

    func revalidate(_ requests: [PhotoAssetRevalidationRequest]) async -> [PhotoAssetRevalidationResult] {
        requests.map { request in
            guard let asset = currentAssets[request.assetID] else {
                return PhotoAssetRevalidationResult(request: request, status: .missing, currentAsset: nil)
            }
            return PhotoAssetRevalidationResult(
                request: request,
                status: asset.sourceRevision == request.expectedSourceRevision ? .unchanged : .changed,
                currentAsset: asset
            )
        }
    }
}

private actor StubDeletionService: PhotoLibraryDeleting {
    enum Behavior: Sendable {
        case succeed
        case cancel
    }

    let behavior: Behavior
    private var calls: [[String]] = []

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func moveToRecentlyDeleted(
        assetIDs: [String],
        foregroundValidator: @escaping PhotoLibraryDeletionForegroundValidator
    ) async throws -> PhotoLibraryDeletionResult {
        calls.append(assetIDs)
        guard await foregroundValidator() else { throw OrganizePhotoServiceError.cancelled }
        if behavior == .cancel { throw OrganizePhotoServiceError.cancelled }
        return PhotoLibraryDeletionResult(
            assetIDs: assetIDs,
            completedAt: Date(timeIntervalSince1970: 2_000)
        )
    }

    func callCount() -> Int { calls.count }
    func lastAssetIDs() -> [String]? { calls.last }
}

@MainActor
private final class DeletionForegroundProbe {
    var isActive = true
}

private actor ForegroundRevalidatingDeletionService: PhotoLibraryDeleting {
    private var isPrepared = false
    private var didPerform = false
    private var preparedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func moveToRecentlyDeleted(
        assetIDs: [String],
        foregroundValidator: @escaping PhotoLibraryDeletionForegroundValidator
    ) async throws -> PhotoLibraryDeletionResult {
        isPrepared = true
        for waiter in preparedWaiters { waiter.resume() }
        preparedWaiters.removeAll()
        await withCheckedContinuation { releaseWaiter = $0 }
        guard await foregroundValidator() else { throw OrganizePhotoServiceError.cancelled }
        didPerform = true
        return PhotoLibraryDeletionResult(
            assetIDs: assetIDs,
            completedAt: Date(timeIntervalSince1970: 2_000)
        )
    }

    func waitUntilPrepared() async {
        if isPrepared { return }
        await withCheckedContinuation { preparedWaiters.append($0) }
    }

    func releasePreparation() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func didPerformChangeRequest() -> Bool { didPerform }
}

private actor LocalMissNetworkThumbnailClient: PhotoThumbnailRequesting {
    private var keys: [PhotoThumbnailKey] = []

    func thumbnailData(for key: PhotoThumbnailKey) async -> Data? {
        keys.append(key)
        try? await Task.sleep(for: .milliseconds(25))
        return key.allowsNetworkAccess ? Data("network-thumbnail".utf8) : nil
    }

    func requestedKeys() -> [PhotoThumbnailKey] { keys }
}

private actor TestThumbnailDecoder: PhotoThumbnailDecoding {
    private var calls = 0

    func decode(
        data: Data,
        key: PhotoThumbnailKey,
        scale: Double
    ) async -> DecodedThumbnailImage? {
        calls += 1
        return DecodedThumbnailImage(UIImage(), estimatedByteCount: 64)
    }

    func callCount() -> Int { calls }
}

private actor StubAnalyzer: AssetResourceAnalyzing {
    func analyze(
        asset: PhotoAsset,
        includeNetwork: Bool,
        progress: @escaping @Sendable (AssetAnalysisProgress) -> Void
    ) async throws -> AssetFingerprint {
        throw StubCoordinatorError.unused
    }
}

private actor RecordingCoordinatorAnalyzer: AssetResourceAnalyzing {
    private let byteCount: Int64
    private var networkValues: [Bool] = []

    init(byteCount: Int64) {
        self.byteCount = byteCount
    }

    func analyze(
        asset: PhotoAsset,
        includeNetwork: Bool,
        progress: @escaping @Sendable (AssetAnalysisProgress) -> Void
    ) async throws -> AssetFingerprint {
        networkValues.append(includeNetwork)
        return AssetFingerprint(
            assetID: asset.id,
            sourceRevision: asset.analysisRevision,
            resources: [
                ResourceFingerprint(
                    kind: .photo,
                    byteCount: byteCount,
                    sha256: String(repeating: "b", count: 64)
                )
            ],
            analyzedAt: Date()
        )
    }

    func includeNetworkValues() -> [Bool] { networkValues }
}

private actor FirstThenBlockingCoordinatorAnalyzer: AssetResourceAnalyzing {
    private let byteCount: Int64
    private var requestCount = 0
    private var secondRequestStarted = false
    private var secondRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init(byteCount: Int64) {
        self.byteCount = byteCount
    }

    func analyze(
        asset: PhotoAsset,
        includeNetwork: Bool,
        progress: @escaping @Sendable (AssetAnalysisProgress) -> Void
    ) async throws -> AssetFingerprint {
        requestCount += 1
        if requestCount == 1 {
            return fingerprint(for: asset)
        }

        secondRequestStarted = true
        for waiter in secondRequestWaiters { waiter.resume() }
        secondRequestWaiters.removeAll()
        await withCheckedContinuation { releaseWaiter = $0 }
        try Task.checkCancellation()
        return fingerprint(for: asset)
    }

    func waitUntilSecondRequestStarts() async {
        if secondRequestStarted { return }
        await withCheckedContinuation { secondRequestWaiters.append($0) }
    }

    func releaseSecondRequest() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    private func fingerprint(for asset: PhotoAsset) -> AssetFingerprint {
        AssetFingerprint(
            assetID: asset.id,
            sourceRevision: asset.sourceRevision,
            resources: [
                ResourceFingerprint(
                    kind: .photo,
                    byteCount: byteCount,
                    sha256: String(repeating: "a", count: 64)
                )
            ],
            analyzedAt: Date()
        )
    }
}

private actor PauseBlockingAnalyzer: AssetResourceAnalyzing {
    private var started = false
    private var released = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func analyze(
        asset: PhotoAsset,
        includeNetwork: Bool,
        progress: @escaping @Sendable (AssetAnalysisProgress) -> Void
    ) async throws -> AssetFingerprint {
        started = true
        for waiter in startedWaiters { waiter.resume() }
        startedWaiters.removeAll()
        if !released {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        throw CancellationError()
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters.removeAll()
    }
}

@MainActor
private final class StubPreviewProvider: PhotoPreviewProviding {
    func imagePreview(
        assetID: String,
        targetSize: CGSize,
        scale: CGFloat,
        includeNetwork: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> UIImage {
        throw StubCoordinatorError.unused
    }

    func videoPlayerItem(
        assetID: String,
        includeNetwork: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> AVPlayerItem {
        throw StubCoordinatorError.unused
    }
}

@MainActor
private final class StubAuditThumbnailStore: AuditThumbnailStoring {
    private(set) var removedPaths: [String] = []
    private let shouldFailPreparation: Bool

    init(shouldFailPreparation: Bool = false) {
        self.shouldFailPreparation = shouldFailPreparation
    }

    func prepareThumbnail(
        assetID: String,
        batchID: UUID,
        includeNetwork: Bool,
        now: Date
    ) async throws -> AuditThumbnailReference {
        if shouldFailPreparation { throw StubCoordinatorError.thumbnailFailed }
        return AuditThumbnailReference(
            relativePath: "OrganizeAuditThumbnails/\(batchID.uuidString)-\(assetID).jpg",
            expiresAt: now.addingTimeInterval(30 * 24 * 60 * 60)
        )
    }

    func loadThumbnail(relativePath: String) async throws -> UIImage? { nil }

    func removeExpired(now: Date) async throws {}

    func removeThumbnail(relativePath: String) async throws {
        removedPaths.append(relativePath)
    }
}

private enum StubCoordinatorError: Error {
    case unused
    case thumbnailFailed
}
