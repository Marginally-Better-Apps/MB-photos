@testable import MBPhotos
import XCTest

final class SelectionAndPlannerTests: XCTestCase {
    func testPortableLibraryAssetLimitAllowsBoundaryAndRejectsOnePastIt() throws {
        XCTAssertNoThrow(try ExportPlanner.validateAssetCount(100_000))
        XCTAssertThrowsError(try ExportPlanner.validateAssetCount(100_001)) { error in
            XCTAssertEqual(
                error as? ExportPlanningError,
                .tooManyAssets(actual: 100_001, limit: 100_000)
            )
            XCTAssertTrue(error.localizedDescription.contains("Split the selection"))
        }
    }

    func testPreflightWorkerPlansLargeLibraryAwayFromMainActor() async throws {
        let assets = (0..<50_000).map {
            FixtureFactory.asset(
                id: "asset-\($0)",
                filename: "IMG_\($0).JPG",
                uti: "public.jpeg"
            )
        }
        let worker = PreflightWorker()
        let heartbeat = expectation(description: "main actor heartbeat")
        let request = Self.request(revision: 1, kind: .allAccessible)
        let planning = Task.detached { [assets = consume assets] in
            try await worker.plan(
                request: request,
                assets: assets,
                albums: []
            )
        }

        Task { @MainActor in heartbeat.fulfill() }
        await fulfillment(of: [heartbeat], timeout: 0.1)
        let result = try await planning.value

        XCTAssertEqual(result.job.assets.count, 50_000)
        XCTAssertEqual(result.preflight.masterFileCount, 50_000)
        XCTAssertEqual(result.preflight.thumbnailFileCount, 50_000)
        XCTAssertEqual(result.job.files.count, 100_000)
    }

    func testPreflightWorkerFreezesManualSelectionFromActorOwnedDeltas() async throws {
        let worker = PreflightWorker()
        let first = FixtureFactory.asset(id: "first")
        let second = FixtureFactory.asset(id: "second")

        await worker.applySelectionDelta(
            .asset(revision: 1, id: first.id, isSelected: true)
        )
        await worker.applySelectionDelta(
            .asset(revision: 2, id: second.id, isSelected: true)
        )
        await worker.applySelectionDelta(
            .asset(revision: 3, id: first.id, isSelected: false)
        )

        let result = try await worker.plan(
            request: Self.request(
                revision: 1,
                selectionRevision: 3,
                kind: .manual
            ),
            assets: [first, second],
            albums: []
        )

        XCTAssertEqual(result.job.assets.map(\.sourceLocalIdentifier), [second.id])
    }

    func testPreflightWorkerAppliesBatchPhotoAndAlbumSelectionDeltas() async throws {
        let worker = PreflightWorker()
        let first = FixtureFactory.asset(id: "first")
        let second = FixtureFactory.asset(id: "second")
        let third = FixtureFactory.asset(id: "third")
        let albums = [
            PhotoAlbum(id: "album", title: "Album", parentID: nil, assetIDs: [third.id])
        ]

        await worker.applySelectionDelta(
            .assets(revision: 1, ids: [first.id, second.id], isSelected: true)
        )
        await worker.applySelectionDelta(
            .assets(revision: 2, ids: [first.id], isSelected: false)
        )
        await worker.applySelectionDelta(
            .albums(revision: 3, ids: ["album"], isSelected: true)
        )

        let result = try await worker.plan(
            request: Self.request(revision: 1, selectionRevision: 3, kind: .manual),
            assets: [first, second, third],
            albums: albums
        )

        XCTAssertEqual(
            Set(result.job.assets.map(\.sourceLocalIdentifier)),
            [second.id, third.id]
        )
        XCTAssertEqual(result.job.selection.sourceAlbumIdentifiers, ["album"])
    }

    func testPreflightWorkerRejectsGappedAndStaleSelectionDeltas() async throws {
        let worker = PreflightWorker()
        let first = FixtureFactory.asset(id: "first")
        let second = FixtureFactory.asset(id: "second")

        await worker.applySelectionDelta(
            .asset(revision: 1, id: first.id, isSelected: true)
        )
        await worker.applySelectionDelta(
            .asset(revision: 3, id: second.id, isSelected: true)
        )
        await worker.applySelectionDelta(
            .asset(revision: 1, id: first.id, isSelected: false)
        )

        let beforeMissingDelta = try await worker.plan(
            request: Self.request(
                revision: 1,
                selectionRevision: 1,
                kind: .manual
            ),
            assets: [first, second],
            albums: []
        )
        XCTAssertEqual(beforeMissingDelta.job.assets.map(\.sourceLocalIdentifier), [first.id])

        await worker.applySelectionDelta(
            .asset(revision: 2, id: second.id, isSelected: true)
        )
        let afterOrderedDelta = try await worker.plan(
            request: Self.request(
                revision: 2,
                selectionRevision: 2,
                kind: .manual
            ),
            assets: [first, second],
            albums: []
        )
        XCTAssertEqual(
            Set(afterOrderedDelta.job.assets.map(\.sourceLocalIdentifier)),
            [first.id, second.id]
        )
    }

