@testable import MBPhotos
import Foundation
import XCTest

final class OrganizeDomainAndPersistenceTests: XCTestCase {
    func testLegacyAnalysisRunWithoutOriginDecodesAsUserInitiated() throws {
        let run = AnalysisRunRecord(
            id: UUID(),
            includesICloudItems: false,
            orderedAssetIDs: ["asset"],
            completedAssetIDs: [],
            status: .paused,
            startedAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200),
            errorMessage: nil
        )
        let encoded = try WireCoders.encoder().encode(run)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "origin")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try WireCoders.decoder().decode(
            AnalysisRunRecord.self,
            from: legacyData
        )

        XCTAssertEqual(decoded.origin, .userInitiated)
    }

    func testPhotoAssetDecodesLegacyPayloadWithIndependentAnalysisRevision() throws {
        let asset = organizeAsset(
            id: "legacy-analysis-revision",
            creationDate: Date(timeIntervalSince1970: 100),
            isEdited: true
        ).asset
        let encoded = try WireCoders.encoder().encode(asset)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "analysisRevision")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try WireCoders.decoder().decode(PhotoAsset.self, from: legacyData)

        XCTAssertEqual(decoded.sourceRevision, asset.sourceRevision)
        XCTAssertEqual(decoded.analysisRevision, asset.analysisRevision)
        XCTAssertNotEqual(decoded.analysisRevision, decoded.sourceRevision)
    }

    func testSortKeepsMissingValuesLastAndUsesStableIdentifierTieBreaker() {
        let sameDate = Date(timeIntervalSince1970: 100)
        let assets = [
            organizeAsset(id: "b", creationDate: sameDate),
            organizeAsset(id: "missing", creationDate: nil),
            organizeAsset(id: "a", creationDate: sameDate)
        ]

        let ascending = OrganizeEngine.sorted(
            assets,
            by: OrganizeSort(metric: .captureDate, direction: .ascending),
            analysisByAssetID: [:],
            reviewStateByAssetID: [:]
        )
        let descending = OrganizeEngine.sorted(
            assets,
            by: OrganizeSort(metric: .captureDate, direction: .descending),
            analysisByAssetID: [:],
            reviewStateByAssetID: [:]
        )

        XCTAssertEqual(ascending.map(\.id), ["a", "b", "missing"])
        XCTAssertEqual(descending.map(\.id), ["a", "b", "missing"])
    }

    func testMetricsFiltersAndRecommendationsAreDeterministic() {
        let oldScreenshot = organizeAsset(
            id: "screenshot-old",
            creationDate: Date(timeIntervalSince1970: 10),
            subtypes: [.screenshot]
        )
        let newScreenshot = organizeAsset(
            id: "screenshot-new",
            creationDate: Date(timeIntervalSince1970: 20),
            subtypes: [.screenshot],
            isFavorite: true,
            albumIDs: ["protected"]
        )
        let video = organizeAsset(
            id: "large-video",
            creationDate: Date(timeIntervalSince1970: 30),
            mediaKind: .video,
            durationMilliseconds: 12_000
        )
        let assets = [newScreenshot, video, oldScreenshot]
        let analyses = [
            oldScreenshot.id: analysis(for: oldScreenshot, bytes: 1_000, sha256: "same"),
            newScreenshot.id: analysis(for: newScreenshot, bytes: 1_000, sha256: "same"),
            video.id: analysis(for: video, bytes: 600_000_000, sha256: "video")
        ]

        let metrics = OrganizeEngine.metrics(assets: assets, analysisByAssetID: analyses)
        XCTAssertEqual(metrics.accessibleItemCount, 3)
        XCTAssertEqual(metrics.knownMediaByteCount, 600_002_000)
        XCTAssertEqual(metrics.buckets.first { $0.kind == .screenshots }?.itemCount, 2)
        XCTAssertEqual(metrics.buckets.first { $0.kind == .noAlbum }?.itemCount, 2)

        var filter = OrganizeFilter()
        filter.mediaSubtypes = [.screenshot]
        filter.isFavorite = true
        XCTAssertEqual(
            OrganizeEngine.filtered(
                assets,
                by: filter,
                analysisByAssetID: analyses,
                reviewStateByAssetID: [:]
            ).map(\.id),
            ["screenshot-new"]
        )

        let recommendations = OrganizeEngine.recommendations(
            assets: assets,
            analysisByAssetID: analyses,
            reviewStateByAssetID: [:],
            protectedAlbumIDs: ["protected"]
        )
        let screenshots = recommendations.first { $0.kind == .screenshots }
        XCTAssertEqual(screenshots?.assetIDs, ["screenshot-old", "screenshot-new"])
        XCTAssertEqual(recommendations.first { $0.kind == .largeVideos }?.assetIDs, ["large-video"])

        let duplicate = recommendations.first { $0.kind == .exactDuplicates }?.duplicateGroups.first
        XCTAssertEqual(duplicate?.assetIDs, ["screenshot-new", "screenshot-old"])
        XCTAssertEqual(duplicate?.recommendedKeeperID, "screenshot-new")
        XCTAssertEqual(duplicate?.keeperReason, .protectedAlbum)
        XCTAssertEqual(duplicate?.reclaimableKnownByteCount, 1_000)
    }

    func testMetadataCleanupRecommendationsUseInclusiveThresholdsAndExplainableOrder() {
        let day: TimeInterval = 24 * 60 * 60
        let referenceDate = Date(timeIntervalSince1970: 20_000_000)
        let screenRecordingNewer = organizeAsset(
            id: "screen-newer",
            creationDate: referenceDate.addingTimeInterval(-day),
            mediaKind: .video,
            subtypes: [.screenRecording],
            durationMilliseconds: 30_000
        )
        let screenRecordingOlder = organizeAsset(
            id: "screen-older",
            creationDate: referenceDate.addingTimeInterval(-2 * day),
            mediaKind: .video,
            subtypes: [.screenRecording],
            durationMilliseconds: 20_000
        )
        let oldScreenshot = organizeAsset(
            id: "old-screenshot",
            creationDate: referenceDate.addingTimeInterval(-90 * day),
            subtypes: [.screenshot]
        )
        let recentScreenshot = organizeAsset(
            id: "recent-screenshot",
            creationDate: referenceDate.addingTimeInterval(-89 * day),
            subtypes: [.screenshot]
        )
        let shortestVideo = organizeAsset(
            id: "shortest-video",
            creationDate: referenceDate,
            mediaKind: .video,
            durationMilliseconds: 500
        )
        let boundaryShortVideo = organizeAsset(
            id: "boundary-short-video",
            creationDate: referenceDate,
            mediaKind: .video,
            durationMilliseconds: 3_000
        )
        let tiny = organizeAsset(
            id: "tiny",
            creationDate: referenceDate,
            pixelWidth: 100,
            pixelHeight: 100
        )
        let boundaryTiny = organizeAsset(
            id: "boundary-tiny",
            creationDate: referenceDate,
            pixelWidth: 1_000,
            pixelHeight: 1_000
        )
        let largeSpatial = organizeAsset(
            id: "large-spatial",
            creationDate: referenceDate,
            subtypes: [.spatialMedia]
        )
        let largerRAW = organizeAsset(
            id: "larger-raw",
            creationDate: referenceDate,
            subtypes: [.raw]
        )
        let assets = [
            recentScreenshot,
            screenRecordingNewer,
            boundaryTiny,
            largeSpatial,
            shortestVideo,
            oldScreenshot,
            largerRAW,
            screenRecordingOlder,
            tiny,
            boundaryShortVideo
        ]
        let analyses = Dictionary(uniqueKeysWithValues: assets.map { item in
            let bytes: Int64 = switch item.id {
            case "large-spatial": 100_000_000
            case "larger-raw": 200_000_000
            default: 1_000
            }
            return (item.id, analysis(for: item, bytes: bytes, sha256: item.id))
        })

        let recommendations = OrganizeEngine.recommendations(
            assets: assets,
            analysisByAssetID: analyses,
            reviewStateByAssetID: [:],
            protectedAlbumIDs: [],
            referenceDate: referenceDate,
            decideLaterAssetIDs: [oldScreenshot.id, screenRecordingOlder.id]
        )
        func ids(_ kind: RecommendationKind) -> [String]? {
            recommendations.first { $0.kind == kind }?.assetIDs
        }

        XCTAssertEqual(ids(.screenRecordings), ["screen-older", "screen-newer"])
        XCTAssertEqual(ids(.oldScreenshots), ["old-screenshot"])
        XCTAssertEqual(ids(.veryShortVideos), ["shortest-video", "boundary-short-video"])
        XCTAssertEqual(ids(.tinyImages), ["tiny", "boundary-tiny"])
        XCTAssertEqual(ids(.largeSpecialtyMedia), ["larger-raw", "large-spatial"])
        XCTAssertEqual(ids(.decideLater), ["old-screenshot", "screen-older"])
    }

    func testStaleAnalysisIsUnknownAndNilLast() {
        let analyzed = organizeAsset(id: "known", creationDate: Date(timeIntervalSince1970: 1))
        let stale = organizeAsset(id: "stale", creationDate: Date(timeIntervalSince1970: 2))
        var staleRecord = analysis(for: stale, bytes: 999, sha256: "stale")
        staleRecord = AssetAnalysisRecord(
            assetID: staleRecord.assetID,
            sourceRevision: "superseded-revision",
            status: staleRecord.status,
            fingerprint: staleRecord.fingerprint,
            updatedAt: staleRecord.updatedAt,
            errorMessage: nil
        )
        let analyses = [
            analyzed.id: analysis(for: analyzed, bytes: 10, sha256: "known"),
            stale.id: staleRecord
        ]

        let ordered = OrganizeEngine.sorted(
            [stale, analyzed],
            by: OrganizeSort(metric: .analyzedByteCount, direction: .descending),
            analysisByAssetID: analyses,
            reviewStateByAssetID: [:]
        )
        XCTAssertEqual(ordered.map(\.id), ["known", "stale"])
        XCTAssertEqual(
            OrganizeEngine.metrics(assets: [stale, analyzed], analysisByAssetID: analyses).analyzedItemCount,
            1
        )
    }

    func testDuplicateKeeperPrefersHiddenProtectedItem() {
        let hidden = organizeAsset(
            id: "hidden",
            creationDate: Date(timeIntervalSince1970: 1),
            isHidden: true
        )
        let plain = organizeAsset(id: "plain", creationDate: Date(timeIntervalSince1970: 2))
        let analyses = [
            hidden.id: analysis(for: hidden, bytes: 100, sha256: "same"),
            plain.id: analysis(for: plain, bytes: 100, sha256: "same")
        ]

        let group = OrganizeEngine.duplicateGroups(
            assets: [plain, hidden],
            analysisByAssetID: analyses,
            protectedAlbumIDs: []
        ).first

        XCTAssertEqual(group?.recommendedKeeperID, hidden.id)
        XCTAssertEqual(group?.keeperReason, .protectedItem)
    }

    func testSafetySensitiveAssetsAreProtectedButLivePhotosRemainUnlocked() async {
        let edited = organizeAsset(
            id: "edited",
            creationDate: Date(timeIntervalSince1970: 1),
            isEdited: true
        )
        let raw = organizeAsset(
            id: "raw",
            creationDate: Date(timeIntervalSince1970: 2),
            subtypes: [.raw]
        )
        let live = organizeAsset(
            id: "live",
            creationDate: Date(timeIntervalSince1970: 3),
            subtypes: [.livePhoto]
        )
        let favorite = organizeAsset(
            id: "favorite",
            creationDate: Date(timeIntervalSince1970: 4),
            isFavorite: true
        )
        let hidden = organizeAsset(
            id: "hidden",
            creationDate: Date(timeIntervalSince1970: 5),
            isHidden: true
        )
        let worker = OrganizeWorker()

        let protectedIDs = await worker.protectedAssetIDs(
            assets: [edited.asset, raw.asset, live.asset, favorite.asset, hidden.asset],
            albumIDsByAssetID: [:],
            protectedAlbumIDs: []
        )

        XCTAssertEqual(protectedIDs, [edited.id, raw.id, favorite.id, hidden.id])
        XCTAssertFalse(protectedIDs.contains(live.id))
    }

    func testReviewSessionPersistsExactUndoState() {
        let start = Date(timeIntervalSince1970: 100)
        var session = ReviewSession(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            recommendationKind: .screenshots,
            orderedAssetIDs: ["a", "b"],
            createdAt: start
        )
        session.apply(.moveToRecentlyDeleted, at: start.addingTimeInterval(1))
        session.apply(.keep, at: start.addingTimeInterval(2))
        XCTAssertEqual(session.status, .completed)

        let undone = session.undo(at: start.addingTimeInterval(3))
        XCTAssertEqual(undone?.assetID, "b")
        XCTAssertEqual(session.currentAssetID, "b")
        XCTAssertNil(session.decisions["b"])
        XCTAssertEqual(session.decisions["a"], .moveToRecentlyDeleted)
        XCTAssertEqual(session.status, .active)
    }

    func testLedgerRoundTripsOrganizeStateAndExpiresOnlyThumbnailReference() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let ledger = try SQLiteLedger(url: directory.appending(path: "ledger.sqlite"))
        let now = Date(timeIntervalSince1970: 1_000)
        let asset = organizeAsset(id: "asset", creationDate: now)
        let analysis = analysis(for: asset, bytes: 42, sha256: "digest")
        try await ledger.saveAnalysisRecord(analysis)
        let run = AnalysisRunRecord(
            id: UUID(),
            includesICloudItems: false,
            orderedAssetIDs: [asset.id],
            completedAssetIDs: [asset.id],
            status: .paused,
            startedAt: now,
            updatedAt: now.addingTimeInterval(1),
            errorMessage: nil
        )
        try await ledger.saveAnalysisRun(run)

        var session = ReviewSession(
            recommendationKind: .screenshots,
            orderedAssetIDs: [asset.id],
            createdAt: now
        )
        session.apply(.moveToRecentlyDeleted, at: now.addingTimeInterval(1))
        try await ledger.saveReviewSession(session)
        try await ledger.saveReviewState(
            AssetReviewStateRecord(
                assetID: asset.id,
                sourceRevision: asset.asset.sourceRevision,
                state: .queuedForRecentlyDeleted,
                recommendationKind: .screenshots,
                updatedAt: now.addingTimeInterval(1)
            )
        )
        try await ledger.enqueueForRecentlyDeleted(
            DeletionQueueItem(
                assetID: asset.id,
                sourceRevision: asset.asset.sourceRevision,
                recommendationKind: .screenshots,
                queuedAt: now.addingTimeInterval(1),
                protectionOverride: false,
                reviewSessionID: session.id
            )
        )
        try await ledger.saveProtectedAlbum(
            ProtectedAlbumRecord(albumID: "album", title: "Protected", protectedAt: now)
        )

        let batchID = UUID()
        let deletedAt = now.addingTimeInterval(2)
        let batch = DeletionBatch(
            id: batchID,
            requestedAt: now,
            completedAt: deletedAt,
            status: .movedToRecentlyDeleted,
            itemCount: 1,
            knownByteCount: 42,
            errorMessage: nil
        )
        let deletedItem = DeletedItemRecord(
            id: UUID(),
            batchID: batchID,
            sourceLocalIdentifier: asset.id,
            sourceRevision: asset.asset.sourceRevision,
            originalFilename: "asset.heic",
            mediaKind: .photo,
            creationDate: now,
            deletedAt: deletedAt,
            pixelWidth: 100,
            pixelHeight: 100,
            durationMilliseconds: nil,
            knownByteCount: 42,
            recommendationKind: .screenshots,
            isLivePhoto: false,
            isRaw: false,
            isFavorite: false,
            isHidden: false,
            isEdited: false,
            result: .movedToRecentlyDeleted,
            thumbnailRelativePath: "DeletedThumbnails/item.jpg",
            thumbnailExpiresAt: deletedAt.addingTimeInterval(30)
        )
        try await ledger.saveDeletionBatch(batch, items: [deletedItem])

        let storedAnalyses = try await ledger.analysisRecords()
        let storedRun = try await ledger.latestAnalysisRun()
        let storedSession = try await ledger.reviewSession(id: session.id)
        let storedStates = try await ledger.reviewStates()
        let storedQueue = try await ledger.recentlyDeletedQueue()
        let storedProtectedAlbums = try await ledger.protectedAlbums()
        let searchedItems = try await ledger.deletedItems(search: "ASSET")
        XCTAssertEqual(storedAnalyses[asset.id], analysis)
        XCTAssertEqual(storedRun, run)
        XCTAssertEqual(storedSession, session)
        XCTAssertEqual(storedStates[asset.id]?.state, .queuedForRecentlyDeleted)
        XCTAssertEqual(storedQueue.map(\.assetID), [asset.id])
        XCTAssertEqual(storedProtectedAlbums.map(\.albumID), ["album"])
        XCTAssertEqual(searchedItems.first?.sourceRevision, asset.asset.sourceRevision)

        try await ledger.removeReviewState(assetID: asset.id)
        let statesAfterUndo = try await ledger.reviewStates()
        XCTAssertNil(statesAfterUndo[asset.id])

        let paths = try await ledger.expireDeletedItemThumbnails(asOf: deletedAt.addingTimeInterval(31))
        XCTAssertEqual(paths, ["DeletedThumbnails/item.jpg"])
        let retained = try await ledger.deletedItems().first
        XCTAssertEqual(retained?.sourceLocalIdentifier, asset.id)
        XCTAssertNil(retained?.thumbnailRelativePath)
        XCTAssertNil(retained?.thumbnailExpiresAt)
        let batches = try await ledger.deletionBatches()
        XCTAssertEqual(batches.first, batch)
    }

    func testLedgerHidesPreparedAndFailedAuditItems() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let ledger = try SQLiteLedger(url: directory.appending(path: "ledger.sqlite"))
        let batchID = UUID()
        let preparing = DeletionBatch(
            id: batchID,
            requestedAt: Date(),
            completedAt: nil,
            status: .preparing,
            itemCount: 1,
            knownByteCount: 0,
            errorMessage: nil
        )
        let item = DeletedItemRecord(
            id: UUID(),
            batchID: batchID,
            sourceLocalIdentifier: "asset",
            sourceRevision: "revision",
            originalFilename: "asset.heic",
            mediaKind: .photo,
            creationDate: nil,
            deletedAt: Date(),
            pixelWidth: 0,
            pixelHeight: 0,
            durationMilliseconds: nil,
            knownByteCount: nil,
            recommendationKind: nil,
            isLivePhoto: false,
            isRaw: false,
            isFavorite: false,
            isHidden: false,
            isEdited: false,
            result: .prepared,
            thumbnailRelativePath: nil,
            thumbnailExpiresAt: nil
        )
        try await ledger.saveDeletionBatch(preparing, items: [item])
        let itemsWhilePreparing = try await ledger.deletedItems()
        XCTAssertTrue(itemsWhilePreparing.isEmpty)

        let failed = DeletionBatch(
            id: batchID,
            requestedAt: preparing.requestedAt,
            completedAt: Date(),
            status: .failed,
            itemCount: 1,
            knownByteCount: 0,
            errorMessage: "cancelled"
        )
        try await ledger.saveDeletionBatch(failed)
        let itemsAfterFailure = try await ledger.deletedItems()
        XCTAssertTrue(itemsAfterFailure.isEmpty)
    }

    func testLedgerRecoversInterruptedPhotoKitConfirmationWithoutClaimingSuccess() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let ledger = try SQLiteLedger(url: directory.appending(path: "ledger.sqlite"))
        let batchID = UUID()
        let requestedAt = Date(timeIntervalSince1970: 1_000)
        let preparing = DeletionBatch(
            id: batchID,
            requestedAt: requestedAt,
            completedAt: nil,
            status: .preparing,
            itemCount: 1,
            knownByteCount: 42,
            errorMessage: nil
        )
        let item = DeletedItemRecord(
            id: UUID(),
            batchID: batchID,
            sourceLocalIdentifier: "interrupted-asset",
            sourceRevision: "revision",
            originalFilename: "interrupted.heic",
            mediaKind: .photo,
            creationDate: nil,
            deletedAt: requestedAt,
            pixelWidth: 100,
            pixelHeight: 100,
            durationMilliseconds: nil,
            knownByteCount: 42,
            recommendationKind: .screenshots,
            isLivePhoto: false,
            isRaw: false,
            isFavorite: false,
            isHidden: false,
            isEdited: false,
            result: .prepared,
            thumbnailRelativePath: "DeletedThumbnails/interrupted.jpg",
            thumbnailExpiresAt: requestedAt.addingTimeInterval(30 * 24 * 60 * 60)
        )
        try await ledger.saveDeletionBatch(preparing, items: [item])
        try await ledger.enqueueForRecentlyDeleted(
            DeletionQueueItem(
                assetID: item.sourceLocalIdentifier,
                sourceRevision: item.sourceRevision,
                recommendationKind: .screenshots,
                queuedAt: requestedAt,
                protectionOverride: false,
                reviewSessionID: nil
            )
        )

        let recovery = try await ledger.recoverInterruptedDeletionBatches()
        let recoveredQueue = try await ledger.recentlyDeletedQueue()
        let recoveredBatches = try await ledger.deletionBatches()
        let secondRecovery = try await ledger.recoverInterruptedDeletionBatches()

        XCTAssertEqual(recovery, InterruptedDeletionRecovery(batchCount: 1, itemCount: 1))
        XCTAssertTrue(recoveredQueue.isEmpty)
        XCTAssertEqual(recoveredBatches.first?.status, .confirmationInterrupted)
        let recoveredItem = try await ledger.deletedItems().first
        XCTAssertEqual(recoveredItem?.result, .confirmationInterrupted)
        XCTAssertEqual(recoveredItem?.thumbnailRelativePath, item.thumbnailRelativePath)
        XCTAssertEqual(secondRecovery, .none)
    }

    private func organizeAsset(
        id: String,
        creationDate: Date?,
        mediaKind: MediaKind = .photo,
        subtypes: Set<AssetMediaSubtype> = [],
        durationMilliseconds: Int? = nil,
        pixelWidth: Int = 2_000,
        pixelHeight: Int = 1_500,
        isFavorite: Bool = false,
        albumIDs: Set<String> = [],
        isHidden: Bool = false,
        isEdited: Bool = false
    ) -> OrganizeAsset {
        OrganizeAsset(
            asset: PhotoAsset(
                id: id,
                mediaKind: mediaKind,
                mediaSubtypes: subtypes,
                creationDate: creationDate,
                modificationDate: nil,
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
                        originalFilename: "\(id).heic",
                        uniformTypeIdentifier: mediaKind == .video ? "public.mpeg-4" : "public.heic"
                    )
                ],
                isHidden: isHidden
            ),
            albumIDs: albumIDs
        )
    }

    private func analysis(
        for item: OrganizeAsset,
        bytes: Int64,
        sha256: String
    ) -> AssetAnalysisRecord {
        let date = Date(timeIntervalSince1970: 500)
        let fingerprint = AssetFingerprint(
            assetID: item.id,
            sourceRevision: item.asset.analysisRevision,
            resources: [
                ResourceFingerprint(
                    kind: item.asset.mediaKind == .video ? .video : .photo,
                    byteCount: bytes,
                    sha256: sha256
                )
            ],
            analyzedAt: date
        )
        return AssetAnalysisRecord(
            assetID: item.id,
            sourceRevision: item.asset.analysisRevision,
            status: .complete,
            fingerprint: fingerprint,
            updatedAt: date,
            errorMessage: nil
        )
    }
}
