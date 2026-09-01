@testable import MBPhotos
import UIKit
import XCTest

@MainActor
final class OrganizeViewModelSafetyTests: XCTestCase {
    func testAutoAnalyzeDefaultsOnAndPersistsTheUserChoice() {
        let suiteName = "OrganizeViewModelSafetyTests.autoAnalyze.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = OrganizeViewModel(settingsDefaults: defaults)
        XCTAssertTrue(model.autoAnalyzeEnabled)

        model.setAutoAnalyzeEnabled(false)

        XCTAssertFalse(model.autoAnalyzeEnabled)
        XCTAssertFalse(OrganizeViewModel(settingsDefaults: defaults).autoAnalyzeEnabled)
    }

    func testAnalysisFractionTracksProcessedWorkAndCurrentAsset() {
        let presentation = OrganizeAnalysisPresentation(
            phase: .running,
            processedAssetCount: 2,
            completedAssetCount: 0,
            totalAssetCount: 4,
            currentAssetFraction: 0.5,
            unavailableAssetCount: 2,
            failedAssetCount: 0,
            includesICloudItems: false,
            statusText: "Analyzing"
        )

        XCTAssertEqual(presentation.fractionComplete, 0.625, accuracy: 0.000_001)
    }

    func testBreakdownMetricPendingCountUsesProcessedAssets() {
        let metric = OrganizeBreakdownMetric(
            id: "photos",
            title: "Photos",
            systemImage: "photo",
            itemCount: 5,
            knownBytes: 42,
            processedAssetCount: 3,
            analyzedAssetCount: 1,
            unavailableAssetCount: 1,
            failedAssetCount: 1,
            tint: .blue,
            overlapsPrimaryCategories: false
        )

        XCTAssertEqual(metric.pendingAssetCount, 2)
        XCTAssertTrue(metric.hasPendingAnalysis)
    }

    func testBreakdownPresentationOmitsEmptyDetailsAndSortsKnownSizeStably() {
        func metric(_ id: String, itemCount: Int, knownBytes: Int64) -> OrganizeBreakdownMetric {
            OrganizeBreakdownMetric(
                id: id,
                title: id,
                systemImage: "photo",
                itemCount: itemCount,
                knownBytes: knownBytes,
                tint: .gray,
                overlapsPrimaryCategories: true
            )
        }

        let metrics = [
            metric("live", itemCount: 2, knownBytes: 200),
            metric("raw", itemCount: 0, knownBytes: 5_000),
            metric("favorites", itemCount: 1, knownBytes: 200),
            metric("edited", itemCount: 1, knownBytes: 300)
        ]

        let presented = OrganizeBreakdownPresentation.metricsByKnownSize(
            metrics,
            omittingEmpty: true
        )

        XCTAssertEqual(presented.map(\.id), ["edited", "live", "favorites"])
    }

    func testScreenshotsAppearInDetailedBreakdownAndPhotoTotal() async {
        let model = await makeModel(assets: [
            asset(id: "screenshot", subtypes: [.screenshot]),
            asset(id: "regular-photo")
        ])

        let photos = model.primaryBreakdown.first { $0.id == "photos" }
        let screenshots = model.primaryBreakdown.first { $0.id == "screenshots" }
        let detailedScreenshots = model.secondaryBreakdown.first { $0.id == "screenshots" }

        XCTAssertEqual(photos?.itemCount, 2)
        XCTAssertNil(screenshots)
        XCTAssertEqual(detailedScreenshots?.itemCount, 1)
        XCTAssertTrue(detailedScreenshots?.overlapsPrimaryCategories == true)
    }

