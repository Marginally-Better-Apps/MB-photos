@testable import MBPhotos
import Foundation
import GRDB
import XCTest

final class OrganizeWorkerConcurrencyTests: XCTestCase {
    func testAnalysisLeaseRejectsOverlapAndReleasesAfterCancellationUnwinds() async throws {
        let worker = OrganizeWorker()
        let ledger = try temporaryLedger()
        let analyzer = BlockingWorkerAnalyzer()
        let asset = makeAsset(id: "lease")
        let input = analysisInput([asset])

        let first = Task {
            try await worker.runAnalysis(input, ledger: ledger, analyzer: analyzer) { _ in }
        }
        await analyzer.waitUntilStarted()

        do {
            _ = try await worker.runAnalysis(input, ledger: ledger, analyzer: FastWorkerAnalyzer()) { _ in }
            XCTFail("A second analysis must not enter while the worker lease is owned")
        } catch let error as OrganizeWorkerError {
            XCTAssertEqual(error, .analysisAlreadyRunning)
        }

        first.cancel()
        await analyzer.release()
        let paused = try await first.value
        XCTAssertEqual(paused.presentation.phase, .paused)

        let resumedInput = OrganizeAnalysisWorkerInput(
            includeICloudItems: false,
            orderedAssetIDs: [asset.id],
            assetsByID: [asset.id: asset],
            sourceRevisionByAssetID: [asset.id: asset.sourceRevision],
            analysisByAssetID: paused.analysisByAssetID,
            analysisRun: paused.analysisRun,
            nextPosition: paused.nextPosition
        )
        let completed = try await worker.runAnalysis(
            resumedInput,
            ledger: ledger,
            analyzer: FastWorkerAnalyzer()
        ) { _ in }
        XCTAssertEqual(completed.presentation.phase, .complete)
    }

    func testPausedAutomaticRunOnlyResumesWithAutomaticOrigin() async throws {
        let worker = OrganizeWorker()
        let ledger = try temporaryLedger()
        let analyzer = BlockingWorkerAnalyzer()
        let asset = makeAsset(id: "origin-policy")
        let automaticInput = analysisInput([asset], origin: .automaticMaintenance)

        let first = Task {
            try await worker.runAnalysis(
                automaticInput,
                ledger: ledger,
                analyzer: analyzer
            ) { _ in }
        }
        await analyzer.waitUntilStarted()
        first.cancel()
        await analyzer.release()
        let paused = try await first.value
        XCTAssertEqual(paused.analysisRun.origin, .automaticMaintenance)
        XCTAssertEqual(paused.analysisRun.status, .paused)

        let userInput = OrganizeAnalysisWorkerInput(
            includeICloudItems: false,
            orderedAssetIDs: [asset.id],
            assetsByID: [asset.id: asset],
            sourceRevisionByAssetID: [asset.id: asset.sourceRevision],
            analysisByAssetID: paused.analysisByAssetID,
            analysisRun: paused.analysisRun,
            nextPosition: paused.nextPosition,
            origin: .userInitiated
        )
        let userResult = try await worker.runAnalysis(
            userInput,
            ledger: ledger,
            analyzer: FastWorkerAnalyzer()
        ) { _ in }

        XCTAssertNotEqual(userResult.analysisRun.id, paused.analysisRun.id)
        XCTAssertEqual(userResult.analysisRun.origin, .userInitiated)

        let automaticResumeInput = OrganizeAnalysisWorkerInput(
            includeICloudItems: false,
            orderedAssetIDs: [asset.id],
            assetsByID: [asset.id: asset],
            sourceRevisionByAssetID: [asset.id: asset.sourceRevision],
            analysisByAssetID: paused.analysisByAssetID,
            analysisRun: paused.analysisRun,
            nextPosition: paused.nextPosition,
            origin: .automaticMaintenance
        )
        let automaticResult = try await worker.runAnalysis(
            automaticResumeInput,
            ledger: ledger,
            analyzer: FastWorkerAnalyzer()
        ) { _ in }

        XCTAssertEqual(automaticResult.analysisRun.id, paused.analysisRun.id)
        XCTAssertEqual(automaticResult.analysisRun.origin, .automaticMaintenance)
    }