    func testPreflightWorkerRejectsMismatchedSelectionAndStalePlanningRevisions() async throws {
        let worker = PreflightWorker()
        let asset = FixtureFactory.asset(id: "selected")
        await worker.applySelectionDelta(
            .asset(revision: 1, id: asset.id, isSelected: true)
        )

        do {
            _ = try await worker.plan(
                request: Self.request(
                    revision: 1,
                    selectionRevision: 0,
                    kind: .manual
                ),
                assets: [asset],
                albums: []
            )
            XCTFail("Expected a mismatched selection revision to be rejected")
        } catch is CancellationError {
            // Expected stale request rejection.
        }

        _ = try await worker.plan(
            request: Self.request(
                revision: 3,
                selectionRevision: 1,
                libraryRevision: 2,
                kind: .manual
            ),
            assets: [asset],
            albums: []
        )

        do {
            _ = try await worker.plan(
                request: Self.request(
                    revision: 3,
                    selectionRevision: 1,
                    libraryRevision: 2,
                    kind: .manual
                ),
                assets: [asset],
                albums: []
            )
            XCTFail("Expected a duplicate planning generation to be rejected")
        } catch is CancellationError {
            // Expected duplicate request rejection.
        }

        do {
            _ = try await worker.plan(
                request: Self.request(
                    revision: 2,
                    selectionRevision: 1,
                    libraryRevision: 2,
                    kind: .manual
                ),
                assets: [asset],
                albums: []
            )
            XCTFail("Expected an older planning generation to be rejected")
        } catch is CancellationError {
            // Expected stale request rejection.
        }

        do {
            _ = try await worker.plan(
                request: Self.request(
                    revision: 4,
                    selectionRevision: 1,
                    libraryRevision: 1,
                    kind: .manual
                ),
                assets: [asset],
                albums: []
            )
            XCTFail("Expected an older library generation to be rejected")
        } catch is CancellationError {
            // Expected stale library rejection.
        }
    }

    func testPreflightWorkerFreezesAlbumSelectionFromActorOwnedDeltas() async throws {
        let worker = PreflightWorker()
        let first = FixtureFactory.asset(id: "first")
        let second = FixtureFactory.asset(id: "second")
        let albums = [
            PhotoAlbum(id: "one", title: "One", parentID: nil, assetIDs: [first.id]),
            PhotoAlbum(id: "two", title: "Two", parentID: nil, assetIDs: [second.id])
        ]

        await worker.applySelectionDelta(
            .album(revision: 1, id: "one", isSelected: true)
        )
        await worker.applySelectionDelta(
            .album(revision: 2, id: "two", isSelected: true)
        )
        await worker.applySelectionDelta(
            .album(revision: 3, id: "one", isSelected: false)
        )

        let result = try await worker.plan(
            request: Self.request(
                revision: 1,
                selectionRevision: 3,
                kind: .albums
            ),
            assets: [first, second],
            albums: albums
        )

        XCTAssertEqual(result.job.assets.map(\.sourceLocalIdentifier), [second.id])
        XCTAssertEqual(result.job.selection.sourceAlbumIdentifiers, ["two"])
    }

    func testAlbumSelectionUsesUnionWithoutDuplicates() throws {
        let first = FixtureFactory.asset(id: "a")
        let second = FixtureFactory.asset(id: "b")
        let albums = [
            PhotoAlbum(id: "one", title: "One", parentID: nil, assetIDs: ["a", "b"]),
            PhotoAlbum(id: "two", title: "Two", parentID: nil, assetIDs: ["a"])
        ]
        let frozen = try SelectionService().freeze(
            source: .albums(["one", "two"]),
            assets: [first, second],
            albums: albums,
            now: Date(timeIntervalSince1970: 0),
            timeZone: TimeZone(identifier: "UTC")!
        )
        XCTAssertEqual(Set(frozen.assets.map(\.id)), ["a", "b"])
        XCTAssertEqual(frozen.assets.count, 2)
    }