    func testAbsoluteAnalysisProgressUpdatesSmallStoragePresentationInPlace() async {
        let model = await makeModel(assets: [
            asset(
                id: "incremental",
                subtypes: [.livePhoto, .raw],
                isFavorite: true,
                isEdited: true
            )
        ])
        let revision = model.presentationRevision
        let originalAsset = model.assets.first
        let presentation = OrganizeAnalysisPresentation(
            phase: .running,
            processedAssetCount: 1,
            completedAssetCount: 1,
            totalAssetCount: 1,
            currentAssetFraction: 0,
            unavailableAssetCount: 0,
            failedAssetCount: 0,
            includesICloudItems: false,
            statusText: "Finishing analysis…"
        )
        let photos = OrganizeStorageAnalysisBucketProgress(
            bucketID: .photos,
            itemCount: 1,
            processedAssetCount: 1,
            analyzedAssetCount: 1,
            unavailableAssetCount: 0,
            failedAssetCount: 0,
            knownBytes: 2_048
        )
        let secondaryBuckets = [
            OrganizeStorageAnalysisBucketID.live,
            .raw,
            .favorites,
            .edited,
            .noAlbum
        ].map { bucketID in
            OrganizeStorageAnalysisBucketProgress(
                bucketID: bucketID,
                itemCount: 1,
                processedAssetCount: 1,
                analyzedAssetCount: 1,
                unavailableAssetCount: 0,
                failedAssetCount: 0,
                knownBytes: 2_048
            )
        }
        let storage = OrganizeStorageAnalysisProgress(
            processedAssetCount: 1,
            analyzedAssetCount: 1,
            unavailableAssetCount: 0,
            failedAssetCount: 0,
            totalAssetCount: 1,
            totalKnownBytes: 2_048,
            buckets: [photos] + secondaryBuckets
        )

        model.applyAnalysisProgress(
            OrganizeAnalysisProgressUpdate(
                presentation: presentation,
                storage: storage,
                currentAssetID: nil,
                currentAssetFilename: nil
            )
        )

        XCTAssertEqual(model.presentationRevision, revision)
        XCTAssertEqual(model.assets.first, originalAsset, "Progress must not mutate the library-sized asset array")
        XCTAssertEqual(model.totalKnownBytes, 2_048)
        XCTAssertEqual(model.analyzedItemCount, 1)
        let photoMetric = model.primaryBreakdown.first { $0.id == "photos" }
        XCTAssertEqual(photoMetric?.knownBytes, 2_048)
        XCTAssertEqual(photoMetric?.processedAssetCount, 1)
        XCTAssertEqual(photoMetric?.analyzedAssetCount, 1)
        let secondaryByID = Dictionary(uniqueKeysWithValues: model.secondaryBreakdown.map {
            ($0.id, $0)
        })
        for id in ["live", "raw", "favorites", "edited", "no-album"] {
            XCTAssertEqual(secondaryByID[id]?.itemCount, 1)
            XCTAssertEqual(secondaryByID[id]?.knownBytes, 2_048)
            XCTAssertEqual(secondaryByID[id]?.processedAssetCount, 1)
            XCTAssertEqual(secondaryByID[id]?.analyzedAssetCount, 1)
        }
        XCTAssertEqual(model.analysis, presentation)
    }

    func testStartingFreshRetryImmediatelyMarksFailedBucketPending() async {
        let model = await makeModel(
            assets: [asset(id: "retry-pending")],
            callbacks: OrganizeViewModelCallbacks(startAnalysis: { _ in })
        )
        let presentation = OrganizeAnalysisPresentation(
            phase: .failed,
            processedAssetCount: 1,
            completedAssetCount: 0,
            totalAssetCount: 1,
            currentAssetFraction: 0,
            unavailableAssetCount: 0,
            failedAssetCount: 1,
            includesICloudItems: false,
            statusText: "Analysis failed"
        )
        let storage = OrganizeStorageAnalysisProgress(
            processedAssetCount: 1,
            analyzedAssetCount: 0,
            unavailableAssetCount: 0,
            failedAssetCount: 1,
            totalAssetCount: 1,
            totalKnownBytes: 0,
            buckets: [
                OrganizeStorageAnalysisBucketProgress(
                    bucketID: .photos,
                    itemCount: 1,
                    processedAssetCount: 1,
                    analyzedAssetCount: 0,
                    unavailableAssetCount: 0,
                    failedAssetCount: 1,
                    knownBytes: 0
                )
            ]
        )
        model.applyAnalysisProgress(
            OrganizeAnalysisProgressUpdate(
                presentation: presentation,
                storage: storage,
                currentAssetID: nil,
                currentAssetFilename: nil
            )
        )

        await model.startAnalysis(includeICloudItems: false)

        XCTAssertEqual(model.analysis.phase, .running)
        XCTAssertEqual(model.analysis.processedAssetCount, 0)
        let photos = model.primaryBreakdown.first { $0.id == "photos" }
        XCTAssertEqual(photos?.processedAssetCount, 0)
        XCTAssertEqual(photos?.pendingAssetCount, 1)
        XCTAssertTrue(photos?.hasPendingAnalysis == true)
    }

