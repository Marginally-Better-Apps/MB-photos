import Foundation
import GRDB

enum LocalJobStatus: String, Codable, Sendable {
    case planned
    case preparing
    case transferring
    case paused
    case completed
    case completedWithFailures
    case abandoned
}

enum LocalFileStatus: String, Sendable {
    case planned
    case preparing
    case transferring
    case verified
    case skipped
    case failed
}

struct ExportHistoryEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let updatedAt: Date
    let status: LocalJobStatus
    let profile: ExportProfileKind
    let assetCount: Int
    let totalFileCount: Int
    let verifiedFileCount: Int
    let skippedFileCount: Int
    let failedFileCount: Int
    let verifiedByteCount: Int64
    let destinationName: String?
    let completionReport: CompletionReport?
}

struct VerifiedAssetExportRecord: Sendable {
    let sourceLocalIdentifier: String
    let sourceRevision: String
    let recoveryFingerprint: RecoveryFingerprint
}

struct InterruptedDeletionRecovery: Equatable, Sendable {
    let batchCount: Int
    let itemCount: Int

    static let none = InterruptedDeletionRecovery(batchCount: 0, itemCount: 0)
}

struct InterruptedAnalysisRecovery: Equatable, Sendable {
    let runCount: Int
    let assetCount: Int

    static let none = InterruptedAnalysisRecovery(runCount: 0, assetCount: 0)
}

/// Constant-size analysis state for progress observers. Unlike
/// `AnalysisRunRecord`, reading this value never hydrates the durable work
/// order or allocates a completed-ID set.
struct AnalysisRunProgressSnapshot: Equatable, Sendable {
    let id: UUID
    let includesICloudItems: Bool
    let origin: AnalysisRunOrigin
    let status: AnalysisRunStatus
    let nextPosition: Int
    let completedAssetCount: Int
    let totalAssetCount: Int
    let errorMessage: String?
}

private struct CachedPhotoLibraryAssetRow: Sendable {
    let identifier: String
    let json: Data
}

private struct CachedPhotoLibraryAlbumRow: Sendable {
    let albumID: String
    let title: String
    let parentID: String?
    let assetID: String?
}

private struct CachedPhotoLibraryRows: Sendable {
    let scopeFingerprint: String?
    let assets: [CachedPhotoLibraryAssetRow]
    let albums: [CachedPhotoLibraryAlbumRow]
    let changeToken: Data?
}

enum ReviewActionPersistenceMutation: Sendable {
    case none
    case append(ReviewAction)
    case remove(UUID)
}

enum ReviewStatePersistenceMutation: Sendable {
    case none
    case upsert(AssetReviewStateRecord)
    case remove(assetID: String)
}

enum ReviewQueuePersistenceMutation: Sendable {
    case none
    case upsert(DeletionQueueItem)
    case remove(assetID: String)
}

enum LedgerError: LocalizedError {
    case open(String)
    case corruptJob(UUID)
    case legacyJobRequiresReplanning(UUID)
    case corruptOrganizeRecord(String)
    case invalidDeletionBatch(String)

    var errorDescription: String? {
        switch self {
        case let .open(message): "Could not open export history: \(message)"
        case let .corruptJob(id): "Saved export \(id.uuidString) is unreadable."
        case .legacyJobRequiresReplanning:
            "This paused transfer uses the previous backup format. Leave it untouched and create a fresh Portable Master Library transfer."
        case let .corruptOrganizeRecord(identifier):
            "Saved Organize record \(identifier) is unreadable."
        case let .invalidDeletionBatch(message): message
        }
    }
}

