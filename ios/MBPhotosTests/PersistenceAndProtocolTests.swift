@testable import MBPhotos
import GRDB
import ImageIO
import XCTest

final class PersistenceAndProtocolTests: XCTestCase {
    func testProtocolFixturesDecode() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let pairData = try Data(contentsOf: root.appending(path: "protocol/fixtures/v1/pair.response.json"))
        let pair = try WireCoders.decoder().decode(PairResponse.self, from: pairData)
        XCTAssertEqual(pair.capabilities.chunkSizeBytes, 8_388_608)
        XCTAssertEqual(pair.destination.pathPolicyVersion, 1)

        let jobData = try Data(contentsOf: root.appending(path: "protocol/fixtures/v1/create-job.request.json"))
        let job = try WireCoders.decoder().decode(ExportJob.self, from: jobData)
        XCTAssertEqual(job.assets.count, 2)
        XCTAssertEqual(job.files.count, 4)
        XCTAssertEqual(job.assets.first?.location?.latitude, 41.8781)
        XCTAssertEqual(job.assets.first?.location?.longitude, -87.6298)

        let responseData = try Data(contentsOf: root.appending(path: "protocol/fixtures/v1/create-job.response.json"))
        let plan = try WireCoders.decoder().decode(JobPlan.self, from: responseData)
        XCTAssertEqual(plan.decisions.first?.action, .resume)
        let preflight = PreflightSummary(
            assetCount: 2,
            originalFileCount: 3,
            generatedJPEGCount: 1,
            estimatedKnownBytes: 1024,
            unknownByteCount: 0,
            editedVideoCount: 0,
            warnings: []
        ).reconciled(with: plan)
        XCTAssertEqual(preflight.destinationFreeBytes, plan.destination.freeBytes)
        XCTAssertEqual(preflight.unchangedFileCount, 1)
        XCTAssertEqual(preflight.resumableFileCount, 1)

        let completeData = try Data(
            contentsOf: root.appending(path: "protocol/fixtures/v1/complete-job-with-failures.request.json")
        )
        let complete = try WireCoders.decoder().decode(CompleteJobRequest.self, from: completeData)
        XCTAssertEqual(complete.failures.count, 1)
        XCTAssertEqual(complete.failures.first?.code, .unavailableSource)