    func testShakeToUndoOnlyFiresForAnEnabledShakeGesture() {
        let controller = ShakeToUndoViewController()
        var undoCount = 0
        controller.onShake = { undoCount += 1 }

        controller.motionEnded(.motionShake, with: nil)
        XCTAssertEqual(undoCount, 0)

        controller.isEnabled = true
        controller.motionEnded(.remoteControlPlay, with: nil)
        XCTAssertEqual(undoCount, 0)

        controller.motionEnded(.motionShake, with: nil)
        XCTAssertEqual(undoCount, 1)
    }

    func testEditedAssetRequiresProtectionOverrideBeforeQueueing() async throws {
        let model = await makeModel(assets: [asset(id: "edited", isEdited: true)])
        let presented = try XCTUnwrap(model.asset(id: "edited"))

        XCTAssertTrue(presented.isProtected)
        XCTAssertEqual(presented.protectionSummary, "Edited")

        let protected = await model.queueAssets([presented.id])

        XCTAssertEqual(protected.map(\.id), [presented.id])
        XCTAssertTrue(model.queuedAssetIDs.isEmpty)

        let overrideResult = await model.queueAssets([presented.id], allowProtected: true)
        XCTAssertTrue(overrideResult.isEmpty)
        XCTAssertEqual(model.queuedAssetIDs, [presented.id])
    }

    func testPresentationStorageRetirementPerformsFinalReleaseOffMainThread() async {
        let retired = expectation(description: "retired storage released")
        let probe = RetirementProbe {
            XCTAssertFalse(Thread.isMainThread, "library-sized storage was destroyed on the UI thread")
            retired.fulfill()
        }
        PresentationStorageRetirement.retire(consume probe)

        await fulfillment(of: [retired], timeout: 2)
    }

    func testUnreviewedIsTheDeterministicPrimaryReviewStack() async {
        let model = await makeModel(assets: [
            asset(id: "regular"),
            asset(id: "screenshot", subtypes: [.screenshot])
        ])

        guard case let .start(recommendation) = model.primaryReviewEntry else {
            return XCTFail("Expected the unreviewed stack to start a review")
        }
        XCTAssertEqual(recommendation.kind, .unreviewed)
        XCTAssertEqual(recommendation.destination, .review)
        XCTAssertEqual(Set(recommendation.assetIDs), ["regular", "screenshot"])
        XCTAssertEqual(model.primaryReviewRecommendation, recommendation)
        XCTAssertFalse(model.alternateReviewRecommendations.contains { $0.kind == .unreviewed })
        XCTAssertTrue(model.alternateReviewRecommendations.contains { $0.kind == .screenshots })
    }

    func testIncompleteSessionTakesPrecedenceOverPrimaryUnreviewedStack() async {
        let model = await makeModel(assets: [
            asset(id: "first", subtypes: [.screenshot]),
            asset(id: "second", subtypes: [.screenshot])
        ])
        let screenshotStack = model.alternateReviewRecommendations.first { $0.kind == .screenshots }
        XCTAssertNotNil(screenshotStack)

        await model.beginReview(screenshotStack!)

        guard case let .resume(session) = model.primaryReviewEntry else {
            return XCTFail("Expected the unfinished screenshot session to resume")
        }
        XCTAssertEqual(session.recommendationKind, .screenshots)
        XCTAssertEqual(session.currentIndex, 0)
        XCTAssertFalse(session.isComplete)
    }

    func testReviewedItemsAreRemovedFromOverlappingStackCountsAndNewSessions() async throws {
        let model = await makeModel(assets: [
            asset(id: "first", subtypes: [.screenshot]),
            asset(id: "second", subtypes: [.screenshot])
        ])
        let primary = try XCTUnwrap(model.primaryReviewRecommendation)
        await model.beginReview(primary)
        let firstAccepted = await model.applyReviewChoice(.keep)
        XCTAssertTrue(firstAccepted)

        let remainingScreenshots = try XCTUnwrap(
            model.alternateReviewRecommendations.first { $0.kind == .screenshots }
        )
        XCTAssertEqual(remainingScreenshots.assetIDs, ["second"])
        XCTAssertEqual(remainingScreenshots.itemCount, 1)

        await model.beginReview(remainingScreenshots)
        XCTAssertEqual(model.activeReviewSession?.recommendationKind, .screenshots)
        XCTAssertEqual(model.activeReviewSession?.assetIDs, ["second"])

        let secondAccepted = await model.applyReviewChoice(.keep)
        XCTAssertTrue(secondAccepted)
        XCTAssertNil(model.primaryReviewRecommendation)
        XCTAssertFalse(model.alternateReviewRecommendations.contains { $0.kind == .screenshots })
        XCTAssertEqual(model.primaryReviewEntry, .complete)
    }

