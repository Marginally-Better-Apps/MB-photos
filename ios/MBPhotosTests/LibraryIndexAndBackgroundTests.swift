@testable import MBPhotos
@preconcurrency import BackgroundTasks
import Foundation
@preconcurrency import UIKit
import XCTest

final class LibraryIndexAndBackgroundTests: XCTestCase {
    func testPersistentLoaderReplaysDeltaAfterTokenExpiryRebuildBeforePublishing() async throws {
        let ledger = try temporaryLedger()
        let first = FixtureFactory.asset(id: "first")
        let second = FixtureFactory.asset(id: "second")
        let rebuild = PhotoLibrarySnapshot(
            revision: 7,
            assets: [first],
            albums: [],
            changeTokenData: Data("token-1".utf8)
        )
        let delta = PhotoLibraryIndexChanges(
            upsertedAssets: [second],
            deletedAssetIDs: [],
            upsertedAlbums: [],
            deletedAlbumIDs: [],
            accessibleAssetIDs: nil,
            changeTokenData: Data("token-2".utf8)
        )
        let changes = ScriptedPhotoLibraryChangeLoader(
            results: [
                .rebuild(rebuild),
                .changes(delta),
                .changes(.unchanged(tokenData: Data("token-2".utf8)))
            ]
        )
        let loader = PersistentLibrarySnapshotLoader(store: ledger, changeLoader: changes)

        let result = try await loader.refreshedSnapshot(revision: 7, authorization: .authorized)

        XCTAssertEqual(Set(result.assets.map(\.id)), ["first", "second"])
        let callCount = await changes.callCount()
        XCTAssertEqual(callCount, 3)
    }

    func testEmptyJournalPageAdvancesTokenWithoutRehydratingIndex() async throws {
        let firstToken = Data("first-token".utf8)
        let secondToken = Data("second-token".utf8)
        let snapshot = PhotoLibrarySnapshot(
            revision: 1,
            assets: [FixtureFactory.asset(id: "cached")],
            albums: [],
            changeTokenData: firstToken
        )
        let store = CountingPhotoLibraryIndexStore(snapshot: snapshot)
        let changes = ScriptedPhotoLibraryChangeLoader(
            results: [.changes(.unchanged(tokenData: secondToken))]
        )
        let loader = PersistentLibrarySnapshotLoader(store: store, changeLoader: changes)

        let refreshed = try await loader.refreshedSnapshot(
            revision: 2,
            authorization: .authorized
        )
        let metrics = await store.metrics()

        XCTAssertEqual(refreshed.assets.map(\.id), ["cached"])
        XCTAssertEqual(refreshed.changeTokenData, secondToken)
        XCTAssertEqual(metrics.cachedReads, 1)
        XCTAssertEqual(metrics.fullDeltaApplications, 0)
        XCTAssertEqual(metrics.tokenAdvances, 1)
    }

    func testPersistentIndexAppliesInsertUpdateDeleteAndRejectsDifferentAuthorizationScope() async throws {
        let ledger = try temporaryLedger()
        let first = FixtureFactory.asset(id: "first", filename: "old.heic")
        let removed = FixtureFactory.asset(id: "removed")
        let initial = PhotoLibrarySnapshot(
            revision: 1,
            assets: [first, removed],
            albums: [PhotoAlbum(id: "album", title: "Album", parentID: nil, assetIDs: ["first", "removed"])],
            changeTokenData: Data("one".utf8)
        )
        try await ledger.replaceCachedPhotoLibrarySnapshot(initial, authorization: .authorized)

        let updated = FixtureFactory.asset(id: "first", filename: "new.heic", modified: Date())
        let inserted = FixtureFactory.asset(id: "inserted")
        let result = try await ledger.applyPhotoLibraryChanges(
            PhotoLibraryIndexChanges(
                upsertedAssets: [updated, inserted],
                deletedAssetIDs: ["removed"],
                upsertedAlbums: [
                    PhotoAlbum(
                        id: "album",
                        title: "Album",
                        parentID: nil,
                        assetIDs: ["inserted", "first", "removed"]
                    )
                ],
                deletedAlbumIDs: [],
                accessibleAssetIDs: nil,
                changeTokenData: Data("two".utf8)
            ),
            revision: 2,
            authorization: .authorized
        )

        XCTAssertEqual(Set(result.assets.map(\.id)), ["first", "inserted"])
        XCTAssertEqual(result.assets.first(where: { $0.id == "first" })?.resources.first?.originalFilename, "new.heic")
        XCTAssertEqual(result.albums.first?.assetIDs, ["inserted", "first"])
        let crossScope = try await ledger.cachedPhotoLibrarySnapshot(
            revision: 2,
            authorization: .limited,
            scopeFingerprint: "limited-scope"
        )
        XCTAssertNil(crossScope)
    }

    func testLimitedPersistentCacheRequiresMatchingScopeFingerprint() async throws {
        let ledger = try temporaryLedger()
        let snapshot = PhotoLibrarySnapshot(
            revision: 1,
            assets: [FixtureFactory.asset(id: "visible")],
            albums: [],
            changeTokenData: nil,
            authorizationScopeFingerprint: "scope-a"
        )
        try await ledger.replaceCachedPhotoLibrarySnapshot(snapshot, authorization: .limited)

        let matching = try await ledger.cachedPhotoLibrarySnapshot(
            revision: 1,
            authorization: .limited,
            scopeFingerprint: "scope-a"
        )
        let changed = try await ledger.cachedPhotoLibrarySnapshot(
            revision: 1,
            authorization: .limited,
            scopeFingerprint: "scope-b"
        )

        XCTAssertEqual(matching?.assets.map(\.id), ["visible"])
        XCTAssertNil(changed)
    }

    func testLimitedObserverRevisionReconcilesAfterScopeCacheRetag() async throws {
        let loader = RetaggingLimitedSnapshotLoader()
        let worker = LibraryIndexWorker(loader: loader)

        let cached = try await worker.loadCachedSnapshot(
            revision: 1,
            authorization: .limited
        )
        XCTAssertEqual(cached?.assets.map(\.id), ["cached"])

        let observed = try await worker.snapshot(
            revision: 2,
            authorization: .limited,
            force: false
        )
        let refreshCount = await loader.refreshCount()

        XCTAssertEqual(observed.source, .fresh)
        XCTAssertEqual(observed.snapshot.revision, 2)
        XCTAssertEqual(observed.snapshot.assets.map(\.id), ["reconciled"])
        XCTAssertEqual(refreshCount, 1)
    }

    func testFailedPersistentCacheReadCanBeRetried() async throws {
        let loader = RetryableCacheLoader()
        let worker = LibraryIndexWorker(loader: loader)

        do {
            _ = try await worker.loadCachedSnapshot(revision: 1, authorization: .authorized)
            XCTFail("Expected the first read to fail")
        } catch TestFailure.transientCacheRead {
            // Expected.
        }

        let retried = try await worker.loadCachedSnapshot(revision: 1, authorization: .authorized)
        XCTAssertEqual(retried?.assets.map(\.id), ["cached"])
        let calls = await loader.cacheCalls()
        XCTAssertEqual(calls, 2)
    }

    func testAuthorizedToLimitedAtSameRevisionNeverReturnsAuthorizedMemoryCache() async throws {
        let loader = AuthorizationAwareSnapshotLoader()
        let worker = LibraryIndexWorker(loader: loader)
        let authorized = try await worker.loadCachedSnapshot(revision: 3, authorization: .authorized)
        XCTAssertEqual(authorized?.assets.map(\.id), ["authorized-only"])

        let limited = try await worker.snapshot(
            revision: 3,
            authorization: .limited,
            force: false
        )

        XCTAssertEqual(limited.snapshot.assets.map(\.id), ["limited-only"])
    }