    func testCustomSelectionCombinesPhotosAndAlbumsWithoutDuplicates() throws {
        let first = FixtureFactory.asset(id: "first")
        let second = FixtureFactory.asset(id: "second")
        let third = FixtureFactory.asset(id: "third")
        let albums = [
            PhotoAlbum(
                id: "favorites",
                title: "Favorites",
                parentID: nil,
                assetIDs: [first.id, second.id, "inaccessible"]
            )
        ]

        let frozen = try SelectionService().freeze(
            source: .custom(
                assetIDs: [first.id, third.id],
                albumIDs: ["favorites"]
            ),
            assets: [first, second, third],
            albums: albums,
            now: Date(timeIntervalSince1970: 0),
            timeZone: TimeZone(identifier: "UTC")!
        )

        XCTAssertEqual(Set(frozen.assets.map(\.id)), [first.id, second.id, third.id])
        XCTAssertEqual(frozen.assets.count, 3)
        XCTAssertEqual(frozen.selectedAlbumIDs, ["favorites"])

        let planned = try ExportPlanner().plan(
            selection: frozen,
            albums: albums,
            profile: ExportProfile()
        )
        XCTAssertEqual(planned.job.selection.kind, .manual)
        XCTAssertEqual(planned.job.selection.sourceAlbumIdentifiers, ["favorites"])
    }

    func testPreflightWorkerClearResetsPhotoAndAlbumSelectionsInOrder() async throws {
        let worker = PreflightWorker()
        let first = FixtureFactory.asset(id: "first")
        let second = FixtureFactory.asset(id: "second")
        let albums = [
            PhotoAlbum(id: "album", title: "Album", parentID: nil, assetIDs: [first.id])
        ]

        await worker.applySelectionDelta(.asset(revision: 1, id: first.id, isSelected: true))
        await worker.applySelectionDelta(.album(revision: 2, id: "album", isSelected: true))
        await worker.applySelectionDelta(.clear(revision: 3))
        await worker.applySelectionDelta(.asset(revision: 4, id: second.id, isSelected: true))

        let result = try await worker.plan(
            request: Self.request(revision: 1, selectionRevision: 4, kind: .manual),
            assets: [first, second],
            albums: albums
        )

        XCTAssertEqual(result.job.assets.map(\.sourceLocalIdentifier), [second.id])
        XCTAssertNil(result.job.selection.sourceAlbumIdentifiers)
    }

    func testIncrementalSelectionReconcilesEveryCandidateWithReceiver() throws {
        let unchanged = FixtureFactory.asset(id: "same")
        let changed = FixtureFactory.asset(id: "changed", modified: Date(timeIntervalSince1970: 2_000_000_000))
        let frozen = try SelectionService().freeze(
            source: .newOrChanged,
            assets: [unchanged, changed],
            albums: [],
            previouslyExportedRevisions: [
                unchanged.id: unchanged.sourceRevision,
                changed.id: String(repeating: "0", count: 64)
            ]
        )
        XCTAssertEqual(Set(frozen.assets.map(\.id)), ["same", "changed"])
    }

    func testSelectionUsesTotalOrderForDatedAndUndatedAssets() throws {
        let assets = [
            FixtureFactory.asset(id: "undated-b", creationDate: nil),
            FixtureFactory.asset(id: "dated-late", creationDate: Date(timeIntervalSince1970: 200)),
            FixtureFactory.asset(id: "undated-a", creationDate: nil),
            FixtureFactory.asset(id: "dated-early", creationDate: Date(timeIntervalSince1970: 100))
        ]

        let frozen = try SelectionService().freeze(source: .allAccessible, assets: assets, albums: [])

        XCTAssertEqual(
            frozen.assets.map(\.id),
            ["dated-early", "dated-late", "undated-a", "undated-b"]
        )
    }

    func testPlannerCreatesExactMasterAndBrowsingThumbnailForHEIC() throws {
        let asset = FixtureFactory.asset()
        let frozen = try SelectionService().freeze(
            source: .allAccessible,
            assets: [asset],
            albums: [],
            timeZone: TimeZone(identifier: "UTC")!
        )
        let result = try ExportPlanner().plan(
            selection: frozen,
            albums: [],
            profile: ExportProfile(),
            jobID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        )
        XCTAssertEqual(result.job.files.map(\.provenance), [.exactPhotoKitResource, .generatedThumbnail])
        XCTAssertTrue(result.job.files[0].proposedRelativePath.hasPrefix("Master/"))
        XCTAssertTrue(result.job.files[1].proposedRelativePath.hasPrefix("MB Photos Data/Thumbnails/"))
        XCTAssertEqual(result.job.files[0].contentType, "image/heic")
        XCTAssertEqual(result.job.files[0].roles, [.masterCurrent, .rootOriginal])
        XCTAssertEqual(result.job.profile, ExportProfile())
    }