    func testAutomaticMaintenanceSkipsValidTerminalIssuesWhileUserRunRetriesThem() async throws {
        let worker = OrganizeWorker()
        let ledger = try temporaryLedger()
        let analyzer = CountingWorkerAnalyzer()
        let unavailable = makeAsset(id: "automatic-unavailable")
        let failed = makeAsset(id: "automatic-failed")
        let records = [
            unavailable.id: AssetAnalysisRecord(
                assetID: unavailable.id,
                sourceRevision: unavailable.analysisRevision,
                status: .unavailableLocally,
                fingerprint: nil,
                updatedAt: Date(),
                errorMessage: "iCloud required"
            ),
            failed.id: AssetAnalysisRecord(
                assetID: failed.id,
                sourceRevision: failed.analysisRevision,
                status: .failed,
                fingerprint: nil,
                updatedAt: Date(),
                errorMessage: "prior failure"
            )
        ]
        let assets = [unavailable, failed]
        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        let revisions = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0.sourceRevision) })
        let automaticInput = OrganizeAnalysisWorkerInput(
            includeICloudItems: false,
            orderedAssetIDs: assets.map(\.id),
            assetsByID: assetsByID,
            sourceRevisionByAssetID: revisions,
            analysisByAssetID: records,
            analysisRun: nil,
            nextPosition: 0,
            origin: .automaticMaintenance
        )

        let automatic = try await worker.runAnalysis(
            automaticInput,
            ledger: ledger,
            analyzer: analyzer
        ) { _ in }

        let automaticInvocationCount = await analyzer.invocationCount()
        XCTAssertEqual(automaticInvocationCount, 0)
        XCTAssertEqual(automatic.analysisRun.status, .complete)
        XCTAssertEqual(automatic.storageProgress.processedAssetCount, 2)
        XCTAssertEqual(automatic.storageProgress.unavailableAssetCount, 1)
        XCTAssertEqual(automatic.storageProgress.failedAssetCount, 1)

        let userInput = OrganizeAnalysisWorkerInput(
            includeICloudItems: true,
            orderedAssetIDs: assets.map(\.id),
            assetsByID: assetsByID,
            sourceRevisionByAssetID: revisions,
            analysisByAssetID: automatic.analysisByAssetID,
            analysisRun: nil,
            nextPosition: 0,
            origin: .userInitiated
        )
        let user = try await worker.runAnalysis(
            userInput,
            ledger: ledger,
            analyzer: analyzer
        ) { _ in }

        let userInvocationCount = await analyzer.invocationCount()
        XCTAssertEqual(userInvocationCount, 2)
        XCTAssertEqual(user.analysisRun.status, .complete)
        XCTAssertEqual(user.storageProgress.analyzedAssetCount, 2)
        XCTAssertEqual(user.storageProgress.unavailableAssetCount, 0)
        XCTAssertEqual(user.storageProgress.failedAssetCount, 0)
    }

    func testExactAnalysisCanRemainDurablyRunningUntilVisualPhaseFinishes() async throws {
        let worker = OrganizeWorker()
        let ledger = try temporaryLedger()
        let asset = makeAsset(id: "deferred-visual-completion")

        let result = try await worker.runAnalysis(
            analysisInput([asset], origin: .automaticMaintenance),
            ledger: ledger,
            analyzer: FastWorkerAnalyzer(),
            deferSuccessfulCompletion: true
        ) { _ in }
        let durable = try await ledger.analysisRunProgress(id: result.analysisRun.id)

        XCTAssertEqual(result.analysisRun.status, .running)
        XCTAssertEqual(result.presentation.phase, .running)
        XCTAssertEqual(durable?.status, .running)
        XCTAssertEqual(durable?.nextPosition, 0)
        XCTAssertEqual(durable?.completedAssetCount, 1)
        XCTAssertTrue(
            BackgroundAutomaticMaintenanceResubmissionPolicy.shouldResubmit(progress: durable)
        )
    }

    func testResumedRunRewindsChangedCompletedAssetAndResetsDurableCount() async throws {
        let worker = OrganizeWorker()
        let ledger = try temporaryLedger()
        let originalAsset = makeAsset(id: "changed-resume")
        let changedAsset = makeAsset(
            id: originalAsset.id,
            modificationDate: Date(timeIntervalSince1970: 2_000)
        )
        let completedRecord = AssetAnalysisRecord(
            assetID: originalAsset.id,
            sourceRevision: originalAsset.analysisRevision,
            status: .complete,
            fingerprint: FastWorkerAnalyzer.fingerprint(for: originalAsset),
            updatedAt: Date(),
            errorMessage: nil
        )
        let pausedRun = AnalysisRunRecord(
            id: UUID(),
            includesICloudItems: false,
            orderedAssetIDs: [originalAsset.id],
            completedAssetIDs: [originalAsset.id],
            status: .paused,
            startedAt: Date(),
            updatedAt: Date(),
            errorMessage: nil
        )
        try await ledger.createAnalysisRun(pausedRun)
        try await ledger.saveAnalysisRecord(completedRecord)
        let storedPosition = try await ledger.analysisNextPosition(runID: pausedRun.id)
        XCTAssertEqual(storedPosition, 1)

        let input = OrganizeAnalysisWorkerInput(
            includeICloudItems: false,
            orderedAssetIDs: [changedAsset.id],
            assetsByID: [changedAsset.id: changedAsset],
            sourceRevisionByAssetID: [changedAsset.id: changedAsset.sourceRevision],
            analysisByAssetID: [changedAsset.id: completedRecord],
            analysisRun: pausedRun,
            nextPosition: storedPosition
        )
        let result = try await worker.runAnalysis(
            input,
            ledger: ledger,
            analyzer: UnavailableWorkerAnalyzer()
        ) { _ in }
        let progress = try await ledger.analysisRunProgress(id: pausedRun.id)

        XCTAssertEqual(result.analysisRun.id, pausedRun.id)
        XCTAssertEqual(result.presentation.completedAssetCount, 0)
        XCTAssertEqual(result.analysisByAssetID[changedAsset.id]?.sourceRevision, changedAsset.analysisRevision)
        XCTAssertEqual(result.analysisByAssetID[changedAsset.id]?.status, .unavailableLocally)
        XCTAssertEqual(progress?.completedAssetCount, 0)
        XCTAssertEqual(progress?.nextPosition, 1)
    }

    func testAnalysisRunningProgressIsThrottledAndTerminalPublishesImmediately() async throws {
        let worker = OrganizeWorker()
        let ledger = try temporaryLedger()
        let assets = (0..<160).map { makeAsset(id: "fast-\($0)") }
        let recorder = WorkerProgressRecorder()

        let result = try await worker.runAnalysis(
            analysisInput(assets),
            ledger: ledger,
            analyzer: FastWorkerAnalyzer()
        ) { update in
            await recorder.append(update)
        }

        let events = await recorder.events()
        let runningDates = events.filter { $0.presentation.phase == .running }.map(\.date)
        for (earlier, later) in zip(runningDates, runningDates.dropFirst()) {
            XCTAssertGreaterThanOrEqual(
                later.timeIntervalSince(earlier),
                0.09,
                "Running callbacks must be capped at approximately 10 Hz"
            )
        }
        XCTAssertEqual(events.last?.presentation.phase, .complete)
        XCTAssertEqual(events.last?.presentation.completedAssetCount, assets.count)
        XCTAssertEqual(result.presentation.phase, .complete)
    }

    func testAnalysisPublishesCurrentAssetFractionBeforeDurableSizeTotals() async throws {
        let worker = OrganizeWorker()
        let ledger = try temporaryLedger()
        let recorder = WorkerProgressRecorder()
        let asset = makeAsset(id: "progressive")

        let result = try await worker.runAnalysis(
            analysisInput([asset]),
            ledger: ledger,
            analyzer: ProgressiveWorkerAnalyzer()
        ) { update in
            await recorder.append(update)
        }

        let events = await recorder.events()
        let inFlight = try XCTUnwrap(events.first { event in
            event.update.currentAssetID == asset.id
                && event.presentation.currentAssetFraction > 0
                && event.presentation.currentAssetFraction < 1
        })
        XCTAssertEqual(inFlight.update.storage.processedAssetCount, 0)
        XCTAssertEqual(inFlight.update.storage.totalKnownBytes, 0)
        XCTAssertEqual(events.last?.update.storage.processedAssetCount, 1)
        XCTAssertEqual(events.last?.update.storage.totalKnownBytes, 1)
        XCTAssertEqual(result.storageProgress.totalKnownBytes, 1)
    }

    func testLocalOnlyRunCountsEveryICloudAssetAsProcessedAndUnavailable() async throws {
        let worker = OrganizeWorker()
        let ledger = try temporaryLedger()
        let recorder = WorkerProgressRecorder()
        let assets = (0..<3).map { makeAsset(id: "icloud-\($0)") }

        let result = try await worker.runAnalysis(
            analysisInput(assets),
            ledger: ledger,
            analyzer: UnavailableWorkerAnalyzer()
        ) { update in
            await recorder.append(update)
        }

        XCTAssertEqual(result.presentation.phase, .complete)
        XCTAssertEqual(result.presentation.processedAssetCount, assets.count)
        XCTAssertEqual(result.presentation.completedAssetCount, 0)
        XCTAssertEqual(result.presentation.unavailableAssetCount, assets.count)
        XCTAssertEqual(result.storageProgress.totalKnownBytes, 0)
        XCTAssertTrue(result.presentation.statusText.contains("require iCloud access"))
        XCTAssertEqual(Set(result.analysisByAssetID.values.map(\.status)), [.unavailableLocally])
        let events = await recorder.events()
        let terminal = try XCTUnwrap(events.last?.update)
        XCTAssertEqual(terminal.storage.processedAssetCount, assets.count)
        XCTAssertEqual(terminal.storage.unavailableAssetCount, assets.count)
    }

    func testAssetFailuresAreVisibleInTerminalProgressAndFailTheRun() async throws {
        let worker = OrganizeWorker()
        let ledger = try temporaryLedger()
        let recorder = WorkerProgressRecorder()
        let assets = [makeAsset(id: "failure-a"), makeAsset(id: "failure-b")]

        let result = try await worker.runAnalysis(
            analysisInput(assets),
            ledger: ledger,
            analyzer: FailingWorkerAnalyzer()
        ) { update in
            await recorder.append(update)
        }

        XCTAssertEqual(result.analysisRun.status, .failed)
        XCTAssertEqual(result.presentation.phase, .failed)
        XCTAssertEqual(result.presentation.processedAssetCount, assets.count)
        XCTAssertEqual(result.presentation.completedAssetCount, 0)
        XCTAssertEqual(result.presentation.failedAssetCount, assets.count)
        XCTAssertTrue(result.presentation.statusText.contains("2 failed"))
        XCTAssertEqual(Set(result.analysisByAssetID.values.map(\.status)), [.failed])
        let events = await recorder.events()
        XCTAssertEqual(events.last?.update.storage.failedAssetCount, assets.count)
    }

    func testResumedProgressSeedsDurableAnalysisBeforeProcessingRemainingWork() async throws {
        let worker = OrganizeWorker()
        let ledger = try temporaryLedger()
        let recorder = WorkerProgressRecorder()
        let first = makeAsset(id: "resume-complete")
        let second = makeAsset(id: "resume-unavailable")
        let record = AssetAnalysisRecord(
            assetID: first.id,
            sourceRevision: first.analysisRevision,
            status: .complete,
            fingerprint: FastWorkerAnalyzer.fingerprint(for: first),
            updatedAt: Date(),
            errorMessage: nil
        )
        let run = AnalysisRunRecord(
            id: UUID(),
            includesICloudItems: false,
            orderedAssetIDs: [first.id, second.id],
            completedAssetIDs: [first.id],
            status: .paused,
            startedAt: Date(),
            updatedAt: Date(),
            errorMessage: nil
        )
        try await ledger.createAnalysisRun(run)
        try await ledger.saveAnalysisRecord(record)
        try await ledger.checkpointAnalysisRun(
            id: run.id,
            status: .paused,
            nextPosition: 1,
            completedAssetCount: 1
        )
        let input = OrganizeAnalysisWorkerInput(
            includeICloudItems: false,
            orderedAssetIDs: [first.id, second.id],
            assetsByID: [first.id: first, second.id: second],
            sourceRevisionByAssetID: [first.id: first.sourceRevision, second.id: second.sourceRevision],
            analysisByAssetID: [first.id: record],
            analysisRun: run,
            nextPosition: 1
        )

        let result = try await worker.runAnalysis(
            input,
            ledger: ledger,
            analyzer: UnavailableWorkerAnalyzer()
        ) { update in
            await recorder.append(update)
        }

        let events = await recorder.events()
        XCTAssertEqual(events.first?.update.storage.processedAssetCount, 1)
        XCTAssertEqual(events.first?.update.storage.analyzedAssetCount, 1)
        XCTAssertEqual(events.first?.update.storage.totalKnownBytes, 1)
        XCTAssertEqual(result.storageProgress.processedAssetCount, 2)
        XCTAssertEqual(result.storageProgress.analyzedAssetCount, 1)
        XCTAssertEqual(result.storageProgress.unavailableAssetCount, 1)
        XCTAssertEqual(result.nextPosition, 2)
    }

    func testStorageProgressAlwaysContainsAllEightStableBuckets() async throws {
        let worker = OrganizeWorker()
        let ledger = try temporaryLedger()
        let plainPhoto = makeAsset(id: "plain-photo")
        let specialPhoto = makeAsset(
            id: "special-photo",
            subtypes: [.screenshot, .livePhoto, .raw],
            isFavorite: true,
            isEdited: true
        )
        let video = makeAsset(id: "video", mediaKind: .video)

        let result = try await worker.runAnalysis(
            analysisInput([plainPhoto, specialPhoto, video]),
            ledger: ledger,
            analyzer: FastWorkerAnalyzer()
        ) { _ in }

        let buckets = result.storageProgress.buckets
        XCTAssertEqual(buckets.map(\.bucketID), OrganizeStorageAnalysisBucketID.allCases)
        XCTAssertEqual(buckets.count, 8)
        let byID = Dictionary(uniqueKeysWithValues: buckets.map { ($0.bucketID, $0) })
        XCTAssertEqual(byID[.photos]?.itemCount, 2)
        XCTAssertEqual(byID[.screenshots]?.itemCount, 1)
        XCTAssertEqual(byID[.videos]?.itemCount, 1)
        XCTAssertEqual(byID[.live]?.itemCount, 1)
        XCTAssertEqual(byID[.raw]?.itemCount, 1)
        XCTAssertEqual(byID[.favorites]?.itemCount, 1)
        XCTAssertEqual(byID[.edited]?.itemCount, 1)
        XCTAssertEqual(byID[.noAlbum]?.itemCount, 3)
        for bucket in buckets {
            XCTAssertEqual(bucket.processedAssetCount, bucket.itemCount)
            XCTAssertEqual(bucket.analyzedAssetCount, bucket.itemCount)
            XCTAssertEqual(bucket.knownBytes, Int64(bucket.itemCount))
        }
    }

    func testAtomicAnalysisCommitRollsBackRecordAndMarksRunFailedWhenCursorWriteFails() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let databaseURL = directory.appending(path: "ledger.sqlite")
        let ledger = try SQLiteLedger(url: databaseURL)
        let worker = OrganizeWorker()
        let runIDs = WorkerRunIDRecorder()
        let progress = WorkerProgressRecorder()

        // Fail after the analysis-record upsert but before the cursor update can
        // commit. The worker's subsequent `.failed` checkpoint is deliberately
        // allowed so the test covers both transaction rollback and terminal state.
        let inspection = try DatabaseQueue(path: databaseURL.path)
        try await inspection.write { database in
            try database.execute(sql: """
                CREATE TRIGGER fail_analysis_cursor
                BEFORE UPDATE OF next_position ON organize_analysis_runs
                WHEN NEW.status = 'running' AND NEW.next_position > OLD.next_position
                BEGIN
                    SELECT RAISE(ABORT, 'injected analysis cursor failure');
                END;
                """)
        }

        let asset = makeAsset(id: "atomic-rollback")
        do {
            _ = try await worker.runAnalysis(
                analysisInput([asset]),
                ledger: ledger,
                analyzer: FastWorkerAnalyzer(),
                analysisRunIdentified: { runID, _, _ in await runIDs.record(runID) }
            ) { update in
                await progress.append(update)
            }
            XCTFail("The injected cursor failure must stop analysis")
        } catch {
            // Expected: persistence failures are surfaced to the coordinator.
        }

        let capturedRunID = await runIDs.value()
        let runID = try XCTUnwrap(capturedRunID)
        let storedRecords = try await ledger.analysisRecords()
        let storedProgress = try await ledger.analysisRunProgress(id: runID)
        let events = await progress.events()

        XCTAssertNil(storedRecords[asset.id], "The record upsert must roll back with its cursor update")
        XCTAssertEqual(storedProgress?.nextPosition, 0)
        XCTAssertEqual(storedProgress?.status, .failed)
        XCTAssertNotNil(storedProgress?.errorMessage)
        XCTAssertEqual(events.last?.presentation.phase, .failed)
        XCTAssertEqual(events.last?.update.storage.processedAssetCount, 0)
        XCTAssertEqual(events.last?.update.storage.analyzedAssetCount, 0)
        XCTAssertEqual(events.last?.update.storage.totalKnownBytes, 0)
        XCTAssertTrue(events.last?.update.storage.buckets.allSatisfy { $0.knownBytes == 0 } ?? false)
    }

    func testAnalysisRunIsNotAnnouncedUntilInitialRunRowIsDurable() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let databaseURL = directory.appending(path: "ledger.sqlite")
        let ledger = try SQLiteLedger(url: databaseURL)
        let worker = OrganizeWorker()
        let announcedRuns = WorkerRunIDRecorder()
        let inspection = try DatabaseQueue(path: databaseURL.path)
        try await inspection.write { database in
            try database.execute(sql: """
                CREATE TRIGGER fail_analysis_run_creation
                BEFORE INSERT ON organize_analysis_runs
                BEGIN
                    SELECT RAISE(ABORT, 'injected run creation failure');
                END;
                """)
        }

        do {
            _ = try await worker.runAnalysis(
                analysisInput([makeAsset(id: "durability-order")]),
                ledger: ledger,
                analyzer: FastWorkerAnalyzer(),
                analysisRunIdentified: { runID, _, _ in await announcedRuns.record(runID) }
            ) { _ in }
            XCTFail("The injected run creation failure must stop analysis")
        } catch {
            // Expected.
        }

        let announcedRunID = await announcedRuns.value()
        let activeRunID = await worker.activeAnalysisRunIdentifier()
        XCTAssertNil(announcedRunID)
        XCTAssertNil(activeRunID)
    }

    func testRecentlyDeletedQueueDeltaIsAtomicAndRollsBackRemovalsWhenAnUpsertFails() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let databaseURL = directory.appending(path: "ledger.sqlite")
        let ledger = try SQLiteLedger(url: databaseURL)
        let retained = queueItem(id: "retained")
        let removed = queueItem(id: "removed")
        let inserted = queueItem(id: "inserted")
        try await ledger.replaceRecentlyDeletedQueue([retained, removed])

        try await ledger.applyRecentlyDeletedQueueDelta(
            upserts: [inserted],
            removals: [removed.assetID]
        )
        let successfulDeltaQueue = try await ledger.recentlyDeletedQueue()
        XCTAssertEqual(
            Set(successfulDeltaQueue.map(\.assetID)),
            [retained.assetID, inserted.assetID]
        )

        let inspection = try DatabaseQueue(path: databaseURL.path)
        try await inspection.write { database in
            try database.execute(sql: """
                CREATE TRIGGER fail_queue_delta_upsert
                BEFORE INSERT ON organize_deletion_queue
                WHEN NEW.asset_id = 'injected-failure'
                BEGIN
                    SELECT RAISE(ABORT, 'injected queue delta failure');
                END;
                """)
        }

        do {
            try await ledger.applyRecentlyDeletedQueueDelta(
                upserts: [queueItem(id: "injected-failure")],
                removals: [inserted.assetID]
            )
            XCTFail("The injected upsert failure must abort the queue delta")
        } catch {
            // Expected. The removal ran first inside the same transaction and must roll back.
        }
        let rolledBackQueue = try await ledger.recentlyDeletedQueue()
        XCTAssertEqual(
            Set(rolledBackQueue.map(\.assetID)),
            [retained.assetID, inserted.assetID]
        )
    }

    func testSingleAnalysisResultInFiftyThousandAssetRunDoesNotRebuildPresentationAndMainActorResponds() async throws {
        let worker = OrganizeWorker()
        let ledger = try temporaryLedger()
        let assets = (0..<50_000).map { makeAsset(id: String(format: "analysis-%05d", $0)) }
        let orderedIDs = assets.map(\.id)
        let resumePosition = orderedIDs.count - 2
        let run = AnalysisRunRecord(
            id: UUID(),
            includesICloudItems: false,
            orderedAssetIDs: orderedIDs,
            completedAssetIDs: [],
            status: .paused,
            startedAt: Date(),
            updatedAt: Date(),
            errorMessage: nil
        )
        try await ledger.createAnalysisRun(run)
        try await ledger.checkpointAnalysisRun(
            id: run.id,
            status: .paused,
            nextPosition: resumePosition
        )

        // Establish a nonzero baseline so the assertion also verifies that the
        // presentation-build instrumentation is connected to the real builder.
        _ = try await worker.presentation(for: emptyPresentationInput(revision: 1))
        let baseline = await worker.instrumentation()
        XCTAssertEqual(baseline.presentationBuildInvocationCount, 1)
        XCTAssertEqual(baseline.committedAnalysisRecordCount, 0)

        let analyzer = FirstThenBlockingWorkerAnalyzer()
        let input = OrganizeAnalysisWorkerInput(
            includeICloudItems: false,
            orderedAssetIDs: orderedIDs,
            assetsByID: Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) }),
            sourceRevisionByAssetID: Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0.sourceRevision) }),
            analysisByAssetID: [:],
            analysisRun: run,
            nextPosition: resumePosition
        )
        let heartbeat = await MainActor.run { MainActorHeartbeat() }
        let heartbeatTask = Task { @MainActor in
            while !Task.isCancelled {
                heartbeat.tick()
                await Task.yield()
            }
        }
        let analysisTask = Task {
            try await worker.runAnalysis(input, ledger: ledger, analyzer: analyzer) { _ in }
        }

        // Entering the second analyzer call proves the first result and cursor
        // transaction completed while the 50k-item analysis lease remains held.
        await analyzer.waitUntilSecondRequestStarts()
        let instrumentation = await worker.instrumentation()
        let durableCursor = try? await ledger.analysisNextPosition(runID: run.id)
        let records = try? await ledger.analysisRecords()
        let interactionCount = await MainActor.run {
            heartbeat.tick()
            return heartbeat.count()
        }

        XCTAssertEqual(instrumentation.committedAnalysisRecordCount, 1)
        XCTAssertEqual(
            instrumentation.presentationBuildInvocationCount,
            baseline.presentationBuildInvocationCount,
            "An individual analysis result must not invoke the whole-library presentation builder"
        )
        XCTAssertEqual(durableCursor, resumePosition + 1)
        XCTAssertEqual(records?[orderedIDs[resumePosition]]?.status, .complete)
        XCTAssertGreaterThan(interactionCount, 0, "MainActor interaction must complete while analysis remains in flight")

        analysisTask.cancel()
        await analyzer.releaseSecondRequest()
        let paused = try await analysisTask.value
        heartbeatTask.cancel()
        XCTAssertEqual(paused.presentation.phase, .paused)
    }

    func testSupersededFiftyThousandAssetBrowseCancelsAndMainActorKeepsTicking() async throws {
        let worker = OrganizeWorker()
        let assets = (0..<50_000).map { makePresentation(index: $0) }
        var configuration = OrganizeBrowseConfiguration()
        configuration.sort = .filename
        configuration.grouping = .none
        let firstQuery = BrowseQuery(
            revision: 1,
            sequence: 1,
            scopeKey: "all-v1",
            scopeAssetIDs: nil,
            configuration: configuration
        )
        let secondIDs = Set(assets.prefix(12).map(\.id))
        let secondQuery = BrowseQuery(
            revision: 2,
            sequence: 2,
            scopeKey: "first-twelve-v2",
            scopeAssetIDs: secondIDs,
            configuration: configuration
        )
        let heartbeat = await MainActor.run { MainActorHeartbeat() }
        let heartbeatTask = Task { @MainActor in
            while !Task.isCancelled {
                heartbeat.tick()
                await Task.yield()
            }
        }

        let first = Task { try await worker.browse(firstQuery, assets: assets) }
        try await Task.sleep(for: .milliseconds(2))
        let second = try await worker.browse(secondQuery, assets: assets)
        heartbeatTask.cancel()

        do {
            _ = try await first.value
            XCTFail("The superseded browse generation must not publish")
        } catch is CancellationError {
            // Expected: the second query owns the worker's current generation.
        }
        XCTAssertEqual(second.query, secondQuery)
        XCTAssertEqual(second.sections.flatMap(\.assets).count, secondIDs.count)
        let heartbeatCount = await heartbeat.count()
        XCTAssertGreaterThan(heartbeatCount, 0)
    }

    func testBrowseDateSectionsAreChronologicalAcrossYearsAndRespectDirection() async throws {
        let worker = OrganizeWorker()
        let calendar = Calendar.current
        let december2023 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2023, month: 12, day: 15, hour: 12)))
        let april2024 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 4, day: 15, hour: 12)))
        let august2024 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2024, month: 8, day: 15, hour: 12)))
        let january2025 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 1, day: 15, hour: 12)))
        let assets = [
            makePresentation(index: 1, creationDate: april2024),
            makePresentation(index: 2, creationDate: january2025),
            makePresentation(index: 3, creationDate: december2023),
            makePresentation(index: 4, creationDate: august2024),
            makePresentation(index: 5, creationDate: nil)
        ]

        var configuration = OrganizeBrowseConfiguration()
        configuration.grouping = .month
        configuration.direction = .descending
        let descendingMonths = try await worker.browse(
            BrowseQuery(
                revision: 1,
                sequence: 1,
                scopeKey: "all",
                scopeAssetIDs: nil,
                configuration: configuration
            ),
            assets: assets
        )
        XCTAssertEqual(
            descendingMonths.sections.compactMap(\.title),
            [
                january2025.formatted(.dateTime.month(.wide).year()),
                august2024.formatted(.dateTime.month(.wide).year()),
                april2024.formatted(.dateTime.month(.wide).year()),
                december2023.formatted(.dateTime.month(.wide).year()),
                "Date Unknown"
            ]
        )

        configuration.grouping = .year
        configuration.direction = .ascending
        let ascendingYears = try await worker.browse(
            BrowseQuery(
                revision: 1,
                sequence: 2,
                scopeKey: "all",
                scopeAssetIDs: nil,
                configuration: configuration
            ),
            assets: assets
        )
        XCTAssertEqual(
            ascendingYears.sections.compactMap(\.title),
            [
                december2023.formatted(.dateTime.year()),
                april2024.formatted(.dateTime.year()),
                january2025.formatted(.dateTime.year()),
                "Date Unknown"
            ]
        )
    }

    func testCanonicalGestureMutationRejectsInFlightBrowseAndPresentation() async throws {
        let worker = OrganizeWorker()
        let assets = (0..<30_000).map { makeAsset(id: String(format: "canonical-%05d", $0)) }
        let indexed = try await worker.index(
            assets: assets,
            albums: [],
            analysisByAssetID: [:],
            reviewStateByAssetID: [:],
            queueItems: [],
            reviewSessions: [],
            protectedAlbums: []
        )
        _ = try await worker.presentation(for: presentationInput(revision: 1, indexed: indexed))

        var configuration = OrganizeBrowseConfiguration()
        configuration.sort = .filename
        configuration.grouping = .none
        let query = BrowseQuery(
            revision: 1,
            sequence: 1,
            scopeKey: "all",
            scopeAssetIDs: nil,
            configuration: configuration
        )
        let browse = Task { try await worker.browse(query) }
        try await Task.sleep(for: .milliseconds(1))
        _ = await worker.mutateSelection(.toggle(assetID: assets[0].id))
        do {
            _ = try await browse.value
            XCTFail("A browse result captured before a canonical gesture must not publish")
        } catch is CancellationError {
            // Expected.
        }

        let nextPresentationInput = presentationInput(revision: 2, indexed: indexed)
        let presentation = Task {
            try await worker.presentation(for: nextPresentationInput)
        }
        try await Task.sleep(for: .milliseconds(1))
        _ = await worker.mutateSelection(.toggle(assetID: assets[1].id))
        do {
            _ = try await presentation.value
            XCTFail("A presentation captured before a canonical gesture must not publish")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testKeepQueuedAssetUpdatesCanonicalReviewAndQueueStateTogether() async throws {
        let worker = OrganizeWorker()
        let asset = makeAsset(id: "queued-keep")
        let item = DeletionQueueItem(
            assetID: asset.id,
            sourceRevision: asset.sourceRevision,
            recommendationKind: .screenshots,
            queuedAt: Date(timeIntervalSince1970: 1_000),
            protectionOverride: false,
            reviewSessionID: nil
        )
        let indexed = try await worker.index(
            assets: [asset],
            albums: [],
            analysisByAssetID: [:],
            reviewStateByAssetID: [:],
            queueItems: [item],
            reviewSessions: [],
            protectedAlbums: []
        )
        let initial = try await worker.presentation(
            for: presentationInput(revision: 1, indexed: indexed)
        )
        XCTAssertEqual(initial.queuedAssetIDs, [asset.id])
        XCTAssertEqual(initial.assets.first?.isReviewed, false)

        let mutation = try await worker.markQueuedAssetReviewedAndRemove(assetID: asset.id)
        XCTAssertEqual(mutation.assetID, asset.id)
        XCTAssertTrue(mutation.isReviewed)
        XCTAssertTrue(mutation.queue.queuedAssetIDs.isEmpty)

        let refreshed = try await worker.presentation(
            for: presentationInput(revision: 2, indexed: indexed)
        )
        XCTAssertTrue(refreshed.queuedAssetIDs.isEmpty)
        XCTAssertEqual(refreshed.assets.first?.isReviewed, true)
    }

    func testOlderIndexGenerationCannotReplaceNewerCanonicalState() async throws {
        let worker = OrganizeWorker()
        let newerAsset = makeAsset(id: "newer")
        let newer = try await worker.index(
            assets: [newerAsset],
            albums: [],
            analysisByAssetID: [:],
            reviewStateByAssetID: [:],
            queueItems: [],
            reviewSessions: [],
            protectedAlbums: [],
            requestGeneration: 2
        )

        do {
            _ = try await worker.index(
                assets: [makeAsset(id: "older")],
                albums: [],
                analysisByAssetID: [:],
                reviewStateByAssetID: [:],
                queueItems: [],
                reviewSessions: [],
                protectedAlbums: [],
                requestGeneration: 1
            )
            XCTFail("An older refresh must not replace newer worker-owned index state")
        } catch is CancellationError {
            // Expected.
        }

        let snapshot = try await worker.presentation(
            for: presentationInput(revision: 1, indexed: newer)
        )
        XCTAssertEqual(snapshot.assets.map(\.id), [newerAsset.id])
    }

    func testOlderPersistenceCompletionCannotRegressNewerQueueOrReviewPresentation() async throws {
        let worker = OrganizeWorker()
        let ledger = try temporaryLedger()
        let assets = [makeAsset(id: "gesture-1"), makeAsset(id: "gesture-2")]
        let indexed = try await worker.index(
            assets: assets,
            albums: [],
            analysisByAssetID: [:],
            reviewStateByAssetID: [:],
            queueItems: [],
            reviewSessions: [],
            protectedAlbums: []
        )
        _ = try await worker.presentation(for: presentationInput(revision: 1, indexed: indexed))

        _ = try await worker.queueSelection(
            requestedIDs: [assets[0].id],
            allowProtected: false,
            recommendationKind: .unreviewed
        )
        _ = try await worker.removeQueueAssets(assetIDs: [assets[0].id])
        _ = try await worker.applyQueueDelta(
            .upsert(
                assetIDs: [assets[0].id],
                recommendationKind: .unreviewed,
                allowProtected: false
            ),
            ledger: ledger
        )

        let optionalSession = await worker.beginReview(recommendationKind: .unreviewed)
        let session = try XCTUnwrap(optionalSession)
        let initialPersistedSession = await worker.domainReviewSession(from: session, previous: nil)
        try await ledger.saveReviewSession(initialPersistedSession)
        let optionalFirst = try await worker.applyReviewChoice(
            OrganizeReviewChoiceMutationRequest(
                sessionID: session.id,
                choice: .keep,
                allowProtected: false
            )
        )
        let first = try XCTUnwrap(optionalFirst)
        let optionalSecond = try await worker.applyReviewChoice(
            OrganizeReviewChoiceMutationRequest(
                sessionID: session.id,
                choice: .later,
                allowProtected: false
            )
        )
        _ = try XCTUnwrap(optionalSecond)
        let persistedSession = await worker.domainReviewSession(from: first.session, previous: nil)
        let persistedAction = ReviewAction(
            id: first.action.id,
            sessionID: session.id,
            sequence: 0,
            assetID: first.assetID,
            decision: .keep,
            previousDecision: nil,
            cursorBefore: first.action.previousIndex,
            cursorAfter: first.session.currentIndex,
            createdAt: Date(),
            wasQueued: first.action.wasQueued,
            wasReviewed: first.action.wasReviewed
        )
        let state = AssetReviewStateRecord(
            assetID: first.assetID,
            sourceRevision: assets[0].sourceRevision,
            state: .kept,
            recommendationKind: .unreviewed,
            updatedAt: Date()
        )
        _ = try await worker.persistReviewMutation(
            session: persistedSession,
            action: .append(persistedAction),
            state: .upsert(state),
            queue: .remove(assetID: first.assetID),
            ledger: ledger
        )

        let snapshot = try await worker.presentation(
            for: presentationInput(revision: 2, indexed: indexed)
        )
        XCTAssertTrue(snapshot.queuedAssetIDs.isEmpty)
        XCTAssertEqual(snapshot.activeReviewSession?.currentIndex, 2)
        XCTAssertEqual(snapshot.reviewDecisionAssetIDs[.keep], [assets[0].id])
        XCTAssertEqual(snapshot.reviewDecisionAssetIDs[.later], [assets[1].id])
    }

    func testPresentationBuildsDecideLaterStackFromLatestDurableSessionDecision() async throws {
        let worker = OrganizeWorker()
        let oldest = makeAsset(
            id: "oldest-later",
            creationDate: Date(timeIntervalSince1970: 100)
        )
        let superseded = makeAsset(
            id: "superseded-later",
            creationDate: Date(timeIntervalSince1970: 200)
        )
        var firstSession = ReviewSession(
            recommendationKind: .unreviewed,
            orderedAssetIDs: [oldest.id, superseded.id],
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        _ = firstSession.apply(.later, at: Date(timeIntervalSince1970: 1_001))
        _ = firstSession.apply(.later, at: Date(timeIntervalSince1970: 1_002))
        var laterSession = ReviewSession(
            recommendationKind: .decideLater,
            orderedAssetIDs: [superseded.id],
            createdAt: Date(timeIntervalSince1970: 2_000)
        )
        _ = laterSession.apply(.keep, at: Date(timeIntervalSince1970: 2_001))

        let indexed = try await worker.index(
            assets: [superseded, oldest],
            albums: [],
            analysisByAssetID: [:],
            reviewStateByAssetID: [:],
            queueItems: [],
            reviewSessions: [firstSession, laterSession],
            protectedAlbums: []
        )
        let snapshot = try await worker.presentation(
            for: presentationInput(revision: 1, indexed: indexed)
        )
        let decideLater = snapshot.reviewRecommendations.first { $0.kind == .decideLater }

        XCTAssertEqual(decideLater?.assetIDs, [oldest.id])
        XCTAssertEqual(decideLater?.destination, .review)
    }

    func testPresentationBuildsExplainableGuardedVisualReviewStacks() async throws {
        let worker = OrganizeWorker()
        let document = makeAsset(id: "document-reference")
        let utility = makeAsset(id: "utility-capture")
        let indexed = try await worker.index(
            assets: [document, utility],
            albums: [],
            analysisByAssetID: [:],
            reviewStateByAssetID: [:],
            queueItems: [],
            reviewSessions: [],
            protectedAlbums: []
        )
        let records = [
            document.id: visualRecord(
                for: document,
                textObservationCount: 6,
                textCoverage: 0.35,
                containsBarcode: true
            ),
            utility.id: visualRecord(
                for: utility,
                aesthetics: -0.75,
                isUtility: true,
                noClearSubject: true,
                lensSmudgeConfidence: 0.8
            )
        ]

        let snapshot = try await worker.presentation(
            for: presentationInput(
                revision: 1,
                indexed: indexed,
                visualAnalysisByAssetID: records
            )
        )
        let byKind = Dictionary(uniqueKeysWithValues: snapshot.reviewRecommendations.map {
            ($0.kind, $0)
        })

        XCTAssertEqual(byKind[.textHeavyDocuments]?.assetIDs, [document.id])
        XCTAssertEqual(byKind[.worthReviewing]?.assetIDs, [utility.id])
        XCTAssertEqual(byKind[.noClearSubject]?.assetIDs, [utility.id])
        XCTAssertEqual(byKind[.smudgedCaptures]?.assetIDs, [utility.id])
        XCTAssertTrue(
            try XCTUnwrap(byKind[.textHeavyDocuments]?.evidenceByAssetID[document.id])
                .contains("Recognized words were not saved")
        )
        XCTAssertEqual(snapshot.assets.first { $0.id == document.id }?.isProtected, true)

        _ = await worker.protectedAlbumPresentationMutation(
            OrganizeProtectedAlbumPersistenceDelta(
                generation: 1,
                albumID: "unrelated-album",
                isProtected: true
            )
        )
        let guardedQueue = try await worker.queueSelection(
            requestedIDs: [document.id],
            allowProtected: false,
            recommendationKind: .textHeavyDocuments
        )
        XCTAssertEqual(guardedQueue.protectedAssets.map(\.id), [document.id])
        XCTAssertTrue(guardedQueue.queuedAssetIDs.isEmpty)

        let optionalSession = await worker.beginReview(
            recommendationKind: .textHeavyDocuments
        )
        let session = try XCTUnwrap(optionalSession)
        XCTAssertEqual(session.recommendationKind, .textHeavyDocuments)
        XCTAssertEqual(
            session.evidenceByAssetID[document.id],
            byKind[.textHeavyDocuments]?.evidenceByAssetID[document.id]
        )
        let durable = await worker.domainReviewSession(from: session, previous: nil)
        XCTAssertEqual(durable.recommendationKind, .textHeavyDocuments)
    }

    func testEditedRawAndDurablyKeptAssetsRequireOverrideWhileLivePhotoRemainsUnlocked() async throws {
        let worker = OrganizeWorker()
        let edited = makeAsset(id: "edited", isEdited: true)
        let raw = makeAsset(id: "raw", subtypes: [.raw])
        let live = makeAsset(id: "live", subtypes: [.livePhoto])
        let kept = makeAsset(id: "kept")
        let keptState = AssetReviewStateRecord(
            assetID: kept.id,
            sourceRevision: kept.sourceRevision,
            state: .kept,
            recommendationKind: .unreviewed,
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )
        let protectedIDs: Set<String> = [edited.id, raw.id, kept.id]
        let indexed = try await worker.index(
            assets: [edited, raw, live, kept],
            albums: [],
            analysisByAssetID: [:],
            reviewStateByAssetID: [kept.id: keptState],
            queueItems: [],
            reviewSessions: [],
            protectedAlbums: []
        )

        XCTAssertEqual(indexed.protectedAssetIDs, protectedIDs)
        let snapshot = try await worker.presentation(
            for: presentationInput(revision: 1, indexed: indexed)
        )
        XCTAssertEqual(
            Set(snapshot.assets.filter(\.isProtected).map(\.id)),
            protectedIDs
        )
        let presentedLive = try XCTUnwrap(snapshot.assets.first { $0.id == live.id })
        XCTAssertFalse(presentedLive.isProtected)
        XCTAssertNil(presentedLive.protectionSummary)

        let queue = try await worker.queueSelection(
            requestedIDs: protectedIDs,
            allowProtected: false,
            recommendationKind: .unreviewed
        )
        XCTAssertEqual(Set(queue.protectedAssets.map(\.id)), protectedIDs)
        XCTAssertTrue(queue.queuedAssetIDs.isEmpty)

        let liveQueue = try await worker.queueSelection(
            requestedIDs: [live.id],
            allowProtected: false,
            recommendationKind: .unreviewed
        )
        XCTAssertTrue(liveQueue.protectedAssets.isEmpty)
        XCTAssertEqual(liveQueue.queuedAssetIDs, [live.id])
    }

    private func temporaryLedger() throws -> SQLiteLedger {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        return try SQLiteLedger(url: directory.appending(path: "ledger.sqlite"))
    }

    private func analysisInput(
        _ assets: [PhotoAsset],
        origin: AnalysisRunOrigin = .userInitiated
    ) -> OrganizeAnalysisWorkerInput {
        OrganizeAnalysisWorkerInput(
            includeICloudItems: false,
            orderedAssetIDs: assets.map(\.id),
            assetsByID: Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) }),
            sourceRevisionByAssetID: Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0.sourceRevision) }),
            analysisByAssetID: [:],
            analysisRun: nil,
            nextPosition: 0,
            origin: origin
        )
    }

    private func emptyPresentationInput(revision: UInt64) -> OrganizePresentationInput {
        OrganizePresentationInput(
            revision: revision,
            authorization: .authorized,
            assets: [],
            albums: [],
            albumIDsByAssetID: [:],
            sourceRevisionByAssetID: [:],
            analysisByAssetID: [:],
            visualAnalysisByAssetID: [:],
            analysisRun: nil,
            reviewStateByAssetID: [:],
            queueByAssetID: [:],
            reviewSessionsByID: [:],
            protectedAlbumIDs: [],
            protectedAssetIDs: [],
            deletionBatches: [],
            deletedItems: [],
            activeReviewSessionOverride: nil,
            analysisOverride: nil,
            selectedAssetIDs: []
        )
    }

    private func presentationInput(
        revision: UInt64,
        indexed: OrganizeIndexedState,
        visualAnalysisByAssetID: [String: VisualAnalysisRecord] = [:]
    ) -> OrganizePresentationInput {
        OrganizePresentationInput(
            revision: revision,
            authorization: .authorized,
            assets: indexed.orderedAssets,
            albums: [],
            albumIDsByAssetID: indexed.albumIDsByAssetID,
            sourceRevisionByAssetID: indexed.sourceRevisionByAssetID,
            analysisByAssetID: indexed.analysisByAssetID,
            visualAnalysisByAssetID: visualAnalysisByAssetID,
            analysisRun: nil,
            reviewStateByAssetID: indexed.reviewStateByAssetID,
            queueByAssetID: indexed.queueByAssetID,
            reviewSessionsByID: indexed.reviewSessionsByID,
            protectedAlbumIDs: indexed.protectedAlbumIDs,
            protectedAssetIDs: indexed.protectedAssetIDs,
            deletionBatches: [],
            deletedItems: [],
            activeReviewSessionOverride: nil,
            analysisOverride: nil,
            selectedAssetIDs: []
        )
    }

    private func makeAsset(
        id: String,
        creationDate: Date? = Date(timeIntervalSince1970: 1_000),
        modificationDate: Date? = nil,
        mediaKind: MediaKind = .photo,
        subtypes: Set<AssetMediaSubtype> = [],
        pixelWidth: Int = 2_000,
        pixelHeight: Int = 1_500,
        durationMilliseconds: Int? = nil,
        isFavorite: Bool = false,
        isEdited: Bool = false
    ) -> PhotoAsset {
        PhotoAsset(
            id: id,
            mediaKind: mediaKind,
            mediaSubtypes: subtypes,
            creationDate: creationDate,
            modificationDate: modificationDate,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            durationMilliseconds: durationMilliseconds,
            location: nil,
            isFavorite: isFavorite,
            isEdited: isEdited,
            resources: [
                PhotoResourceDescriptor(
                    id: "\(id)-resource",
                    kind: mediaKind == .video ? .video : .photo,
                    originalFilename: mediaKind == .video ? "\(id).mov" : "\(id).heic",
                    uniformTypeIdentifier: mediaKind == .video ? "public.movie" : "public.heic"
                )
            ]
        )
    }

    private func visualRecord(
        for asset: PhotoAsset,
        aesthetics: Float? = nil,
        isUtility: Bool = false,
        textObservationCount: Int = 0,
        textCoverage: Double = 0,
        containsBarcode: Bool = false,
        noClearSubject: Bool = false,
        lensSmudgeConfidence: Float? = nil
    ) -> VisualAnalysisRecord {
        VisualAnalysisRecord(
            assetID: asset.id,
            sourceRevision: asset.analysisRevision,
            algorithmVersion: VisualAnalysisAlgorithm.currentVersion,
            visionRevisions: .pinnedV1,
            featurePrint: nil,
            aesthetics: aesthetics.map {
                VisualAestheticsResult(overallScore: $0, isUtility: isUtility)
            },
            faces: VisualFaceResult(count: 0, bestCaptureQuality: nil),
            text: VisualTextStatistics(
                observationCount: textObservationCount,
                normalizedCoverage: textCoverage
            ),
            containsBarcode: containsBarcode,
            saliency: noClearSubject
                ? VisualSaliencyResult(
                    salientObjectCount: 0,
                    maximumValue: nil,
                    noClearSubject: true
                )
                : nil,
            lensSmudge: lensSmudgeConfidence.map {
                VisualLensSmudgeResult(confidence: $0)
            },
            analyzedAt: Date(timeIntervalSince1970: 2_000)
        )
    }

    private func queueItem(id: String) -> DeletionQueueItem {
        DeletionQueueItem(
            assetID: id,
            sourceRevision: "revision-\(id)",
            recommendationKind: .screenshots,
            queuedAt: Date(timeIntervalSince1970: 1_000),
            protectionOverride: false,
            reviewSessionID: nil
        )
    }

    private func makePresentation(index: Int) -> OrganizeAssetPresentation {
        makePresentation(
            index: index,
            creationDate: Date(timeIntervalSince1970: TimeInterval(index))
        )
    }

    private func makePresentation(
        index: Int,
        creationDate: Date?
    ) -> OrganizeAssetPresentation {
        let id = String(format: "asset-%05d", index)
        return OrganizeAssetPresentation(
            id: id,
            originalFilename: String(format: "image-%05d.heic", 50_000 - index),
            mediaKind: .photo,
            creationDate: creationDate,
            modificationDate: nil,
            addedDate: nil,
            pixelWidth: 2_000,
            pixelHeight: 1_500,
            durationMilliseconds: nil,
            knownBytes: Int64(index),
            albumIDs: [],
            albumNames: [],
            fileFormat: "heic",
            sourceRevision: "revision-\(index)",
            burstIdentifier: nil,
            hasLocation: false,
            isFavorite: false,
            isHidden: false,
            isEdited: false,
            isLivePhoto: false,
            isRAW: false,
            isScreenshot: false,
            isProtected: false,
            isReviewed: false,
            analysisState: .analyzed
        )
    }
}

