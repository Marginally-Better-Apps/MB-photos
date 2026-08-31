@testable import MBPhotos
import XCTest

final class SelectionAndPlannerTests: XCTestCase {
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
        XCTAssertEqual(result.job.files.count, 50_000)
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

    func testPlannerCreatesOriginalAndCurrentJPEGForHEIC() throws {
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
            profile: ExportProfile(kind: .originalsAndCurrentJpegs, preserveLocation: false),
            jobID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        )
        XCTAssertEqual(result.job.files.map(\.kind), [.originalResource, .currentJpeg])
        XCTAssertTrue(result.job.files[1].proposedRelativePath.hasSuffix("IMG_0001__current.jpg"))
        XCTAssertEqual(result.job.files[0].contentType, "image/heic")
        XCTAssertEqual(result.job.profile.jpegRendererVersion, ExportConstants.jpegRendererVersion)
    }

    func testCompatibleUneditedJPEGIsNotDuplicated() throws {
        let asset = FixtureFactory.asset(filename: "IMG_1.JPG", uti: "public.jpeg")
        let frozen = try SelectionService().freeze(source: .allAccessible, assets: [asset], albums: [])
        let result = try ExportPlanner().plan(
            selection: frozen,
            albums: [],
            profile: ExportProfile(kind: .originalsAndCurrentJpegs, preserveLocation: true)
        )
        XCTAssertEqual(result.job.files.count, 1)
        XCTAssertEqual(result.job.files.first?.kind, .originalResource)
    }

    func testPlannerIncludesLocationOnlyWhenProfilePreservesIt() throws {
        let location = AssetLocation(latitude: 41.8781, longitude: -87.6298, altitudeMeters: 181)
        let asset = FixtureFactory.asset(location: location)
        let frozen = try SelectionService().freeze(source: .allAccessible, assets: [asset], albums: [])

        let preserving = try ExportPlanner().plan(
            selection: frozen,
            albums: [],
            profile: ExportProfile(kind: .preserveOriginals, preserveLocation: true)
        )
        let removing = try ExportPlanner().plan(
            selection: frozen,
            albums: [],
            profile: ExportProfile(kind: .preserveOriginals, preserveLocation: false)
        )

        XCTAssertEqual(preserving.job.assets.first?.location, location)
        XCTAssertNil(removing.job.assets.first?.location)
    }

    func testAdjustmentsAndRenderedEditsAreNotOriginals() {
        XCTAssertEqual(ResourceClassifier.classify(.adjustmentData), .adjustment)
        XCTAssertEqual(ResourceClassifier.classify(.adjustmentBasePhoto), .adjustment)
        XCTAssertEqual(ResourceClassifier.classify(.fullSizePhoto), .renderedEdit)
        XCTAssertEqual(ResourceClassifier.classify(.photoProxy), .proxy)
        XCTAssertEqual(ResourceClassifier.classify(.pairedVideo), .original(.pairedVideo))
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
            profile: ExportProfile(kind: .preserveOriginals, preserveLocation: true)
        )
    }
}