actor SQLiteLedger: PhotoLibraryIndexPersisting {
    private let database: DatabaseQueue
    private let encoder = WireCoders.encoder()
    private let decoder = WireCoders.decoder()

    init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            var configuration = Configuration()
            configuration.label = "MarginallyBetterPhotos.Ledger"
            configuration.prepareDatabase { database in
                try database.execute(sql: "PRAGMA foreign_keys = ON")
                try database.execute(sql: "PRAGMA journal_mode = WAL")
            }
            database = try DatabaseQueue(path: url.path, configuration: configuration)
            try Self.migrator.migrate(database)
            try database.write { database in
                let now = Date()
                // iOS may terminate without delivering a final scene transition.
                // Any nonterminal work from the previous process is resumable,
                // never assumed to have completed.
                try database.execute(
                    sql: """
                    UPDATE jobs SET status=:paused, updated_at=:updated
                    WHERE status IN (:planned, :preparing, :transferring)
                    """,
                    arguments: [
                        "paused": LocalJobStatus.paused.rawValue,
                        "updated": WireDate.string(now),
                        "planned": LocalJobStatus.planned.rawValue,
                        "preparing": LocalJobStatus.preparing.rawValue,
                        "transferring": LocalJobStatus.transferring.rawValue
                    ]
                )
                _ = try Self.recoverInterruptedAnalysis(in: database, asOf: now)
            }
        } catch {
            throw LedgerError.open(error.localizedDescription)
        }
    }

    static func applicationLedger() throws -> SQLiteLedger {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return try SQLiteLedger(url: support.appending(path: "MBPhotos/ledger.sqlite"))
    }

    func savePlannedJob(_ job: ExportJob) throws {
        let json = try encoder.encode(job)
        try database.write { database in
            try database.execute(
                sql: """
                INSERT INTO jobs (
                    job_id, destination_id, created_at, updated_at, status, profile,
                    asset_count, total_file_count, verified_file_count, skipped_file_count,
                    failed_file_count, verified_byte_count, job_json, report_json
                ) VALUES (:jobID, NULL, :created, :updated, :status, :profile,
                          :assets, :files, 0, 0, 0, 0, :jobJSON, NULL)
                ON CONFLICT(job_id) DO UPDATE SET
                    updated_at=excluded.updated_at, status=excluded.status, job_json=excluded.job_json
                WHERE jobs.status=:status
                """,
                arguments: [
                    "jobID": Self.id(job.jobId),
                    "created": WireDate.string(job.createdAt),
                    "updated": WireDate.string(Date()),
                    "status": LocalJobStatus.planned.rawValue,
                    "profile": job.profile.kind.rawValue,
                    "assets": job.assets.count,
                    "files": job.files.count,
                    "jobJSON": json
                ]
            )
        }
    }

    /// Claims a resumable job for one export execution without regressing a
    /// newer background checkpoint. A paused row is eligible only when its
    /// checkpoint predates the user/start request; terminal rows never move.
    @discardableResult
    func activateJobForTransfer(
        _ job: ExportJob,
        requestedAt: Date
    ) throws -> Bool {
        // Creates a missing planned row. The conflict clause in
        // `savePlannedJob` only refreshes rows that are still planned, so a
        // paused or terminal row keeps the timestamp used by the CAS below.
        try savePlannedJob(job)
        return try database.write { database in
            try database.execute(
                sql: """
                UPDATE jobs SET status=:transferring, updated_at=:updated
                WHERE job_id=:job AND (
                    status IN (:planned, :preparing, :transferring)
                    OR (status=:paused AND updated_at<:requested)
                )
                """,
                arguments: [
                    "transferring": LocalJobStatus.transferring.rawValue,
                    "updated": WireDate.string(Date()),
                    "job": Self.id(job.jobId),
                    "planned": LocalJobStatus.planned.rawValue,
                    "preparing": LocalJobStatus.preparing.rawValue,
                    "paused": LocalJobStatus.paused.rawValue,
                    "requested": WireDate.string(requestedAt)
                ]
            )
            return database.changesCount == 1
        }
    }

    func attachDestination(_ destination: Destination, to jobID: UUID) throws {
        try database.write { database in
            let now = WireDate.string(Date())
            try database.execute(
                sql: """
                INSERT INTO destinations(destination_id, display_name, created_at, last_seen_at)
                VALUES (:id, :name, :created, :seen)
                ON CONFLICT(destination_id) DO UPDATE SET
                    display_name=excluded.display_name, last_seen_at=excluded.last_seen_at
                """,
                arguments: [
                    "id": Self.id(destination.destinationId),
                    "name": destination.displayName,
                    "created": WireDate.string(destination.createdAt),
                    "seen": now
                ]
            )
            try database.execute(
                sql: "UPDATE jobs SET destination_id=:destination, updated_at=:updated WHERE job_id=:job",
                arguments: [
                    "destination": Self.id(destination.destinationId),
                    "updated": now,
                    "job": Self.id(jobID)
                ]
            )
        }
    }

    func destinationID(for jobID: UUID) throws -> UUID? {
        let stored: String? = try database.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT destination_id FROM jobs WHERE job_id=?",
                arguments: [Self.id(jobID)]
            )
        }
        guard let stored else { return nil }
        guard let destinationID = UUID(uuidString: stored) else {
            throw LedgerError.corruptJob(jobID)
        }
        return destinationID
    }

    func updateJobStatus(_ status: LocalJobStatus, jobID: UUID) throws {
        try database.write { database in
            try database.execute(
                sql: "UPDATE jobs SET status=:status, updated_at=:updated WHERE job_id=:job",
                arguments: [
                    "status": status.rawValue,
                    "updated": WireDate.string(Date()),
                    "job": Self.id(jobID)
                ]
            )
        }
    }

    /// Durably pauses only live export states. The predicate prevents a late
    /// background-expiration checkpoint from regressing a job that completed
    /// or was abandoned concurrently.
    @discardableResult
    func pauseJobIfActive(jobID: UUID, at date: Date = Date()) throws -> Bool {
        try database.write { database in
            try database.execute(
                sql: """
                UPDATE jobs SET status=:paused, updated_at=:updated
                WHERE job_id=:job
                  AND status IN (:planned, :preparing, :transferring)
                """,
                arguments: [
                    "paused": LocalJobStatus.paused.rawValue,
                    "updated": WireDate.string(date),
                    "job": Self.id(jobID),
                    "planned": LocalJobStatus.planned.rawValue,
                    "preparing": LocalJobStatus.preparing.rawValue,
                    "transferring": LocalJobStatus.transferring.rawValue
                ]
            )
            return database.changesCount == 1
        }
    }

    func recordFile(
        _ file: ExportFile,
        jobID: UUID,
        status: LocalFileStatus,
        acceptedPath: String?,
        digest: FileDigest?,
        acknowledgedChunkCount: Int,
        error: String? = nil
    ) throws {
        try database.write { database in
            try database.execute(
                sql: """
                INSERT INTO files(
                    job_id, file_id, asset_id, source_revision, proposed_path, accepted_path,
                    status, byte_count, sha256, acknowledged_chunks, last_error, updated_at
                ) VALUES (:job, :file, :asset, :revision, :proposed, :accepted,
                          :status, :bytes, :sha, :chunks, :error, :updated)
                ON CONFLICT(job_id, file_id) DO UPDATE SET
                    accepted_path=excluded.accepted_path, status=excluded.status,
                    byte_count=excluded.byte_count, sha256=excluded.sha256,
                    acknowledged_chunks=excluded.acknowledged_chunks,
                    last_error=excluded.last_error, updated_at=excluded.updated_at
                """,
                arguments: [
                    "job": Self.id(jobID),
                    "file": Self.id(file.fileId),
                    "asset": Self.id(file.assetId),
                    "revision": file.sourceRevision,
                    "proposed": file.proposedRelativePath,
                    "accepted": acceptedPath,
                    "status": status.rawValue,
                    "bytes": digest?.byteCount,
                    "sha": digest?.sha256,
                    "chunks": acknowledgedChunkCount,
                    "error": error,
                    "updated": WireDate.string(Date())
                ]
            )
            try Self.refreshJobCounters(jobID, in: database)
        }
    }

    func recordVerifiedAsset(
        destinationID: UUID,
        sourceLocalIdentifier: String,
        sourceRevision: String,
        recoveryFingerprint: RecoveryFingerprint
    ) throws {
        try recordVerifiedAssets(
            destinationID: destinationID,
            records: [
                VerifiedAssetExportRecord(
                    sourceLocalIdentifier: sourceLocalIdentifier,
                    sourceRevision: sourceRevision,
                    recoveryFingerprint: recoveryFingerprint
                )
            ]
        )
    }

    /// Writes a bounded finalization batch in one transaction. Cancellation is
    /// checked while encoding and again inside the transaction; cancellation
    /// therefore rolls back only the current small batch instead of waiting for
    /// one transaction per asset—or one uninterruptible whole-library write.
    func recordVerifiedAssets(
        destinationID: UUID,
        records: [VerifiedAssetExportRecord]
    ) throws {
        guard !records.isEmpty else { return }
        var encoded: [(record: VerifiedAssetExportRecord, fingerprint: Data)] = []
        encoded.reserveCapacity(records.count)
        for (offset, record) in records.enumerated() {
            if offset.isMultiple(of: 64) { try Task.checkCancellation() }
            encoded.append((record, try encoder.encode(record.recoveryFingerprint)))
        }
        let destination = Self.id(destinationID)
        let verifiedAt = WireDate.string(Date())
        try database.write { database in
            for (offset, entry) in encoded.enumerated() {
                if offset.isMultiple(of: 64) { try Task.checkCancellation() }
                try database.execute(
                    sql: """
                    INSERT INTO asset_exports(
                        destination_id, source_local_identifier, source_revision, recovery_fingerprint, verified_at
                    ) VALUES (:destination, :source, :revision, :fingerprint, :verified)
                    ON CONFLICT(destination_id, source_local_identifier) DO UPDATE SET
                        source_revision=excluded.source_revision,
                        recovery_fingerprint=excluded.recovery_fingerprint,
                        verified_at=excluded.verified_at
                    """,
                    arguments: [
                        "destination": destination,
                        "source": entry.record.sourceLocalIdentifier,
                        "revision": entry.record.sourceRevision,
                        "fingerprint": entry.fingerprint,
                        "verified": verifiedAt
                    ]
                )
            }
        }
    }

    func previouslyExportedRevisions(destinationID: UUID) throws -> [String: String] {
        try database.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: "SELECT source_local_identifier, source_revision FROM asset_exports WHERE destination_id=?",
                arguments: [Self.id(destinationID)]
            )
            return Dictionary(uniqueKeysWithValues: rows.map { row in
                let source: String = row["source_local_identifier"]
                let revision: String = row["source_revision"]
                return (source, revision)
            })
        }
    }

    /// Commits receiver completion only while this process still owns a live
    /// export phase. If a background checkpoint or discard won the race, its
    /// paused/terminal state remains authoritative.
    @discardableResult
    func completeJob(_ report: CompletionReport) throws -> Bool {
        let reportJSON = try encoder.encode(report)
        let status: LocalJobStatus = report.state == .completed ? .completed : .completedWithFailures
        return try database.write { database in
            try database.execute(
                sql: """
                UPDATE jobs SET status=:status, updated_at=:updated,
                    verified_file_count=:verified, skipped_file_count=:skipped,
                    failed_file_count=:failed, verified_byte_count=:bytes,
                    report_json=:report
                WHERE job_id=:job
                  AND status IN (:planned, :preparing, :transferring)
                """,
                arguments: [
                    "status": status.rawValue,
                    "updated": WireDate.string(report.completedAt),
                    "verified": report.counts.filesCommitted,
                    "skipped": report.counts.filesSkipped,
                    "failed": report.counts.filesFailed,
                    "bytes": report.counts.bytesCommitted,
                    "report": reportJSON,
                    "job": Self.id(report.jobId),
                    "planned": LocalJobStatus.planned.rawValue,
                    "preparing": LocalJobStatus.preparing.rawValue,
                    "transferring": LocalJobStatus.transferring.rawValue
                ]
            )
            return database.changesCount == 1
        }
    }

    /// Returns only jobs whose staged renditions can never be resumed. The
    /// staging actor uses this as a deletion allow-list during startup and
    /// background maintenance, so paused/live work is preserved after a
    /// force-quit.
    func terminalExportJobIDs() throws -> Set<UUID> {
        let identifiers = try database.read { database in
            try String.fetchAll(
                database,
                sql: """
                SELECT job_id FROM jobs
                WHERE status IN (:completed, :completedWithFailures, :abandoned)
                """,
                arguments: [
                    "completed": LocalJobStatus.completed.rawValue,
                    "completedWithFailures": LocalJobStatus.completedWithFailures.rawValue,
                    "abandoned": LocalJobStatus.abandoned.rawValue
                ]
            )
        }
        return Set(identifiers.compactMap(UUID.init(uuidString:)))
    }

    func loadJob(_ id: UUID) throws -> ExportJob {
        let storedData = try database.read { database in
            try Data.fetchOne(
                database,
                sql: "SELECT job_json FROM jobs WHERE job_id=?",
                arguments: [Self.id(id)]
            )
        }
        guard let storedData else { throw LedgerError.corruptJob(id) }
        if let object = try? JSONSerialization.jsonObject(with: storedData) as? [String: Any],
           let version = object["protocolVersion"] as? Int,
           version != ExportConstants.protocolVersion {
            throw LedgerError.legacyJobRequiresReplanning(id)
        }
        guard let job = try? decoder.decode(ExportJob.self, from: storedData) else {
            throw LedgerError.corruptJob(id)
        }
        return job
    }

    func history() throws -> [ExportHistoryEntry] {
        let rows = try database.read { database in
            try Row.fetchAll(
                database,
                sql: """
                SELECT j.job_id, j.created_at, j.updated_at, j.status, j.profile,
                       j.asset_count, j.total_file_count, j.verified_file_count,
                       j.skipped_file_count, j.failed_file_count, j.verified_byte_count,
                       d.display_name, j.report_json
                FROM jobs j LEFT JOIN destinations d ON d.destination_id=j.destination_id
                ORDER BY j.created_at DESC
                """
            )
        }
        return rows.compactMap { row in
            let idString: String = row["job_id"]
            let createdString: String = row["created_at"]
            let updatedString: String = row["updated_at"]
            let statusString: String = row["status"]
            let profileString: String = row["profile"]
            guard let id = UUID(uuidString: idString),
                  let created = WireDate.parse(createdString),
                  let updated = WireDate.parse(updatedString),
                  let status = LocalJobStatus(rawValue: statusString),
                  let profile = ExportProfileKind(rawValue: profileString)
            else { return nil }
            let reportData: Data? = row["report_json"]
            return ExportHistoryEntry(
                id: id,
                createdAt: created,
                updatedAt: updated,
                status: status,
                profile: profile,
                assetCount: row["asset_count"],
                totalFileCount: row["total_file_count"],
                verifiedFileCount: row["verified_file_count"],
                skippedFileCount: row["skipped_file_count"],
                failedFileCount: row["failed_file_count"],
                verifiedByteCount: row["verified_byte_count"],
                destinationName: row["display_name"],
                completionReport: reportData.flatMap { try? decoder.decode(CompletionReport.self, from: $0) }
            )
        }
    }

    func savePhotoChangeToken(_ data: Data?) throws {
        try database.write { database in
            try database.execute(
                sql: """
                INSERT INTO metadata(key, value) VALUES ('photo_change_token', ?)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value
                """,
                arguments: [data]
            )
        }
    }

    // MARK: - Durable PhotoKit library index

    func cachedPhotoLibrarySnapshot(
        revision: UInt64,
        authorization: PhotoAuthorizationState,
        scopeFingerprint: String?
    ) async throws -> PhotoLibrarySnapshot? {
        // Read readiness, scope, objects, memberships, and the change token from
        // one SQLite snapshot. Splitting these into separate awaited reads lets
        // the ledger actor re-enter for a journal write and can pair old object
        // rows with a newer token, permanently advancing past unseen content.
        let stored = try await database.read { database -> CachedPhotoLibraryRows? in
            let ready = try Data.fetchOne(
                database,
                sql: "SELECT value FROM metadata WHERE key='photo_index_ready'"
            )
            let scope = try Data.fetchOne(
                database,
                sql: "SELECT value FROM metadata WHERE key='photo_index_authorization'"
            )
            let fingerprint = try Data.fetchOne(
                database,
                sql: "SELECT value FROM metadata WHERE key='photo_index_scope_fingerprint'"
            )
            guard ready == Data([1]),
                  scope == Data(Self.libraryAuthorizationScope(authorization).utf8) else {
                return nil
            }
            let storedScopeFingerprint = fingerprint.flatMap { String(data: $0, encoding: .utf8) }
            if authorization == .limited,
               (scopeFingerprint == nil || storedScopeFingerprint != scopeFingerprint) {
                return nil
            }

            let assetRows = try Row.fetchAll(
                database,
                sql: "SELECT asset_id, asset_json FROM photo_library_assets"
            )
            let assets = assetRows.map { row in
                CachedPhotoLibraryAssetRow(
                    identifier: row["asset_id"],
                    json: row["asset_json"]
                )
            }
            let albumRows = try Row.fetchAll(
                database,
                sql: """
                SELECT a.album_id, a.title, a.parent_id, m.asset_id
                FROM photo_library_albums a
                LEFT JOIN photo_library_album_assets m ON m.album_id=a.album_id
                ORDER BY a.album_id, m.position
                """
            )
            let albums = albumRows.map { row in
                CachedPhotoLibraryAlbumRow(
                    albumID: row["album_id"],
                    title: row["title"],
                    parentID: row["parent_id"],
                    assetID: row["asset_id"]
                )
            }
            let token = try Data.fetchOne(
                database,
                sql: "SELECT value FROM metadata WHERE key='photo_change_token'"
            )
            return CachedPhotoLibraryRows(
                scopeFingerprint: storedScopeFingerprint,
                assets: assets,
                albums: albums,
                changeToken: token
            )
        }

        guard let stored else { return nil }
        var assets: [PhotoAsset] = []
        assets.reserveCapacity(stored.assets.count)
        for row in stored.assets {
            do {
                assets.append(try decoder.decode(PhotoAsset.self, from: row.json))
            } catch {
                throw LedgerError.corruptOrganizeRecord("photo-asset:\(row.identifier)")
            }
        }
        assets.sort(by: Self.libraryAssetComesBefore)

        var albumMetadata: [String: (title: String, parentID: String?)] = [:]
        var memberships: [String: [String]] = [:]
        for row in stored.albums {
            albumMetadata[row.albumID] = (row.title, row.parentID)
            if let assetID = row.assetID {
                memberships[row.albumID, default: []].append(assetID)
            }
        }
        let albums = albumMetadata.map { albumID, metadata in
            PhotoAlbum(
                id: albumID,
                title: metadata.title,
                parentID: metadata.parentID,
                assetIDs: memberships[albumID] ?? []
            )
        }.sorted { lhs, rhs in
            let order = lhs.title.localizedStandardCompare(rhs.title)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
        return PhotoLibrarySnapshot(
            revision: revision,
            assets: assets,
            albums: albums,
            changeTokenData: stored.changeToken,
            authorizationScopeFingerprint: stored.scopeFingerprint
        )
    }

    func replaceCachedPhotoLibrarySnapshot(
        _ snapshot: PhotoLibrarySnapshot,
        authorization: PhotoAuthorizationState
    ) async throws {
        let encodedAssets = try snapshot.assets.map { ($0, try encoder.encode($0)) }
        let accessibleIDs = Set(snapshot.assets.map(\.id))
        try await database.write { database in
            try database.execute(sql: "DELETE FROM photo_library_album_assets")
            try database.execute(sql: "DELETE FROM photo_library_albums")
            try database.execute(sql: "DELETE FROM photo_library_assets")
            for (asset, data) in encodedAssets {
                try database.execute(
                    sql: "INSERT INTO photo_library_assets(asset_id, asset_json) VALUES (?, ?)",
                    arguments: [asset.id, data]
                )
            }
            for album in snapshot.albums {
                try Self.upsertLibraryAlbum(album, accessibleAssetIDs: accessibleIDs, in: database)
            }
            try Self.saveLibraryIndexMetadata(
                token: snapshot.changeTokenData,
                authorization: authorization,
                scopeFingerprint: snapshot.authorizationScopeFingerprint,
                in: database
            )
        }
    }

    func advanceCachedPhotoLibraryChangeToken(_ changeTokenData: Data?) async throws {
        try await database.write { database in
            try database.execute(
                sql: """
                INSERT INTO metadata(key, value) VALUES ('photo_change_token', ?)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value
                """,
                arguments: [changeTokenData]
            )
        }
    }

    func applyPhotoLibraryChanges(
        _ changes: PhotoLibraryIndexChanges,
        revision: UInt64,
        authorization: PhotoAuthorizationState
    ) async throws -> PhotoLibrarySnapshot {
        let encodedAssets = try changes.upsertedAssets.map { ($0, try encoder.encode($0)) }
        try await database.write { database in
            for (asset, data) in encodedAssets {
                try database.execute(
                    sql: """
                    INSERT INTO photo_library_assets(asset_id, asset_json) VALUES (:id, :json)
                    ON CONFLICT(asset_id) DO UPDATE SET asset_json=excluded.asset_json
                    """,
                    arguments: ["id": asset.id, "json": data]
                )
            }
            for assetID in changes.deletedAssetIDs {
                try database.execute(
                    sql: "DELETE FROM photo_library_assets WHERE asset_id=?",
                    arguments: [assetID]
                )
            }
            if let accessibleAssetIDs = changes.accessibleAssetIDs {
                let storedIDs = try String.fetchAll(database, sql: "SELECT asset_id FROM photo_library_assets")
                for assetID in storedIDs where !accessibleAssetIDs.contains(assetID) {
                    try database.execute(
                        sql: "DELETE FROM photo_library_assets WHERE asset_id=?",
                        arguments: [assetID]
                    )
                }
            }
            for albumID in changes.deletedAlbumIDs {
                try database.execute(
                    sql: "DELETE FROM photo_library_albums WHERE album_id=?",
                    arguments: [albumID]
                )
            }
            let accessibleIDs = Set(try String.fetchAll(database, sql: "SELECT asset_id FROM photo_library_assets"))
            for album in changes.upsertedAlbums {
                try Self.upsertLibraryAlbum(album, accessibleAssetIDs: accessibleIDs, in: database)
            }
            try Self.saveLibraryIndexMetadata(
                token: changes.changeTokenData,
                authorization: authorization,
                scopeFingerprint: changes.authorizationScopeFingerprint,
                in: database
            )
        }
        guard let snapshot = try await cachedPhotoLibrarySnapshot(
            revision: revision,
            authorization: authorization,
            scopeFingerprint: changes.authorizationScopeFingerprint
        ) else {
            throw LedgerError.open("The cached PhotoKit index could not be read after updating it.")
        }
        return snapshot
    }

    // MARK: - Organize analysis

    func saveAnalysisRecord(_ record: AssetAnalysisRecord) throws {
        try saveAnalysisRecords([record])
    }

    func saveAnalysisRecords(_ records: [AssetAnalysisRecord]) throws {
        let encoded = try records.map { ($0, try encoder.encode($0)) }
        try database.write { database in
            for (record, json) in encoded {
                try database.execute(
                    sql: """
                    INSERT INTO organize_analysis(
                        asset_id, source_revision, status, known_byte_count,
                        exact_duplicate_key, updated_at, record_json
                    ) VALUES (:asset, :revision, :status, :bytes, :duplicate, :updated, :json)
                    ON CONFLICT(asset_id) DO UPDATE SET
                        source_revision=excluded.source_revision,
                        status=excluded.status,
                        known_byte_count=excluded.known_byte_count,
                        exact_duplicate_key=excluded.exact_duplicate_key,
                        updated_at=excluded.updated_at,
                        record_json=excluded.record_json
                    """,
                    arguments: [
                        "asset": record.assetID,
                        "revision": record.sourceRevision,
                        "status": record.status.rawValue,
                        "bytes": record.knownByteCount,
                        "duplicate": record.exactDuplicateKey,
                        "updated": WireDate.string(record.updatedAt),
                        "json": json
                    ]
                )
            }
        }
    }

    /// Commits one analyzed asset and the first unfinished work position in the
    /// same SQLite transaction. A cursor must never advance unless the record it
    /// advances past is durable, otherwise a relaunch could silently skip work.
    func commitAnalysisProgress(
        _ record: AssetAnalysisRecord,
        runID: UUID,
        status: AnalysisRunStatus,
        nextPosition: Int,
        updatedAt: Date,
        errorMessage: String? = nil
    ) throws {
        let json = try encoder.encode(record)
        try database.write { database in
            let prior = try Row.fetchOne(
                database,
                sql: "SELECT source_revision, status FROM organize_analysis WHERE asset_id=?",
                arguments: [record.assetID]
            )
            let wasCompleteForRevision = prior.map { row in
                let revision: String = row["source_revision"]
                let storedStatus: String = row["status"]
                return revision == record.sourceRevision
                    && storedStatus == AnalysisStatus.complete.rawValue
            } ?? false
            let isComplete = record.status == .complete
            let completedDelta = (isComplete ? 1 : 0) - (wasCompleteForRevision ? 1 : 0)
            try database.execute(
                sql: """
                INSERT INTO organize_analysis(
                    asset_id, source_revision, status, known_byte_count,
                    exact_duplicate_key, updated_at, record_json
                ) VALUES (:asset, :revision, :status, :bytes, :duplicate, :updated, :json)
                ON CONFLICT(asset_id) DO UPDATE SET
                    source_revision=excluded.source_revision,
                    status=excluded.status,
                    known_byte_count=excluded.known_byte_count,
                    exact_duplicate_key=excluded.exact_duplicate_key,
                    updated_at=excluded.updated_at,
                    record_json=excluded.record_json
                """,
                arguments: [
                    "asset": record.assetID,
                    "revision": record.sourceRevision,
                    "status": record.status.rawValue,
                    "bytes": record.knownByteCount,
                    "duplicate": record.exactDuplicateKey,
                    "updated": WireDate.string(record.updatedAt),
                    "json": json
                ]
            )
            try database.execute(
                sql: """
                UPDATE organize_analysis_runs
                SET status=:status,
                    next_position=MAX(
                        next_position,
                        MIN(MAX(:next, 0), total_asset_count)
                    ),
                    completed_asset_count=MIN(
                        MAX(completed_asset_count + :completed_delta, 0),
                        total_asset_count
                    ),
                    updated_at=:updated,
                    error_message=:error
                WHERE run_id=:id
                """,
                arguments: [
                    "status": status.rawValue,
                    "next": nextPosition,
                    "completed_delta": completedDelta,
                    "updated": WireDate.string(updatedAt),
                    "error": errorMessage,
                    "id": Self.id(runID)
                ]
            )
            guard database.changesCount == 1 else {
                throw LedgerError.corruptOrganizeRecord(runID.uuidString)
            }
        }
    }

    func analysisRecords() throws -> [String: AssetAnalysisRecord] {
        let rows = try database.read { database in
            try Row.fetchAll(database, sql: "SELECT asset_id, record_json FROM organize_analysis")
        }
        var result: [String: AssetAnalysisRecord] = [:]
        for row in rows {
            let assetID: String = row["asset_id"]
            let data: Data = row["record_json"]
            result[assetID] = try decodeOrganize(AssetAnalysisRecord.self, from: data, identifier: assetID)
        }
        return result
    }

    func removeAnalysisRecord(assetID: String) throws {
        try database.write { database in
            try database.execute(sql: "DELETE FROM organize_analysis WHERE asset_id=?", arguments: [assetID])
        }
    }

    // MARK: - Lightweight visual analysis

    func saveVisualAnalysisRecord(_ record: VisualAnalysisRecord) throws {
        try saveVisualAnalysisRecords([record])
    }

    func saveVisualAnalysisRecords(_ records: [VisualAnalysisRecord]) throws {
        let encoded = try records.map { ($0, try encoder.encode($0)) }
        try database.write { database in
            for (record, json) in encoded {
                try database.execute(
                    sql: """
                    INSERT INTO organize_visual_analysis(
                        asset_id, source_revision, algorithm_version,
                        feature_print_revision, aesthetics_score, is_utility,
                        analyzed_at, record_json
                    ) VALUES (
                        :asset, :revision, :algorithm, :feature_revision,
                        :aesthetics, :utility, :analyzed, :json
                    )
                    ON CONFLICT(asset_id) DO UPDATE SET
                        source_revision=excluded.source_revision,
                        algorithm_version=excluded.algorithm_version,
                        feature_print_revision=excluded.feature_print_revision,
                        aesthetics_score=excluded.aesthetics_score,
                        is_utility=excluded.is_utility,
                        analyzed_at=excluded.analyzed_at,
                        record_json=excluded.record_json
                    """,
                    arguments: [
                        "asset": record.assetID,
                        "revision": record.sourceRevision,
                        "algorithm": record.algorithmVersion,
                        "feature_revision": record.visionRevisions.featurePrint,
                        "aesthetics": record.aesthetics?.overallScore,
                        "utility": record.aesthetics?.isUtility,
                        "analyzed": WireDate.string(record.analyzedAt),
                        "json": json
                    ]
                )
                try database.execute(
                    sql: "DELETE FROM organize_visual_analysis_attempts WHERE asset_id=?",
                    arguments: [record.assetID]
                )
            }
        }
    }

    func visualAnalysisRecords() throws -> [String: VisualAnalysisRecord] {
        let rows = try database.read { database in
            try Row.fetchAll(
                database,
                sql: "SELECT asset_id, record_json FROM organize_visual_analysis"
            )
        }
        var result: [String: VisualAnalysisRecord] = [:]
        result.reserveCapacity(rows.count)
        var unreadableAssetIDs: [String] = []
        for row in rows {
            let assetID: String = row["asset_id"]
            let data: Data = row["record_json"]
            do {
                result[assetID] = try decodeOrganize(
                    VisualAnalysisRecord.self,
                    from: data,
                    identifier: assetID
                )
            } catch {
                // Visual evidence is an advisory, revision-pinned cache. A single
                // stale or corrupt row must not make review history unavailable.
                unreadableAssetIDs.append(assetID)
            }
        }
        if !unreadableAssetIDs.isEmpty {
            try? database.write { database in
                for assetID in unreadableAssetIDs {
                    try database.execute(
                        sql: "DELETE FROM organize_visual_analysis WHERE asset_id=?",
                        arguments: [assetID]
                    )
                }
            }
        }
        return result
    }

    func removeVisualAnalysisRecord(assetID: String) throws {
        try database.write { database in
            try database.execute(
                sql: "DELETE FROM organize_visual_analysis WHERE asset_id=?",
                arguments: [assetID]
            )
        }
    }

    func saveVisualAnalysisAttempt(_ attempt: VisualAnalysisAttemptRecord) throws {
        guard attempt.isStructurallyValid else {
            throw LedgerError.corruptOrganizeRecord("visual-attempt:\(attempt.assetID)")
        }
        try database.write { database in
            try database.execute(
                sql: "DELETE FROM organize_visual_analysis WHERE asset_id=?",
                arguments: [attempt.assetID]
            )
            try database.execute(
                sql: """
                INSERT INTO organize_visual_analysis_attempts(
                    asset_id, source_revision, algorithm_version,
                    vision_revisions_json, status, attempted_at
                ) VALUES (:asset, :revision, :algorithm, :vision, :status, :attempted)
                ON CONFLICT(asset_id) DO UPDATE SET
                    source_revision=excluded.source_revision,
                    algorithm_version=excluded.algorithm_version,
                    vision_revisions_json=excluded.vision_revisions_json,
                    status=excluded.status,
                    attempted_at=excluded.attempted_at
                """,
                arguments: [
                    "asset": attempt.assetID,
                    "revision": attempt.sourceRevision,
                    "algorithm": attempt.algorithmVersion,
                    "vision": try encoder.encode(attempt.visionRevisions),
                    "status": attempt.status.rawValue,
                    "attempted": WireDate.string(attempt.attemptedAt)
                ]
            )
        }
    }

    func visualAnalysisAttempts() throws -> [String: VisualAnalysisAttemptRecord] {
        let rows = try database.read { database in
            try Row.fetchAll(
                database,
                sql: """
                SELECT asset_id, source_revision, algorithm_version,
                       vision_revisions_json, status, attempted_at
                FROM organize_visual_analysis_attempts
                """
            )
        }
        var result: [String: VisualAnalysisAttemptRecord] = [:]
        result.reserveCapacity(rows.count)
        var unreadableAssetIDs: [String] = []
        for row in rows {
            let assetID: String = row["asset_id"]
            do {
                let sourceRevision: String = row["source_revision"]
                let algorithmVersion: String = row["algorithm_version"]
                let revisionsData: Data = row["vision_revisions_json"]
                let statusRawValue: String = row["status"]
                let attemptedAtString: String = row["attempted_at"]
                guard let status = VisualAnalysisAttemptStatus(rawValue: statusRawValue),
                      let attemptedAt = WireDate.parse(attemptedAtString) else {
                    throw LedgerError.corruptOrganizeRecord("visual-attempt:\(assetID)")
                }
                let revisions = try decoder.decode(
                    VisualAnalysisVisionRevisions.self,
                    from: revisionsData
                )
                let attempt = VisualAnalysisAttemptRecord(
                    assetID: assetID,
                    sourceRevision: sourceRevision,
                    algorithmVersion: algorithmVersion,
                    visionRevisions: revisions,
                    status: status,
                    attemptedAt: attemptedAt
                )
                guard attempt.isStructurallyValid else {
                    throw LedgerError.corruptOrganizeRecord("visual-attempt:\(assetID)")
                }
                result[assetID] = attempt
            } catch {
                unreadableAssetIDs.append(assetID)
            }
        }
        if !unreadableAssetIDs.isEmpty {
            try? database.write { database in
                for assetID in unreadableAssetIDs {
                    try database.execute(
                        sql: "DELETE FROM organize_visual_analysis_attempts WHERE asset_id=?",
                        arguments: [assetID]
                    )
                }
            }
        }
        return result
    }

    func removeVisualAnalysisAttempt(assetID: String) throws {
        try database.write { database in
            try database.execute(
                sql: "DELETE FROM organize_visual_analysis_attempts WHERE asset_id=?",
                arguments: [assetID]
            )
        }
    }

    func saveAnalysisRun(_ run: AnalysisRunRecord) throws {
        // `run_json` is retained only for v2 migration compatibility. New runs
        // keep their immutable order in organize_analysis_work and checkpoint
        // scalar progress in columns, so this payload must stay constant-size.
        let json = Data("{}".utf8)
        let nextPosition = Self.nextAnalysisPosition(for: run)
        try database.write { database in
            try database.execute(
                sql: """
                    INSERT INTO organize_analysis_runs(
                    run_id, includes_icloud_items, origin, status, started_at, updated_at, run_json,
                    next_position, completed_asset_count, total_asset_count, error_message
                ) VALUES (
                    :id, :icloud, :origin, :status, :started, :updated, :json,
                    :next, :completed, :total, :error
                )
                ON CONFLICT(run_id) DO UPDATE SET
                    includes_icloud_items=excluded.includes_icloud_items,
                    origin=excluded.origin,
                    status=excluded.status,
                    updated_at=excluded.updated_at,
                    next_position=excluded.next_position,
                    completed_asset_count=excluded.completed_asset_count,
                    total_asset_count=excluded.total_asset_count,
                    error_message=excluded.error_message
                """,
                arguments: [
                    "id": Self.id(run.id),
                    "icloud": run.includesICloudItems,
                    "origin": run.origin.rawValue,
                    "status": run.status.rawValue,
                    "started": WireDate.string(run.startedAt),
                    "updated": WireDate.string(run.updatedAt),
                    "json": json,
                    "next": nextPosition,
                    "completed": run.completedAssetIDs.count,
                    "total": run.orderedAssetIDs.count,
                    "error": run.errorMessage
                ]
            )
            for (position, assetID) in run.orderedAssetIDs.enumerated() {
                try database.execute(
                    sql: """
                    INSERT OR IGNORE INTO organize_analysis_work(run_id, position, asset_id)
                    VALUES (?, ?, ?)
                    """,
                    arguments: [Self.id(run.id), position, assetID]
                )
            }
        }
    }

    func createAnalysisRun(_ run: AnalysisRunRecord) throws {
        try saveAnalysisRun(run)
    }

    /// Writes only scalar progress. The immutable work order is normalized and
    /// stored once by `createAnalysisRun`, avoiding an ever-growing JSON rewrite
    /// after each analyzed asset.
    func checkpointAnalysisRun(
        id: UUID,
        status: AnalysisRunStatus,
        nextPosition: Int,
        completedAssetCount: Int? = nil,
        allowPositionRewind: Bool = false,
        updatedAt: Date = Date(),
        errorMessage: String? = nil
    ) throws {
        try database.write { database in
            try database.execute(
                sql: """
                UPDATE organize_analysis_runs
                SET status=:status,
                    next_position=CASE
                        WHEN :allow_rewind THEN MIN(MAX(:next, 0), total_asset_count)
                        ELSE MAX(
                            next_position,
                            MIN(MAX(:next, 0), total_asset_count)
                        )
                    END,
                    completed_asset_count=CASE
                        WHEN :completed IS NULL THEN completed_asset_count
                        ELSE MIN(MAX(:completed, 0), total_asset_count)
                    END,
                    updated_at=:updated,
                    error_message=:error
                WHERE run_id=:id
                """,
                arguments: [
                    "status": status.rawValue,
                    "next": nextPosition,
                    "completed": completedAssetCount,
                    "allow_rewind": allowPositionRewind,
                    "updated": WireDate.string(updatedAt),
                    "error": errorMessage,
                    "id": Self.id(id)
                ]
            )
        }
    }

    func analysisWork(
        runID: UUID,
        startingAt position: Int = 0,
        limit: Int? = nil
    ) throws -> [String] {
        try database.read { database in
            if let limit {
                return try String.fetchAll(
                    database,
                    sql: """
                    SELECT asset_id FROM organize_analysis_work
                    WHERE run_id=? AND position>=?
                    ORDER BY position LIMIT ?
                    """,
                    arguments: [Self.id(runID), max(position, 0), max(limit, 0)]
                )
            }
            return try String.fetchAll(
                database,
                sql: """
                SELECT asset_id FROM organize_analysis_work
                WHERE run_id=? AND position>=?
                ORDER BY position
                """,
                arguments: [Self.id(runID), max(position, 0)]
            )
        }
    }

    func analysisNextPosition(runID: UUID) throws -> Int {
        try database.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: """
                SELECT next_position, total_asset_count
                FROM organize_analysis_runs WHERE run_id=?
                """,
                arguments: [Self.id(runID)]
            ) else { return 0 }
            let next: Int = row["next_position"]
            let total: Int = row["total_asset_count"]
            return min(max(next, 0), max(total, 0))
        }
    }

    func analysisRunProgress(id: UUID) throws -> AnalysisRunProgressSnapshot? {
        try database.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: """
                SELECT r.run_id,
                       r.includes_icloud_items,
                       r.origin,
                       r.status,
                       r.next_position,
                       r.completed_asset_count,
                       r.total_asset_count,
                       r.error_message
                FROM organize_analysis_runs r
                WHERE r.run_id=:id
                """,
                arguments: ["id": Self.id(id)]
            ) else { return nil }
            let identifier: String = row["run_id"]
            guard let runID = UUID(uuidString: identifier),
                  let origin = AnalysisRunOrigin(rawValue: row["origin"]),
                  let status = AnalysisRunStatus(rawValue: row["status"]) else {
                throw LedgerError.corruptOrganizeRecord(identifier)
            }
            let total = max(row["total_asset_count"] as Int, 0)
            return AnalysisRunProgressSnapshot(
                id: runID,
                includesICloudItems: row["includes_icloud_items"],
                origin: origin,
                status: status,
                nextPosition: min(max(row["next_position"] as Int, 0), total),
                completedAssetCount: min(
                    max(row["completed_asset_count"] as Int, 0),
                    total
                ),
                totalAssetCount: total,
                errorMessage: row["error_message"]
            )
        }
    }

    func analysisRun(id: UUID) throws -> AnalysisRunRecord? {
        try database.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT * FROM organize_analysis_runs WHERE run_id=?",
                arguments: [Self.id(id)]
            ) else { return nil }
            return try Self.normalizedAnalysisRun(from: row, in: database)
        }
    }

    func latestAnalysisRun() throws -> AnalysisRunRecord? {
        try database.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT * FROM organize_analysis_runs ORDER BY updated_at DESC, run_id LIMIT 1"
            ) else { return nil }
            return try Self.normalizedAnalysisRun(from: row, in: database)
        }
    }

    /// Atomically turns process-local analysis states into durable, resumable
    /// states. Both the indexed columns and JSON payloads are updated together so
    /// readers can never observe contradictory recovery state.
    func recoverInterruptedAnalysis(asOf date: Date = Date()) throws -> InterruptedAnalysisRecovery {
        try database.write { database in
            try Self.recoverInterruptedAnalysis(in: database, asOf: date)
        }
    }

    // MARK: - Organize review sessions and state

    func saveReviewSession(_ session: ReviewSession) throws {
        let sessionJSON = try encoder.encode(session)
        let actionJSON = try session.actions.map { ($0, try encoder.encode($0)) }
        try database.write { database in
            try database.execute(
                sql: """
                INSERT INTO organize_review_sessions(
                    session_id, recommendation_kind, status, created_at, updated_at, session_json
                ) VALUES (:id, :kind, :status, :created, :updated, :json)
                ON CONFLICT(session_id) DO UPDATE SET
                    recommendation_kind=excluded.recommendation_kind,
                    status=excluded.status,
                    updated_at=excluded.updated_at,
                    session_json=excluded.session_json
                """,
                arguments: [
                    "id": Self.id(session.id),
                    "kind": session.recommendationKind.rawValue,
                    "status": session.status.rawValue,
                    "created": WireDate.string(session.createdAt),
                    "updated": WireDate.string(session.updatedAt),
                    "json": sessionJSON
                ]
            )
            try database.execute(
                sql: "DELETE FROM organize_review_actions WHERE session_id=?",
                arguments: [Self.id(session.id)]
            )
            for (action, json) in actionJSON {
                try database.execute(
                    sql: """
                    INSERT INTO organize_review_actions(
                        session_id, sequence, action_id, asset_id, decision, created_at, action_json
                    ) VALUES (:session, :sequence, :action, :asset, :decision, :created, :json)
                    """,
                    arguments: [
                        "session": Self.id(session.id),
                        "sequence": action.sequence,
                        "action": Self.id(action.id),
                        "asset": action.assetID,
                        "decision": action.decision.rawValue,
                        "created": WireDate.string(action.createdAt),
                        "json": json
                    ]
                )
            }
        }
    }

    /// Persists one review choice or undo as a single transaction. Callers no longer need
    /// separate session, review-state, and queue writes that can be torn apart by
    /// suspension or process termination.
    func applyReviewMutation(
        session: ReviewSession,
        action: ReviewActionPersistenceMutation,
        state: ReviewStatePersistenceMutation,
        queue: ReviewQueuePersistenceMutation
    ) throws {
        let actionJSON: Data? = if case let .append(value) = action {
            try encoder.encode(value)
        } else { nil }
        let stateJSON: Data? = if case let .upsert(value) = state {
            try encoder.encode(value)
        } else { nil }
        let queueJSON: Data? = if case let .upsert(value) = queue {
            try encoder.encode(value)
        } else { nil }

        try database.write { database in
            try database.execute(
                sql: """
                UPDATE organize_review_sessions
                SET status=:status, updated_at=:updated
                WHERE session_id=:id
                """,
                arguments: [
                    "id": Self.id(session.id),
                    "status": session.status.rawValue,
                    "updated": WireDate.string(session.updatedAt)
                ]
            )
            guard database.changesCount == 1 else {
                throw LedgerError.corruptOrganizeRecord(session.id.uuidString)
            }

            switch action {
            case .none:
                break
            case let .append(value):
                try database.execute(
                    sql: """
                    INSERT INTO organize_review_actions(
                        session_id, sequence, action_id, asset_id, decision, created_at, action_json
                    ) VALUES (:session, :sequence, :action, :asset, :decision, :created, :json)
                    ON CONFLICT(session_id, sequence) DO UPDATE SET
                        action_id=excluded.action_id, asset_id=excluded.asset_id,
                        decision=excluded.decision, created_at=excluded.created_at,
                        action_json=excluded.action_json
                    """,
                    arguments: [
                        "session": Self.id(value.sessionID),
                        "sequence": value.sequence,
                        "action": Self.id(value.id),
                        "asset": value.assetID,
                        "decision": value.decision.rawValue,
                        "created": WireDate.string(value.createdAt),
                        "json": actionJSON
                    ]
                )
            case let .remove(actionID):
                try database.execute(
                    sql: "DELETE FROM organize_review_actions WHERE action_id=?",
                    arguments: [Self.id(actionID)]
                )
            }

            switch state {
            case .none:
                break
            case let .upsert(value):
                try database.execute(
                    sql: """
                    INSERT INTO organize_review_states(
                        asset_id, source_revision, state, recommendation_kind, updated_at, record_json
                    ) VALUES (:asset, :revision, :state, :kind, :updated, :json)
                    ON CONFLICT(asset_id) DO UPDATE SET
                        source_revision=excluded.source_revision, state=excluded.state,
                        recommendation_kind=excluded.recommendation_kind,
                        updated_at=excluded.updated_at, record_json=excluded.record_json
                    """,
                    arguments: [
                        "asset": value.assetID,
                        "revision": value.sourceRevision,
                        "state": value.state.rawValue,
                        "kind": value.recommendationKind?.rawValue,
                        "updated": WireDate.string(value.updatedAt),
                        "json": stateJSON
                    ]
                )
            case let .remove(assetID):
                try database.execute(
                    sql: "DELETE FROM organize_review_states WHERE asset_id=?",
                    arguments: [assetID]
                )
            }

            switch queue {
            case .none:
                break
            case let .upsert(value):
                try database.execute(
                    sql: """
                    INSERT INTO organize_deletion_queue(
                        asset_id, source_revision, recommendation_kind, queued_at,
                        protection_override, review_session_id, item_json
                    ) VALUES (:asset, :revision, :kind, :queued, :override, :session, :json)
                    ON CONFLICT(asset_id) DO UPDATE SET
                        source_revision=excluded.source_revision,
                        recommendation_kind=excluded.recommendation_kind,
                        queued_at=excluded.queued_at,
                        protection_override=excluded.protection_override,
                        review_session_id=excluded.review_session_id,
                        item_json=excluded.item_json
                    """,
                    arguments: [
                        "asset": value.assetID,
                        "revision": value.sourceRevision,
                        "kind": value.recommendationKind?.rawValue,
                        "queued": WireDate.string(value.queuedAt),
                        "override": value.protectionOverride,
                        "session": value.reviewSessionID.map(Self.id),
                        "json": queueJSON
                    ]
                )
            case let .remove(assetID):
                try database.execute(
                    sql: "DELETE FROM organize_deletion_queue WHERE asset_id=?",
                    arguments: [assetID]
                )
            }
        }
    }

    func reviewSession(id: UUID) throws -> ReviewSession? {
        let stored = try database.read { database -> (Row, [Row])? in
            guard let sessionRow = try Row.fetchOne(
                database,
                sql: "SELECT * FROM organize_review_sessions WHERE session_id=?",
                arguments: [Self.id(id)]
            ) else { return nil }
            let actionRows = try Row.fetchAll(
                database,
                sql: """
                SELECT action_id, action_json FROM organize_review_actions
                WHERE session_id=? ORDER BY sequence
                """,
                arguments: [Self.id(id)]
            )
            return (sessionRow, actionRows)
        }
        guard let stored else { return nil }
        return try rehydratedReviewSession(sessionRow: stored.0, actionRows: stored.1)
    }

    func reviewSessions() throws -> [ReviewSession] {
        let stored = try database.read { database -> ([Row], [Row]) in
            let sessions = try Row.fetchAll(
                database,
                sql: "SELECT * FROM organize_review_sessions ORDER BY updated_at DESC, session_id"
            )
            let actions = try Row.fetchAll(
                database,
                sql: """
                SELECT session_id, action_id, action_json FROM organize_review_actions
                ORDER BY session_id, sequence
                """
            )
            return (sessions, actions)
        }
        var actionRowsBySessionID: [String: [Row]] = [:]
        for row in stored.1 {
            let sessionID: String = row["session_id"]
            actionRowsBySessionID[sessionID, default: []].append(row)
        }
        var sessions: [ReviewSession] = []
        sessions.reserveCapacity(stored.0.count)
        for row in stored.0 {
            let sessionID: String = row["session_id"]
            let actionRows = actionRowsBySessionID.removeValue(forKey: sessionID) ?? []
            sessions.append(
                try rehydratedReviewSession(
                    sessionRow: row,
                    actionRows: actionRows
                )
            )
        }
        return sessions
    }

    func deleteReviewSession(id: UUID) throws {
        try database.write { database in
            try database.execute(
                sql: "DELETE FROM organize_review_sessions WHERE session_id=?",
                arguments: [Self.id(id)]
            )
        }
    }

    func saveReviewState(_ record: AssetReviewStateRecord) throws {
        try saveReviewStates([record])
    }

    func saveReviewStates(_ records: [AssetReviewStateRecord]) throws {
        let encoded = try records.map { ($0, try encoder.encode($0)) }
        try database.write { database in
            for (record, json) in encoded {
                try database.execute(
                    sql: """
                    INSERT INTO organize_review_states(
                        asset_id, source_revision, state, recommendation_kind, updated_at, record_json
                    ) VALUES (:asset, :revision, :state, :kind, :updated, :json)
                    ON CONFLICT(asset_id) DO UPDATE SET
                        source_revision=excluded.source_revision,
                        state=excluded.state,
                        recommendation_kind=excluded.recommendation_kind,
                        updated_at=excluded.updated_at,
                        record_json=excluded.record_json
                    """,
                    arguments: [
                        "asset": record.assetID,
                        "revision": record.sourceRevision,
                        "state": record.state.rawValue,
                        "kind": record.recommendationKind?.rawValue,
                        "updated": WireDate.string(record.updatedAt),
                        "json": json
                    ]
                )
            }
        }
    }

    func reviewStates() throws -> [String: AssetReviewStateRecord] {
        let rows = try database.read { database in
            try Row.fetchAll(database, sql: "SELECT asset_id, record_json FROM organize_review_states")
        }
        var result: [String: AssetReviewStateRecord] = [:]
        for row in rows {
            let assetID: String = row["asset_id"]
            let data: Data = row["record_json"]
            result[assetID] = try decodeOrganize(AssetReviewStateRecord.self, from: data, identifier: assetID)
        }
        return result
    }

    func removeReviewState(assetID: String) throws {
        try database.write { database in
            try database.execute(sql: "DELETE FROM organize_review_states WHERE asset_id=?", arguments: [assetID])
        }
    }

    // MARK: - Recently Deleted queue

    func enqueueForRecentlyDeleted(_ item: DeletionQueueItem) throws {
        let json = try encoder.encode(item)
        try database.write { database in
            try database.execute(
                sql: """
                INSERT INTO organize_deletion_queue(
                    asset_id, source_revision, recommendation_kind, queued_at,
                    protection_override, review_session_id, item_json
                ) VALUES (:asset, :revision, :kind, :queued, :override, :session, :json)
                ON CONFLICT(asset_id) DO UPDATE SET
                    source_revision=excluded.source_revision,
                    recommendation_kind=excluded.recommendation_kind,
                    queued_at=excluded.queued_at,
                    protection_override=excluded.protection_override,
                    review_session_id=excluded.review_session_id,
                    item_json=excluded.item_json
                """,
                arguments: [
                    "asset": item.assetID,
                    "revision": item.sourceRevision,
                    "kind": item.recommendationKind?.rawValue,
                    "queued": WireDate.string(item.queuedAt),
                    "override": item.protectionOverride,
                    "session": item.reviewSessionID.map(Self.id),
                    "json": json
                ]
            )
        }
    }

    /// Atomically replaces the staged queue so a crash cannot leave only part of a
    /// multi-selection persisted.
    func replaceRecentlyDeletedQueue(_ items: [DeletionQueueItem]) throws {
        let encoded = try items.map { ($0, try encoder.encode($0)) }
        try database.write { database in
            try database.execute(sql: "DELETE FROM organize_deletion_queue")
            for (item, json) in encoded {
                try database.execute(
                    sql: """
                    INSERT INTO organize_deletion_queue(
                        asset_id, source_revision, recommendation_kind, queued_at,
                        protection_override, review_session_id, item_json
                    ) VALUES (:asset, :revision, :kind, :queued, :override, :session, :json)
                    """,
                    arguments: [
                        "asset": item.assetID,
                        "revision": item.sourceRevision,
                        "kind": item.recommendationKind?.rawValue,
                        "queued": WireDate.string(item.queuedAt),
                        "override": item.protectionOverride,
                        "session": item.reviewSessionID.map(Self.id),
                        "json": json
                    ]
                )
            }
        }
    }

    /// Applies one intent-sized queue change in a single transaction. Removing first
    /// gives an upsert deterministic precedence when callers include the same asset in
    /// both collections, while a failure in any later upsert rolls every removal back.
    func applyRecentlyDeletedQueueDelta(
        upserts: [DeletionQueueItem],
        removals: [String]
    ) throws {
        let encoded = try upserts.map { ($0, try encoder.encode($0)) }
        try database.write { database in
            for assetID in Set(removals) {
                try database.execute(
                    sql: "DELETE FROM organize_deletion_queue WHERE asset_id=?",
                    arguments: [assetID]
                )
            }
            for (item, json) in encoded {
                try database.execute(
                    sql: """
                    INSERT INTO organize_deletion_queue(
                        asset_id, source_revision, recommendation_kind, queued_at,
                        protection_override, review_session_id, item_json
                    ) VALUES (:asset, :revision, :kind, :queued, :override, :session, :json)
                    ON CONFLICT(asset_id) DO UPDATE SET
                        source_revision=excluded.source_revision,
                        recommendation_kind=excluded.recommendation_kind,
                        queued_at=excluded.queued_at,
                        protection_override=excluded.protection_override,
                        review_session_id=excluded.review_session_id,
                        item_json=excluded.item_json
                    """,
                    arguments: [
                        "asset": item.assetID,
                        "revision": item.sourceRevision,
                        "kind": item.recommendationKind?.rawValue,
                        "queued": WireDate.string(item.queuedAt),
                        "override": item.protectionOverride,
                        "session": item.reviewSessionID.map(Self.id),
                        "json": json
                    ]
                )
            }
        }
    }

    func recentlyDeletedQueue() throws -> [DeletionQueueItem] {
        let rows = try database.read { database in
            try Row.fetchAll(
                database,
                sql: "SELECT asset_id, item_json FROM organize_deletion_queue ORDER BY queued_at, asset_id"
            )
        }
        return try rows.map { row in
            let identifier: String = row["asset_id"]
            let data: Data = row["item_json"]
            return try decodeOrganize(DeletionQueueItem.self, from: data, identifier: identifier)
        }
    }

    func removeFromRecentlyDeletedQueue(assetIDs: [String]) throws {
        try database.write { database in
            for assetID in Set(assetIDs) {
                try database.execute(
                    sql: "DELETE FROM organize_deletion_queue WHERE asset_id=?",
                    arguments: [assetID]
                )
            }
        }
    }

    // MARK: - Protected albums

    func saveProtectedAlbum(_ album: ProtectedAlbumRecord) throws {
        let json = try encoder.encode(album)
        try database.write { database in
            try database.execute(
                sql: """
                INSERT INTO organize_protected_albums(album_id, title, protected_at, record_json)
                VALUES (:id, :title, :protected, :json)
                ON CONFLICT(album_id) DO UPDATE SET
                    title=excluded.title,
                    protected_at=excluded.protected_at,
                    record_json=excluded.record_json
                """,
                arguments: [
                    "id": album.albumID,
                    "title": album.title,
                    "protected": WireDate.string(album.protectedAt),
                    "json": json
                ]
            )
        }
    }

    func protectedAlbums() throws -> [ProtectedAlbumRecord] {
        let rows = try database.read { database in
            try Row.fetchAll(
                database,
                sql: "SELECT album_id, record_json FROM organize_protected_albums ORDER BY title, album_id"
            )
        }
        return try rows.map { row in
            let identifier: String = row["album_id"]
            let data: Data = row["record_json"]
            return try decodeOrganize(ProtectedAlbumRecord.self, from: data, identifier: identifier)
        }
    }

    func removeProtectedAlbum(id: String) throws {
        try database.write { database in
            try database.execute(sql: "DELETE FROM organize_protected_albums WHERE album_id=?", arguments: [id])
        }
    }

    // MARK: - Recently Deleted audit history

    func saveDeletionBatch(_ batch: DeletionBatch, items: [DeletedItemRecord] = []) throws {
        guard items.allSatisfy({ $0.batchID == batch.id }) else {
            throw LedgerError.invalidDeletionBatch("Every deleted-item audit record must belong to its batch.")
        }
        guard items.isEmpty || batch.status == .preparing || batch.status == .movedToRecentlyDeleted || batch.status == .confirmationInterrupted else {
            throw LedgerError.invalidDeletionBatch(
                "Deleted-item metadata can only be staged during preflight or saved after PhotoKit confirms the move."
            )
        }
        let batchJSON = try encoder.encode(batch)
        let encodedItems = try items.map { ($0, try encoder.encode($0)) }
        try database.write { database in
            try database.execute(
                sql: """
                INSERT INTO organize_deletion_batches(
                    batch_id, requested_at, completed_at, status, item_count,
                    known_byte_count, error_message, batch_json
                ) VALUES (:id, :requested, :completed, :status, :count, :bytes, :error, :json)
                ON CONFLICT(batch_id) DO UPDATE SET
                    completed_at=excluded.completed_at,
                    status=excluded.status,
                    item_count=excluded.item_count,
                    known_byte_count=excluded.known_byte_count,
                    error_message=excluded.error_message,
                    batch_json=excluded.batch_json
                """,
                arguments: [
                    "id": Self.id(batch.id),
                    "requested": WireDate.string(batch.requestedAt),
                    "completed": batch.completedAt.map(WireDate.string),
                    "status": batch.status.rawValue,
                    "count": batch.itemCount,
                    "bytes": batch.knownByteCount,
                    "error": batch.errorMessage,
                    "json": batchJSON
                ]
            )
            for (item, json) in encodedItems {
                try database.execute(
                    sql: """
                    INSERT INTO organize_deleted_items(
                        item_id, batch_id, source_local_identifier, original_filename,
                        media_kind, deleted_at, thumbnail_relative_path,
                        thumbnail_expires_at, item_json
                    ) VALUES (:id, :batch, :source, :filename, :kind, :deleted, :thumbnail, :expires, :json)
                    ON CONFLICT(item_id) DO UPDATE SET
                        thumbnail_relative_path=excluded.thumbnail_relative_path,
                        thumbnail_expires_at=excluded.thumbnail_expires_at,
                        item_json=excluded.item_json
                    """,
                    arguments: [
                        "id": Self.id(item.id),
                        "batch": Self.id(item.batchID),
                        "source": item.sourceLocalIdentifier,
                        "filename": item.originalFilename,
                        "kind": item.mediaKind.rawValue,
                        "deleted": WireDate.string(item.deletedAt),
                        "thumbnail": item.thumbnailRelativePath,
                        "expires": item.thumbnailExpiresAt.map(WireDate.string),
                        "json": json
                    ]
                )
            }
        }
    }

    /// Recovers a request that crossed the non-transactional boundary between
    /// PhotoKit and the app database. There is no API that can query Apple's
    /// Recently Deleted collection after relaunch, so these rows are preserved as
    /// an explicit unknown outcome rather than hidden or falsely marked successful.
    /// Their staged queue entries are removed atomically to prevent an automatic
    /// retry; the user can verify the result in Apple Photos and queue an accessible
    /// item again deliberately if needed.
    func recoverInterruptedDeletionBatches() throws -> InterruptedDeletionRecovery {
        let batchRows = try database.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT batch_id, batch_json
                    FROM organize_deletion_batches
                    WHERE status=:status
                    ORDER BY requested_at, batch_id
                    """,
                arguments: ["status": DeletionBatchStatus.preparing.rawValue]
            )
        }
        guard !batchRows.isEmpty else { return .none }

        var recoveredBatches: [(batch: DeletionBatch, json: Data)] = []
        var recoveredItems: [(item: DeletedItemRecord, json: Data)] = []
        let interruptedMessage = "The app closed before Apple Photos' result could be recorded. Verify this batch in Apple Photos."

        for row in batchRows {
            let identifier: String = row["batch_id"]
            let data: Data = row["batch_json"]
            var batch = try decodeOrganize(DeletionBatch.self, from: data, identifier: identifier)
            batch.completedAt = nil
            batch.status = .confirmationInterrupted
            batch.errorMessage = interruptedMessage
            recoveredBatches.append((batch, try encoder.encode(batch)))
        }

        let batchIDs = Set(recoveredBatches.map { Self.id($0.batch.id) })
        let itemRows = try database.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT item_id, batch_id, item_json
                    FROM organize_deleted_items
                    WHERE batch_id IN (SELECT batch_id FROM organize_deletion_batches WHERE status=:status)
                    ORDER BY batch_id, item_id
                    """,
                arguments: ["status": DeletionBatchStatus.preparing.rawValue]
            )
        }
        for row in itemRows {
            let batchID: String = row["batch_id"]
            guard batchIDs.contains(batchID) else { continue }
            let identifier: String = row["item_id"]
            let data: Data = row["item_json"]
            let stored = try decodeOrganize(DeletedItemRecord.self, from: data, identifier: identifier)
            let item = Self.withResult(stored, result: .confirmationInterrupted)
            recoveredItems.append((item, try encoder.encode(item)))
        }

        try database.write { database in
            for recovered in recoveredBatches {
                try database.execute(
                    sql: """
                        UPDATE organize_deletion_batches
                        SET completed_at=NULL, status=:status, error_message=:error, batch_json=:json
                        WHERE batch_id=:id AND status=:preparing
                        """,
                    arguments: [
                        "status": DeletionBatchStatus.confirmationInterrupted.rawValue,
                        "error": interruptedMessage,
                        "json": recovered.json,
                        "id": Self.id(recovered.batch.id),
                        "preparing": DeletionBatchStatus.preparing.rawValue
                    ]
                )
            }
            for recovered in recoveredItems {
                try database.execute(
                    sql: "UPDATE organize_deleted_items SET item_json=:json WHERE item_id=:id",
                    arguments: ["json": recovered.json, "id": Self.id(recovered.item.id)]
                )
                try database.execute(
                    sql: "DELETE FROM organize_deletion_queue WHERE asset_id=:asset",
                    arguments: ["asset": recovered.item.sourceLocalIdentifier]
                )
            }
        }

        return InterruptedDeletionRecovery(
            batchCount: recoveredBatches.count,
            itemCount: recoveredItems.count
        )
    }

    func deletionBatches() throws -> [DeletionBatch] {
        let rows = try database.read { database in
            try Row.fetchAll(
                database,
                sql: "SELECT batch_id, batch_json FROM organize_deletion_batches ORDER BY requested_at DESC, batch_id"
            )
        }
        return try rows.map { row in
            let identifier: String = row["batch_id"]
            let data: Data = row["batch_json"]
            return try decodeOrganize(DeletionBatch.self, from: data, identifier: identifier)
        }
    }

    func deletedItems(search: String? = nil) throws -> [DeletedItemRecord] {
        let rows = try database.read { database -> [Row] in
            let base = """
                SELECT i.item_id, i.thumbnail_relative_path, i.thumbnail_expires_at, i.item_json
                FROM organize_deleted_items i
                JOIN organize_deletion_batches b ON b.batch_id=i.batch_id
                WHERE b.status IN ('movedToRecentlyDeleted', 'confirmationInterrupted')
                """
            guard let search, !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return try Row.fetchAll(database, sql: base + " ORDER BY i.deleted_at DESC, i.item_id")
            }
            return try Row.fetchAll(
                database,
                sql: base + """
                      AND (i.original_filename LIKE :search ESCAPE '\\' COLLATE NOCASE
                           OR i.source_local_identifier LIKE :search ESCAPE '\\' COLLATE NOCASE)
                    ORDER BY i.deleted_at DESC, i.item_id
                    """,
                arguments: ["search": "%\(Self.likePattern(search))%"]
            )
        }
        return try rows.map { row in
            let identifier: String = row["item_id"]
            let data: Data = row["item_json"]
            let stored = try decodeOrganize(DeletedItemRecord.self, from: data, identifier: identifier)
            let thumbnail: String? = row["thumbnail_relative_path"]
            let expirationString: String? = row["thumbnail_expires_at"]
            return Self.withThumbnail(
                stored,
                relativePath: thumbnail,
                expiresAt: expirationString.flatMap(WireDate.parse)
            )
        }
    }

    /// Clears only expired cache references and returns the relative paths for the caller to unlink.
    /// The deletion batch and all deleted-item audit metadata remain in the ledger indefinitely.
    func expireDeletedItemThumbnails(asOf date: Date = Date()) throws -> [String] {
        try database.write { database in
            let paths = try String.fetchAll(
                database,
                sql: """
                SELECT thumbnail_relative_path FROM organize_deleted_items
                WHERE thumbnail_relative_path IS NOT NULL
                  AND thumbnail_expires_at IS NOT NULL
                  AND thumbnail_expires_at <= :cutoff
                ORDER BY thumbnail_relative_path
                """,
                arguments: ["cutoff": WireDate.string(date)]
            )
            try database.execute(
                sql: """
                UPDATE organize_deleted_items
                SET thumbnail_relative_path=NULL, thumbnail_expires_at=NULL
                WHERE thumbnail_relative_path IS NOT NULL
                  AND thumbnail_expires_at IS NOT NULL
                  AND thumbnail_expires_at <= :cutoff
                """,
                arguments: ["cutoff": WireDate.string(date)]
            )
            return paths
        }
    }

    private func decodeOrganize<Value: Decodable>(
        _ type: Value.Type,
        from data: Data,
        identifier: String
    ) throws -> Value {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw LedgerError.corruptOrganizeRecord(identifier)
        }
    }

    private func rehydratedReviewSession(
        sessionRow: Row,
        actionRows: [Row]
    ) throws -> ReviewSession {
        let identifier: String = sessionRow["session_id"]
        let data: Data = sessionRow["session_json"]
        var session = try decodeOrganize(ReviewSession.self, from: data, identifier: identifier)
        var actions: [ReviewAction] = []
        actions.reserveCapacity(actionRows.count)
        for row in actionRows {
            let actionID: String = row["action_id"]
            let actionData: Data = row["action_json"]
            actions.append(
                try decodeOrganize(ReviewAction.self, from: actionData, identifier: actionID)
            )
        }
        var decisions: [String: ReviewDecision] = [:]
        for action in actions { decisions[action.assetID] = action.decision }
        guard let status = ReviewSessionStatus(rawValue: sessionRow["status"]),
              let updatedAt = WireDate.parse(sessionRow["updated_at"]) else {
            throw LedgerError.corruptOrganizeRecord(identifier)
        }
        session.actions = actions
        session.decisions = decisions
        session.cursor = min(
            max(actions.last?.cursorAfter ?? 0, 0),
            session.orderedAssetIDs.count
        )
        session.status = status
        session.updatedAt = updatedAt
        return session
    }

    private static func recoverInterruptedAnalysis(
        in database: Database,
        asOf date: Date
    ) throws -> InterruptedAnalysisRecovery {
        let decoder = WireCoders.decoder()
        let encoder = WireCoders.encoder()
        let updated = WireDate.string(date)

        let runRows = try Row.fetchAll(
            database,
            sql: "SELECT run_id FROM organize_analysis_runs WHERE status=?",
            arguments: [AnalysisRunStatus.running.rawValue]
        )
        for row in runRows {
            let identifier: String = row["run_id"]
            try database.execute(
                sql: """
                UPDATE organize_analysis_runs
                SET status=:status, updated_at=:updated, error_message=NULL
                WHERE run_id=:id
                """,
                arguments: [
                    "status": AnalysisRunStatus.paused.rawValue,
                    "updated": updated,
                    "id": identifier
                ]
            )
        }

        let assetRows = try Row.fetchAll(
            database,
            sql: "SELECT asset_id, record_json FROM organize_analysis WHERE status=?",
            arguments: [AnalysisStatus.analyzing.rawValue]
        )
        for row in assetRows {
            let identifier: String = row["asset_id"]
            let data: Data = row["record_json"]
            var record: AssetAnalysisRecord
            do {
                record = try decoder.decode(AssetAnalysisRecord.self, from: data)
            } catch {
                throw LedgerError.corruptOrganizeRecord(identifier)
            }
            record.status = .queued
            record.fingerprint = nil
            record.updatedAt = date
            record.errorMessage = nil
            try database.execute(
                sql: """
                UPDATE organize_analysis
                SET status=:status, known_byte_count=NULL,
                    exact_duplicate_key=NULL, updated_at=:updated, record_json=:json
                WHERE asset_id=:id
                """,
                arguments: [
                    "status": AnalysisStatus.queued.rawValue,
                    "updated": updated,
                    "json": try encoder.encode(record),
                    "id": identifier
                ]
            )
        }

        return InterruptedAnalysisRecovery(
            runCount: runRows.count,
            assetCount: assetRows.count
        )
    }

    private static func nextAnalysisPosition(for run: AnalysisRunRecord) -> Int {
        var position = 0
        while position < run.orderedAssetIDs.count,
              run.completedAssetIDs.contains(run.orderedAssetIDs[position]) {
            position += 1
        }
        return position
    }

    private static func normalizedAnalysisRun(from row: Row, in database: Database) throws -> AnalysisRunRecord {
        let identifier: String = row["run_id"]
        guard let id = UUID(uuidString: identifier),
              let origin = AnalysisRunOrigin(rawValue: row["origin"]),
              let status = AnalysisRunStatus(rawValue: row["status"]),
              let startedAt = WireDate.parse(row["started_at"]),
              let updatedAt = WireDate.parse(row["updated_at"]) else {
            throw LedgerError.corruptOrganizeRecord(identifier)
        }
        let orderedAssetIDs = try String.fetchAll(
            database,
            sql: "SELECT asset_id FROM organize_analysis_work WHERE run_id=? ORDER BY position",
            arguments: [identifier]
        )
        let storedTotal: Int = row["total_asset_count"]
        let boundedTotal = min(max(storedTotal, 0), orderedAssetIDs.count)
        let completedAssetIDs = try String.fetchAll(
            database,
            sql: """
            SELECT w.asset_id
            FROM organize_analysis_work w
            JOIN organize_analysis a ON a.asset_id=w.asset_id
            WHERE w.run_id=? AND a.status=?
            ORDER BY w.position
            """,
            arguments: [identifier, AnalysisStatus.complete.rawValue]
        )
        return AnalysisRunRecord(
            id: id,
            includesICloudItems: row["includes_icloud_items"],
            orderedAssetIDs: Array(orderedAssetIDs.prefix(boundedTotal)),
            completedAssetIDs: Set(completedAssetIDs),
            status: status,
            startedAt: startedAt,
            updatedAt: updatedAt,
            errorMessage: row["error_message"],
            origin: origin
        )
    }

    private static func libraryAssetComesBefore(_ lhs: PhotoAsset, _ rhs: PhotoAsset) -> Bool {
        switch (lhs.creationDate, rhs.creationDate) {
        case let (left?, right?) where left != right: return left > right
        case (_?, nil): return true
        case (nil, _?): return false
        default: return lhs.id < rhs.id
        }
    }

    private static func upsertLibraryAlbum(
        _ album: PhotoAlbum,
        accessibleAssetIDs: Set<String>,
        in database: Database
    ) throws {
        try database.execute(
            sql: """
            INSERT INTO photo_library_albums(album_id, title, parent_id)
            VALUES (:id, :title, :parent)
            ON CONFLICT(album_id) DO UPDATE SET
                title=excluded.title, parent_id=excluded.parent_id
            """,
            arguments: ["id": album.id, "title": album.title, "parent": album.parentID]
        )
        try database.execute(
            sql: "DELETE FROM photo_library_album_assets WHERE album_id=?",
            arguments: [album.id]
        )
        for (position, assetID) in album.assetIDs.enumerated()
        where accessibleAssetIDs.contains(assetID) {
            try database.execute(
                sql: """
                INSERT INTO photo_library_album_assets(album_id, asset_id, position)
                VALUES (?, ?, ?)
                """,
                arguments: [album.id, assetID, position]
            )
        }
    }

    private static func saveLibraryIndexMetadata(
        token: Data?,
        authorization: PhotoAuthorizationState,
        scopeFingerprint: String?,
        in database: Database
    ) throws {
        try database.execute(
            sql: """
            INSERT INTO metadata(key, value) VALUES ('photo_index_ready', :ready)
            ON CONFLICT(key) DO UPDATE SET value=excluded.value
            """,
            arguments: ["ready": Data([1])]
        )
        try database.execute(
            sql: """
            INSERT INTO metadata(key, value) VALUES ('photo_change_token', :token)
            ON CONFLICT(key) DO UPDATE SET value=excluded.value
            """,
            arguments: ["token": token]
        )
        try database.execute(
            sql: """
            INSERT INTO metadata(key, value) VALUES ('photo_index_authorization', :scope)
            ON CONFLICT(key) DO UPDATE SET value=excluded.value
            """,
            arguments: ["scope": Data(libraryAuthorizationScope(authorization).utf8)]
        )
        if let scopeFingerprint {
            try database.execute(
                sql: """
                INSERT INTO metadata(key, value) VALUES ('photo_index_scope_fingerprint', :fingerprint)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value
                """,
                arguments: ["fingerprint": Data(scopeFingerprint.utf8)]
            )
        } else {
            try database.execute(
                sql: "DELETE FROM metadata WHERE key='photo_index_scope_fingerprint'"
            )
        }
    }

    private static func libraryAuthorizationScope(_ authorization: PhotoAuthorizationState) -> String {
        switch authorization {
        case .authorized: "authorized"
        case .limited: "limited"
        case .notDetermined: "notDetermined"
        case .denied: "denied"
        case .restricted: "restricted"
        }
    }

    private static func likePattern(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func withThumbnail(
        _ record: DeletedItemRecord,
        relativePath: String?,
        expiresAt: Date?
    ) -> DeletedItemRecord {
        DeletedItemRecord(
            id: record.id,
            batchID: record.batchID,
            sourceLocalIdentifier: record.sourceLocalIdentifier,
            sourceRevision: record.sourceRevision,
            originalFilename: record.originalFilename,
            mediaKind: record.mediaKind,
            creationDate: record.creationDate,
            deletedAt: record.deletedAt,
            pixelWidth: record.pixelWidth,
            pixelHeight: record.pixelHeight,
            durationMilliseconds: record.durationMilliseconds,
            knownByteCount: record.knownByteCount,
            recommendationKind: record.recommendationKind,
            isLivePhoto: record.isLivePhoto,
            isRaw: record.isRaw,
            isFavorite: record.isFavorite,
            isHidden: record.isHidden,
            isEdited: record.isEdited,
            result: record.result,
            thumbnailRelativePath: relativePath,
            thumbnailExpiresAt: expiresAt
        )
    }

    private static func withResult(
        _ record: DeletedItemRecord,
        result: DeletedItemResult
    ) -> DeletedItemRecord {
        DeletedItemRecord(
            id: record.id,
            batchID: record.batchID,
            sourceLocalIdentifier: record.sourceLocalIdentifier,
            sourceRevision: record.sourceRevision,
            originalFilename: record.originalFilename,
            mediaKind: record.mediaKind,
            creationDate: record.creationDate,
            deletedAt: record.deletedAt,
            pixelWidth: record.pixelWidth,
            pixelHeight: record.pixelHeight,
            durationMilliseconds: record.durationMilliseconds,
            knownByteCount: record.knownByteCount,
            recommendationKind: record.recommendationKind,
            isLivePhoto: record.isLivePhoto,
            isRaw: record.isRaw,
            isFavorite: record.isFavorite,
            isHidden: record.isHidden,
            isEdited: record.isEdited,
            result: result,
            thumbnailRelativePath: record.thumbnailRelativePath,
            thumbnailExpiresAt: record.thumbnailExpiresAt
        )
    }

    private static func refreshJobCounters(_ jobID: UUID, in database: Database) throws {
        try database.execute(
            sql: """
            UPDATE jobs SET
                verified_file_count=(SELECT COUNT(*) FROM files WHERE job_id=:job AND status='verified'),
                skipped_file_count=(SELECT COUNT(*) FROM files WHERE job_id=:job AND status='skipped'),
                failed_file_count=(SELECT COUNT(*) FROM files WHERE job_id=:job AND status='failed'),
                verified_byte_count=COALESCE((SELECT SUM(byte_count) FROM files WHERE job_id=:job AND status='verified'), 0),
                updated_at=:updated WHERE job_id=:job
            """,
            arguments: ["job": Self.id(jobID), "updated": WireDate.string(Date())]
        )
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-export-ledger") { database in
            try database.execute(sql: """
            CREATE TABLE IF NOT EXISTS destinations(
                destination_id TEXT PRIMARY KEY,
                display_name TEXT NOT NULL,
                created_at TEXT NOT NULL,
                last_seen_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS jobs(
                job_id TEXT PRIMARY KEY,
                destination_id TEXT REFERENCES destinations(destination_id),
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                status TEXT NOT NULL,
                profile TEXT NOT NULL,
                asset_count INTEGER NOT NULL,
                total_file_count INTEGER NOT NULL,
                verified_file_count INTEGER NOT NULL DEFAULT 0,
                skipped_file_count INTEGER NOT NULL DEFAULT 0,
                failed_file_count INTEGER NOT NULL DEFAULT 0,
                verified_byte_count INTEGER NOT NULL DEFAULT 0,
                job_json BLOB NOT NULL,
                report_json BLOB
            );
            CREATE TABLE IF NOT EXISTS files(
                job_id TEXT NOT NULL REFERENCES jobs(job_id) ON DELETE CASCADE,
                file_id TEXT NOT NULL,
                asset_id TEXT NOT NULL,
                source_revision TEXT NOT NULL,
                proposed_path TEXT NOT NULL,
                accepted_path TEXT,
                status TEXT NOT NULL,
                byte_count INTEGER,
                sha256 TEXT,
                acknowledged_chunks INTEGER NOT NULL DEFAULT 0,
                last_error TEXT,
                updated_at TEXT NOT NULL,
                PRIMARY KEY(job_id, file_id)
            );
            CREATE TABLE IF NOT EXISTS asset_exports(
                destination_id TEXT NOT NULL REFERENCES destinations(destination_id),
                source_local_identifier TEXT NOT NULL,
                source_revision TEXT NOT NULL,
                recovery_fingerprint BLOB NOT NULL,
                verified_at TEXT NOT NULL,
                PRIMARY KEY(destination_id, source_local_identifier)
            );
            CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY, value BLOB);
            """)
        }
        migrator.registerMigration("v2-organize-library") { database in
            try database.execute(sql: """
            CREATE TABLE organize_analysis(
                asset_id TEXT PRIMARY KEY,
                source_revision TEXT NOT NULL,
                status TEXT NOT NULL,
                known_byte_count INTEGER,
                exact_duplicate_key TEXT,
                updated_at TEXT NOT NULL,
                record_json BLOB NOT NULL
            );
            CREATE INDEX organize_analysis_duplicate
                ON organize_analysis(exact_duplicate_key)
                WHERE exact_duplicate_key IS NOT NULL;
            CREATE TABLE organize_analysis_runs(
                run_id TEXT PRIMARY KEY,
                includes_icloud_items INTEGER NOT NULL,
                status TEXT NOT NULL,
                started_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                run_json BLOB NOT NULL
            );

            CREATE TABLE organize_review_sessions(
                session_id TEXT PRIMARY KEY,
                recommendation_kind TEXT NOT NULL,
                status TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                session_json BLOB NOT NULL
            );
            CREATE TABLE organize_review_actions(
                session_id TEXT NOT NULL REFERENCES organize_review_sessions(session_id) ON DELETE CASCADE,
                sequence INTEGER NOT NULL,
                action_id TEXT NOT NULL UNIQUE,
                asset_id TEXT NOT NULL,
                decision TEXT NOT NULL,
                created_at TEXT NOT NULL,
                action_json BLOB NOT NULL,
                PRIMARY KEY(session_id, sequence)
            );
            CREATE TABLE organize_review_states(
                asset_id TEXT PRIMARY KEY,
                source_revision TEXT NOT NULL,
                state TEXT NOT NULL,
                recommendation_kind TEXT,
                updated_at TEXT NOT NULL,
                record_json BLOB NOT NULL
            );

            CREATE TABLE organize_deletion_queue(
                asset_id TEXT PRIMARY KEY,
                source_revision TEXT NOT NULL,
                recommendation_kind TEXT,
                queued_at TEXT NOT NULL,
                protection_override INTEGER NOT NULL DEFAULT 0,
                review_session_id TEXT REFERENCES organize_review_sessions(session_id) ON DELETE SET NULL,
                item_json BLOB NOT NULL
            );
            CREATE INDEX organize_deletion_queue_date ON organize_deletion_queue(queued_at);

            CREATE TABLE organize_protected_albums(
                album_id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                protected_at TEXT NOT NULL,
                record_json BLOB NOT NULL
            );

            CREATE TABLE organize_deletion_batches(
                batch_id TEXT PRIMARY KEY,
                requested_at TEXT NOT NULL,
                completed_at TEXT,
                status TEXT NOT NULL,
                item_count INTEGER NOT NULL,
                known_byte_count INTEGER NOT NULL,
                error_message TEXT,
                batch_json BLOB NOT NULL
            );
            CREATE TABLE organize_deleted_items(
                item_id TEXT PRIMARY KEY,
                batch_id TEXT NOT NULL REFERENCES organize_deletion_batches(batch_id),
                source_local_identifier TEXT NOT NULL,
                original_filename TEXT NOT NULL,
                media_kind TEXT NOT NULL,
                deleted_at TEXT NOT NULL,
                thumbnail_relative_path TEXT,
                thumbnail_expires_at TEXT,
                item_json BLOB NOT NULL
            );
            CREATE INDEX organize_deleted_items_batch ON organize_deleted_items(batch_id);
            CREATE INDEX organize_deleted_items_date ON organize_deleted_items(deleted_at DESC);
            """)
        }
        migrator.registerMigration("v3-photo-library-index") { database in
            try database.execute(sql: """
            CREATE TABLE photo_library_assets(
                asset_id TEXT PRIMARY KEY,
                asset_json BLOB NOT NULL
            );
            CREATE TABLE photo_library_albums(
                album_id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                parent_id TEXT
            );
            CREATE TABLE photo_library_album_assets(
                album_id TEXT NOT NULL REFERENCES photo_library_albums(album_id) ON DELETE CASCADE,
                asset_id TEXT NOT NULL REFERENCES photo_library_assets(asset_id) ON DELETE CASCADE,
                position INTEGER NOT NULL,
                PRIMARY KEY(album_id, asset_id)
            );
            CREATE INDEX photo_library_album_assets_position
                ON photo_library_album_assets(album_id, position);
            """)
        }
        migrator.registerMigration("v4-normalized-analysis-work") { database in
            try database.execute(sql: """
            ALTER TABLE organize_analysis_runs ADD COLUMN next_position INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE organize_analysis_runs ADD COLUMN total_asset_count INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE organize_analysis_runs ADD COLUMN error_message TEXT;
            CREATE TABLE organize_analysis_work(
                run_id TEXT NOT NULL REFERENCES organize_analysis_runs(run_id) ON DELETE CASCADE,
                position INTEGER NOT NULL,
                asset_id TEXT NOT NULL,
                PRIMARY KEY(run_id, position),
                UNIQUE(run_id, asset_id)
            );
            """)
            let decoder = WireCoders.decoder()
            let rows = try Row.fetchAll(
                database,
                sql: "SELECT run_id, run_json FROM organize_analysis_runs"
            )
            for row in rows {
                let identifier: String = row["run_id"]
                let data: Data = row["run_json"]
                guard let run = try? decoder.decode(AnalysisRunRecord.self, from: data) else { continue }
                for (position, assetID) in run.orderedAssetIDs.enumerated() {
                    try database.execute(
                        sql: "INSERT INTO organize_analysis_work(run_id, position, asset_id) VALUES (?, ?, ?)",
                        arguments: [identifier, position, assetID]
                    )
                }
                try database.execute(
                    sql: """
                    UPDATE organize_analysis_runs
                    SET next_position=:next, total_asset_count=:total, error_message=:error
                    WHERE run_id=:id
                    """,
                    arguments: [
                        "next": Self.nextAnalysisPosition(for: run),
                        "total": run.orderedAssetIDs.count,
                        "error": run.errorMessage,
                        "id": identifier
                    ]
                )
            }
        }
        migrator.registerMigration("v5-photo-library-membership-asset-index") { database in
            // SQLite requires an index on the child-key columns for efficient
            // foreign-key cascades. Incremental PhotoKit deletions and limited-
            // scope revocations delete by asset_id, while the existing primary
            // key and position index both begin with album_id.
            try database.execute(sql: """
            CREATE INDEX IF NOT EXISTS photo_library_album_assets_asset
                ON photo_library_album_assets(asset_id);
            """)
        }
        migrator.registerMigration("v6-analysis-run-origin") { database in
            try database.execute(sql: """
            ALTER TABLE organize_analysis_runs
                ADD COLUMN origin TEXT NOT NULL DEFAULT 'userInitiated';
            """)
        }
        migrator.registerMigration("v7-analysis-run-completed-counter") { database in
            try database.execute(sql: """
            ALTER TABLE organize_analysis_runs
                ADD COLUMN completed_asset_count INTEGER NOT NULL DEFAULT 0;
            UPDATE organize_analysis_runs
            SET completed_asset_count=MIN(
                total_asset_count,
                (
                    SELECT COUNT(*)
                    FROM organize_analysis_work w
                    JOIN organize_analysis a ON a.asset_id=w.asset_id
                    WHERE w.run_id=organize_analysis_runs.run_id
                      AND a.status='complete'
                )
            );
            """)
        }
        migrator.registerMigration("v8-independent-analysis-revision") { database in
            let decoder = WireCoders.decoder()
            let encoder = WireCoders.encoder()
            let rows = try Row.fetchAll(
                database,
                sql: """
                SELECT a.asset_id, a.record_json, p.asset_json
                FROM organize_analysis a
                JOIN photo_library_assets p ON p.asset_id=a.asset_id
                """
            )
            for row in rows {
                let assetID: String = row["asset_id"]
                let recordData: Data = row["record_json"]
                let assetData: Data = row["asset_json"]
                guard let asset = try? decoder.decode(PhotoAsset.self, from: assetData),
                      let record = try? decoder.decode(AssetAnalysisRecord.self, from: recordData),
                      record.sourceRevision == asset.sourceRevision else { continue }

                let fingerprint = record.fingerprint.map {
                    AssetFingerprint(
                        assetID: $0.assetID,
                        sourceRevision: asset.analysisRevision,
                        resources: $0.resources,
                        analyzedAt: $0.analyzedAt
                    )
                }
                let migrated = AssetAnalysisRecord(
                    assetID: record.assetID,
                    sourceRevision: asset.analysisRevision,
                    status: record.status,
                    fingerprint: fingerprint,
                    updatedAt: record.updatedAt,
                    errorMessage: record.errorMessage
                )
                let migratedData = try encoder.encode(migrated)
                try database.execute(
                    sql: """
                    UPDATE organize_analysis
                    SET source_revision=:revision,
                        known_byte_count=:bytes,
                        exact_duplicate_key=:duplicate,
                        record_json=:json
                    WHERE asset_id=:asset
                    """,
                    arguments: [
                        "revision": asset.analysisRevision,
                        "bytes": migrated.knownByteCount,
                        "duplicate": migrated.exactDuplicateKey,
                        "json": migratedData,
                        "asset": assetID
                    ]
                )
            }
        }
        migrator.registerMigration("v9-lightweight-visual-analysis") { database in
            try database.execute(sql: """
            CREATE TABLE organize_visual_analysis(
                asset_id TEXT PRIMARY KEY
                    REFERENCES photo_library_assets(asset_id) ON DELETE CASCADE,
                source_revision TEXT NOT NULL,
                algorithm_version TEXT NOT NULL,
                feature_print_revision INTEGER NOT NULL,
                aesthetics_score REAL,
                is_utility INTEGER,
                analyzed_at TEXT NOT NULL,
                record_json BLOB NOT NULL
            );
            CREATE INDEX organize_visual_analysis_revision
                ON organize_visual_analysis(source_revision, algorithm_version);
            """)
        }
        migrator.registerMigration("v10-visual-analysis-attempts") { database in
            try database.execute(sql: """
            CREATE TABLE organize_visual_analysis_attempts(
                asset_id TEXT PRIMARY KEY
                    REFERENCES photo_library_assets(asset_id) ON DELETE CASCADE,
                source_revision TEXT NOT NULL,
                algorithm_version TEXT NOT NULL,
                vision_revisions_json BLOB NOT NULL,
                status TEXT NOT NULL,
                attempted_at TEXT NOT NULL
            );
            CREATE INDEX organize_visual_analysis_attempts_revision
                ON organize_visual_analysis_attempts(source_revision, algorithm_version, status);
            """)
        }
        return migrator
    }

    private static func id(_ value: UUID) -> String { value.uuidString.lowercased() }
}