    func testCompatibleUneditedJPEGIsMasterPlusOnlyOptionalThumbnail() throws {
        let asset = FixtureFactory.asset(filename: "IMG_1.JPG", uti: "public.jpeg")
        let frozen = try SelectionService().freeze(source: .allAccessible, assets: [asset], albums: [])
        let result = try ExportPlanner().plan(
            selection: frozen,
            albums: [],
            profile: ExportProfile()
        )
        XCTAssertEqual(result.job.files.count, 2)
        XCTAssertEqual(result.job.files.filter { $0.storageArea == .master }.count, 1)
        XCTAssertEqual(result.job.files.filter { $0.provenance == .generatedThumbnail }.count, 1)
    }

    func testPlannerAlwaysPreservesLocationMetadata() throws {
        let location = AssetLocation(latitude: 41.8781, longitude: -87.6298, altitudeMeters: 181)
        let asset = FixtureFactory.asset(location: location)
        let frozen = try SelectionService().freeze(source: .allAccessible, assets: [asset], albums: [])

        let planned = try ExportPlanner().plan(
            selection: frozen,
            albums: [],
            profile: ExportProfile()
        )

        XCTAssertEqual(planned.job.assets.first?.location, location)
    }

    func testEditedPhotoUsesExactFullSizeMasterAndArchivesRootOriginal() throws {
        let original = PhotoResourceDescriptor(
            id: "edited#photo",
            kind: .photo,
            rawResourceType: 1,
            originalFilename: "IMG_0100.HEIC",
            uniformTypeIdentifier: "public.heic",
            pixelWidth: 4_032,
            pixelHeight: 3_024
        )
        let current = PhotoResourceDescriptor(
            id: "edited#full-size",
            kind: .fullSizePhoto,
            rawResourceType: 5,
            originalFilename: "IMG_E0100.HEIC",
            uniformTypeIdentifier: "public.heic",
            pixelWidth: 3_024,
            pixelHeight: 3_024
        )
        let asset = Self.asset(
            id: "edited",
            edited: true,
            modified: Date(timeIntervalSince1970: 200),
            resources: [original, current]
        )

        let result = try Self.plan(asset)
        let exportAsset = try XCTUnwrap(result.job.assets.first)
        let master = try XCTUnwrap(exportAsset.files.first { $0.fileId == exportAsset.masterFileId })
        let archivedOriginal = try XCTUnwrap(exportAsset.files.first { $0.photoKitResourceType == .photo })

        XCTAssertEqual(master.photoKitResourceType, .fullSizePhoto)
        XCTAssertEqual(master.provenance, .exactPhotoKitResource)
        XCTAssertEqual(master.storageArea, .master)
        XCTAssertEqual(master.roles, [.masterCurrent])
        XCTAssertEqual(master.pixelWidth, 3_024)
        XCTAssertTrue(master.proposedRelativePath.hasPrefix("Master/"))
        XCTAssertEqual(archivedOriginal.storageArea, .libraryData)
        XCTAssertEqual(archivedOriginal.roles, [.rootOriginal])
        XCTAssertTrue(archivedOriginal.proposedRelativePath.hasPrefix("MB Photos Data/Resources/"))
    }