    func testStartReviewPreviewIDsAreOrderedAndCappedAtThree() {
        let entry = OrganizePrimaryReviewEntry.start(
            recommendation(assetIDs: ["first", "second", "third", "fourth"])
        )

        XCTAssertEqual(entry.previewAssetIDs(), ["first", "second", "third"])
        XCTAssertEqual(entry.remainingItemCount, 4)
    }

    func testResumeReviewPreviewIDsBeginAtCurrentIndex() {
        let entry = OrganizePrimaryReviewEntry.resume(
            reviewSession(assetIDs: ["reviewed-1", "reviewed-2", "next", "after"], currentIndex: 2)
        )

        XCTAssertEqual(entry.previewAssetIDs(), ["next", "after"])
        XCTAssertEqual(entry.remainingItemCount, 2)
    }

    func testPrimaryReviewPreviewHandlesSmallCompleteAndUnavailableStacks() {
        XCTAssertEqual(
            OrganizePrimaryReviewEntry.start(recommendation(assetIDs: ["only"])).previewAssetIDs(),
            ["only"]
        )
        XCTAssertEqual(
            OrganizePrimaryReviewEntry.start(recommendation(assetIDs: ["first", "second"])).previewAssetIDs(),
            ["first", "second"]
        )
        XCTAssertEqual(OrganizePrimaryReviewEntry.complete.previewAssetIDs(), [])
        XCTAssertEqual(OrganizePrimaryReviewEntry.complete.remainingItemCount, 0)

        let staleEntry = OrganizePrimaryReviewEntry.resume(
            reviewSession(assetIDs: ["current", "missing", "later"], currentIndex: 0)
        )
        XCTAssertEqual(
            staleEntry.previewAssetIDs(isAvailable: { $0 != "missing" }),
            ["current"],
            "A missing item must not be skipped in favor of a later, misleading preview"
        )
        XCTAssertEqual(
            staleEntry.previewAssetIDs(isAvailable: { $0 != "current" }),
            [],
            "An unavailable current item must not display a different photo as the front card"
        )
    }

    func testReviewEntryKnownSizeUsesTheWholeNewStackAndOnlyRemainingResumeItems() {
        let start = OrganizePrimaryReviewEntry.start(
            recommendation(assetIDs: ["first", "second"], knownBytes: 900)
        )
        XCTAssertEqual(start.remainingKnownBytes { _ in nil }, 900)

        let resume = OrganizePrimaryReviewEntry.resume(
            reviewSession(assetIDs: ["reviewed", "next", "last"], currentIndex: 1)
        )
        let knownBytes: [String: Int64] = [
            "reviewed": 1_000,
            "next": 200,
            "last": 300
        ]
        XCTAssertEqual(resume.remainingKnownBytes { knownBytes[$0] }, 500)
        XCTAssertEqual(OrganizePrimaryReviewEntry.complete.remainingKnownBytes { _ in 100 }, 0)
    }

    func testReviewChoicesOnlyStageDecisionsUntilFinalMove() async {
        var moveCallCount = 0
        let model = await makeModel(
            assets: [asset(id: "screenshot", subtypes: [.screenshot])],
            callbacks: OrganizeViewModelCallbacks(
                moveToRecentlyDeleted: { _, _ in
                    moveCallCount += 1
                    return .moved(Self.batch(assetID: "screenshot"), auditWarning: nil)
                }
            )
        )
        let recommendation = model.reviewRecommendations.first { $0.kind == .screenshots }
        XCTAssertNotNil(recommendation)
        await model.beginReview(recommendation!)

        let accepted = await model.applyReviewChoice(.queueForRecentlyDeleted)
        XCTAssertTrue(accepted)
        XCTAssertEqual(model.queuedAssetIDs, ["screenshot"])
        XCTAssertEqual(model.reviewDecisionCount(.queueForRecentlyDeleted), 1)
        XCTAssertEqual(moveCallCount, 0)

        await model.undoLastReviewChoice()
        XCTAssertTrue(model.queuedAssetIDs.isEmpty)
        XCTAssertEqual(model.reviewDecisionCount(.queueForRecentlyDeleted), 0)
        XCTAssertEqual(moveCallCount, 0)
    }

