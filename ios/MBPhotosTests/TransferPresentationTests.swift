@testable import MBPhotos
import XCTest

final class TransferPresentationTests: XCTestCase {
    @MainActor
    func testTransferPreferencesAlwaysUsePortableLibrary() {
        let suiteName = "TransferPresentationTests.preferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = TransferPreferences(defaults: defaults)
        XCTAssertEqual(initial.profileKind, .portableLibrary)

        initial.profileKind = .originalsAndCurrentJpegs

        let reloaded = TransferPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.profileKind, .portableLibrary)
    }

    func testOnlyFullSuccessClearsTheQuickSelection() {
        XCTAssertTrue(TransferPresentationPolicy.clearsQuickSelection(after: .completed))
        XCTAssertFalse(TransferPresentationPolicy.clearsQuickSelection(after: .completedWithFailures))
        XCTAssertFalse(TransferPresentationPolicy.clearsQuickSelection(after: .failed))
        XCTAssertFalse(TransferPresentationPolicy.clearsQuickSelection(after: .paused))
    }

    func testFrozenResumeSurvivesPairingWhileOrdinaryPreflightIsInvalidated() {
        let jobID = UUID()
        XCTAssertFalse(
            TransferPresentationPolicy.shouldInvalidatePreparedTransferForConnection(
                preparedJobID: jobID,
                frozenResumeJobID: jobID,
                isPlanning: false,
                hasPendingPreflight: false
            )
        )
        XCTAssertTrue(
            TransferPresentationPolicy.shouldInvalidatePreparedTransferForConnection(
                preparedJobID: jobID,
                frozenResumeJobID: nil,
                isPlanning: false,
                hasPendingPreflight: false
            )
        )
        XCTAssertTrue(
            TransferPresentationPolicy.shouldInvalidatePreparedTransferForConnection(
                preparedJobID: nil,
                frozenResumeJobID: nil,
                isPlanning: true,
                hasPendingPreflight: false
            )
        )
    }

    func testFileProgressIsMonotonicAcrossPhaseBoundaries() {
        var progress = ExportProgressState(totalFileCount: 1)
        progress.beginFile(index: 1, filename: "example.mov")

        progress.advanceCurrentFile(through: .preparation, phaseFraction: 1)
        XCTAssertEqual(progress.currentFileFraction, 0.15, accuracy: 0.000_001)

        // Every phase begins at the preceding phase's endpoint, so resetting a
        // phase-local callback to zero cannot make lock-screen progress regress.
        progress.advanceCurrentFile(through: .hashing, phaseFraction: 0)
        XCTAssertEqual(progress.currentFileFraction, 0.15, accuracy: 0.000_001)
        progress.advanceCurrentFile(through: .hashing, phaseFraction: 0.5)
        XCTAssertEqual(progress.currentFileFraction, 0.20, accuracy: 0.000_001)
        progress.advanceCurrentFile(through: .transfer, phaseFraction: 0)
        XCTAssertEqual(progress.currentFileFraction, 0.25, accuracy: 0.000_001)
        progress.advanceCurrentFile(through: .transfer, phaseFraction: 0.5)
        XCTAssertEqual(progress.currentFileFraction, 0.60, accuracy: 0.000_001)

        // A late callback from an earlier stage cannot overwrite newer work.
        progress.advanceCurrentFile(through: .preparation, phaseFraction: 0.25)
        XCTAssertEqual(progress.currentFileFraction, 0.60, accuracy: 0.000_001)
        progress.advanceCurrentFile(through: .verification, phaseFraction: 0)
        XCTAssertEqual(progress.currentFileFraction, 0.95, accuracy: 0.000_001)

        progress.completeCurrentFile()
        XCTAssertEqual(progress.currentFileFraction, 1)
        XCTAssertEqual(progress.overallFraction, 1)
    }

    func testFileRolloverDoesNotJumpOrRegressOverallProgress() {
        var progress = ExportProgressState(totalFileCount: 3)
        progress.beginFile(index: 1, filename: "first.jpg")
        progress.completeCurrentFile()
        let completedFirst = progress.overallFraction

        progress.beginFile(index: 2, filename: "second.jpg")

        XCTAssertEqual(progress.overallFraction, completedFirst, accuracy: 0.000_001)
        XCTAssertEqual(progress.currentFileFraction, 0)
    }

    func testTransferPhotoBadgesExposeLiveVideoAndEditedMetadata() {
        let liveEdited = PhotoAsset(
            id: "live-edited",
            mediaKind: .photo,
            mediaSubtypes: [.livePhoto],
            creationDate: nil,
            modificationDate: nil,
            pixelWidth: 1,
            pixelHeight: 1,
            durationMilliseconds: nil,
            location: nil,
            isFavorite: false,
            isEdited: true,
            resources: []
        )
        let video = PhotoAsset(
            id: "video",
            mediaKind: .video,
            mediaSubtypes: [],
            creationDate: nil,
            modificationDate: nil,
            pixelWidth: 1,
            pixelHeight: 1,
            durationMilliseconds: 1_000,
            location: nil,
            isFavorite: false,
            isEdited: false,
            resources: []
        )

        XCTAssertEqual(TransferPhotoBadge.badges(for: liveEdited), [.livePhoto, .edited])
        XCTAssertEqual(TransferPhotoBadge.badges(for: video), [.video])
    }

    func testDragSelectionVisitsEachPhotoOnlyOnce() {
        var session = TransferPhotoDragSession(isSelecting: true, lastLocation: .zero)

        XCTAssertTrue(session.visit("one"))
        XCTAssertTrue(session.visit("two"))
        XCTAssertFalse(session.visit("one"))
        XCTAssertEqual(session.visitedAssetIDs, ["one", "two"])
    }

    func testTransferPhotosCanBeGroupedByDayMonthAndYear() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let augustSecond = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 2, hour: 12))
        )
        let augustFirst = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 1, hour: 12))
        )
        let july2025 = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2025, month: 7, day: 31, hour: 12))
        )
        let assets = [
            makePhotoAsset(id: "august-first", creationDate: augustFirst),
            makePhotoAsset(id: "unknown", creationDate: nil),
            makePhotoAsset(id: "july-2025", creationDate: july2025),
            makePhotoAsset(id: "august-second", creationDate: augustSecond)
        ]

        XCTAssertEqual(
            TransferPhotoDateSection.sections(
                for: assets,
                grouping: .day,
                calendar: calendar
            ).map { $0.assets.map(\.id) },
            [["august-second"], ["august-first"], ["july-2025"], ["unknown"]]
        )
        XCTAssertEqual(
            TransferPhotoDateSection.sections(
                for: assets,
                grouping: .month,
                calendar: calendar
            ).map { $0.assets.map(\.id) },
            [["august-first", "august-second"], ["july-2025"], ["unknown"]]
        )
        XCTAssertEqual(
            TransferPhotoDateSection.sections(
                for: assets,
                grouping: .year,
                calendar: calendar
            ).map { $0.assets.map(\.id) },
            [["august-first", "august-second"], ["july-2025"], ["unknown"]]
        )
        XCTAssertEqual(TransferPhotoDateGrouping.allCases.map(\.label), ["Day", "Month", "Year"])
    }

    func testSelectionSizeIncludesAlbumAssetsWithoutDoubleCounting() {
        let album = PhotoAlbum(
            id: "album",
            title: "Album",
            parentID: nil,
            assetIDs: ["one", "two"]
        )
        let bytesByAssetID: [String: Int64] = ["one": 100, "two": 250]

        let size = TransferSelectionSize.calculate(
            selectedAssetIDs: ["one"],
            selectedAlbumIDs: ["album"],
            albums: [album],
            knownByteCount: { bytesByAssetID[$0] }
        )

        XCTAssertEqual(
            size,
            TransferSelectionSize(assetCount: 2, knownBytes: 350, unknownAssetCount: 0)
        )
    }

    func testSelectionSizePresentationDoesNotCallPartialBytesATotal() {
        let formatter: (Int64, ByteCountFormatter.CountStyle) -> String = { bytes, _ in
            "\(bytes) bytes"
        }

        XCTAssertEqual(
            TransferSelectionSizePresentation.text(
                for: TransferSelectionSize(
                    assetCount: 2,
                    knownBytes: 350,
                    unknownAssetCount: 0
                ),
                byteCountFormatter: formatter
            ),
            "Total size: 350 bytes"
        )
        XCTAssertEqual(
            TransferSelectionSizePresentation.text(
                for: TransferSelectionSize(
                    assetCount: 3,
                    knownBytes: 350,
                    unknownAssetCount: 1
                ),
                byteCountFormatter: formatter
            ),
            "Known size: 350 bytes · 1 item pending"
        )
        XCTAssertEqual(
            TransferSelectionSizePresentation.text(
                for: TransferSelectionSize(
                    assetCount: 1,
                    knownBytes: 0,
                    unknownAssetCount: 1
                ),
                byteCountFormatter: formatter
            ),
            "Total size: Calculating…"
        )
    }

    func testPhotoDragIntentPrioritizesVerticalScrolling() {
        XCTAssertEqual(
            TransferPhotoDragIntent.resolve(CGSize(width: 4, height: 10)),
            .scrolling
        )
        XCTAssertEqual(
            TransferPhotoDragIntent.resolve(CGSize(width: 18, height: 12)),
            .scrolling
        )
    }

    func testPhotoDragIntentRequiresADeliberateHorizontalSwipe() {
        XCTAssertEqual(
            TransferPhotoDragIntent.resolve(CGSize(width: 18, height: 2)),
            .undecided
        )
        XCTAssertEqual(
            TransferPhotoDragIntent.resolve(CGSize(width: 24, height: 8)),
            .selecting
        )
    }

    private func makePhotoAsset(id: String, creationDate: Date?) -> PhotoAsset {
        PhotoAsset(
            id: id,
            mediaKind: .photo,
            mediaSubtypes: [],
            creationDate: creationDate,
            modificationDate: nil,
            pixelWidth: 1,
            pixelHeight: 1,
            durationMilliseconds: nil,
            location: nil,
            isFavorite: false,
            isEdited: false,
            resources: []
        )
    }
}