    func testOriginalFileIdentityAndRevisionStayStableAcrossNondestructiveEdits() throws {
        let original = PhotoResourceDescriptor(
            id: "stable#photo",
            kind: .photo,
            originalFilename: "IMG_0200.HEIC",
            uniformTypeIdentifier: "public.heic"
        )
        let current = PhotoResourceDescriptor(
            id: "stable#full-size",
            kind: .fullSizePhoto,
            originalFilename: "IMG_E0200.HEIC",
            uniformTypeIdentifier: "public.heic"
        )
        let rediscoveredOriginal = PhotoResourceDescriptor(
            id: "stable#photo-new-descriptor",
            kind: .photo,
            originalFilename: "IMG_0200.HEIC",
            uniformTypeIdentifier: "public.heic"
        )
        let nextCurrent = PhotoResourceDescriptor(
            id: "stable#full-size-new-descriptor",
            kind: .fullSizePhoto,
            originalFilename: "IMG_E0200_V2.HEIC",
            uniformTypeIdentifier: "public.heic"
        )
        let first = Self.asset(
            id: "stable",
            edited: true,
            modified: Date(timeIntervalSince1970: 200),
            resources: [original, current]
        )
        let second = Self.asset(
            id: "stable",
            edited: true,
            modified: Date(timeIntervalSince1970: 300),
            resources: [rediscoveredOriginal, nextCurrent]
        )

        let firstPlan = try Self.plan(first)
        let secondPlan = try Self.plan(second)
        let firstOriginal = try XCTUnwrap(firstPlan.job.files.first { $0.photoKitResourceType == .photo })
        let secondOriginal = try XCTUnwrap(secondPlan.job.files.first { $0.photoKitResourceType == .photo })
        let firstCurrent = try XCTUnwrap(firstPlan.job.files.first { $0.photoKitResourceType == .fullSizePhoto })
        let secondCurrent = try XCTUnwrap(secondPlan.job.files.first { $0.photoKitResourceType == .fullSizePhoto })

        XCTAssertEqual(firstOriginal.fileId, secondOriginal.fileId)
        XCTAssertEqual(firstOriginal.contentRevision, secondOriginal.contentRevision)
        XCTAssertEqual(firstCurrent.fileId, secondCurrent.fileId)
        XCTAssertNotEqual(firstCurrent.contentRevision, secondCurrent.contentRevision)
    }

    func testEditedAssetMissingRootOriginalUsesUnavailableArchivePlaceholder() throws {
        let current = PhotoResourceDescriptor(
            id: "missing-original#current",
            kind: .fullSizePhoto,
            originalFilename: "IMG_E0225.HEIC",
            uniformTypeIdentifier: "public.heic"
        )
        let result = try Self.plan(Self.asset(
            id: "missing-original",
            edited: true,
            resources: [current]
        ))
        let exportAsset = try XCTUnwrap(result.job.assets.first)
        XCTAssertNotNil(exportAsset.masterFileId)
        let original = try XCTUnwrap(exportAsset.files.first { $0.roles == [.rootOriginal] })
        XCTAssertEqual(original.storageArea, .libraryData)
        XCTAssertEqual(original.criticality, .archiveRequired)
        XCTAssertEqual(original.availability, .sourceUnavailable)
        XCTAssertEqual(original.photoKitResourceType, .photo)
        XCTAssertNil(result.sourceResourcesByFileID[original.fileId])
        XCTAssertNil(result.sourceAssetIDsByFileID[original.fileId])
        XCTAssertTrue(result.preflight.warnings.contains { $0.contains("archive will be reported as incomplete") })
    }

    func testEditedVideoUsesExactFullSizeVideoAsMaster() throws {
        let original = PhotoResourceDescriptor(
            id: "video#original",
            kind: .video,
            originalFilename: "IMG_0250.MOV",
            uniformTypeIdentifier: "com.apple.quicktime-movie",
            pixelWidth: 3_840,
            pixelHeight: 2_160
        )
        let current = PhotoResourceDescriptor(
            id: "video#current",
            kind: .fullSizeVideo,
            originalFilename: "IMG_E0250.MOV",
            uniformTypeIdentifier: "com.apple.quicktime-movie",
            pixelWidth: 1_920,
            pixelHeight: 1_080
        )
        let asset = PhotoAsset(
            id: "edited-video",
            mediaKind: .video,
            mediaSubtypes: [.hdr],
            creationDate: Date(timeIntervalSince1970: 100),
            modificationDate: Date(timeIntervalSince1970: 200),
            pixelWidth: 1_920,
            pixelHeight: 1_080,
            durationMilliseconds: 12_000,
            location: nil,
            isFavorite: false,
            isEdited: true,
            resources: [original, current]
        )

        let exportAsset = try XCTUnwrap(Self.plan(asset).job.assets.first)
        let master = try XCTUnwrap(exportAsset.files.first { $0.fileId == exportAsset.masterFileId })
        let archivedOriginal = try XCTUnwrap(exportAsset.files.first { $0.photoKitResourceType == .video })
        XCTAssertEqual(master.photoKitResourceType, .fullSizeVideo)
        XCTAssertEqual(master.durationMilliseconds, 12_000)
        XCTAssertEqual(master.pixelWidth, 1_920)
        XCTAssertEqual(archivedOriginal.roles, [.rootOriginal])
        XCTAssertEqual(archivedOriginal.storageArea, .libraryData)
    }