    func testReviewMutationRequeriesBrowseWithoutAdvancingAuthoritativeRevision() async {
        let screenshot = asset(id: "browse-review", subtypes: [.screenshot])
        let model = await makeModel(assets: [screenshot])
        model.browseConfiguration.filter.reviewState = .unreviewed

        let initialQuery = model.browseQuery()
        let initialSections = await model.browseSections(for: initialQuery)
        XCTAssertEqual(initialSections?.flatMap(\.assets).map(\.id), [screenshot.id])
        let authoritativeRevision = model.presentationRevision

        let recommendation = model.reviewRecommendations.first { $0.kind == .screenshots }!
        await model.beginReview(recommendation)
        let accepted = await model.applyReviewChoice(.keep)
        XCTAssertTrue(accepted)

        let reviewedQuery = model.browseQuery()
        XCTAssertEqual(model.presentationRevision, authoritativeRevision)
        XCTAssertGreaterThan(reviewedQuery.contentRevision, initialQuery.contentRevision)
        let reviewedSections = await model.browseSections(for: reviewedQuery)
        XCTAssertTrue(reviewedSections?.flatMap(\.assets).isEmpty == true)

        await model.undoLastReviewChoice()
        let undoneQuery = model.browseQuery()
        XCTAssertEqual(model.presentationRevision, authoritativeRevision)
        XCTAssertGreaterThan(undoneQuery.contentRevision, reviewedQuery.contentRevision)
        let undoneSections = await model.browseSections(for: undoneQuery)
        XCTAssertEqual(undoneSections?.flatMap(\.assets).map(\.id), [screenshot.id])

        let nextAsset = asset(id: "next-canonical")
        model.applyLibrary(authorization: .authorized, assets: [nextAsset], albums: [])
        await model.waitForPendingPresentation()
        XCTAssertEqual(model.presentationRevision, authoritativeRevision &+ 1)
        XCTAssertEqual(model.assets.map(\.id), [nextAsset.id])
    }

    func testProtectedReviewDecisionRequiresExplicitOverride() async {
        let model = await makeModel(assets: [
            asset(id: "favorite", subtypes: [.screenshot], isFavorite: true)
        ])
        let recommendation = model.reviewRecommendations.first { $0.kind == .screenshots }!
        await model.beginReview(recommendation)

        let protectedAccepted = await model.applyReviewChoice(.queueForRecentlyDeleted)
        XCTAssertFalse(protectedAccepted)
        XCTAssertTrue(model.queuedAssetIDs.isEmpty)
        XCTAssertEqual(model.activeReviewSession?.currentIndex, 0)

        let overrideAccepted = await model.applyReviewChoice(
            .queueForRecentlyDeleted,
            allowProtected: true
        )
        XCTAssertTrue(overrideAccepted)
        XCTAssertEqual(model.queuedAssetIDs, ["favorite"])
        XCTAssertEqual(model.activeReviewSession?.currentIndex, 1)
    }

    func testFailedFinalMoveRetainsQueueAndCreatesNoAuditBatch() async {
        var moveCallCount = 0
        let model = await makeModel(
            assets: [asset(id: "queued")],
            callbacks: OrganizeViewModelCallbacks(
                moveToRecentlyDeleted: { _, _ in
                    moveCallCount += 1
                    throw StubError.failed
                }
            )
        )
        let protected = await model.queueAssets(["queued"])
        XCTAssertTrue(protected.isEmpty)

        await model.moveQueueToRecentlyDeleted()

        XCTAssertEqual(moveCallCount, 1)
        XCTAssertEqual(model.queuedAssetIDs, ["queued"])
        XCTAssertTrue(model.deletedBatches.isEmpty)
        XCTAssertEqual(model.userMessage?.title, "Nothing Was Moved")
    }

    func testMutationDuringInitialPersistenceDrainInvalidatesMoveBeforeCoordinatorEntry() async {
        let persistenceStarted = expectation(description: "queue persistence is draining")
        let persistenceGate = AsyncStream<Void>.makeStream()
        var moveCallCount = 0
        let model = await makeModel(
            assets: [asset(id: "draining-queue")],
            callbacks: OrganizeViewModelCallbacks(
                persistQueueDelta: { _ in
                    persistenceStarted.fulfill()
                    for await _ in persistenceGate.stream { break }
                },
                moveToRecentlyDeleted: { _, _ in
                    moveCallCount += 1
                    return .moved(Self.batch(assetID: "draining-queue"), auditWarning: nil)
                }
            )
        )
        _ = await model.queueAssets(["draining-queue"])
        await fulfillment(of: [persistenceStarted], timeout: 0.5)

        let move = Task { @MainActor in await model.moveQueueToRecentlyDeleted() }
        for _ in 0..<100 where !model.isMovingToRecentlyDeleted {
            await Task.yield()
        }
        XCTAssertTrue(model.isMovingToRecentlyDeleted)

        await model.removeFromQueue("draining-queue")
        XCTAssertEqual(model.queuedAssetIDs, ["draining-queue"])
        persistenceGate.continuation.yield(())
        persistenceGate.continuation.finish()
        await move.value

        XCTAssertEqual(moveCallCount, 0)
        XCTAssertEqual(model.queuedAssetIDs, ["draining-queue"])
        XCTAssertFalse(model.isMovingToRecentlyDeleted)
    }