        let reportData = try Data(
            contentsOf: root.appending(path: "protocol/fixtures/v1/completion-report-with-failures.response.json")
        )
        let report = try WireCoders.decoder().decode(CompletionReport.self, from: reportData)
        XCTAssertEqual(report.state, .completedWithFailures)
        XCTAssertEqual(report.counts.filesFailed, 1)
    }

    func testCompleteJobRequestDefaultsMissingFailuresToEmpty() throws {
        let data = Data(#"{"completedAt":"2026-08-24T15:17:52Z"}"#.utf8)
        let request = try WireCoders.decoder().decode(CompleteJobRequest.self, from: data)
        XCTAssertEqual(request.failures, [])
    }

    func testEverySharedProtocolFixtureDecodesAndReencodes() throws {
        try roundTripFixture("pair.request.json", as: PairRequest.self)
        try roundTripFixture("pair.response.json", as: PairResponse.self)
        try roundTripFixture("create-job.request.json", as: ExportJob.self)
        try roundTripFixture("create-job.response.json", as: JobPlan.self)
        try roundTripFixture("job-status.response.json", as: JobStatusResponse.self)
        try roundTripFixture("chunk-receipt.response.json", as: ChunkReceipt.self)
        try roundTripFixture("commit-file.request.json", as: CommitFileRequest.self)
        try roundTripFixture("commit-file.response.json", as: FileCommitReceipt.self)
        try roundTripFixture("complete-job.request.json", as: CompleteJobRequest.self)
        try roundTripFixture("complete-job-with-failures.request.json", as: CompleteJobRequest.self)
        try roundTripFixture("completion-report.response.json", as: CompletionReport.self)
        try roundTripFixture("completion-report-with-failures.response.json", as: CompletionReport.self)
        try roundTripFixture("abandon-job.request.json", as: AbandonJobRequest.self)
        try roundTripFixture("abandon-job.response.json", as: AbandonmentReceipt.self)
        try roundTripFixture("api-error.response.json", as: APIErrorResponse.self)
    }

    func testWireEncoderWritesRequiredNullsAndOmitsOptionalNulls() throws {
        let assetID = UUID()
        let file = ExportFile(
            fileId: UUID(),
            assetId: assetID,
            kind: .originalResource,
            resourceType: .photo,
            originalFilename: "IMG_0001.HEIC",
            proposedRelativePath: "Photos/Undated/IMG_0001.HEIC",
            byteCount: nil,
            sha256: nil,
            sourceRevision: String(repeating: "a", count: 64),
            captureDate: nil,
            contentType: nil
        )
        let fingerprint = RecoveryFingerprint(
            captureDate: nil,
            pixelWidth: 0,
            pixelHeight: 0,
            durationMilliseconds: nil,
            mediaType: .photo,
            originalFilenames: [file.originalFilename],
            resourceByteCounts: [nil]
        )
        let asset = ExportAsset(
            assetId: assetID,
            sourceLocalIdentifier: "fixture/undated",
            sourceRevision: file.sourceRevision,
            mediaType: .photo,
            mediaSubtypes: [],
            creationDate: nil,
            modificationDate: nil,
            location: nil,
            isEdited: false,
            recoveryFingerprint: fingerprint,
            files: [file]
        )
        let membership = AlbumMembership(
            albumId: UUID(),
            sourceAlbumIdentifier: "fixture/album",
            albumTitle: "Fixture",
            parentAlbumId: nil,
            assetId: assetID
        )
        let job = ExportJob(
            protocolVersion: 1,
            jobId: UUID(),
            createdAt: Date(timeIntervalSince1970: 0),
            sourceTimeZone: "UTC",
            profile: ExportProfile(kind: .preserveOriginals, preserveLocation: false),
            selection: ExportSelection(
                kind: .allAccessible,
                assetCount: 1,
                dateRange: nil,
                sourceAlbumIdentifiers: nil
            ),
            assets: [asset],
            albumMemberships: [membership]
        )
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: WireCoders.encoder().encode(job)) as? [String: Any]
        )
        let profileObject = try XCTUnwrap(root["profile"] as? [String: Any])
        XCTAssertNil(profileObject["jpegRendererVersion"])
        let assetObject = try XCTUnwrap((root["assets"] as? [[String: Any]])?.first)
        XCTAssertTrue(assetObject["creationDate"] is NSNull)
        XCTAssertTrue(assetObject["modificationDate"] is NSNull)
        XCTAssertNil(assetObject["location"])
        let fingerprintObject = try XCTUnwrap(assetObject["recoveryFingerprint"] as? [String: Any])
        XCTAssertTrue(fingerprintObject["captureDate"] is NSNull)
        XCTAssertTrue(fingerprintObject["durationMilliseconds"] is NSNull)
        let fileObject = try XCTUnwrap((assetObject["files"] as? [[String: Any]])?.first)
        for key in ["byteCount", "sha256", "captureDate", "contentType"] {
            XCTAssertTrue(fileObject[key] is NSNull, "Expected required null for \(key)")
        }
        let membershipObject = try XCTUnwrap((root["albumMemberships"] as? [[String: Any]])?.first)
        XCTAssertTrue(membershipObject["parentAlbumId"] is NSNull)
    }

    func testSQLiteLedgerPersistsFrozenJobAndHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let ledger = try SQLiteLedger(url: directory.appending(path: "ledger.sqlite"))
        let asset = FixtureFactory.asset()
        let frozen = try SelectionService().freeze(source: .allAccessible, assets: [asset], albums: [])
        let planned = try ExportPlanner().plan(
            selection: frozen,
            albums: [],
            profile: ExportProfile(kind: .preserveOriginals, preserveLocation: true)
        )
        try await ledger.savePlannedJob(planned.job)
        let loaded = try await ledger.loadJob(planned.job.jobId)
        XCTAssertEqual(try WireCoders.encoder().encode(loaded), try WireCoders.encoder().encode(planned.job))
        let history = try await ledger.history()
        XCTAssertEqual(history.first?.id, planned.job.jobId)
        XCTAssertEqual(history.first?.status, .planned)
    }

    func testSQLiteLedgerNormalizesInterruptedJobAndRetainsDestinationBinding() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let databaseURL = directory.appending(path: "ledger.sqlite")
        let firstLedger = try SQLiteLedger(url: databaseURL)
        let frozen = try SelectionService().freeze(
            source: .allAccessible,
            assets: [FixtureFactory.asset()],
            albums: []
        )
        let planned = try ExportPlanner().plan(
            selection: frozen,
            albums: [],
            profile: ExportProfile(kind: .preserveOriginals, preserveLocation: true)
        )
        let destination = Destination(
            destinationId: UUID(),
            displayName: "Fixture PC",
            createdAt: Date(timeIntervalSince1970: 100),
            freeBytes: 1_000_000,
            pathPolicyVersion: ExportConstants.pathPolicyVersion
        )
        try await firstLedger.savePlannedJob(planned.job)
        try await firstLedger.attachDestination(destination, to: planned.job.jobId)
        try await firstLedger.updateJobStatus(.transferring, jobID: planned.job.jobId)

        let reopenedLedger = try SQLiteLedger(url: databaseURL)
        let reopenedStatus = try await reopenedLedger.history().first?.status
        let reopenedDestinationID = try await reopenedLedger.destinationID(for: planned.job.jobId)

        XCTAssertEqual(reopenedStatus, .paused)
        XCTAssertEqual(reopenedDestinationID, destination.destinationId)
    }

    func testTerminalStagingRecoveryRemovesTerminalJobAndRetainsPausedJob() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let databaseURL = directory.appending(path: "ledger.sqlite")
        let stagingRoot = directory.appending(path: "Staging", directoryHint: .isDirectory)
        let ledger = try SQLiteLedger(url: databaseURL)
        let staging = StagedRenditionStore(root: stagingRoot)

        let frozen = try SelectionService().freeze(
            source: .allAccessible,
            assets: [FixtureFactory.asset()],
            albums: []
        )
        let terminal = try ExportPlanner().plan(
            selection: frozen,
            albums: [],
            profile: ExportProfile(kind: .preserveOriginals, preserveLocation: true)
        ).job
        let paused = ExportJob(
            protocolVersion: terminal.protocolVersion,
            jobId: UUID(),
            createdAt: terminal.createdAt,
            sourceTimeZone: terminal.sourceTimeZone,
            profile: terminal.profile,
            selection: terminal.selection,
            assets: terminal.assets,
            albumMemberships: terminal.albumMemberships
        )
        try await ledger.savePlannedJob(terminal)
        try await ledger.updateJobStatus(.completed, jobID: terminal.jobId)
        try await ledger.savePlannedJob(paused)
        try await ledger.updateJobStatus(.paused, jobID: paused.jobId)

        let terminalDirectory = stagingRoot.appending(
            path: terminal.jobId.uuidString.lowercased(),
            directoryHint: .isDirectory
        )
        let pausedDirectory = stagingRoot.appending(
            path: paused.jobId.uuidString.lowercased(),
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: terminalDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pausedDirectory, withIntermediateDirectories: true)
        try Data("terminal rendition".utf8).write(to: terminalDirectory.appending(path: "file.jpg"))
        try Data("paused rendition".utf8).write(to: pausedDirectory.appending(path: "file.jpg"))

        // Reopening models a force-quit after the terminal commit but before
        // best-effort staging deletion.
        let reopenedLedger = try SQLiteLedger(url: databaseURL)
        let removedCount = try await staging.sweepTerminalJobs(using: reopenedLedger)

        XCTAssertEqual(removedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: terminalDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pausedDirectory.path))
    }

    func testGRDBMigrationIsIdempotentAndFailedWriteRollsBack() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let databaseURL = directory.appending(path: "ledger.sqlite")
        let ledger = try SQLiteLedger(url: databaseURL)
        _ = try SQLiteLedger(url: databaseURL)

        let orphan = FixtureFactory.asset().resources[0]
        let missingJobFile = ExportFile(
            fileId: UUID(),
            assetId: UUID(),
            kind: .originalResource,
            resourceType: orphan.kind,
            originalFilename: orphan.originalFilename,
            proposedRelativePath: "Photos/2026/IMG_0001.HEIC",
            byteCount: nil,
            sha256: nil,
            sourceRevision: String(repeating: "a", count: 64),
            captureDate: nil,
            contentType: "image/heic"
        )
        do {
            try await ledger.recordFile(
                missingJobFile,
                jobID: UUID(),
                status: .verified,
                acceptedPath: missingJobFile.proposedRelativePath,
                digest: FileDigest(byteCount: 1, sha256: String(repeating: "b", count: 64)),
                acknowledgedChunkCount: 1
            )
            XCTFail("The foreign-key violation should roll back the write")
        } catch {
            // Expected: the file and counter update share one GRDB transaction.
        }

        let inspection = try DatabaseQueue(path: databaseURL.path)
        let migrationCount = try await inspection.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM grdb_migrations")
        }
        let fileCount = try await inspection.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM files")
        }
        let membershipIndexes = try await inspection.read {
            try String.fetchAll(
                $0,
                sql: "SELECT name FROM pragma_index_list('photo_library_album_assets')"
            )
        }
        XCTAssertEqual(migrationCount, 10)
        XCTAssertEqual(fileCount, 0)
        XCTAssertTrue(membershipIndexes.contains("photo_library_album_assets_asset"))
    }

    func testV8MigratesMatchingLegacyAnalysisToIndependentRevision() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let databaseURL = directory.appending(path: "ledger.sqlite")
        _ = try SQLiteLedger(url: databaseURL)
        let asset = FixtureFactory.asset(id: "legacy-analysis")

        var legacyAssetObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: WireCoders.encoder().encode(asset)
            ) as? [String: Any]
        )
        legacyAssetObject.removeValue(forKey: "analysisRevision")
        let legacyAssetData = try JSONSerialization.data(withJSONObject: legacyAssetObject)
        let analyzedAt = Date(timeIntervalSince1970: 500)
        let legacyRecord = AssetAnalysisRecord(
            assetID: asset.id,
            sourceRevision: asset.sourceRevision,
            status: .complete,
            fingerprint: AssetFingerprint(
                assetID: asset.id,
                sourceRevision: asset.sourceRevision,
                resources: [ResourceFingerprint(kind: .photo, byteCount: 42, sha256: "digest")],
                analyzedAt: analyzedAt
            ),
            updatedAt: analyzedAt,
            errorMessage: nil
        )
        let legacyRecordData = try WireCoders.encoder().encode(legacyRecord)
        let inspection = try DatabaseQueue(path: databaseURL.path)
        try await inspection.write { database in
            try database.execute(
                sql: "INSERT INTO photo_library_assets(asset_id, asset_json) VALUES (?, ?)",
                arguments: [asset.id, legacyAssetData]
            )
            try database.execute(
                sql: """
                INSERT INTO organize_analysis(
                    asset_id, source_revision, status, known_byte_count,
                    exact_duplicate_key, updated_at, record_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    asset.id,
                    asset.sourceRevision,
                    AnalysisStatus.complete.rawValue,
                    42,
                    legacyRecord.exactDuplicateKey,
                    WireDate.string(analyzedAt),
                    legacyRecordData
                ]
            )
            try database.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier=?",
                arguments: ["v8-independent-analysis-revision"]
            )
        }

        let migratedLedger = try SQLiteLedger(url: databaseURL)
        let migratedRecords = try await migratedLedger.analysisRecords()
        let migrated = try XCTUnwrap(migratedRecords[asset.id])
        let rawRevision = try await inspection.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT source_revision FROM organize_analysis WHERE asset_id=?",
                arguments: [asset.id]
            )
        }

        XCTAssertEqual(migrated.sourceRevision, asset.analysisRevision)
        XCTAssertEqual(migrated.fingerprint?.sourceRevision, asset.analysisRevision)
        XCTAssertEqual(migrated.knownByteCount, 42)
        XCTAssertEqual(rawRevision, asset.analysisRevision)
    }

    func testVisualAnalysisRoundTripsAndCascadesWithCachedAsset() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let databaseURL = directory.appending(path: "ledger.sqlite")
        let ledger = try SQLiteLedger(url: databaseURL)
        let asset = FixtureFactory.asset(id: "visual-analysis")
        try await ledger.replaceCachedPhotoLibrarySnapshot(
            PhotoLibrarySnapshot(
                assets: [asset],
                albums: [],
                changeTokenData: nil
            ),
            authorization: .authorized
        )
        let analyzedAt = Date(timeIntervalSince1970: 1_700_000_123)
        let record = VisualAnalysisRecord(
            assetID: asset.id,
            sourceRevision: asset.analysisRevision,
            algorithmVersion: VisualAnalysisAlgorithm.currentVersion,
            visionRevisions: .pinnedV1,
            featurePrint: nil,
            aesthetics: VisualAestheticsResult(overallScore: -0.6, isUtility: true),
            faces: VisualFaceResult(count: 1, bestCaptureQuality: 0.8),
            text: VisualTextStatistics(observationCount: 4, normalizedCoverage: 0.25),
            containsBarcode: true,
            saliency: VisualSaliencyResult(
                salientObjectCount: 0,
                maximumValue: nil,
                noClearSubject: true
            ),
            lensSmudge: nil,
            analyzedAt: analyzedAt
        )

        try await ledger.saveVisualAnalysisRecord(record)
        let loaded = try await ledger.visualAnalysisRecords()
        XCTAssertEqual(loaded[asset.id], record)
        XCTAssertTrue(try XCTUnwrap(loaded[asset.id]).isValid(for: asset))

        try await ledger.replaceCachedPhotoLibrarySnapshot(
            PhotoLibrarySnapshot(assets: [], albums: [], changeTokenData: nil),
            authorization: .authorized
        )
        let remainingRecords = try await ledger.visualAnalysisRecords()
        XCTAssertTrue(remainingRecords.isEmpty)
    }

    func testVisualAnalysisAttemptPersistsAndSuccessfulEvidenceClearsIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let databaseURL = directory.appending(path: "ledger.sqlite")
        let ledger = try SQLiteLedger(url: databaseURL)
        let asset = FixtureFactory.asset(id: "visual-attempt")
        try await ledger.replaceCachedPhotoLibrarySnapshot(
            PhotoLibrarySnapshot(assets: [asset], albums: [], changeTokenData: nil),
            authorization: .authorized
        )
        let attemptedAt = Date(timeIntervalSince1970: 1_700_000_456)
        let attempt = VisualAnalysisAttemptRecord(
            assetID: asset.id,
            sourceRevision: asset.analysisRevision,
            algorithmVersion: VisualAnalysisAlgorithm.currentVersion,
            visionRevisions: .pinnedV1,
            status: .unavailableLocally,
            attemptedAt: attemptedAt
        )

        try await ledger.saveVisualAnalysisAttempt(attempt)
        let loadedAttempts = try await ledger.visualAnalysisAttempts()
        XCTAssertEqual(loadedAttempts[asset.id], attempt)

        let record = VisualAnalysisRecord(
            assetID: asset.id,
            sourceRevision: asset.analysisRevision,
            algorithmVersion: VisualAnalysisAlgorithm.currentVersion,
            visionRevisions: .pinnedV1,
            featurePrint: nil,
            aesthetics: nil,
            faces: VisualFaceResult(count: 0, bestCaptureQuality: nil),
            text: VisualTextStatistics(observationCount: 0, normalizedCoverage: 0),
            containsBarcode: false,
            saliency: nil,
            lensSmudge: nil,
            analyzedAt: attemptedAt.addingTimeInterval(10)
        )
        try await ledger.saveVisualAnalysisRecord(record)

        let loadedRecords = try await ledger.visualAnalysisRecords()
        let clearedAttempts = try await ledger.visualAnalysisAttempts()
        XCTAssertEqual(loadedRecords[asset.id], record)
        XCTAssertTrue(clearedAttempts.isEmpty)
    }

    func testCorruptVisualAnalysisCacheRowIsDiscardedWithoutFailingLoad() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let databaseURL = directory.appending(path: "ledger.sqlite")
        let ledger = try SQLiteLedger(url: databaseURL)
        let asset = FixtureFactory.asset(id: "corrupt-visual-cache")
        try await ledger.replaceCachedPhotoLibrarySnapshot(
            PhotoLibrarySnapshot(assets: [asset], albums: [], changeTokenData: nil),
            authorization: .authorized
        )
        let record = VisualAnalysisRecord(
            assetID: asset.id,
            sourceRevision: asset.analysisRevision,
            algorithmVersion: VisualAnalysisAlgorithm.currentVersion,
            visionRevisions: .pinnedV1,
            featurePrint: nil,
            aesthetics: nil,
            faces: VisualFaceResult(count: 0, bestCaptureQuality: nil),
            text: VisualTextStatistics(observationCount: 0, normalizedCoverage: 0),
            containsBarcode: false,
            saliency: nil,
            lensSmudge: nil,
            analyzedAt: Date(timeIntervalSince1970: 1_700_000_789)
        )
        try await ledger.saveVisualAnalysisRecord(record)
        let inspection = try DatabaseQueue(path: databaseURL.path)
        try await inspection.write { database in
            try database.execute(
                sql: "UPDATE organize_visual_analysis SET record_json=? WHERE asset_id=?",
                arguments: [Data("not-json".utf8), asset.id]
            )
        }

        let loadedRecords = try await ledger.visualAnalysisRecords()
        XCTAssertTrue(loadedRecords.isEmpty)
        let remainingCount = try await inspection.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM organize_visual_analysis")
        }
        XCTAssertEqual(remainingCount, 0)
    }

    func testVerifiedAssetFinalizationBatchHonorsCancellationBeforeWriting() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let databaseURL = directory.appending(path: "ledger.sqlite")
        let ledger = try SQLiteLedger(url: databaseURL)
        let gate = LedgerCancellationGate()
        let fingerprint = RecoveryFingerprint(
            captureDate: nil,
            pixelWidth: 4_032,
            pixelHeight: 3_024,
            durationMilliseconds: nil,
            mediaType: .photo,
            originalFilenames: ["IMG_0001.HEIC"],
            resourceByteCounts: [nil]
        )
        let records = (0..<10_000).map { index in
            VerifiedAssetExportRecord(
                sourceLocalIdentifier: "asset-\(index)",
                sourceRevision: String(repeating: "a", count: 63) + String(index % 10),
                recoveryFingerprint: fingerprint
            )
        }
        let destinationID = UUID()
        let write = Task {
            await gate.wait()
            try await ledger.recordVerifiedAssets(
                destinationID: destinationID,
                records: records
            )
        }
        await gate.waitUntilBlocked()
        write.cancel()
        await gate.open()

        do {
            try await write.value
            XCTFail("A cancelled finalization batch must stop before writing")
        } catch is CancellationError {
            // Expected.
        }

        let inspection = try DatabaseQueue(path: databaseURL.path)
        let count = try await inspection.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM asset_exports")
        }
        XCTAssertEqual(count, 0)
    }

    func testLocationMetadataPolicy() {
        let source: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 41.8],
            kCGImagePropertyIPTCDictionary: [
                kCGImagePropertyIPTCCity: "Chicago",
                kCGImagePropertyIPTCCaptionAbstract: "Family picnic"
            ],
            "{XMP}" as CFString: [
                "Location" as CFString: "Chicago",
                "Copyright" as CFString: "Fixture creator"
            ],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Fixture Camera"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifExposureTime: 0.01]
        ]
        let removed = JPEGMetadataPolicy.outputProperties(source: source, preserveLocation: false)
        XCTAssertNil(removed[kCGImagePropertyGPSDictionary])
        let retainedIPTC = removed[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        XCTAssertNil(retainedIPTC?[kCGImagePropertyIPTCCity])
        XCTAssertEqual(retainedIPTC?[kCGImagePropertyIPTCCaptionAbstract] as? String, "Family picnic")
        let retainedXMP = removed["{XMP}" as CFString] as? [CFString: Any]
        XCTAssertNil(retainedXMP?["Location" as CFString])
        XCTAssertEqual(retainedXMP?["Copyright" as CFString] as? String, "Fixture creator")
        XCTAssertEqual(
            (removed[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] as? String,
            "Fixture Camera"
        )
        XCTAssertEqual(
            (removed[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifExposureTime] as? Double,
            0.01
        )
        XCTAssertEqual(removed[kCGImagePropertyOrientation] as? Int, 1)
        let retained = JPEGMetadataPolicy.outputProperties(
            source: source,
            preserveLocation: true,
            authoritativeLocation: AssetLocation(latitude: -33.86, longitude: 151.21, altitudeMeters: 12)
        )
        let retainedGPS = retained[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        XCTAssertEqual(retainedGPS?[kCGImagePropertyGPSLatitude] as? Double, 33.86)
        XCTAssertEqual(retainedGPS?[kCGImagePropertyGPSLatitudeRef] as? String, "S")
        XCTAssertEqual(retainedGPS?[kCGImagePropertyGPSLongitude] as? Double, 151.21)
        XCTAssertEqual(retainedGPS?[kCGImagePropertyGPSLongitudeRef] as? String, "E")
        XCTAssertEqual(retained[kCGImageDestinationLossyCompressionQuality] as? Double, 0.92)
    }

    func testFixtureRenditionProviderWritesKnownBytes() async throws {
        let data = Data("fixture-original".utf8)
        let output = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let provider = FixtureOriginalProvider(bytes: data)
        try await provider.materializeOriginal(
            assetID: "fixture",
            descriptor: FixtureFactory.asset().resources[0],
            to: output,
            progress: { _ in }
        )
        XCTAssertEqual(try Data(contentsOf: output), data)
        XCTAssertEqual(try FileDigest.compute(url: output).byteCount, Int64(data.count))
    }

    func testFileDigestHonorsCancellationBeforeReading() async throws {
        let output = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data(repeating: 0x5a, count: 2 * 1_024 * 1_024).write(to: output, options: .atomic)
        defer { try? FileManager.default.removeItem(at: output) }

        let hashing = Task.detached(priority: .utility) {
            while !Task.isCancelled { await Task.yield() }
            try FileDigest.compute(url: output, bufferSize: 4_096)
        }
        hashing.cancel()

        do {
            _ = try await hashing.value
            XCTFail("Cancelled hashing unexpectedly completed")
        } catch is CancellationError {
            // Expected: cancellation is checked before and between every read.
        }
    }

    private func roundTripFixture<Value: Codable>(_ name: String, as type: Value.Type) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appending(path: "protocol/fixtures/v1/\(name)"))
        let decoded = try WireCoders.decoder().decode(type, from: data)
        _ = try WireCoders.encoder().encode(decoded)
    }
}

private actor LedgerCancellationGate {
    private var isBlocked = false
    private var openContinuation: CheckedContinuation<Void, Never>?
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        isBlocked = true
        let waiters = blockedWaiters
        blockedWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { openContinuation = $0 }
    }

    func waitUntilBlocked() async {
        if isBlocked { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }

    func open() {
        openContinuation?.resume()
        openContinuation = nil
    }
}