    func testLivePhotoKeepsOnlyStillInMasterAndLinksExactMotionArchive() throws {
        let still = PhotoResourceDescriptor(
            id: "live#still",
            kind: .photo,
            originalFilename: "IMG_0300.HEIC",
            uniformTypeIdentifier: "public.heic"
        )
        let motion = PhotoResourceDescriptor(
            id: "live#motion",
            kind: .pairedVideo,
            originalFilename: "IMG_0300.MOV",
            uniformTypeIdentifier: "com.apple.quicktime-movie"
        )
        let asset = Self.asset(
            id: "live",
            subtypes: [.livePhoto],
            durationMilliseconds: 3_020,
            resources: [still, motion]
        )

        let result = try Self.plan(asset)
        let exportAsset = try XCTUnwrap(result.job.assets.first)
        let relationships = try XCTUnwrap(exportAsset.livePhotoRelationships)
        let motionFile = try XCTUnwrap(exportAsset.files.first { $0.photoKitResourceType == .pairedVideo })

        XCTAssertEqual(relationships.currentStillFileId, exportAsset.masterFileId)
        XCTAssertEqual(relationships.originalStillFileId, exportAsset.masterFileId)
        XCTAssertEqual(relationships.currentMotionFileId, motionFile.fileId)
        XCTAssertEqual(relationships.originalMotionFileId, motionFile.fileId)
        XCTAssertEqual(motionFile.storageArea, .libraryData)
        XCTAssertEqual(motionFile.roles, [.currentLiveMotion, .originalLiveMotion])
        XCTAssertEqual(motionFile.durationMilliseconds, 3_020)
        XCTAssertEqual(result.job.files.filter { $0.storageArea == .master }.count, 1)
    }

    func testPairedMotionNormalizesLivePhotoSubtypeOnWire() throws {
        let still = PhotoResourceDescriptor(
            id: "inferred-live#still",
            kind: .photo,
            originalFilename: "IMG_0350.HEIC",
            uniformTypeIdentifier: "public.heic"
        )
        let motion = PhotoResourceDescriptor(
            id: "inferred-live#motion",
            kind: .pairedVideo,
            originalFilename: "IMG_0350.MOV",
            uniformTypeIdentifier: "com.apple.quicktime-movie"
        )

        let exportAsset = try XCTUnwrap(Self.plan(Self.asset(
            id: "inferred-live",
            resources: [still, motion]
        )).job.assets.first)

        XCTAssertTrue(exportAsset.mediaSubtypes.contains(.livePhoto))
        XCTAssertNotNil(exportAsset.livePhotoRelationships)
    }

    func testEditedLivePhotoLinksCurrentAndOriginalMotionSeparately() throws {
        let resources = [
            PhotoResourceDescriptor(
                id: "edited-live#still-original",
                kind: .photo,
                originalFilename: "IMG_0400.HEIC",
                uniformTypeIdentifier: "public.heic"
            ),
            PhotoResourceDescriptor(
                id: "edited-live#still-current",
                kind: .fullSizePhoto,
                originalFilename: "IMG_E0400.HEIC",
                uniformTypeIdentifier: "public.heic"
            ),
            PhotoResourceDescriptor(
                id: "edited-live#motion-original",
                kind: .pairedVideo,
                originalFilename: "IMG_0400.MOV",
                uniformTypeIdentifier: "com.apple.quicktime-movie"
            ),
            PhotoResourceDescriptor(
                id: "edited-live#motion-current",
                kind: .fullSizePairedVideo,
                originalFilename: "IMG_E0400.MOV",
                uniformTypeIdentifier: "com.apple.quicktime-movie"
            )
        ]
        let asset = Self.asset(
            id: "edited-live",
            subtypes: [.livePhoto],
            edited: true,
            modified: Date(timeIntervalSince1970: 400),
            durationMilliseconds: 3_000,
            resources: resources
        )

        let exportAsset = try XCTUnwrap(Self.plan(asset).job.assets.first)
        let relationships = try XCTUnwrap(exportAsset.livePhotoRelationships)
        let currentMotion = try XCTUnwrap(exportAsset.files.first { $0.photoKitResourceType == .fullSizePairedVideo })
        let originalMotion = try XCTUnwrap(exportAsset.files.first { $0.photoKitResourceType == .pairedVideo })

        XCTAssertEqual(relationships.currentMotionFileId, currentMotion.fileId)
        XCTAssertEqual(relationships.originalMotionFileId, originalMotion.fileId)
        XCTAssertEqual(currentMotion.roles, [.currentLiveMotion])
        XCTAssertEqual(originalMotion.roles, [.originalLiveMotion])
        XCTAssertTrue(exportAsset.files.filter { $0.roles.contains(.currentLiveMotion) }.allSatisfy {
            $0.storageArea == .libraryData
        })
    }