private actor BlockingWorkerAnalyzer: AssetResourceAnalyzing {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func analyze(
        asset: PhotoAsset,
        includeNetwork: Bool,
        progress: @escaping @Sendable (AssetAnalysisProgress) -> Void
    ) async throws -> AssetFingerprint {
        started = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { releaseContinuation = $0 }
        try Task.checkCancellation()
        return FastWorkerAnalyzer.fingerprint(for: asset)
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private struct FastWorkerAnalyzer: AssetResourceAnalyzing {
    func analyze(
        asset: PhotoAsset,
        includeNetwork: Bool,
        progress: @escaping @Sendable (AssetAnalysisProgress) -> Void
    ) async throws -> AssetFingerprint {
        Self.fingerprint(for: asset)
    }

    static func fingerprint(for asset: PhotoAsset) -> AssetFingerprint {
        AssetFingerprint(
            assetID: asset.id,
            sourceRevision: asset.analysisRevision,
            resources: [ResourceFingerprint(kind: .photo, byteCount: 1, sha256: asset.id)],
            analyzedAt: Date()
        )
    }
}

private struct UnavailableWorkerAnalyzer: AssetResourceAnalyzing {
    func analyze(
        asset: PhotoAsset,
        includeNetwork: Bool,
        progress: @escaping @Sendable (AssetAnalysisProgress) -> Void
    ) async throws -> AssetFingerprint {
        throw OrganizePhotoServiceError.networkAccessRequired(
            asset.resources.first?.originalFilename ?? asset.id
        )
    }
}

private struct FailingWorkerAnalyzer: AssetResourceAnalyzing {
    func analyze(
        asset: PhotoAsset,
        includeNetwork: Bool,
        progress: @escaping @Sendable (AssetAnalysisProgress) -> Void
    ) async throws -> AssetFingerprint {
        throw OrganizePhotoServiceError.requestFailed("Injected analysis failure")
    }
}

private struct ProgressiveWorkerAnalyzer: AssetResourceAnalyzing {
    func analyze(
        asset: PhotoAsset,
        includeNetwork: Bool,
        progress: @escaping @Sendable (AssetAnalysisProgress) -> Void
    ) async throws -> AssetFingerprint {
        progress(AssetAnalysisProgress(
            assetID: asset.id,
            completedResourceCount: 0,
            totalResourceCount: 1,
            currentResourceKind: asset.resources.first?.kind,
            currentResourceProgress: 0.35
        ))
        try await Task.sleep(for: .milliseconds(160))
        progress(AssetAnalysisProgress(
            assetID: asset.id,
            completedResourceCount: 0,
            totalResourceCount: 1,
            currentResourceKind: asset.resources.first?.kind,
            currentResourceProgress: 0.8
        ))
        try await Task.sleep(for: .milliseconds(160))
        return FastWorkerAnalyzer.fingerprint(for: asset)
    }
}

private actor CountingWorkerAnalyzer: AssetResourceAnalyzing {
    private var count = 0

    func analyze(
        asset: PhotoAsset,
        includeNetwork: Bool,
        progress: @escaping @Sendable (AssetAnalysisProgress) -> Void
    ) async throws -> AssetFingerprint {
        count += 1
        return FastWorkerAnalyzer.fingerprint(for: asset)
    }

    func invocationCount() -> Int { count }
}

private actor FirstThenBlockingWorkerAnalyzer: AssetResourceAnalyzing {
    private var requestCount = 0
    private var secondRequestStarted = false
    private var secondRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func analyze(
        asset: PhotoAsset,
        includeNetwork: Bool,
        progress: @escaping @Sendable (AssetAnalysisProgress) -> Void
    ) async throws -> AssetFingerprint {
        requestCount += 1
        guard requestCount > 1 else { return FastWorkerAnalyzer.fingerprint(for: asset) }
        secondRequestStarted = true
        for waiter in secondRequestWaiters { waiter.resume() }
        secondRequestWaiters.removeAll()
        await withCheckedContinuation { releaseContinuation = $0 }
        try Task.checkCancellation()
        return FastWorkerAnalyzer.fingerprint(for: asset)
    }

    func waitUntilSecondRequestStarts() async {
        guard !secondRequestStarted else { return }
        await withCheckedContinuation { secondRequestWaiters.append($0) }
    }

    func releaseSecondRequest() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor WorkerProgressRecorder {
    struct Event: Sendable {
        let date: Date
        let update: OrganizeAnalysisProgressUpdate

        var presentation: OrganizeAnalysisPresentation { update.presentation }
    }

    private var recorded: [Event] = []

    func append(_ update: OrganizeAnalysisProgressUpdate) {
        recorded.append(Event(date: Date(), update: update))
    }

    func events() -> [Event] { recorded }
}

private actor WorkerRunIDRecorder {
    private var runID: UUID?

    func record(_ runID: UUID) { self.runID = runID }
    func value() -> UUID? { runID }
}

@MainActor
private final class MainActorHeartbeat {
    private var value = 0

    func tick() { value += 1 }
    func count() -> Int { value }
}