    func testSuccessfulFinalMoveClearsQueueAndDoesNotDuplicateBatch() async {
        let batch = Self.batch(assetID: "queued")
        let model = await makeModel(
            assets: [asset(id: "queued")],
            callbacks: OrganizeViewModelCallbacks(
                moveToRecentlyDeleted: { _, _ in .moved(batch, auditWarning: nil) }
            )
        )
        model.setDeletedBatches([batch])
        let protected = await model.queueAssets(["queued"])
        XCTAssertTrue(protected.isEmpty)

        await model.moveQueueToRecentlyDeleted()

        XCTAssertTrue(model.queuedAssetIDs.isEmpty)
        XCTAssertEqual(model.deletedBatches.map(\.id), [batch.id])
        XCTAssertEqual(model.userMessage?.title, "Moved to Recently Deleted")
        XCTAssertTrue(model.userMessage?.message.contains("clear it there") == true)
    }

    func testRevalidationOutcomeRemovesMissingAndChangedItemsForFreshReview() async {
        let model = await makeModel(
            assets: [asset(id: "missing"), asset(id: "changed")],
            callbacks: OrganizeViewModelCallbacks(
                moveToRecentlyDeleted: { _, _ in
                    .needsReview(missingAssetIDs: ["missing"], changedAssetIDs: ["changed"])
                }
            )
        )
        let protected = await model.queueAssets(["missing", "changed"])
        XCTAssertTrue(protected.isEmpty)

        await model.moveQueueToRecentlyDeleted()

        XCTAssertTrue(model.queuedAssetIDs.isEmpty)
        XCTAssertTrue(model.deletedBatches.isEmpty)
        XCTAssertEqual(model.userMessage?.title, "Review Queue Again")
    }

    func testProtectedAlbumSelectionUsesPersistenceCallback() async {
        var savedDelta: OrganizeProtectedAlbumPersistenceDelta?
        let album = PhotoAlbum(id: "album", title: "Family", parentID: nil, assetIDs: ["photo"])
        let model = OrganizeViewModel(
            authorization: .authorized,
            assets: [asset(id: "photo")],
            albums: [album],
            callbacks: OrganizeViewModelCallbacks(
                persistProtectedAlbumDelta: { savedDelta = $0 }
            )
        )
        await model.waitForPendingPresentation()

        await model.setAlbumProtected("album", isProtected: true)
        await model.waitForPendingProtectedAlbumPersistence()

        XCTAssertEqual(model.protectedAlbumIDs, ["album"])
        XCTAssertEqual(
            savedDelta,
            OrganizeProtectedAlbumPersistenceDelta(
                generation: 1,
                albumID: "album",
                isProtected: true
            )
        )
    }