    func testNewestGenerationCoalescesAndOlderWaiterReceivesLatestContent() async throws {
        let loader = RevisionRecordingLoader()
        let worker = LibraryIndexWorker { revision in try await loader.load(revision: revision) }
        async let first = worker.snapshot(revision: 1, force: true)
        try await Task.sleep(for: .milliseconds(20))
        async let second = worker.snapshot(revision: 2, force: true)

        let results = try await [first, second]

        let revisions = await loader.revisions()
        XCTAssertEqual(revisions, [1, 2])
        XCTAssertTrue(results.allSatisfy { $0.snapshot.assets.first?.id == "asset-2" })
        XCTAssertEqual(Set(results.map(\.generation)), [1, 2])
    }

    func testCancellingOnlyIndexWaiterCancelsSharedRefresh() async throws {
        let loader = CancellationObservingLoader()
        let worker = LibraryIndexWorker { revision in try await loader.load(revision: revision) }
        let request = Task { try await worker.snapshot(revision: 1, force: true) }
        try await Task.sleep(for: .milliseconds(20))
        request.cancel()

        do {
            _ = try await request.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        try await Task.sleep(for: .milliseconds(20))
        let wasCancelled = await loader.wasCancelled()
        XCTAssertTrue(wasCancelled)
    }

    func testReplacementIndexWaiterRestartsBehindCancelledRefresh() async throws {
        let loader = CancelledRefreshReplacementLoader()
        let worker = LibraryIndexWorker { revision in try await loader.load(revision: revision) }
        let cancelled = Task { try await worker.snapshot(revision: 1, force: true) }
        await loader.waitUntilFirstStarted()

        cancelled.cancel()
        await loader.waitUntilCancellationObserved()
        do {
            _ = try await cancelled.value
            XCTFail("Expected the original waiter to be cancelled")
        } catch is CancellationError {
            // Expected. The underlying loader is deliberately still unwinding.
        }

        let replacement = Task { try await worker.snapshot(revision: 2, force: true) }
        var replacementWasQueued = false
        for _ in 0..<1_000 {
            if await worker.pendingWaiterCount() == 1 {
                replacementWasQueued = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(replacementWasQueued)

        await loader.releaseCancellation()
        let result = try await replacement.value
        let callCount = await loader.callCount()

        XCTAssertEqual(result.requestedRevision, 2)
        XCTAssertEqual(result.snapshot.assets.map(\.id), ["asset-2"])
        XCTAssertEqual(callCount, 2)
    }

    func testThumbnailPipelineDeduplicatesAndBoundsConcurrentRequests() async {
        let client = CountingThumbnailClient()
        let pipeline = PhotoThumbnailPipeline(
            client: client,
            maximumConcurrentRequests: 2,
            maximumEntryCount: 8,
            maximumByteCount: 1_024
        )
        let shared = PhotoThumbnailKey(
            assetID: "shared",
            revision: 1,
            pixelWidth: 100,
            pixelHeight: 100
        )
        await withTaskGroup(of: Data?.self) { group in
            for _ in 0..<4 { group.addTask { await pipeline.thumbnailData(for: shared) } }
            for index in 0..<4 {
                group.addTask {
                    await pipeline.thumbnailData(
                        for: PhotoThumbnailKey(
                            assetID: "other-\(index)",
                            revision: 1,
                            pixelWidth: 100,
                            pixelHeight: 100
                        )
                    )
                }
            }
            for await _ in group {}
        }

        let metrics = await client.metrics()
        XCTAssertEqual(metrics.callsByAssetID["shared"], 1)
        XCTAssertLessThanOrEqual(metrics.maximumActive, 2)
    }

    func testNetworkThumbnailUsesBoundedSingleFlightWithoutAliasingLocalOnlyCache() async {
        let client = CountingThumbnailClient()
        let decoder = CountingThumbnailDecoder()
        let pipeline = PhotoThumbnailPipeline(
            client: client,
            decoder: decoder,
            maximumConcurrentRequests: 2,
            maximumPendingRequests: 8,
            maximumEntryCount: 8,
            maximumByteCount: 1_024
        )
        let networkKey = PhotoThumbnailKey(
            assetID: "icloud-thumbnail",
            revision: 3,
            pixelWidth: 120,
            pixelHeight: 120,
            allowsNetworkAccess: true
        )

        await withTaskGroup(of: DecodedThumbnailImage?.self) { group in
            for _ in 0..<16 {
                group.addTask { await pipeline.decodedThumbnail(for: networkKey, scale: 2) }
            }
            for await image in group { XCTAssertNotNil(image) }
        }

        let localKey = PhotoThumbnailKey(
            assetID: networkKey.assetID,
            revision: networkKey.revision,
            pixelWidth: networkKey.pixelWidth,
            pixelHeight: networkKey.pixelHeight
        )
        let localData = await pipeline.thumbnailData(for: localKey)
        XCTAssertNotNil(localData)

        let metrics = await client.metrics()
        let decodeCount = await decoder.callCount()
        let networkRequests = metrics.requestedKeys.filter(\.allowsNetworkAccess)
        let localRequests = metrics.requestedKeys.filter { !$0.allowsNetworkAccess }
        XCTAssertEqual(networkRequests, [networkKey])
        XCTAssertEqual(localRequests, [localKey])
        XCTAssertEqual(decodeCount, 1)
        XCTAssertLessThanOrEqual(metrics.maximumActive, 2)
    }

    func testDecodedThumbnailIsSingleFlightAndCacheHitsDoNotRedecode() async {
        let client = CountingThumbnailClient()
        let decoder = CountingThumbnailDecoder()
        let pipeline = PhotoThumbnailPipeline(
            client: client,
            decoder: decoder,
            maximumConcurrentRequests: 2,
            maximumEntryCount: 8,
            maximumByteCount: 1_024
        )
        let key = PhotoThumbnailKey(
            assetID: "shared-decoded",
            revision: 1,
            pixelWidth: 100,
            pixelHeight: 100
        )

        await withTaskGroup(of: DecodedThumbnailImage?.self) { group in
            for _ in 0..<16 {
                group.addTask { await pipeline.decodedThumbnail(for: key, scale: 2) }
            }
            for await image in group { XCTAssertNotNil(image) }
        }
        for _ in 0..<16 {
            let cached = await pipeline.decodedThumbnail(for: key, scale: 2)
            XCTAssertNotNil(cached)
        }

        let decodeCount = await decoder.callCount()
        let clientMetrics = await client.metrics()
        XCTAssertEqual(decodeCount, 1)
        XCTAssertEqual(clientMetrics.callsByAssetID[key.assetID], 1)
    }

    func testDecodedThumbnailCacheAndSingleFlightIncludeDisplayScale() async {
        let client = CountingThumbnailClient()
        let decoder = ScaleRecordingThumbnailDecoder()
        let pipeline = PhotoThumbnailPipeline(
            client: client,
            decoder: decoder,
            maximumConcurrentRequests: 2,
            maximumPendingRequests: 8,
            maximumEntryCount: 8,
            maximumByteCount: 1_024
        )
        let key = PhotoThumbnailKey(
            assetID: "scale-sensitive",
            revision: 1,
            pixelWidth: 200,
            pixelHeight: 200
        )

        async let scaleTwoRequest = pipeline.decodedThumbnail(for: key, scale: 2)
        async let scaleThreeRequest = pipeline.decodedThumbnail(for: key, scale: 3)
        let (scaleTwo, scaleThree) = await (scaleTwoRequest, scaleThreeRequest)
        let cachedScaleTwo = await pipeline.decodedThumbnail(for: key, scale: 2)
        let cachedScaleThree = await pipeline.decodedThumbnail(for: key, scale: 3)
        let decodedScales = await decoder.scales()
        let clientMetrics = await client.metrics()

        XCTAssertNotNil(scaleTwo)
        XCTAssertNotNil(scaleThree)
        XCTAssertFalse(scaleTwo === scaleThree)
        XCTAssertTrue(scaleTwo === cachedScaleTwo)
        XCTAssertTrue(scaleThree === cachedScaleThree)
        XCTAssertEqual(decodedScales.sorted(), [2, 3])
        XCTAssertEqual(clientMetrics.callsByAssetID[key.assetID], 1)
    }

    func testDecodedThumbnailUniqueBurstHasHardBoundedResidentWork() async {
        let client = CancellationCooperativeBlockingThumbnailClient()
        let pipeline = PhotoThumbnailPipeline(
            client: client,
            decoder: CountingThumbnailDecoder(),
            maximumConcurrentRequests: 2,
            maximumPendingRequests: 8,
            maximumEntryCount: 8,
            maximumByteCount: 1_024
        )
        let requestCount = 500
        let tasks = (0..<requestCount).map { index in
            Task {
                await pipeline.decodedThumbnail(
                    for: PhotoThumbnailKey(
                        assetID: "burst-\(index)",
                        revision: 1,
                        pixelWidth: 100,
                        pixelHeight: 100
                    ),
                    scale: 2
                )
            }
        }

        var state = await pipeline.workState()
        for _ in 0..<5_000 where state.admittedDecodedRequestCount < requestCount {
            await Task.yield()
            state = await pipeline.workState()
        }
        var startedCount = await client.startedCount()
        for _ in 0..<5_000 where startedCount < 2 {
            await Task.yield()
            startedCount = await client.startedCount()
        }
        state = await pipeline.workState()

        XCTAssertEqual(state.admittedDecodedRequestCount, requestCount)
        XCTAssertEqual(state.activeDecodedTaskCount, 2)
        XCTAssertEqual(state.pendingDecodedWorkCount, 8)
        XCTAssertEqual(state.residentDecodedRequestCount, 10)
        XCTAssertLessThanOrEqual(state.activeDataTaskCount, 2)
        XCTAssertLessThanOrEqual(state.pendingDataWorkCount, 8)
        XCTAssertLessThanOrEqual(state.residentDataRequestCount, 10)
        XCTAssertEqual(startedCount, 2)

        for task in tasks { task.cancel() }
        for task in tasks { _ = await task.value }
        for _ in 0..<5_000 {
            state = await pipeline.workState()
            if state.activeDataTaskCount == 0,
               state.activeDecodedTaskCount == 0,
               state.residentDataRequestCount == 0,
               state.residentDecodedRequestCount == 0 {
                break
            }
            await Task.yield()
        }
        XCTAssertEqual(state.activeDataTaskCount, 0)
        XCTAssertEqual(state.activeDecodedTaskCount, 0)
        XCTAssertEqual(state.residentDataRequestCount, 0)
        XCTAssertEqual(state.residentDecodedRequestCount, 0)
    }

    func testSharedThumbnailCancellationIsPromptAndOldRequestCannotFinishReplacement() async throws {
        let client = ControlledThumbnailClient()
        let pipeline = PhotoThumbnailPipeline(client: client, maximumConcurrentRequests: 2)
        let key = PhotoThumbnailKey(
            assetID: "shared-generation",
            revision: 1,
            pixelWidth: 100,
            pixelHeight: 100
        )
        let firstProbe = ThumbnailCompletionProbe()
        let first = Task {
            let value = await pipeline.thumbnailData(for: key)
            await firstProbe.finish(value)
            return value
        }
        await client.waitForCallCount(1)
        first.cancel()
        try await Task.sleep(for: .milliseconds(25))
        let firstFinishedPromptly = await firstProbe.isFinished()
        XCTAssertTrue(firstFinishedPromptly, "a cancelled waiter stayed blocked on shared PhotoKit work")

        let secondProbe = ThumbnailCompletionProbe()
        let second = Task {
            let value = await pipeline.thumbnailData(for: key)
            await secondProbe.finish(value)
            return value
        }
        await client.waitForCallCount(2)
        await client.release(call: 1, data: Data("old".utf8))
        try await Task.sleep(for: .milliseconds(25))
        let replacementFinishedEarly = await secondProbe.isFinished()
        XCTAssertFalse(replacementFinishedEarly, "an old request completed its same-key replacement")

        let expected = Data("new".utf8)
        await client.release(call: 2, data: expected)
        let firstValue = await first.value
        let secondValue = await second.value
        XCTAssertNil(firstValue)
        XCTAssertEqual(secondValue, expected)
    }

    func testInterruptedAnalysisRecoveryUsesNormalizedStateAndKeepsCursorIndependent() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let url = directory.appending(path: "ledger.sqlite")
        let ledger = try SQLiteLedger(url: url)
        let run = AnalysisRunRecord(
            id: UUID(),
            includesICloudItems: false,
            orderedAssetIDs: ["complete", "unavailable", "queued"],
            completedAssetIDs: [],
            status: .running,
            startedAt: Date(),
            updatedAt: Date(),
            errorMessage: nil,
            origin: .automaticMaintenance
        )
        try await ledger.createAnalysisRun(run)
        let completedRecord = AssetAnalysisRecord(
            assetID: "complete",
            sourceRevision: "1",
            status: .complete,
            fingerprint: nil,
            updatedAt: Date(),
            errorMessage: nil
        )
        try await ledger.saveAnalysisRecords([
            AssetAnalysisRecord(
                assetID: "unavailable",
                sourceRevision: "1",
                status: .unavailableLocally,
                fingerprint: nil,
                updatedAt: Date(),
                errorMessage: nil
            ),
            AssetAnalysisRecord(
                assetID: "queued",
                sourceRevision: "1",
                status: .analyzing,
                fingerprint: nil,
                updatedAt: Date(),
                errorMessage: nil
            )
        ])
        try await ledger.commitAnalysisProgress(
            completedRecord,
            runID: run.id,
            status: .running,
            nextPosition: 1,
            updatedAt: Date()
        )
        try await ledger.checkpointAnalysisRun(
            id: run.id,
            status: .running,
            nextPosition: 2
        )

        let reopened = try SQLiteLedger(url: url)
        let recovered = try await reopened.analysisRun(id: run.id)
        let progress = try await reopened.analysisRunProgress(id: run.id)
        let records = try await reopened.analysisRecords()

        XCTAssertEqual(recovered?.status, .paused)
        XCTAssertEqual(recovered?.origin, .automaticMaintenance)
        XCTAssertEqual(recovered?.completedAssetIDs, ["complete"])
        let nextPosition = try await reopened.analysisNextPosition(runID: run.id)
        XCTAssertEqual(nextPosition, 2)
        XCTAssertEqual(progress?.nextPosition, 2)
        XCTAssertEqual(progress?.completedAssetCount, 1)
        XCTAssertEqual(progress?.totalAssetCount, 3)
        XCTAssertEqual(progress?.status, .paused)
        XCTAssertEqual(progress?.origin, .automaticMaintenance)
        XCTAssertEqual(records["queued"]?.status, .queued)
    }

    func testConditionalJobPauseCannotRegressTerminalState() async throws {
        let ledger = try temporaryLedger()
        let frozen = try SelectionService().freeze(
            source: .allAccessible,
            assets: [FixtureFactory.asset(id: "pause-fixture")],
            albums: []
        )
        let planned = try ExportPlanner().plan(
            selection: frozen,
            albums: [],
            profile: ExportProfile(kind: .preserveOriginals, preserveLocation: true)
        )
        try await ledger.savePlannedJob(planned.job)

        let firstPause = try await ledger.pauseJobIfActive(jobID: planned.job.jobId)
        try await ledger.updateJobStatus(.completed, jobID: planned.job.jobId)
        let latePause = try await ledger.pauseJobIfActive(jobID: planned.job.jobId)
        let finalStatus = try await ledger.history().first?.status

        XCTAssertTrue(firstPause)
        XCTAssertFalse(latePause)
        XCTAssertEqual(finalStatus, .completed)
    }

    func testDelayedExportStartupAndCompletionCannotRegressNewerCheckpoint() async throws {
        let ledger = try temporaryLedger()
        let frozen = try SelectionService().freeze(
            source: .allAccessible,
            assets: [FixtureFactory.asset(id: "delayed-start-fixture")],
            albums: []
        )
        let planned = try ExportPlanner().plan(
            selection: frozen,
            albums: [],
            profile: ExportProfile(kind: .preserveOriginals, preserveLocation: true)
        )
        try await ledger.savePlannedJob(planned.job)

        let requestedAt = Date()
        let checkpointedAt = requestedAt.addingTimeInterval(10)
        let checkpointed = try await ledger.pauseJobIfActive(
            jobID: planned.job.jobId,
            at: checkpointedAt
        )
        XCTAssertTrue(checkpointed)

        let delayedActivation = try await ledger.activateJobForTransfer(
            planned.job,
            requestedAt: requestedAt
        )
        let report = CompletionReport(
            protocolVersion: ExportConstants.protocolVersion,
            jobId: planned.job.jobId,
            destinationId: UUID(),
            state: .completed,
            startedAt: requestedAt,
            completedAt: checkpointedAt.addingTimeInterval(1),
            counts: CompletionCounts(
                assetsPlanned: planned.job.assets.count,
                filesPlanned: planned.job.files.count,
                filesCommitted: planned.job.files.count,
                filesSkipped: 0,
                filesFailed: 0,
                bytesTransferred: 0,
                bytesCommitted: 0,
                verifiedOriginalFiles: planned.job.files.count
            ),
            failures: [],
            reportRelativePath: "reports/completion.json",
            manifestRelativePaths: []
        )
        let delayedCompletion = try await ledger.completeJob(report)
        let checkpointedStatus = try await ledger.history().first?.status

        XCTAssertFalse(delayedActivation)
        XCTAssertFalse(delayedCompletion)
        XCTAssertEqual(checkpointedStatus, .paused)

        try await ledger.updateJobStatus(.abandoned, jobID: planned.job.jobId)
        let terminalActivation = try await ledger.activateJobForTransfer(
            planned.job,
            requestedAt: checkpointedAt.addingTimeInterval(2)
        )
        let terminalStatus = try await ledger.history().first?.status

        XCTAssertFalse(terminalActivation)
        XCTAssertEqual(terminalStatus, .abandoned)
    }

    func testBackgroundProcessingPoliciesAreExplicit() {
        let automatic = BackgroundProcessingPolicy.automaticLocalMaintenance
        XCTAssertTrue(automatic.requiresExternalPower)
        XCTAssertFalse(automatic.requiresNetworkConnectivity)
        XCTAssertTrue(automatic.isAutomatic)

        let localUser = BackgroundProcessingPolicy.userAnalysis(includeICloudItems: false)
        XCTAssertFalse(localUser.requiresExternalPower)
        XCTAssertFalse(localUser.requiresNetworkConnectivity)
        XCTAssertFalse(localUser.isAutomatic)

        let cloudUser = BackgroundProcessingPolicy.userAnalysis(includeICloudItems: true)
        XCTAssertFalse(cloudUser.requiresExternalPower)
        XCTAssertTrue(cloudUser.requiresNetworkConnectivity)
    }

    func testBackgroundConstraintPolicySeparatesUserAndAutomaticWork() {
        let nominal = BackgroundExecutionConstraints(
            isLowPowerModeEnabled: false,
            thermalCondition: .nominal
        )
        let fair = BackgroundExecutionConstraints(
            isLowPowerModeEnabled: false,
            thermalCondition: .fair
        )
        let serious = BackgroundExecutionConstraints(
            isLowPowerModeEnabled: false,
            thermalCondition: .serious
        )
        let critical = BackgroundExecutionConstraints(
            isLowPowerModeEnabled: false,
            thermalCondition: .critical
        )
        let lowPower = BackgroundExecutionConstraints(
            isLowPowerModeEnabled: true,
            thermalCondition: .nominal
        )
        let user = BackgroundProcessingPolicy.userAnalysis(includeICloudItems: false)
        let automatic = BackgroundProcessingPolicy.automaticLocalMaintenance

        XCTAssertEqual(
            BackgroundExecutionConstraintPolicy.disposition(for: user, constraints: nominal),
            .run
        )
        XCTAssertEqual(
            BackgroundExecutionConstraintPolicy.disposition(for: user, constraints: fair),
            .run
        )
        XCTAssertEqual(
            BackgroundExecutionConstraintPolicy.disposition(for: user, constraints: serious),
            .pause(.thermalSerious)
        )
        XCTAssertEqual(
            BackgroundExecutionConstraintPolicy.disposition(for: user, constraints: critical),
            .pause(.thermalCritical)
        )
        XCTAssertEqual(
            BackgroundExecutionConstraintPolicy.disposition(for: user, constraints: lowPower),
            .pause(.lowPowerMode)
        )

        XCTAssertEqual(
            BackgroundExecutionConstraintPolicy.disposition(for: automatic, constraints: nominal),
            .run
        )
        XCTAssertEqual(
            BackgroundExecutionConstraintPolicy.disposition(for: automatic, constraints: fair),
            .run
        )
        XCTAssertEqual(
            BackgroundExecutionConstraintPolicy.disposition(for: automatic, constraints: serious),
            .deferUntilLater(.thermalSerious)
        )
        XCTAssertEqual(
            BackgroundExecutionConstraintPolicy.disposition(for: automatic, constraints: critical),
            .deferUntilLater(.thermalCritical)
        )
        XCTAssertEqual(
            BackgroundExecutionConstraintPolicy.disposition(for: automatic, constraints: lowPower),
            .deferUntilLater(.lowPowerMode)
        )
    }

    @MainActor
    func testBackgroundControllerUsesInjectedConstraints() {
        let constraints = BackgroundExecutionConstraints(
            isLowPowerModeEnabled: false,
            thermalCondition: .serious
        )
        let controller = BackgroundWorkController(
            constraintProvider: FixedBackgroundConstraintProvider(constraints: constraints)
        )

        XCTAssertEqual(controller.currentConstraints(), constraints)
        XCTAssertEqual(
            controller.constraintDisposition(for: .userAnalysis(includeICloudItems: false)),
            .pause(.thermalSerious)
        )
        XCTAssertEqual(
            controller.constraintDisposition(for: .automaticLocalMaintenance),
            .deferUntilLater(.thermalSerious)
        )
    }

    func testBackgroundTaskLaunchBridgeEntersOffMainBeforeHoppingToMainActor() async {
        let callbackReturned = expectation(description: "background callback returned")
        let operationRan = expectation(description: "main actor operation ran")
        let callback = BackgroundTaskLaunchBridge.makeMainActorCallback {
            (value: Int) in
            MainActor.preconditionIsolated()
            XCTAssertEqual(value, 42)
            operationRan.fulfill()
        }
        let launchQueue = DispatchQueue(
            label: "com.marginallybetter.photos.tests.background-task-launch"
        )

        launchQueue.async {
            dispatchPrecondition(condition: .notOnQueue(.main))
            callback(42)
            callbackReturned.fulfill()
        }

        await fulfillment(of: [callbackReturned, operationRan], timeout: 1)
    }

    func testBackgroundSchedulerErrorsMapToStructuredOutcomes() {
        let expected: [(Int, BackgroundTaskSchedulingOutcome)] = [
            (1, .unavailable),
            (2, .tooManyPendingRequests),
            (3, .notPermitted),
            (4, .immediateRunIneligible)
        ]
        for (code, outcome) in expected {
            let error = NSError(domain: BGTaskScheduler.errorDomain, code: code)
            XCTAssertEqual(BackgroundTaskSchedulingOutcome.submissionFailure(error), outcome)
        }
        XCTAssertEqual(
            BackgroundTaskSchedulingOutcome.submissionFailure(
                NSError(domain: BGTaskScheduler.errorDomain, code: 999)
            ),
            .unknownFailure
        )
        XCTAssertEqual(
            BackgroundTaskSchedulingOutcome.submissionFailure(
                NSError(domain: "not-background-tasks", code: 1)
            ),
            .unknownFailure
        )
    }

    func testSchedulingOutcomeDistinguishesQueuedFromContinuedExecution() {
        XCTAssertTrue(BackgroundTaskSchedulingOutcome.scheduled.acceptedByScheduler)
        XCTAssertTrue(BackgroundTaskSchedulingOutcome.scheduled.grantsContinuedExecution)

        let deferred = BackgroundTaskSchedulingOutcome.scheduledForLater(.lowPowerMode)
        XCTAssertTrue(deferred.acceptedByScheduler)
        XCTAssertFalse(deferred.grantsContinuedExecution)
        XCTAssertEqual(deferred.diagnosticValue, "scheduled-for-later:lowPowerMode")

        XCTAssertFalse(BackgroundTaskSchedulingOutcome.notPermitted.acceptedByScheduler)
        XCTAssertFalse(BackgroundTaskSchedulingOutcome.notPermitted.grantsContinuedExecution)
    }

    func testSystemAnalysisProgressUsesDurableCursorNotExactSizeCoverage() {
        let snapshot = AnalysisRunProgressSnapshot(
            id: UUID(),
            includesICloudItems: false,
            origin: .userInitiated,
            status: .running,
            nextPosition: 7,
            completedAssetCount: 3,
            totalAssetCount: 10,
            errorMessage: nil
        )

        XCTAssertEqual(BackgroundAnalysisProgressPolicy.processedUnitCount(from: snapshot), 7)
        XCTAssertNotEqual(
            BackgroundAnalysisProgressPolicy.processedUnitCount(from: snapshot),
            snapshot.completedAssetCount
        )
    }

    func testAnalysisWaitingStatusNamesTheBlockingCondition() {
        XCTAssertEqual(
            BackgroundAnalysisWaitingStatus.message(
                policy: .userAnalysis(includeICloudItems: false),
                reason: .lowPowerMode
            ),
            "Waiting for Low Power Mode to turn off."
        )
        XCTAssertEqual(
            BackgroundAnalysisWaitingStatus.message(
                policy: .userAnalysis(includeICloudItems: true),
                reason: .systemScheduling
            ),
            "Waiting for iOS and a network connection to continue analysis."
        )
        XCTAssertEqual(
            BackgroundAnalysisWaitingStatus.message(
                policy: .automaticLocalMaintenance,
                reason: .thermalFair
            ),
            "Waiting for external power and the device to cool down."
        )
    }

    func testSynchronousRunIdentifiedCancellationPreventsFirstResourceRead() async throws {
        let worker = OrganizeWorker()
        let ledger = try temporaryLedger()
        let analyzer = CountingConstraintAnalyzer()
        let asset = FixtureFactory.asset(id: "constraint-first-read")
        let input = OrganizeAnalysisWorkerInput(
            includeICloudItems: false,
            orderedAssetIDs: [asset.id],
            assetsByID: [asset.id: asset],
            sourceRevisionByAssetID: [asset.id: asset.analysisRevision],
            albumIDsByAssetID: [asset.id: []],
            analysisByAssetID: [:],
            analysisRun: nil,
            nextPosition: 0,
            origin: .userInitiated
        )

        let operation = Task {
            try await worker.runAnalysis(
                input,
                ledger: ledger,
                analyzer: analyzer,
                analysisRunIdentified: { _, _, _ in
                    // Mirrors AppModel's synchronous coordinator pause inside
                    // the callback, before the independent durable waiter starts.
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            ) { _ in }
        }
        let result = try await operation.value
        let analyzerCalls = await analyzer.callCount()
        let progress = try await ledger.analysisRunProgress(id: result.analysisRun.id)

        XCTAssertEqual(analyzerCalls, 0)
        XCTAssertEqual(result.analysisRun.status, .paused)
        XCTAssertEqual(result.nextPosition, 0)
        XCTAssertEqual(progress?.status, .paused)
        XCTAssertEqual(progress?.nextPosition, 0)
    }

    func testAutomaticMaintenanceResubmitsOnlyAnUnfinishedAutomaticRun() {
        func progress(
            origin: AnalysisRunOrigin,
            status: AnalysisRunStatus,
            nextPosition: Int,
            total: Int
        ) -> AnalysisRunProgressSnapshot {
            AnalysisRunProgressSnapshot(
                id: UUID(),
                includesICloudItems: false,
                origin: origin,
                status: status,
                nextPosition: nextPosition,
                completedAssetCount: nextPosition,
                totalAssetCount: total,
                errorMessage: nil
            )
        }

        XCTAssertTrue(BackgroundAutomaticMaintenanceResubmissionPolicy.shouldResubmit(
            progress: progress(
                origin: .automaticMaintenance,
                status: .paused,
                nextPosition: 4,
                total: 10
            )
        ))
        XCTAssertFalse(BackgroundAutomaticMaintenanceResubmissionPolicy.shouldResubmit(
            progress: progress(
                origin: .automaticMaintenance,
                status: .complete,
                nextPosition: 10,
                total: 10
            )
        ))
        XCTAssertFalse(BackgroundAutomaticMaintenanceResubmissionPolicy.shouldResubmit(
            progress: progress(
                origin: .userInitiated,
                status: .paused,
                nextPosition: 4,
                total: 10
            )
        ))
        XCTAssertFalse(BackgroundAutomaticMaintenanceResubmissionPolicy.shouldResubmit(
            progress: nil
        ))
    }

    func testOnlyUserInitiatedActiveAnalysisSchedulesDiscretionaryProcessing() {
        XCTAssertTrue(
            BackgroundAnalysisSchedulingPolicy.shouldScheduleUserProcessing(
                phase: .running,
                origin: .userInitiated
            )
        )
        XCTAssertTrue(
            BackgroundAnalysisSchedulingPolicy.shouldScheduleUserProcessing(
                phase: .paused,
                origin: .userInitiated
            )
        )
        XCTAssertFalse(
            BackgroundAnalysisSchedulingPolicy.shouldScheduleUserProcessing(
                phase: .running,
                origin: .automaticMaintenance
            )
        )
        XCTAssertFalse(
            BackgroundAnalysisSchedulingPolicy.shouldScheduleUserProcessing(
                phase: .complete,
                origin: .userInitiated
            )
        )
    }

    @MainActor
    func testActiveSceneGenerationRejectsBackgroundWorkAfterBlockedLookup() async {
        let fence = SceneTransitionGenerationFence()
        let backgroundGeneration = fence.enterBackground()
        let gate = AsyncStream<Void>.makeStream()
        let lookupStarted = expectation(description: "background lookup suspended")
        let staleBackground = Task { @MainActor in
            lookupStarted.fulfill()
            for await _ in gate.stream { break }
            return fence.permitsBackground(backgroundGeneration)
        }
        await fulfillment(of: [lookupStarted], timeout: 0.5)

        fence.enterActive()
        gate.continuation.yield(())
        gate.continuation.finish()

        let staleBackgroundWasPermitted = await staleBackground.value
        XCTAssertFalse(staleBackgroundWasPermitted)
    }

    @MainActor
    func testActiveSceneCancelsAuxiliaryBackgroundCheckpoint() async {
        let fence = SceneTransitionGenerationFence()
        let backgroundGeneration = fence.enterBackground()
        let checkpointStarted = expectation(description: "auxiliary checkpoint started")
        var cancellationWasObserved = false
        let checkpoint = Task { @MainActor in
            await fence.runBackgroundCheckpoint(generation: backgroundGeneration) {
                checkpointStarted.fulfill()
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch is CancellationError {
                    cancellationWasObserved = Task.isCancelled
                } catch {
                    XCTFail("Unexpected checkpoint error: \(error)")
                }
            }
        }
        await fulfillment(of: [checkpointStarted], timeout: 0.5)

        fence.enterActive()
        await checkpoint.value

        XCTAssertTrue(cancellationWasObserved)
    }

    func testBackgroundExecutionOwnershipIsPerKindAndReferenceCounted() {
        let analysisRunID = UUID()
        let otherRunID = UUID()
        let exportJobID = UUID()
        var ownership = BackgroundExecutionOwnership()

        ownership.begin(.analysis(runID: analysisRunID))
        ownership.begin(.analysis(runID: analysisRunID))
        ownership.begin(.export(jobID: exportJobID))

        XCTAssertTrue(ownership.coversAnalysis(runID: analysisRunID))
        XCTAssertFalse(ownership.coversAnalysis(runID: otherRunID))
        XCTAssertTrue(ownership.coversExport(jobID: exportJobID))

        ownership.end(.analysis(runID: analysisRunID))
        XCTAssertTrue(ownership.coversAnalysis(runID: analysisRunID))
        ownership.end(.analysis(runID: analysisRunID))
        XCTAssertFalse(ownership.coversAnalysis(runID: analysisRunID))
        XCTAssertTrue(ownership.coversExport(jobID: exportJobID))
    }

    func testBackgroundTaskCompletionClaimSurvivesSuspendingCleanup() async {
        for winningPath in [
            BackgroundTaskCompletionArbiter.Path.normal,
            .expiration,
        ] {
            let losingPath: BackgroundTaskCompletionArbiter.Path = winningPath == .normal
                ? .expiration
                : .normal
            let arbiter = BackgroundTaskCompletionArbiter()
            XCTAssertTrue(arbiter.claim(winningPath))

            let cleanupStarted = expectation(
                description: "\(winningPath) completion cleanup suspended"
            )
            let resumeCleanup = AsyncStream<Void>.makeStream()
            let cleanup = Task {
                cleanupStarted.fulfill()
                for await _ in resumeCleanup.stream { break }
                return arbiter.finish(winningPath)
            }
            await fulfillment(of: [cleanupStarted], timeout: 0.5)

            // An expiration racing normal release, or normal completion racing
            // an expiration checkpoint, cannot acquire a second teardown path.
            XCTAssertFalse(arbiter.claim(losingPath))
            XCTAssertFalse(arbiter.finish(losingPath))

            resumeCleanup.continuation.yield(())
            resumeCleanup.continuation.finish()
            let didFinishCleanup = await cleanup.value
            XCTAssertTrue(didFinishCleanup)
            XCTAssertFalse(arbiter.finish(winningPath), "setTaskCompleted must be single-shot")
        }
    }

    func testExportPublicationThrottleInvalidatesQueuedCallbackOnDirectPublish() {
        var throttle = ExportPublicationThrottle(minimumIntervalNanoseconds: 100)
        XCTAssertEqual(
            throttle.request(at: 1_000, immediate: false),
            .publishNow(cancelPending: false)
        )

        let delayed = throttle.request(at: 1_050, immediate: false)
        guard case let .schedule(token, delay) = delayed else {
            return XCTFail("Expected a delayed progress publication")
        }
        XCTAssertEqual(delay, 50)
        XCTAssertEqual(throttle.pendingToken, token)

        // The actor can be busy until the cadence boundary while the delayed
        // callback is already queued. A new direct publication must invalidate
        // that callback before emitting its value.
        XCTAssertEqual(
            throttle.request(at: 1_100, immediate: false),
            .publishNow(cancelPending: true)
        )
        XCTAssertNil(throttle.pendingToken)
        XCTAssertEqual(
            throttle.delayedCallbackFired(token: token, at: 1_101),
            .none
        )
        XCTAssertEqual(
            throttle.request(at: 1_150, immediate: false),
            .schedule(token: token &+ 1, delayNanoseconds: 50)
        )
    }

    func testExportPublicationThrottleDoesNotFireBeforeTenHertzBoundary() {
        var throttle = ExportPublicationThrottle(minimumIntervalNanoseconds: 100)
        XCTAssertEqual(
            throttle.request(at: 10_000, immediate: false),
            .publishNow(cancelPending: false)
        )
        guard case let .schedule(token, _) = throttle.request(
            at: 10_001,
            immediate: false
        ) else {
            return XCTFail("Expected throttled progress")
        }

        XCTAssertEqual(
            throttle.delayedCallbackFired(token: token, at: 10_099),
            .schedule(token: token, delayNanoseconds: 1)
        )
        XCTAssertEqual(
            throttle.delayedCallbackFired(token: token, at: 10_100),
            .publishNow(cancelPending: false)
        )

        // Terminal/error events retain their explicit prompt-publication path.
        XCTAssertEqual(
            throttle.request(at: 10_101, immediate: true),
            .publishNow(cancelPending: false)
        )
    }

    func testBackgroundCheckpointPolicyProtectsEachWorkKindIndependently() {
        let analysisRunID = UUID()
        let exportJobID = UUID()
        let newerExportJobID = UUID()

        let continuedAnalysis = BackgroundCheckpointPolicy(
            ownership: BackgroundExecutionOwnership(),
            analysisIsRunning: true,
            currentAnalysisRunID: analysisRunID,
            continuedAnalysisRunID: analysisRunID,
            currentExportJobID: exportJobID,
            continuedExportJobID: nil
        )
        XCTAssertFalse(continuedAnalysis.shouldCheckpointAnalysis)
        XCTAssertTrue(continuedAnalysis.shouldCheckpointExport)

        let staleAnalysisGrant = BackgroundCheckpointPolicy(
            ownership: BackgroundExecutionOwnership(),
            analysisIsRunning: true,
            currentAnalysisRunID: UUID(),
            continuedAnalysisRunID: analysisRunID,
            currentExportJobID: nil,
            continuedExportJobID: nil
        )
        XCTAssertTrue(staleAnalysisGrant.shouldCheckpointAnalysis)

        let continuedExport = BackgroundCheckpointPolicy(
            ownership: BackgroundExecutionOwnership(),
            analysisIsRunning: true,
            currentAnalysisRunID: analysisRunID,
            continuedAnalysisRunID: nil,
            currentExportJobID: exportJobID,
            continuedExportJobID: exportJobID
        )
        XCTAssertTrue(continuedExport.shouldCheckpointAnalysis)
        XCTAssertFalse(continuedExport.shouldCheckpointExport)

        let staleExportGrant = BackgroundCheckpointPolicy(
            ownership: BackgroundExecutionOwnership(),
            analysisIsRunning: false,
            currentAnalysisRunID: nil,
            continuedAnalysisRunID: nil,
            currentExportJobID: newerExportJobID,
            continuedExportJobID: exportJobID
        )
        XCTAssertTrue(staleExportGrant.shouldCheckpointExport)

        var refreshOwnership = BackgroundExecutionOwnership()
        refreshOwnership.begin(.metadataRefresh)
        let metadataRefresh = BackgroundCheckpointPolicy(
            ownership: refreshOwnership,
            analysisIsRunning: true,
            currentAnalysisRunID: analysisRunID,
            continuedAnalysisRunID: nil,
            currentExportJobID: exportJobID,
            continuedExportJobID: nil
        )
        XCTAssertTrue(metadataRefresh.shouldCheckpointAnalysis)
        XCTAssertTrue(metadataRefresh.shouldCheckpointExport)
    }

    func testEndingAnalysisLeaseRechecksAnalysisWithoutDisturbingCoveredExport() {
        let exportJobID = UUID()
        var ownership = BackgroundExecutionOwnership()
        ownership.begin(.analysis(runID: nil))
        ownership.begin(.export(jobID: exportJobID))

        let whileBothCovered = BackgroundCheckpointPolicy(
            ownership: ownership,
            analysisIsRunning: true,
            currentAnalysisRunID: nil,
            continuedAnalysisRunID: nil,
            currentExportJobID: exportJobID,
            continuedExportJobID: nil
        )
        XCTAssertFalse(whileBothCovered.shouldCheckpointAnalysis)
        XCTAssertFalse(whileBothCovered.shouldCheckpointExport)

        ownership.end(.analysis(runID: nil))
        let afterAnalysisLeaseEnds = BackgroundCheckpointPolicy(
            ownership: ownership,
            analysisIsRunning: true,
            currentAnalysisRunID: nil,
            continuedAnalysisRunID: nil,
            currentExportJobID: exportJobID,
            continuedExportJobID: nil
        )
        XCTAssertTrue(afterAnalysisLeaseEnds.shouldCheckpointAnalysis)
        XCTAssertFalse(afterAnalysisLeaseEnds.shouldCheckpointExport)
    }

    func testDelayedProgressCannotResurrectTerminalBackgroundWork() async {
        let worker = BackgroundWorkStateWorker()
        let kind = BackgroundWorkKind.export(jobID: UUID())
        _ = await worker.transition(
            kind: kind,
            phase: .running,
            completed: 4,
            total: 10
        )
        let terminal = await worker.transition(
            kind: kind,
            phase: .completed,
            completed: 10,
            total: 10
        )

        let delayed = await worker.reportProgress(
            kind: kind,
            completed: 5,
            total: 10
        )
        let latest = await worker.latest()

        XCTAssertEqual(delayed, terminal)
        XCTAssertEqual(latest?.phase, .completed)
    }

    func testDelayedProgressCannotResurrectTerminalWorkAfterAnotherKindStarts() async {
        let worker = BackgroundWorkStateWorker()
        let completedKind = BackgroundWorkKind.export(jobID: UUID())
        let activeKind = BackgroundWorkKind.libraryRefresh
        _ = await worker.transition(
            kind: completedKind,
            phase: .running,
            completed: 4,
            total: 10
        )
        let terminal = await worker.transition(
            kind: completedKind,
            phase: .completed,
            completed: 10,
            total: 10
        )
        let active = await worker.transition(kind: activeKind, phase: .running)

        let delayed = await worker.reportProgress(
            kind: completedKind,
            completed: 5,
            total: 10
        )
        let latest = await worker.latest()

        XCTAssertEqual(delayed, terminal)
        XCTAssertEqual(latest, active)
    }

    func testConstraintPauseSurvivesDelayedProgressAndWorkerCompletion() async {
        let worker = BackgroundWorkStateWorker()
        let kind = BackgroundWorkKind.analysis(
            runID: UUID(),
            includeICloudItems: false
        )
        _ = await worker.transition(
            kind: kind,
            phase: .running,
            completed: 2,
            total: 8,
            policy: .userAnalysis(includeICloudItems: false)
        )
        let paused = await worker.transition(
            kind: kind,
            phase: .paused,
            completed: 3,
            total: 8,
            policy: .userAnalysis(includeICloudItems: false),
            deferralReason: .lowPowerMode
        )

        let delayed = await worker.reportProgress(kind: kind, completed: 4, total: 8)
        let finished = await worker.finish(kind: kind, success: false)
        let stored = await worker.state(for: kind)

        XCTAssertEqual(delayed, paused)
        XCTAssertEqual(finished, paused)
        XCTAssertEqual(stored?.phase, .paused)
        XCTAssertEqual(stored?.completedUnitCount, 3)
        XCTAssertTrue(BackgroundWorkDeferralReason.lowPowerMode.isPowerOrThermalConstraint)
        XCTAssertFalse(BackgroundWorkDeferralReason.systemExpiration.isPowerOrThermalConstraint)
    }

    func testWaitingRequestNeverBecomesRunningFromProgressOrCompletionCallbacks() async {
        let worker = BackgroundWorkStateWorker()
        let waiting = await worker.transition(
            kind: .libraryMaintenance,
            phase: .waiting,
            policy: .automaticLocalMaintenance,
            deferralReason: .thermalFair
        )

        let delayed = await worker.reportProgress(
            kind: .libraryMaintenance,
            completed: 1,
            total: 10
        )
        let finished = await worker.finish(kind: .libraryMaintenance, success: true)

        XCTAssertEqual(delayed, waiting)
        XCTAssertEqual(finished, waiting)
        XCTAssertEqual(finished?.phase, .waiting)
    }

    private func temporaryLedger() throws -> SQLiteLedger {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        return try SQLiteLedger(url: directory.appending(path: "ledger.sqlite"))
    }
}

private struct FixedBackgroundConstraintProvider: BackgroundExecutionConstraintProviding {
    let constraints: BackgroundExecutionConstraints

    func currentConstraints() -> BackgroundExecutionConstraints { constraints }
}

private actor CountingConstraintAnalyzer: AssetResourceAnalyzing {
    private var calls = 0

    func analyze(
        asset: PhotoAsset,
        includeNetwork: Bool,
        progress: @escaping @Sendable (AssetAnalysisProgress) -> Void
    ) async throws -> AssetFingerprint {
        calls += 1
        return AssetFingerprint(
            assetID: asset.id,
            sourceRevision: asset.analysisRevision,
            resources: [
                ResourceFingerprint(kind: .photo, byteCount: 1, sha256: asset.id)
            ],
            analyzedAt: Date()
        )
    }

    func callCount() -> Int { calls }
}

private actor ScriptedPhotoLibraryChangeLoader: PhotoLibraryChangeLoading {
    private var results: [PhotoLibraryChangeLoadResult]
    private var calls = 0

    init(results: [PhotoLibraryChangeLoadResult]) { self.results = results }

    func loadChanges(
        since changeTokenData: Data?,
        revision: UInt64,
        authorization: PhotoAuthorizationState,
        knownAssetIDs: Set<String>
    ) async throws -> PhotoLibraryChangeLoadResult {
        calls += 1
        guard !results.isEmpty else { throw TestFailure.missingScriptedResult }
        return results.removeFirst()
    }

    func callCount() -> Int { calls }

    func currentAuthorizationScopeFingerprint(
        authorization: PhotoAuthorizationState
    ) async throws -> String? { nil }
}

private actor CountingPhotoLibraryIndexStore: PhotoLibraryIndexPersisting {
    struct Metrics: Sendable {
        let cachedReads: Int
        let fullDeltaApplications: Int
        let tokenAdvances: Int
    }

    private var snapshot: PhotoLibrarySnapshot
    private var cachedReads = 0
    private var fullDeltaApplications = 0
    private var tokenAdvances = 0

    init(snapshot: PhotoLibrarySnapshot) { self.snapshot = snapshot }

    func cachedPhotoLibrarySnapshot(
        revision: UInt64,
        authorization: PhotoAuthorizationState,
        scopeFingerprint: String?
    ) async throws -> PhotoLibrarySnapshot? {
        cachedReads += 1
        return retag(snapshot, revision: revision)
    }

    func replaceCachedPhotoLibrarySnapshot(
        _ snapshot: PhotoLibrarySnapshot,
        authorization: PhotoAuthorizationState
    ) async throws {
        self.snapshot = snapshot
    }

    func applyPhotoLibraryChanges(
        _ changes: PhotoLibraryIndexChanges,
        revision: UInt64,
        authorization: PhotoAuthorizationState
    ) async throws -> PhotoLibrarySnapshot {
        fullDeltaApplications += 1
        return retag(snapshot, revision: revision)
    }

    func advanceCachedPhotoLibraryChangeToken(_ changeTokenData: Data?) async throws {
        tokenAdvances += 1
        snapshot = PhotoLibrarySnapshot(
            revision: snapshot.revision,
            assets: snapshot.assets,
            albums: snapshot.albums,
            changeTokenData: changeTokenData,
            authorizationScopeFingerprint: snapshot.authorizationScopeFingerprint
        )
    }

    func metrics() -> Metrics {
        Metrics(
            cachedReads: cachedReads,
            fullDeltaApplications: fullDeltaApplications,
            tokenAdvances: tokenAdvances
        )
    }

    private func retag(
        _ snapshot: PhotoLibrarySnapshot,
        revision: UInt64
    ) -> PhotoLibrarySnapshot {
        PhotoLibrarySnapshot(
            revision: revision,
            assets: snapshot.assets,
            albums: snapshot.albums,
            changeTokenData: snapshot.changeTokenData,
            authorizationScopeFingerprint: snapshot.authorizationScopeFingerprint
        )
    }
}

private actor RetryableCacheLoader: LibrarySnapshotLoading {
    private var calls = 0

    func cachedSnapshot(
        revision: UInt64,
        authorization: PhotoAuthorizationState
    ) async throws -> PhotoLibrarySnapshot? {
        calls += 1
        if calls == 1 { throw TestFailure.transientCacheRead }
        return PhotoLibrarySnapshot(
            revision: revision,
            assets: [FixtureFactory.asset(id: "cached")],
            albums: [],
            changeTokenData: nil
        )
    }

    func refreshedSnapshot(
        revision: UInt64,
        authorization: PhotoAuthorizationState
    ) async throws -> PhotoLibrarySnapshot {
        throw TestFailure.missingScriptedResult
    }

    func cacheCalls() -> Int { calls }
}

private actor RetaggingLimitedSnapshotLoader: LibrarySnapshotLoading {
    private var refreshes = 0

    func cachedSnapshot(
        revision: UInt64,
        authorization: PhotoAuthorizationState
    ) async throws -> PhotoLibrarySnapshot? {
        PhotoLibrarySnapshot(
            revision: revision,
            assets: [FixtureFactory.asset(id: "cached")],
            albums: [],
            changeTokenData: Data("cached-token".utf8),
            authorizationScopeFingerprint: "limited-scope"
        )
    }

    func refreshedSnapshot(
        revision: UInt64,
        authorization: PhotoAuthorizationState
    ) async throws -> PhotoLibrarySnapshot {
        refreshes += 1
        return PhotoLibrarySnapshot(
            revision: revision,
            assets: [FixtureFactory.asset(id: "reconciled")],
            albums: [],
            changeTokenData: Data("fresh-token".utf8),
            authorizationScopeFingerprint: "limited-scope"
        )
    }

    func refreshCount() -> Int { refreshes }
}

private actor AuthorizationAwareSnapshotLoader: LibrarySnapshotLoading {
    func cachedSnapshot(
        revision: UInt64,
        authorization: PhotoAuthorizationState
    ) async throws -> PhotoLibrarySnapshot? {
        snapshot(revision: revision, authorization: authorization)
    }

    func refreshedSnapshot(
        revision: UInt64,
        authorization: PhotoAuthorizationState
    ) async throws -> PhotoLibrarySnapshot {
        snapshot(revision: revision, authorization: authorization)
    }

    private func snapshot(
        revision: UInt64,
        authorization: PhotoAuthorizationState
    ) -> PhotoLibrarySnapshot {
        let id = authorization == .limited ? "limited-only" : "authorized-only"
        return PhotoLibrarySnapshot(
            revision: revision,
            assets: [FixtureFactory.asset(id: id)],
            albums: [],
            changeTokenData: nil
        )
    }
}

private actor RevisionRecordingLoader {
    private var loadedRevisions: [UInt64] = []

    func load(revision: UInt64) async throws -> PhotoLibrarySnapshot {
        loadedRevisions.append(revision)
        if revision == 1 { try await Task.sleep(for: .milliseconds(80)) }
        return PhotoLibrarySnapshot(
            revision: revision,
            assets: [FixtureFactory.asset(id: "asset-\(revision)")],
            albums: [],
            changeTokenData: nil
        )
    }

    func revisions() -> [UInt64] { loadedRevisions }
}

private actor CancellationObservingLoader {
    private var cancelled = false

    func load(revision: UInt64) async throws -> PhotoLibrarySnapshot {
        do {
            try await Task.sleep(for: .seconds(5))
        } catch is CancellationError {
            cancelled = true
            throw CancellationError()
        }
        return PhotoLibrarySnapshot(revision: revision, assets: [], albums: [], changeTokenData: nil)
    }

    func wasCancelled() -> Bool { cancelled }
}

private actor CancelledRefreshReplacementLoader {
    private var calls = 0
    private var firstStarted = false
    private var cancellationObserved = false
    private var cancellationReleased = false
    private var firstStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func load(revision: UInt64) async throws -> PhotoLibrarySnapshot {
        calls += 1
        if calls == 1 {
            firstStarted = true
            let startedWaiters = firstStartedWaiters
            firstStartedWaiters.removeAll(keepingCapacity: false)
            for waiter in startedWaiters { waiter.resume() }

            do {
                try await Task.sleep(for: .seconds(30))
            } catch is CancellationError {
                cancellationObserved = true
                let observedWaiters = cancellationWaiters
                cancellationWaiters.removeAll(keepingCapacity: false)
                for waiter in observedWaiters { waiter.resume() }
                if !cancellationReleased {
                    await withCheckedContinuation { releaseWaiter = $0 }
                }
                throw CancellationError()
            }
        }
        return PhotoLibrarySnapshot(
            revision: revision,
            assets: [FixtureFactory.asset(id: "asset-\(revision)")],
            albums: [],
            changeTokenData: nil
        )
    }

    func waitUntilFirstStarted() async {
        if firstStarted { return }
        await withCheckedContinuation { firstStartedWaiters.append($0) }
    }

    func waitUntilCancellationObserved() async {
        if cancellationObserved { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }

    func releaseCancellation() {
        cancellationReleased = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func callCount() -> Int { calls }
}

private actor CountingThumbnailClient: PhotoThumbnailRequesting {
    struct Metrics: Sendable {
        let callsByAssetID: [String: Int]
        let maximumActive: Int
        let requestedKeys: [PhotoThumbnailKey]
    }

    private var callsByAssetID: [String: Int] = [:]
    private var requestedKeys: [PhotoThumbnailKey] = []
    private var active = 0
    private var maximumActive = 0

    func thumbnailData(for key: PhotoThumbnailKey) async -> Data? {
        callsByAssetID[key.assetID, default: 0] += 1
        requestedKeys.append(key)
        active += 1
        maximumActive = max(maximumActive, active)
        try? await Task.sleep(for: .milliseconds(40))
        active -= 1
        return Data(key.assetID.utf8)
    }

    func metrics() -> Metrics {
        Metrics(
            callsByAssetID: callsByAssetID,
            maximumActive: maximumActive,
            requestedKeys: requestedKeys
        )
    }
}

private actor CountingThumbnailDecoder: PhotoThumbnailDecoding {
    private var calls = 0

    func decode(
        data: Data,
        key: PhotoThumbnailKey,
        scale: Double
    ) async -> DecodedThumbnailImage? {
        calls += 1
        try? await Task.sleep(for: .milliseconds(40))
        return DecodedThumbnailImage(UIImage(), estimatedByteCount: 64)
    }

    func callCount() -> Int { calls }
}

private actor ScaleRecordingThumbnailDecoder: PhotoThumbnailDecoding {
    private var requestedScales: [Double] = []

    func decode(
        data: Data,
        key: PhotoThumbnailKey,
        scale: Double
    ) async -> DecodedThumbnailImage? {
        requestedScales.append(scale)
        try? await Task.sleep(for: .milliseconds(40))
        return DecodedThumbnailImage(UIImage(), estimatedByteCount: 64)
    }

    func scales() -> [Double] { requestedScales }
}

private actor CancellationCooperativeBlockingThumbnailClient: PhotoThumbnailRequesting {
    private var started = 0

    func thumbnailData(for key: PhotoThumbnailKey) async -> Data? {
        started += 1
        do {
            try await Task.sleep(for: .seconds(30))
            return Data(key.assetID.utf8)
        } catch {
            return nil
        }
    }

    func startedCount() -> Int { started }
}

private actor ControlledThumbnailClient: PhotoThumbnailRequesting {
    private var callCount = 0
    private var callWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var releases: [Int: CheckedContinuation<Data?, Never>] = [:]

    func thumbnailData(for key: PhotoThumbnailKey) async -> Data? {
        callCount += 1
        let call = callCount
        let ready = callWaiters.filter { callCount >= $0.0 }
        callWaiters.removeAll { callCount >= $0.0 }
        for (_, continuation) in ready { continuation.resume() }
        return await withCheckedContinuation { releases[call] = $0 }
    }

    func waitForCallCount(_ target: Int) async {
        if callCount >= target { return }
        await withCheckedContinuation { callWaiters.append((target, $0)) }
    }

    func release(call: Int, data: Data?) {
        releases.removeValue(forKey: call)?.resume(returning: data)
    }
}

private actor ThumbnailCompletionProbe {
    private var finished = false

    func finish(_ value: Data?) { finished = true }
    func isFinished() -> Bool { finished }
}

private enum TestFailure: Error {
    case missingScriptedResult
    case transientCacheRead
}