    func testMissingUneditedLiveMotionUsesOneUnavailableArchivePlaceholder() throws {
        let still = PhotoResourceDescriptor(
            id: "missing-live#still",
            kind: .photo,
            originalFilename: "IMG_0450.HEIC",
            uniformTypeIdentifier: "public.heic"
        )
        let result = try Self.plan(Self.asset(
            id: "missing-live",
            subtypes: [.livePhoto],
            durationMilliseconds: 3_000,
            resources: [still]
        ))
        let exportAsset = try XCTUnwrap(result.job.assets.first)
        let relationships = try XCTUnwrap(exportAsset.livePhotoRelationships)
        let motionID = try XCTUnwrap(relationships.currentMotionFileId)
        XCTAssertEqual(relationships.originalMotionFileId, motionID)
        let placeholder = try XCTUnwrap(exportAsset.files.first { $0.fileId == motionID })
        XCTAssertEqual(placeholder.roles, [.currentLiveMotion, .originalLiveMotion])
        XCTAssertEqual(placeholder.criticality, .archiveRequired)
        XCTAssertEqual(placeholder.availability, .sourceUnavailable)
        XCTAssertEqual(placeholder.photoKitResourceType, .pairedVideo)
        XCTAssertNil(result.sourceResourcesByFileID[motionID])
        XCTAssertNil(result.sourceAssetIDsByFileID[motionID])
        XCTAssertTrue(result.preflight.warnings.contains { $0.contains("archive will be reported as incomplete") })
    }

    func testMissingEditedLiveMotionTracksCurrentAndOriginalFailuresSeparately() throws {
        let originalStill = PhotoResourceDescriptor(
            id: "missing-edited-live#original",
            kind: .photo,
            originalFilename: "IMG_0475.HEIC",
            uniformTypeIdentifier: "public.heic"
        )
        let currentStill = PhotoResourceDescriptor(
            id: "missing-edited-live#current",
            kind: .fullSizePhoto,
            originalFilename: "IMG_E0475.HEIC",
            uniformTypeIdentifier: "public.heic"
        )
        let result = try Self.plan(Self.asset(
            id: "missing-edited-live",
            subtypes: [.livePhoto],
            edited: true,
            durationMilliseconds: 3_000,
            resources: [originalStill, currentStill]
        ))
        let relationships = try XCTUnwrap(result.job.assets.first?.livePhotoRelationships)
        let currentID = try XCTUnwrap(relationships.currentMotionFileId)
        let originalID = try XCTUnwrap(relationships.originalMotionFileId)
        XCTAssertNotEqual(currentID, originalID)
        let current = try XCTUnwrap(result.job.files.first { $0.fileId == currentID })
        let original = try XCTUnwrap(result.job.files.first { $0.fileId == originalID })
        XCTAssertEqual(current.roles, [.currentLiveMotion])
        XCTAssertEqual(current.photoKitResourceTypeRaw, 10)
        XCTAssertEqual(original.roles, [.originalLiveMotion])
        XCTAssertEqual(original.photoKitResourceTypeRaw, 9)
        for placeholder in [current, original] {
            XCTAssertEqual(placeholder.storageArea, .libraryData)
            XCTAssertEqual(placeholder.criticality, .archiveRequired)
            XCTAssertEqual(placeholder.availability, .sourceUnavailable)
            XCTAssertTrue(placeholder.proposedRelativePath.hasPrefix("MB Photos Data/Resources/"))
        }
    }

    func testMissingEditedFullSizeResourceCreatesNoMasterFallback() throws {
        let asset = Self.asset(
            id: "missing-current",
            edited: true,
            resources: [
                PhotoResourceDescriptor(
                    id: "missing-current#photo",
                    kind: .photo,
                    originalFilename: "IMG_0500.HEIC",
                    uniformTypeIdentifier: "public.heic"
                )
            ]
        )

        let result = try Self.plan(asset)
        let exportAsset = try XCTUnwrap(result.job.assets.first)
        XCTAssertNil(exportAsset.masterFileId)
        let unavailable = try XCTUnwrap(exportAsset.files.first {
            $0.roles == [.masterCurrent] && $0.availability == .sourceUnavailable
        })
        XCTAssertEqual(unavailable.storageArea, .master)
        XCTAssertEqual(unavailable.criticality, .masterRequired)
        XCTAssertEqual(unavailable.photoKitResourceType, .fullSizePhoto)
        XCTAssertNil(unavailable.byteCount)
        XCTAssertNil(unavailable.sha256)
        XCTAssertNil(result.sourceResourcesByFileID[unavailable.fileId])
        XCTAssertNil(result.sourceAssetIDsByFileID[unavailable.fileId])
        XCTAssertEqual(result.preflight.masterFileCount, 0)
        XCTAssertEqual(result.preflight.missingMasterCount, 1)
        XCTAssertTrue(result.preflight.warnings.contains { $0.contains("no generated fallback") })
    }