    func testProtectedAlbumPersistenceSerializesRapidGenerations() async {
        var received: [OrganizeProtectedAlbumPersistenceDelta] = []
        var firstWriteContinuation: CheckedContinuation<Void, Never>?
        var secondWriteContinuation: CheckedContinuation<Void, Never>?
        let model = await makeModel(assets: [asset(id: "photo")])
        model.installCallbacks(
            OrganizeViewModelCallbacks(
                persistProtectedAlbumDelta: { delta in
                    received.append(delta)
                    if delta.generation == 1 {
                        await withCheckedContinuation { continuation in
                            firstWriteContinuation = continuation
                        }
                        model.apply(
                            snapshot: Self.snapshot(
                                revision: model.presentationRevision &+ 1,
                                protectedAlbumIDs: ["album"]
                            )
                        )
                    } else {
                        await withCheckedContinuation { continuation in
                            secondWriteContinuation = continuation
                        }
                        model.apply(
                            snapshot: Self.snapshot(
                                revision: model.presentationRevision &+ 1,
                                protectedAlbumIDs: []
                            )
                        )
                    }
                }
            )
        )

        await model.setAlbumProtected("album", isProtected: true)
        for _ in 0..<100 where firstWriteContinuation == nil { await Task.yield() }
        XCTAssertNotNil(firstWriteContinuation)

        await model.setAlbumProtected("album", isProtected: false)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(received.map(\.generation), [1])
        XCTAssertTrue(model.protectedAlbumIDs.isEmpty)

        firstWriteContinuation?.resume()
        firstWriteContinuation = nil
        for _ in 0..<100 where secondWriteContinuation == nil { await Task.yield() }
        XCTAssertNotNil(secondWriteContinuation)
        XCTAssertTrue(
            model.protectedAlbumIDs.isEmpty,
            "An older completion snapshot must not overwrite a newer optimistic generation"
        )

        secondWriteContinuation?.resume()
        secondWriteContinuation = nil
        await model.waitForPendingProtectedAlbumPersistence()

        XCTAssertEqual(received.map(\.generation), [1, 2])
        XCTAssertEqual(received.map(\.isProtected), [true, false])
        XCTAssertTrue(model.protectedAlbumIDs.isEmpty)
    }

    func testRapidDifferentAlbumProtectionTogglesComposeInWorkerOrder() async {
        let model = await makeModel(assets: [asset(id: "photo")])

        await model.setAlbumProtected("album-a", isProtected: true)
        await model.setAlbumProtected("album-b", isProtected: true)

        XCTAssertEqual(model.protectedAlbumIDs, ["album-a", "album-b"])
    }

    func testSelectionMutationsComposeInWorkerOrder() async {
        let model = await makeModel(assets: [asset(id: "first"), asset(id: "second")])

        await model.toggleSelection("first")
        await model.toggleSelection("second")
        await model.toggleSelection("first")
        XCTAssertEqual(model.selectedAssetIDs, ["second"])

        await model.clearSelection()
        XCTAssertTrue(model.selectedAssetIDs.isEmpty)
    }

    func testScopedBrowseQueueCarriesRecommendationSource() async {
        var savedDelta: OrganizeQueuePersistenceDelta?
        let model = await makeModel(
            assets: [asset(id: "no-album")],
            callbacks: OrganizeViewModelCallbacks(
                persistQueueDelta: { savedDelta = $0 }
            )
        )

        let protected = await model.queueAssets(
            ["no-album"],
            recommendationKind: .noAlbum
        )
        XCTAssertTrue(protected.isEmpty)
        await model.waitForPendingQueuePersistence()

        XCTAssertEqual(
            savedDelta,
            .upsert(
                assetIDs: ["no-album"],
                recommendationKind: .noAlbum,
                allowProtected: false
            )
        )
    }

    func testQueuePersistenceDeltasCannotCompleteOutOfOrderOrRetainWholeQueue() async {
        var firstWriteContinuation: CheckedContinuation<Void, Never>?
        var received: [OrganizeQueuePersistenceDelta] = []
        let model = await makeModel(
            assets: [asset(id: "first"), asset(id: "second")],
            callbacks: OrganizeViewModelCallbacks(
                persistQueueDelta: { delta in
                    received.append(delta)
                    if received.count == 1 {
                        await withCheckedContinuation { continuation in
                            firstWriteContinuation = continuation
                        }
                    }
                }
            )
        )

        let firstProtected = await model.queueAssets(["first"])
        XCTAssertTrue(firstProtected.isEmpty)
        for _ in 0..<100 where firstWriteContinuation == nil { await Task.yield() }
        XCTAssertNotNil(firstWriteContinuation)

        let secondProtected = await model.queueAssets(["second"])
        XCTAssertTrue(secondProtected.isEmpty)
        XCTAssertEqual(model.queuedAssetIDs, ["first", "second"])
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(received.count, 1, "The newer delta must wait for the preceding write")

        firstWriteContinuation?.resume()
        firstWriteContinuation = nil
        await model.waitForPendingQueuePersistence()

        XCTAssertEqual(
            received,
            [
                .upsert(assetIDs: ["first"], recommendationKind: nil, allowProtected: false),
                .upsert(assetIDs: ["second"], recommendationKind: nil, allowProtected: false)
            ],
            "Each suspended write must own only its action IDs, never the complete live queue"
        )

        await model.removeFromQueue("first")
        await model.waitForPendingQueuePersistence()
        XCTAssertEqual(received.last, .remove(assetIDs: ["first"]))
    }