    func testRAWAlternateAndUnknownResourcesStayOutsideMasterAndPhotoProxyIsExcluded() throws {
        let primary = PhotoResourceDescriptor(
            id: "raw#primary",
            kind: .photo,
            originalFilename: "IMG_0600.DNG",
            uniformTypeIdentifier: "com.adobe.raw-image"
        )
        let alternate = PhotoResourceDescriptor(
            id: "raw#alternate",
            kind: .alternatePhoto,
            originalFilename: "IMG_0600.JPG",
            uniformTypeIdentifier: "public.jpeg"
        )
        let future = PhotoResourceDescriptor(
            id: "raw#future",
            kind: .unknown,
            rawResourceType: 99,
            originalFilename: "IMG_0600.DEPTH",
            uniformTypeIdentifier: "com.example.depth"
        )
        let proxy = PhotoResourceDescriptor(
            id: "raw#proxy",
            kind: .photoProxy,
            originalFilename: "IMG_0600_PROXY.JPG",
            uniformTypeIdentifier: "public.jpeg"
        )
        let result = try Self.plan(Self.asset(
            id: "raw",
            subtypes: [.raw],
            resources: [primary, alternate, future, proxy]
        ))

        XCTAssertEqual(result.job.files.filter { $0.storageArea == .master }.count, 1)
        XCTAssertEqual(result.job.files.first { $0.photoKitResourceType == .alternatePhoto }?.roles, [.alternateOriginal])
        XCTAssertEqual(result.job.files.first { $0.photoKitResourceTypeRaw == 99 }?.roles, [.auxiliary])
        XCTAssertFalse(result.job.files.contains { $0.originalFilename.contains("PROXY") })
    }

    func testAdjustmentsAndRenderedEditsAreNotOriginals() {
        XCTAssertEqual(ResourceClassifier.classify(.adjustmentData), .adjustment)
        XCTAssertEqual(ResourceClassifier.classify(.adjustmentBasePhoto), .adjustment)
        XCTAssertEqual(ResourceClassifier.classify(.fullSizePhoto), .renderedEdit)
        XCTAssertEqual(ResourceClassifier.classify(.photoProxy), .proxy)
        XCTAssertEqual(ResourceClassifier.classify(.pairedVideo), .original(.pairedVideo))
    }

    private static func plan(_ asset: PhotoAsset) throws -> PlannedExport {
        let frozen = try SelectionService().freeze(
            source: .allAccessible,
            assets: [asset],
            albums: [],
            timeZone: TimeZone(identifier: "UTC")!
        )
        return try ExportPlanner().plan(selection: frozen, albums: [], profile: ExportProfile())
    }

    private static func asset(
        id: String,
        subtypes: Set<AssetMediaSubtype> = [],
        edited: Bool = false,
        modified: Date? = nil,
        durationMilliseconds: Int? = nil,
        resources: [PhotoResourceDescriptor]
    ) -> PhotoAsset {
        PhotoAsset(
            id: id,
            mediaKind: .photo,
            mediaSubtypes: subtypes,
            creationDate: Date(timeIntervalSince1970: 100),
            modificationDate: modified,
            pixelWidth: 4_032,
            pixelHeight: 3_024,
            durationMilliseconds: durationMilliseconds,
            location: nil,
            isFavorite: false,
            isEdited: edited,
            resources: resources
        )
    }

    private static func request(
        revision: UInt64,
        selectionRevision: UInt64 = 0,
        libraryRevision: UInt64 = 0,
        kind: SelectionKind
    ) -> PreflightRequest {
        PreflightRequest(
            revision: revision,
            selectionRevision: selectionRevision,
            libraryRevision: libraryRevision,
            kind: kind,
            rangeStart: Date.distantPast,
            rangeEnd: Date.distantFuture,
            profile: ExportProfile()
        )
    }
}