    private func makeModel(
        assets: [PhotoAsset],
        callbacks: OrganizeViewModelCallbacks = .init()
    ) async -> OrganizeViewModel {
        let model = OrganizeViewModel(
            authorization: .authorized,
            assets: assets,
            albums: [],
            callbacks: callbacks
        )
        await model.waitForPendingPresentation()
        return model
    }

    private func asset(
        id: String,
        subtypes: Set<AssetMediaSubtype> = [],
        isFavorite: Bool = false,
        isEdited: Bool = false
    ) -> PhotoAsset {
        PhotoAsset(
            id: id,
            mediaKind: .photo,
            mediaSubtypes: subtypes,
            creationDate: Date(timeIntervalSince1970: 1_000),
            modificationDate: nil,
            pixelWidth: 2_000,
            pixelHeight: 1_500,
            durationMilliseconds: nil,
            location: nil,
            isFavorite: isFavorite,
            isEdited: isEdited,
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

    private func recommendation(
        assetIDs: [String],
        knownBytes: Int64 = 0
    ) -> OrganizeRecommendationPresentation {
        OrganizeRecommendationPresentation(
            kind: .unreviewed,
            title: "Unreviewed",
            detail: "Review these items",
            systemImage: "rectangle.stack",
            assetIDs: assetIDs,
            assetIDSet: Set(assetIDs),
            knownBytes: knownBytes,
            destination: .review
        )
    }

    private func reviewSession(
        assetIDs: [String],
        currentIndex: Int
    ) -> OrganizeReviewSessionPresentation {
        OrganizeReviewSessionPresentation(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000221")!,
            recommendationKind: .unreviewed,
            title: "Unreviewed",
            reason: "Review these items",
            assetIDs: assetIDs,
            currentIndex: currentIndex,
            decisions: [:],
            undoStack: []
        )
    }

    private static func batch(assetID: String) -> OrganizeDeletedBatchPresentation {
        let now = Date(timeIntervalSince1970: 2_000)
        return OrganizeDeletedBatchPresentation(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000111")!,
            deletedAt: now,
            records: [
                OrganizeDeletedItemPresentation(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000112")!,
                    sourceAssetID: assetID,
                    sourceRevision: "revision",
                    originalFilename: "\(assetID).heic",
                    mediaKind: .photo,
                    captureDate: now,
                    deletedAt: now,
                    pixelWidth: 2_000,
                    pixelHeight: 1_500,
                    durationMilliseconds: nil,
                    knownBytes: 42,
                    recommendationSource: "Screenshot",
                    isFavorite: false,
                    isHidden: false,
                    isEdited: false,
                    isLivePhoto: false,
                    isRAW: false,
                    status: .movedToRecentlyDeleted,
                    thumbnailExpiresAt: now.addingTimeInterval(30 * 24 * 60 * 60)
                )
            ],
            photoKitResult: "Moved to Recently Deleted"
        )
    }

    private static func snapshot(
        revision: UInt64,
        protectedAlbumIDs: Set<String>
    ) -> OrganizePresentationSnapshot {
        OrganizePresentationSnapshot(
            revision: revision,
            authorization: .authorized,
            assets: [],
            assetIndexByID: [:],
            albums: [],
            primaryBreakdown: [],
            secondaryBreakdown: [],
            reviewRecommendations: [],
            organizeRecommendations: [],
            queuedAssetIDs: [],
            queuedAssets: [],
            queuedAssetIndexByID: [:],
            queuedAssetIDsInOrder: [],
            queueKnownBytes: 0,
            queuedRecommendationKinds: [:],
            protectedAlbumIDs: protectedAlbumIDs,
            activeReviewSession: nil,
            duplicateGroups: [],
            deletedBatches: [],
            analysis: OrganizeAnalysisPresentation(),
            totalKnownBytes: 0,
            analyzedItemCount: 0,
            availableFormats: [],
            hasAddedDates: false,
            deletedAuditRecordCount: 0,
            reviewDecisionAssetIDs: [:],
            reviewDecisionAssetIndexByID: [:],
            retainedSelectedAssetIDs: []
        )
    }
}

private enum StubError: Error {
    case failed
}

private final class RetirementProbe: @unchecked Sendable {
    private let onDeinit: () -> Void

    init(onDeinit: @escaping () -> Void) {
        self.onDeinit = onDeinit
    }

    deinit {
        onDeinit()
    }
}
