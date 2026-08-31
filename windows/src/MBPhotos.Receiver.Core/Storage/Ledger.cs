using Microsoft.Data.Sqlite;
using MBPhotos.Receiver.Models;

namespace MBPhotos.Receiver.Storage;

public sealed record LedgerJob(
    Guid JobId,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt,
    JobState State,
    string ManifestJson,
    DateTimeOffset? CompletedAt,
    string? CompletionRequestJson,
    string? ReportJson,
    int? AbandonRemovedPartialFiles);

public sealed record LedgerFile(
    Guid JobId,
    Guid FileId,
    Guid AssetId,
    string SourceRevision,
    ExportFileKind Kind,
    string ProposedPath,
    string RelativePath,
    string OriginalFilename,
    DateTimeOffset? CaptureDate,
    long? ExpectedBytes,
    string? ExpectedSha256,
    string State,
    string? CommittedSha256,
    long? CommittedBytes,
    DateTimeOffset? CommittedAt,
    long? ObservedWriteTicks,
    long BytesTransferred);

public sealed record LedgerChunk(
    int ChunkIndex,
    long Offset,
    long Length,
    long TotalBytes,
    string Sha256,
    DateTimeOffset ReceivedAt);

public sealed record LedgerChunkState(
    int NextChunkIndex,
    long? TotalBytes,
    long BytesTransferred,
    LedgerChunk? RequestedChunk);

public sealed record LedgerStats(
    int TotalFiles,
    int CommittedFiles,
    int SkippedFiles,
    int FailedFiles,
    long BytesTransferred,
    long BytesCommitted,
    int VerifiedOriginalFiles);

public sealed record LedgerSkip(
    Guid FileId,
    LedgerFile Prior,
    long ObservedWriteTicks);

public sealed record LedgerCompletedJobBatch(
    LedgerJob Job,
    IReadOnlyList<LedgerFile> Files,
    bool IsFirst,
    bool IsLast);

public sealed class Ledger : IAsyncDisposable
{
    private readonly string connectionString;
    private readonly SemaphoreSlim gate = new(1, 1);

    public Ledger(string databasePath)
    {
        if (string.IsNullOrWhiteSpace(databasePath))
        {
            throw new ArgumentException("A database path is required.", nameof(databasePath));
        }
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(databasePath))!);
        connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = databasePath,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Cache = SqliteCacheMode.Shared,
            ForeignKeys = true,
        }.ToString();
    }

    public async Task InitializeAsync(CancellationToken cancellationToken = default)
    {
        await WithLockAsync(async connection =>
        {
            await ExecuteAsync(connection, "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;", cancellationToken);
            var version = Convert.ToInt32(await ScalarAsync(connection, "PRAGMA user_version;", cancellationToken));
            if (version > 3)
            {
                throw new InvalidDataException($"The receiver ledger schema {version} is newer than this app supports.");
            }

            if (version == 0)
            {
                using var transaction = connection.BeginTransaction();
                var command = connection.CreateCommand();
                command.Transaction = transaction;
                command.CommandText = """
                    CREATE TABLE jobs (
                        job_id TEXT PRIMARY KEY,
                        created_at TEXT NOT NULL,
                        updated_at TEXT NOT NULL,
                        state TEXT NOT NULL,
                        manifest_json TEXT NOT NULL,
                        completed_at TEXT NULL,
                        abandon_reason TEXT NULL,
                        abandon_removed_partial_files INTEGER NULL,
                        completion_request_json TEXT NULL,
                        report_json TEXT NULL,
                        total_files INTEGER NOT NULL DEFAULT 0,
                        committed_files INTEGER NOT NULL DEFAULT 0,
                        skipped_files INTEGER NOT NULL DEFAULT 0,
                        failed_files INTEGER NOT NULL DEFAULT 0,
                        bytes_transferred INTEGER NOT NULL DEFAULT 0,
                        bytes_committed INTEGER NOT NULL DEFAULT 0,
                        verified_original_files INTEGER NOT NULL DEFAULT 0
                    );

                    CREATE TABLE files (
                        job_id TEXT NOT NULL,
                        file_id TEXT NOT NULL,
                        asset_id TEXT NOT NULL,
                        source_revision TEXT NOT NULL,
                        kind TEXT NOT NULL,
                        proposed_path TEXT NOT NULL COLLATE NOCASE,
                        relative_path TEXT NOT NULL COLLATE NOCASE,
                        original_filename TEXT NOT NULL,
                        capture_date TEXT NULL,
                        expected_bytes INTEGER NULL,
                        expected_sha256 TEXT NULL,
                        state TEXT NOT NULL,
                        committed_sha256 TEXT NULL,
                        committed_bytes INTEGER NULL,
                        committed_at TEXT NULL,
                        observed_write_ticks INTEGER NULL,
                        bytes_transferred INTEGER NOT NULL DEFAULT 0,
                        next_chunk_index INTEGER NOT NULL DEFAULT 0,
                        upload_total_bytes INTEGER NULL,
                        PRIMARY KEY (job_id, file_id),
                        FOREIGN KEY (job_id) REFERENCES jobs(job_id) ON DELETE CASCADE
                    );

                    CREATE INDEX ix_files_file_revision
                        ON files(file_id, source_revision, committed_at DESC);
                    CREATE INDEX ix_files_relative_path
                        ON files(relative_path);

                    CREATE TABLE chunks (
                        job_id TEXT NOT NULL,
                        file_id TEXT NOT NULL,
                        chunk_index INTEGER NOT NULL,
                        byte_offset INTEGER NOT NULL,
                        byte_length INTEGER NOT NULL,
                        total_bytes INTEGER NOT NULL,
                        sha256 TEXT NOT NULL,
                        received_at TEXT NOT NULL,
                        PRIMARY KEY (job_id, file_id, chunk_index),
                        FOREIGN KEY (job_id, file_id) REFERENCES files(job_id, file_id) ON DELETE CASCADE
                    );

                    CREATE TABLE failures (
                        job_id TEXT NOT NULL,
                        file_id TEXT NOT NULL,
                        code TEXT NOT NULL,
                        message TEXT NOT NULL,
                        retryable INTEGER NOT NULL,
                        occurred_at TEXT NOT NULL,
                        FOREIGN KEY (job_id, file_id) REFERENCES files(job_id, file_id) ON DELETE CASCADE
                    );

                    PRAGMA user_version=3;
                    """;
                await command.ExecuteNonQueryAsync(cancellationToken);
                transaction.Commit();
            }
            else
            {
                if (version == 1)
                {
                    using var transaction = connection.BeginTransaction();
                    var command = connection.CreateCommand();
                    command.Transaction = transaction;
                    command.CommandText = """
                        ALTER TABLE jobs ADD COLUMN abandon_removed_partial_files INTEGER NULL;
                        PRAGMA user_version=2;
                        """;
                    await command.ExecuteNonQueryAsync(cancellationToken);
                    transaction.Commit();
                    version = 2;
                }

                if (version == 2)
                {
                    using var transaction = connection.BeginTransaction();
                    var command = connection.CreateCommand();
                    command.Transaction = transaction;
                    command.CommandText = """
                        ALTER TABLE jobs ADD COLUMN total_files INTEGER NOT NULL DEFAULT 0;
                        ALTER TABLE jobs ADD COLUMN committed_files INTEGER NOT NULL DEFAULT 0;
                        ALTER TABLE jobs ADD COLUMN skipped_files INTEGER NOT NULL DEFAULT 0;
                        ALTER TABLE jobs ADD COLUMN failed_files INTEGER NOT NULL DEFAULT 0;
                        ALTER TABLE jobs ADD COLUMN bytes_transferred INTEGER NOT NULL DEFAULT 0;
                        ALTER TABLE jobs ADD COLUMN bytes_committed INTEGER NOT NULL DEFAULT 0;
                        ALTER TABLE jobs ADD COLUMN verified_original_files INTEGER NOT NULL DEFAULT 0;
                        ALTER TABLE files ADD COLUMN next_chunk_index INTEGER NOT NULL DEFAULT 0;
                        ALTER TABLE files ADD COLUMN upload_total_bytes INTEGER NULL;

                        -- Interrupted writes can leave bytes beyond the last durable
                        -- receipt, but a durable v2 chunk history should still be a
                        -- contiguous, single-total prefix. Discard only an invalid
                        -- history so the sender safely resumes that file from zero.
                        DELETE FROM chunks
                        WHERE (job_id,file_id) IN (
                            SELECT job_id,file_id FROM chunks
                            GROUP BY job_id,file_id
                            HAVING MIN(chunk_index) <> 0
                                OR MAX(chunk_index) + 1 <> COUNT(*)
                                OR MIN(total_bytes) <> MAX(total_bytes)
                                OR SUM(CASE
                                    WHEN byte_offset <> chunk_index * 8388608
                                        OR byte_length <= 0
                                        OR byte_length > 8388608
                                    THEN 1 ELSE 0 END) <> 0
                        );

                        UPDATE files SET
                            bytes_transferred=COALESCE((
                                SELECT SUM(byte_length) FROM chunks
                                WHERE chunks.job_id=files.job_id AND chunks.file_id=files.file_id
                            ),0),
                            next_chunk_index=COALESCE((
                                SELECT COUNT(*) FROM chunks
                                WHERE chunks.job_id=files.job_id AND chunks.file_id=files.file_id
                            ),0),
                            upload_total_bytes=(
                                SELECT MIN(total_bytes) FROM chunks
                                WHERE chunks.job_id=files.job_id AND chunks.file_id=files.file_id
                            );

                        UPDATE jobs SET
                            total_files=(SELECT COUNT(*) FROM files WHERE files.job_id=jobs.job_id),
                            committed_files=(SELECT COUNT(*) FROM files WHERE files.job_id=jobs.job_id AND state='committed'),
                            skipped_files=(SELECT COUNT(*) FROM files WHERE files.job_id=jobs.job_id AND state='skipped'),
                            failed_files=(SELECT COUNT(*) FROM failures WHERE failures.job_id=jobs.job_id),
                            bytes_transferred=COALESCE((SELECT SUM(bytes_transferred) FROM files WHERE files.job_id=jobs.job_id),0),
                            bytes_committed=COALESCE((SELECT SUM(committed_bytes) FROM files WHERE files.job_id=jobs.job_id AND state IN ('committed','skipped')),0),
                            verified_original_files=(SELECT COUNT(*) FROM files WHERE files.job_id=jobs.job_id AND state IN ('committed','skipped') AND kind='originalResource');

                        PRAGMA user_version=3;
                        """;
                    await command.ExecuteNonQueryAsync(cancellationToken);
                    transaction.Commit();
                }
            }

            return true;
        }, cancellationToken);
    }

    public Task<LedgerJob?> GetJobAsync(Guid jobId, CancellationToken cancellationToken = default) =>
        WithLockAsync(async connection =>
        {
            var command = connection.CreateCommand();
            command.CommandText = """
                SELECT job_id,created_at,updated_at,state,manifest_json,completed_at,
                    completion_request_json,report_json,abandon_removed_partial_files
                FROM jobs WHERE job_id=$jobId
                """;
            command.Parameters.AddWithValue("$jobId", Id(jobId));
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            return await reader.ReadAsync(cancellationToken) ? ReadJob(reader) : null;
        }, cancellationToken);

    public Task CreateJobAsync(
        ExportJob job,
        string manifestJson,
        IReadOnlyDictionary<Guid, string> proposedPaths,
        IReadOnlyDictionary<Guid, string> acceptedPaths,
        CancellationToken cancellationToken = default) =>
        WithLockAsync(async connection =>
        {
            using var transaction = connection.BeginTransaction();
            var jobCommand = connection.CreateCommand();
            jobCommand.Transaction = transaction;
            jobCommand.CommandText = """
                INSERT INTO jobs(job_id,created_at,updated_at,state,manifest_json,total_files)
                VALUES($id,$created,$created,'transferring',$manifest,$totalFiles)
                """;
            jobCommand.Parameters.AddWithValue("$id", Id(job.JobId));
            jobCommand.Parameters.AddWithValue("$created", Date(job.CreatedAt));
            jobCommand.Parameters.AddWithValue("$manifest", manifestJson);
            jobCommand.Parameters.AddWithValue("$totalFiles", job.Assets.Sum(static asset => asset.Files.Count));
            await jobCommand.ExecuteNonQueryAsync(cancellationToken);

            var fileCommand = connection.CreateCommand();
            fileCommand.Transaction = transaction;
            fileCommand.CommandText = """
                INSERT INTO files(
                    job_id,file_id,asset_id,source_revision,kind,proposed_path,relative_path,original_filename,
                    capture_date,expected_bytes,expected_sha256,state)
                VALUES($job,$file,$asset,$revision,$kind,$proposed,$path,$name,$capture,$bytes,$sha,'pending')
                """;
            fileCommand.Parameters.Add("$job", SqliteType.Text);
            fileCommand.Parameters.Add("$file", SqliteType.Text);
            fileCommand.Parameters.Add("$asset", SqliteType.Text);
            fileCommand.Parameters.Add("$revision", SqliteType.Text);
            fileCommand.Parameters.Add("$kind", SqliteType.Text);
            fileCommand.Parameters.Add("$proposed", SqliteType.Text);
            fileCommand.Parameters.Add("$path", SqliteType.Text);
            fileCommand.Parameters.Add("$name", SqliteType.Text);
            fileCommand.Parameters.Add("$capture", SqliteType.Text);
            fileCommand.Parameters.Add("$bytes", SqliteType.Integer);
            fileCommand.Parameters.Add("$sha", SqliteType.Text);
            foreach (var asset in job.Assets)
            {
                foreach (var file in asset.Files)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    fileCommand.Parameters["$job"].Value = Id(job.JobId);
                    fileCommand.Parameters["$file"].Value = Id(file.FileId);
                    fileCommand.Parameters["$asset"].Value = Id(asset.AssetId);
                    fileCommand.Parameters["$revision"].Value = file.SourceRevision;
                    fileCommand.Parameters["$kind"].Value = EnumName(file.Kind);
                    fileCommand.Parameters["$proposed"].Value = proposedPaths[file.FileId];
                    fileCommand.Parameters["$path"].Value = acceptedPaths[file.FileId];
                    fileCommand.Parameters["$name"].Value = file.OriginalFilename;
                    fileCommand.Parameters["$capture"].Value = Db(file.CaptureDate is null ? null : Date(file.CaptureDate.Value));
                    fileCommand.Parameters["$bytes"].Value = Db(file.ByteCount);
                    fileCommand.Parameters["$sha"].Value = Db(file.Sha256);
                    await fileCommand.ExecuteNonQueryAsync(cancellationToken);
                }
            }

            transaction.Commit();
            return true;
        }, cancellationToken);

    public Task<IReadOnlyList<LedgerFile>> GetJobFilesAsync(Guid jobId, CancellationToken cancellationToken = default) =>
        WithLockAsync(async connection =>
        {
            var command = connection.CreateCommand();
            command.CommandText = FileColumns + " WHERE job_id=$job ORDER BY rowid";
            command.Parameters.AddWithValue("$job", Id(jobId));
            var results = new List<LedgerFile>();
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken))
            {
                results.Add(ReadFile(reader));
            }

            return (IReadOnlyList<LedgerFile>)results;
        }, cancellationToken);

    public Task<LedgerFile?> GetFileAsync(Guid jobId, Guid fileId, CancellationToken cancellationToken = default) =>
        WithLockAsync(async connection =>
        {
            var command = connection.CreateCommand();
            command.CommandText = FileColumns + " WHERE job_id=$job AND file_id=$file";
            command.Parameters.AddWithValue("$job", Id(jobId));
            command.Parameters.AddWithValue("$file", Id(fileId));
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            return await reader.ReadAsync(cancellationToken) ? ReadFile(reader) : null;
        }, cancellationToken);

    public Task<LedgerFile?> FindPriorCommittedAsync(
        Guid fileId,
        string sourceRevision,
        CancellationToken cancellationToken = default) =>
        WithLockAsync(async connection =>
        {
            var command = connection.CreateCommand();
            command.CommandText = FileColumns + """
                 WHERE file_id=$file AND source_revision=$revision AND state IN ('committed','skipped')
                 ORDER BY committed_at DESC LIMIT 1
                """;
            command.Parameters.AddWithValue("$file", Id(fileId));
            command.Parameters.AddWithValue("$revision", sourceRevision);
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            return await reader.ReadAsync(cancellationToken) ? ReadFile(reader) : null;
        }, cancellationToken);

    public Task<IReadOnlyDictionary<(Guid FileId, string SourceRevision), LedgerFile>> FindPriorCommittedAsync(
        IReadOnlyCollection<(Guid FileId, string SourceRevision)> requested,
        CancellationToken cancellationToken = default) =>
        WithLockAsync(async connection =>
        {
            const int batchSize = 200;
            var keys = requested.Distinct().ToArray();
            var results = new Dictionary<(Guid FileId, string SourceRevision), LedgerFile>();
            for (var offset = 0; offset < keys.Length; offset += batchSize)
            {
                var count = Math.Min(batchSize, keys.Length - offset);
                var predicates = new string[count];
                var command = connection.CreateCommand();
                for (var index = 0; index < count; index++)
                {
                    var fileParameter = "$file" + index;
                    var revisionParameter = "$revision" + index;
                    predicates[index] = $"(file_id={fileParameter} AND source_revision={revisionParameter})";
                    var key = keys[offset + index];
                    command.Parameters.AddWithValue(fileParameter, Id(key.FileId));
                    command.Parameters.AddWithValue(revisionParameter, key.SourceRevision);
                }

                command.CommandText = FileColumns +
                    " WHERE state IN ('committed','skipped') AND (" +
                    string.Join(" OR ", predicates) +
                    ") ORDER BY file_id,source_revision,committed_at DESC";
                await using var reader = await command.ExecuteReaderAsync(cancellationToken);
                while (await reader.ReadAsync(cancellationToken))
                {
                    var file = ReadFile(reader);
                    var key = (file.FileId, file.SourceRevision);
                    results.TryAdd(key, file);
                }
            }

            return (IReadOnlyDictionary<(Guid FileId, string SourceRevision), LedgerFile>)results;
        }, cancellationToken);

    public Task MarkSkippedAsync(
        Guid jobId,
        Guid fileId,
        LedgerFile prior,
        long observedWriteTicks,
        CancellationToken cancellationToken = default) => MarkSkippedAsync(
            jobId,
            new[] { new LedgerSkip(fileId, prior, observedWriteTicks) },
            cancellationToken);

    public Task MarkSkippedAsync(
        Guid jobId,
        IReadOnlyCollection<LedgerSkip> skips,
        CancellationToken cancellationToken = default) =>
        WithLockAsync(async connection =>
        {
            if (skips.Count == 0)
            {
                return true;
            }

            using var transaction = connection.BeginTransaction();
            var command = connection.CreateCommand();
            command.Transaction = transaction;
            command.CommandText = """
                UPDATE files SET state='skipped', relative_path=$path, committed_sha256=$sha,
                    committed_bytes=$bytes, committed_at=$committed, observed_write_ticks=$ticks
                WHERE job_id=$job AND file_id=$file AND state='pending'
                """;
            command.Parameters.Add("$path", SqliteType.Text);
            command.Parameters.Add("$sha", SqliteType.Text);
            command.Parameters.Add("$bytes", SqliteType.Integer);
            command.Parameters.Add("$committed", SqliteType.Text);
            command.Parameters.Add("$ticks", SqliteType.Integer);
            command.Parameters.Add("$job", SqliteType.Text);
            command.Parameters.Add("$file", SqliteType.Text);

            var updateObserved = connection.CreateCommand();
            updateObserved.Transaction = transaction;
            updateObserved.CommandText = """
                UPDATE files SET observed_write_ticks=$ticks
                WHERE job_id=$job AND file_id=$file
                """;
            updateObserved.Parameters.Add("$ticks", SqliteType.Integer);
            updateObserved.Parameters.Add("$job", SqliteType.Text);
            updateObserved.Parameters.Add("$file", SqliteType.Text);

            var skippedFiles = 0;
            long skippedBytes = 0;
            var verifiedOriginalFiles = 0;
            foreach (var skip in skips)
            {
                cancellationToken.ThrowIfCancellationRequested();
                command.Parameters["$path"].Value = skip.Prior.RelativePath;
                command.Parameters["$sha"].Value = Db(skip.Prior.CommittedSha256);
                command.Parameters["$bytes"].Value = Db(skip.Prior.CommittedBytes);
                command.Parameters["$committed"].Value = Db(skip.Prior.CommittedAt is null ? null : Date(skip.Prior.CommittedAt.Value));
                command.Parameters["$ticks"].Value = skip.ObservedWriteTicks;
                command.Parameters["$job"].Value = Id(jobId);
                command.Parameters["$file"].Value = Id(skip.FileId);
                if (await command.ExecuteNonQueryAsync(cancellationToken) == 1)
                {
                    skippedFiles++;
                    skippedBytes += skip.Prior.CommittedBytes ?? 0;
                    if (skip.Prior.Kind == ExportFileKind.OriginalResource)
                    {
                        verifiedOriginalFiles++;
                    }
                }

                updateObserved.Parameters["$ticks"].Value = skip.ObservedWriteTicks;
                updateObserved.Parameters["$job"].Value = Id(skip.Prior.JobId);
                updateObserved.Parameters["$file"].Value = Id(skip.Prior.FileId);
                await updateObserved.ExecuteNonQueryAsync(cancellationToken);
            }

            if (skippedFiles > 0)
            {
                var updateJob = connection.CreateCommand();
                updateJob.Transaction = transaction;
                updateJob.CommandText = """
                    UPDATE jobs SET skipped_files=skipped_files+$files,
                        bytes_committed=bytes_committed+$bytes,
                        verified_original_files=verified_original_files+$originals,
                        updated_at=$updated
                    WHERE job_id=$job
                    """;
                updateJob.Parameters.AddWithValue("$files", skippedFiles);
                updateJob.Parameters.AddWithValue("$bytes", skippedBytes);
                updateJob.Parameters.AddWithValue("$originals", verifiedOriginalFiles);
                updateJob.Parameters.AddWithValue("$updated", Date(DateTimeOffset.UtcNow));
                updateJob.Parameters.AddWithValue("$job", Id(jobId));
                await updateJob.ExecuteNonQueryAsync(cancellationToken);
            }
            transaction.Commit();
            return true;
        }, cancellationToken);

    public Task UpdateObservedFileAsync(
        Guid jobId,
        Guid fileId,
        long observedWriteTicks,
        CancellationToken cancellationToken = default) =>
        ExecuteUpdateAsync(
            "UPDATE files SET observed_write_ticks=$ticks WHERE job_id=$job AND file_id=$file",
            jobId,
            fileId,
            ("$ticks", observedWriteTicks),
            cancellationToken);

    public Task<IReadOnlyList<LedgerChunk>> GetChunksAsync(
        Guid jobId,
        Guid fileId,
        CancellationToken cancellationToken = default) =>
        WithLockAsync(async connection =>
        {
            var command = connection.CreateCommand();
            command.CommandText = """
                SELECT chunk_index,byte_offset,byte_length,total_bytes,sha256,received_at FROM chunks
                WHERE job_id=$job AND file_id=$file ORDER BY chunk_index
                """;
            command.Parameters.AddWithValue("$job", Id(jobId));
            command.Parameters.AddWithValue("$file", Id(fileId));
            var results = new List<LedgerChunk>();
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken))
            {
                results.Add(new LedgerChunk(
                    reader.GetInt32(0),
                    reader.GetInt64(1),
                    reader.GetInt64(2),
                    reader.GetInt64(3),
                    reader.GetString(4),
                    ParseDate(reader.GetString(5))));
            }

            return (IReadOnlyList<LedgerChunk>)results;
        }, cancellationToken);

    /// <summary>
    /// Returns the durable upload cursor and, when this is a retry, only the
    /// requested receipt. Both lookups are backed by primary-key probes; upload
    /// cost therefore does not grow with the number of prior chunks.
    /// </summary>
    public Task<LedgerChunkState?> GetChunkStateAsync(
        Guid jobId,
        Guid fileId,
        int requestedChunkIndex,
        CancellationToken cancellationToken = default) =>
        WithLockAsync(async connection =>
        {
            var command = connection.CreateCommand();
            command.CommandText = """
                SELECT f.next_chunk_index,f.upload_total_bytes,f.bytes_transferred,
                    c.chunk_index,c.byte_offset,c.byte_length,c.total_bytes,c.sha256,c.received_at
                FROM files AS f
                LEFT JOIN chunks AS c
                    ON c.job_id=f.job_id AND c.file_id=f.file_id AND c.chunk_index=$chunk
                WHERE f.job_id=$job AND f.file_id=$file
                """;
            command.Parameters.AddWithValue("$job", Id(jobId));
            command.Parameters.AddWithValue("$file", Id(fileId));
            command.Parameters.AddWithValue("$chunk", requestedChunkIndex);
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            if (!await reader.ReadAsync(cancellationToken))
            {
                return null;
            }

            LedgerChunk? requested = reader.IsDBNull(3)
                ? null
                : new LedgerChunk(
                    reader.GetInt32(3),
                    reader.GetInt64(4),
                    reader.GetInt64(5),
                    reader.GetInt64(6),
                    reader.GetString(7),
                    ParseDate(reader.GetString(8)));
            return new LedgerChunkState(
                reader.GetInt32(0),
                reader.IsDBNull(1) ? null : reader.GetInt64(1),
                reader.GetInt64(2),
                requested);
        }, cancellationToken);

    public Task<IReadOnlyDictionary<Guid, int>> GetChunkCountsAsync(
        Guid jobId,
        CancellationToken cancellationToken = default) =>
        WithLockAsync(async connection =>
        {
            var command = connection.CreateCommand();
            command.CommandText = """
                SELECT file_id,next_chunk_index FROM files
                WHERE job_id=$job AND next_chunk_index > 0
                """;
            command.Parameters.AddWithValue("$job", Id(jobId));
            var results = new Dictionary<Guid, int>();
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken))
            {
                results[Guid.Parse(reader.GetString(0))] = reader.GetInt32(1);
            }

            return (IReadOnlyDictionary<Guid, int>)results;
        }, cancellationToken);

    public Task RecordChunkAsync(
        Guid jobId,
        Guid fileId,
        LedgerChunk chunk,
        CancellationToken cancellationToken = default) =>
        WithLockAsync(async connection =>
        {
            using var transaction = connection.BeginTransaction();
            var insert = connection.CreateCommand();
            insert.Transaction = transaction;
            insert.CommandText = """
                INSERT INTO chunks(job_id,file_id,chunk_index,byte_offset,byte_length,total_bytes,sha256,received_at)
                VALUES($job,$file,$index,$offset,$length,$total,$sha,$received)
                """;
            insert.Parameters.AddWithValue("$job", Id(jobId));
            insert.Parameters.AddWithValue("$file", Id(fileId));
            insert.Parameters.AddWithValue("$index", chunk.ChunkIndex);
            insert.Parameters.AddWithValue("$offset", chunk.Offset);
            insert.Parameters.AddWithValue("$length", chunk.Length);
            insert.Parameters.AddWithValue("$total", chunk.TotalBytes);
            insert.Parameters.AddWithValue("$sha", chunk.Sha256);
            insert.Parameters.AddWithValue("$received", Date(chunk.ReceivedAt));
            await insert.ExecuteNonQueryAsync(cancellationToken);

            var update = connection.CreateCommand();
            update.Transaction = transaction;
            update.CommandText = """
                UPDATE files SET bytes_transferred=bytes_transferred+$length,
                    next_chunk_index=next_chunk_index+1,
                    upload_total_bytes=COALESCE(upload_total_bytes,$total)
                WHERE job_id=$job AND file_id=$file AND state='pending'
                    AND next_chunk_index=$index
                    AND (upload_total_bytes IS NULL OR upload_total_bytes=$total)
                """;
            update.Parameters.AddWithValue("$length", chunk.Length);
            update.Parameters.AddWithValue("$total", chunk.TotalBytes);
            update.Parameters.AddWithValue("$index", chunk.ChunkIndex);
            update.Parameters.AddWithValue("$job", Id(jobId));
            update.Parameters.AddWithValue("$file", Id(fileId));
            if (await update.ExecuteNonQueryAsync(cancellationToken) != 1)
            {
                throw new InvalidOperationException("The chunk no longer matches the durable upload cursor.");
            }

            var updateJob = connection.CreateCommand();
            updateJob.Transaction = transaction;
            updateJob.CommandText = """
                UPDATE jobs SET bytes_transferred=bytes_transferred+$length,updated_at=$updated
                WHERE job_id=$job
                """;
            updateJob.Parameters.AddWithValue("$length", chunk.Length);
            updateJob.Parameters.AddWithValue("$updated", Date(chunk.ReceivedAt));
            updateJob.Parameters.AddWithValue("$job", Id(jobId));
            await updateJob.ExecuteNonQueryAsync(cancellationToken);
            transaction.Commit();
            return true;
        }, cancellationToken);

    public Task ClearChunksAsync(
        Guid jobId,
        Guid fileId,
        CancellationToken cancellationToken = default) =>
        WithLockAsync(async connection =>
        {
            using var transaction = connection.BeginTransaction();
            var updateJob = connection.CreateCommand();
            updateJob.Transaction = transaction;
            updateJob.CommandText = """
                UPDATE jobs SET
                    bytes_transferred=MAX(0,bytes_transferred-COALESCE((
                        SELECT bytes_transferred FROM files
                        WHERE job_id=$job AND file_id=$file
                    ),0)),
                    updated_at=$updated
                WHERE job_id=$job
                """;
            updateJob.Parameters.AddWithValue("$job", Id(jobId));
            updateJob.Parameters.AddWithValue("$file", Id(fileId));
            updateJob.Parameters.AddWithValue("$updated", Date(DateTimeOffset.UtcNow));
            await updateJob.ExecuteNonQueryAsync(cancellationToken);

            var delete = connection.CreateCommand();
            delete.Transaction = transaction;
            delete.CommandText = "DELETE FROM chunks WHERE job_id=$job AND file_id=$file";
            delete.Parameters.AddWithValue("$job", Id(jobId));
            delete.Parameters.AddWithValue("$file", Id(fileId));
            await delete.ExecuteNonQueryAsync(cancellationToken);
            var update = connection.CreateCommand();
            update.Transaction = transaction;
            update.CommandText = """
                UPDATE files SET bytes_transferred=0,next_chunk_index=0,upload_total_bytes=NULL
                WHERE job_id=$job AND file_id=$file
                """;
            update.Parameters.AddWithValue("$job", Id(jobId));
            update.Parameters.AddWithValue("$file", Id(fileId));
            await update.ExecuteNonQueryAsync(cancellationToken);
            transaction.Commit();
            return true;
        }, cancellationToken);

    public Task ClearUncommittedChunksAsync(
        Guid jobId,
        CancellationToken cancellationToken = default) =>
        WithLockAsync(async connection =>
        {
            using var transaction = connection.BeginTransaction();
            var updateJob = connection.CreateCommand();
            updateJob.Transaction = transaction;
            updateJob.CommandText = """
                UPDATE jobs SET
                    bytes_transferred=MAX(0,bytes_transferred-COALESCE((
                        SELECT SUM(bytes_transferred) FROM files
                        WHERE job_id=$job AND state IN ('pending','failed')
                    ),0)),
                    updated_at=$updated
                WHERE job_id=$job
                """;
            updateJob.Parameters.AddWithValue("$job", Id(jobId));
            updateJob.Parameters.AddWithValue("$updated", Date(DateTimeOffset.UtcNow));
            await updateJob.ExecuteNonQueryAsync(cancellationToken);

            var delete = connection.CreateCommand();
            delete.Transaction = transaction;
            delete.CommandText = """
                DELETE FROM chunks
                WHERE job_id=$job AND file_id IN (
                    SELECT file_id FROM files
                    WHERE job_id=$job AND state IN ('pending','failed')
                )
                """;
            delete.Parameters.AddWithValue("$job", Id(jobId));
            var deletedChunks = await delete.ExecuteNonQueryAsync(cancellationToken);

            var update = connection.CreateCommand();
            update.Transaction = transaction;
            update.CommandText = """
                UPDATE files SET bytes_transferred=0,next_chunk_index=0,upload_total_bytes=NULL
                WHERE job_id=$job AND state IN ('pending','failed')
                """;
            update.Parameters.AddWithValue("$job", Id(jobId));
            var resetFiles = await update.ExecuteNonQueryAsync(cancellationToken);
            _ = deletedChunks;
            _ = resetFiles;
            transaction.Commit();
            return true;
        }, cancellationToken);

    public Task MarkCommittedAsync(
        Guid jobId,
        Guid fileId,
        string sha256,
        long byteCount,
        DateTimeOffset committedAt,
        long observedWriteTicks,
        CancellationToken cancellationToken = default) =>
        WithLockAsync(async connection =>
        {
            using var transaction = connection.BeginTransaction();
            var command = connection.CreateCommand();
            command.Transaction = transaction;
            command.CommandText = """
                UPDATE files SET state='committed', committed_sha256=$sha, committed_bytes=$bytes,
                    committed_at=$committed, observed_write_ticks=$ticks
                WHERE job_id=$job AND file_id=$file AND state='pending'
                """;
            command.Parameters.AddWithValue("$sha", sha256);
            command.Parameters.AddWithValue("$bytes", byteCount);
            command.Parameters.AddWithValue("$committed", Date(committedAt));
            command.Parameters.AddWithValue("$ticks", observedWriteTicks);
            command.Parameters.AddWithValue("$job", Id(jobId));
            command.Parameters.AddWithValue("$file", Id(fileId));
            if (await command.ExecuteNonQueryAsync(cancellationToken) != 1)
            {
                throw new InvalidOperationException("The pending file could not be committed in the ledger.");
            }

            var clearFailures = connection.CreateCommand();
            clearFailures.Transaction = transaction;
            clearFailures.CommandText = "DELETE FROM failures WHERE job_id=$job AND file_id=$file";
            clearFailures.Parameters.AddWithValue("$job", Id(jobId));
            clearFailures.Parameters.AddWithValue("$file", Id(fileId));
            var clearedFailures = await clearFailures.ExecuteNonQueryAsync(cancellationToken);

            var updateJob = connection.CreateCommand();
            updateJob.Transaction = transaction;
            updateJob.CommandText = """
                UPDATE jobs SET committed_files=committed_files+1,
                    failed_files=MAX(0,failed_files-$clearedFailures),
                    bytes_committed=bytes_committed+$bytes,
                    verified_original_files=verified_original_files+CASE WHEN (
                        SELECT kind FROM files WHERE job_id=$job AND file_id=$file
                    )='originalResource' THEN 1 ELSE 0 END,
                    updated_at=$committed
                WHERE job_id=$job
                """;
            updateJob.Parameters.AddWithValue("$clearedFailures", clearedFailures);
            updateJob.Parameters.AddWithValue("$bytes", byteCount);
            updateJob.Parameters.AddWithValue("$committed", Date(committedAt));
            updateJob.Parameters.AddWithValue("$job", Id(jobId));
            updateJob.Parameters.AddWithValue("$file", Id(fileId));
            await updateJob.ExecuteNonQueryAsync(cancellationToken);
            transaction.Commit();

            return true;
        }, cancellationToken);

    public Task AddFailureAsync(
        Guid jobId,
        Guid fileId,
        string code,
        string message,
        bool retryable,
        CancellationToken cancellationToken = default) =>
        WithLockAsync(async connection =>
        {
            using var transaction = connection.BeginTransaction();
            var command = connection.CreateCommand();
            command.Transaction = transaction;
            command.CommandText = """
                INSERT INTO failures(job_id,file_id,code,message,retryable,occurred_at)
                VALUES($job,$file,$code,$message,$retryable,$at)
                """;
            command.Parameters.AddWithValue("$job", Id(jobId));
            command.Parameters.AddWithValue("$file", Id(fileId));
            command.Parameters.AddWithValue("$code", code);
            command.Parameters.AddWithValue("$message", message);
            command.Parameters.AddWithValue("$retryable", retryable ? 1 : 0);
            command.Parameters.AddWithValue("$at", Date(DateTimeOffset.UtcNow));
            await command.ExecuteNonQueryAsync(cancellationToken);

            var updateJob = connection.CreateCommand();
            updateJob.Transaction = transaction;
            updateJob.CommandText = """
                UPDATE jobs SET failed_files=failed_files+1,updated_at=$updated
                WHERE job_id=$job
                """;
            updateJob.Parameters.AddWithValue("$updated", Date(DateTimeOffset.UtcNow));
            updateJob.Parameters.AddWithValue("$job", Id(jobId));
            await updateJob.ExecuteNonQueryAsync(cancellationToken);
            transaction.Commit();
            return true;
        }, cancellationToken);

    public Task<IReadOnlyList<CompletionFailure>> GetFailuresAsync(Guid jobId, CancellationToken cancellationToken = default) =>
        WithLockAsync(async connection =>
        {
            var command = connection.CreateCommand();
            command.CommandText = """
                SELECT file_id,code,message,retryable FROM failures
                WHERE job_id=$job ORDER BY occurred_at
                """;
            command.Parameters.AddWithValue("$job", Id(jobId));
            var failures = new List<CompletionFailure>();
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken))
            {
                failures.Add(new CompletionFailure(Guid.Parse(reader.GetString(0)), reader.GetString(1), reader.GetString(2), reader.GetBoolean(3)));
            }

            return (IReadOnlyList<CompletionFailure>)failures;
        }, cancellationToken);

    public Task<LedgerStats> GetStatsAsync(Guid jobId, CancellationToken cancellationToken = default) =>
        WithLockAsync(async connection =>
        {
            var command = connection.CreateCommand();
            command.CommandText = """
                SELECT total_files,committed_files,skipped_files,failed_files,
                    bytes_transferred,bytes_committed,verified_original_files
                FROM jobs WHERE job_id=$job
                """;
            command.Parameters.AddWithValue("$job", Id(jobId));
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            if (!await reader.ReadAsync(cancellationToken))
            {
                throw new ReceiverApiException(404, ErrorCodes.JobNotFound, "The export job does not exist.");
            }

            return new LedgerStats(
                reader.GetInt32(0),
                reader.GetInt32(1),
                reader.GetInt32(2),
                reader.GetInt32(3),
                reader.GetInt64(4),
                reader.GetInt64(5),
                reader.GetInt32(6));
        }, cancellationToken);

    public Task MarkCompletedAsync(Guid jobId, DateTimeOffset completedAt, CancellationToken cancellationToken = default) =>
        SetJobStateAsync(jobId, "completed", completedAt, null, cancellationToken);

    public Task FinalizeJobAsync(
        Guid jobId,
        DateTimeOffset completedAt,
        string state,
        string completionRequestJson,
        string reportJson,
        IReadOnlyList<CompletionFailure> failures,
        CancellationToken cancellationToken = default) =>
        WithLockAsync(async connection =>
        {
            using var transaction = connection.BeginTransaction();
            var mark = connection.CreateCommand();
            mark.Transaction = transaction;
            mark.CommandText = """
                UPDATE files SET state='failed' WHERE job_id=$job AND file_id=$file AND state='pending'
                """;
            mark.Parameters.Add("$job", SqliteType.Text);
            mark.Parameters.Add("$file", SqliteType.Text);

            var insert = connection.CreateCommand();
            insert.Transaction = transaction;
            insert.CommandText = """
                INSERT INTO failures(job_id,file_id,code,message,retryable,occurred_at)
                VALUES($job,$file,$code,$message,$retryable,$at)
                """;
            insert.Parameters.Add("$job", SqliteType.Text);
            insert.Parameters.Add("$file", SqliteType.Text);
            insert.Parameters.Add("$code", SqliteType.Text);
            insert.Parameters.Add("$message", SqliteType.Text);
            insert.Parameters.Add("$retryable", SqliteType.Integer);
            insert.Parameters.Add("$at", SqliteType.Text);

            foreach (var failure in failures)
            {
                cancellationToken.ThrowIfCancellationRequested();
                mark.Parameters["$job"].Value = Id(jobId);
                mark.Parameters["$file"].Value = Id(failure.FileId);
                if (await mark.ExecuteNonQueryAsync(cancellationToken) != 1)
                {
                    throw new ReceiverApiException(409, ErrorCodes.FileConflict, "A reported failed file is not pending.");
                }

                insert.Parameters["$job"].Value = Id(jobId);
                insert.Parameters["$file"].Value = Id(failure.FileId);
                insert.Parameters["$code"].Value = failure.Code;
                insert.Parameters["$message"].Value = failure.Message;
                insert.Parameters["$retryable"].Value = failure.Retryable ? 1 : 0;
                insert.Parameters["$at"].Value = Date(completedAt);
                await insert.ExecuteNonQueryAsync(cancellationToken);
            }

            var pending = connection.CreateCommand();
            pending.Transaction = transaction;
            pending.CommandText = "SELECT COUNT(*) FROM files WHERE job_id=$job AND state='pending'";
            pending.Parameters.AddWithValue("$job", Id(jobId));
            if (Convert.ToInt32(await pending.ExecuteScalarAsync(cancellationToken)) != 0)
            {
                throw new ReceiverApiException(409, ErrorCodes.JobConflict, "Every pending file must be reported as a failure before completing with failures.");
            }

            var update = connection.CreateCommand();
            update.Transaction = transaction;
            update.CommandText = """
                UPDATE jobs SET state=$state,completed_at=$completed,updated_at=$completed,
                    completion_request_json=$request,report_json=$report,
                    failed_files=failed_files+$failedFiles
                WHERE job_id=$job AND state IN ('transferring','paused','planned')
                """;
            update.Parameters.AddWithValue("$state", state);
            update.Parameters.AddWithValue("$completed", Date(completedAt));
            update.Parameters.AddWithValue("$request", completionRequestJson);
            update.Parameters.AddWithValue("$report", reportJson);
            update.Parameters.AddWithValue("$failedFiles", failures.Count);
            update.Parameters.AddWithValue("$job", Id(jobId));
            if (await update.ExecuteNonQueryAsync(cancellationToken) != 1)
            {
                throw new ReceiverApiException(409, ErrorCodes.JobConflict, "The job is already terminal.");
            }

            transaction.Commit();
            return true;
        }, cancellationToken);

    public Task MarkAbandonedAsync(
        Guid jobId,
        string? reason,
        DateTimeOffset abandonedAt,
        int removedPartialFiles,
        CancellationToken cancellationToken = default) =>
        WithLockAsync(async connection =>
        {
            var command = connection.CreateCommand();
            command.CommandText = """
                UPDATE jobs SET state='abandoned',completed_at=$completed,
                    updated_at=$completed,abandon_reason=$reason,
                    abandon_removed_partial_files=$removed
                WHERE job_id=$job AND state IN ('planned','transferring','paused')
                """;
            command.Parameters.AddWithValue("$completed", Date(abandonedAt));
            command.Parameters.AddWithValue("$reason", Db(reason));
            command.Parameters.AddWithValue("$removed", removedPartialFiles);
            command.Parameters.AddWithValue("$job", Id(jobId));
            if (await command.ExecuteNonQueryAsync(cancellationToken) != 1)
            {
                throw new ReceiverApiException(409, ErrorCodes.JobConflict, "Only an active job can be abandoned.");
            }

            return true;
        }, cancellationToken);

    public Task<IReadOnlyList<Guid>> GetTerminalJobIdsAsync(CancellationToken cancellationToken = default) =>
        WithLockAsync(async connection =>
        {
            var command = connection.CreateCommand();
            command.CommandText = """
                SELECT job_id FROM jobs
                WHERE state IN ('completed','completedWithFailures','abandoned')
                """;
            var jobIds = new List<Guid>();
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken))
            {
                jobIds.Add(Guid.Parse(reader.GetString(0)));
            }

            return (IReadOnlyList<Guid>)jobIds;
        }, cancellationToken);

    public Task<IReadOnlyList<string>> GetCompletedManifestsAsync(CancellationToken cancellationToken = default) =>
        WithLockAsync(async connection =>
        {
            var command = connection.CreateCommand();
            command.CommandText = """
                SELECT manifest_json FROM jobs
                WHERE state IN ('completed','completedWithFailures') ORDER BY created_at
                """;
            var manifests = new List<string>();
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken))
            {
                manifests.Add(reader.GetString(0));
            }

            return (IReadOnlyList<string>)manifests;
        }, cancellationToken);

    public Task<IReadOnlyList<Guid>> GetCompletedJobIdsAsync(CancellationToken cancellationToken = default) =>
        WithLockAsync(async connection =>
        {
            var command = connection.CreateCommand();
            command.CommandText = """
                SELECT job_id FROM jobs
                WHERE state IN ('completed','completedWithFailures') ORDER BY created_at
                """;
            var jobIds = new List<Guid>();
            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken))
            {
                jobIds.Add(Guid.Parse(reader.GetString(0)));
            }

            return (IReadOnlyList<Guid>)jobIds;
        }, cancellationToken);

    /// <summary>
    /// Streams all completed jobs and their files from one ordered SQLite
    /// snapshot. The manifest appears once per job and files are delivered in
    /// bounded batches, avoiding both N+1 ledger reads and whole-history memory.
    /// The consumer must not call back into this ledger while the snapshot is
    /// being read.
    /// </summary>
    public Task StreamCompletedJobsAsync(
        Func<LedgerCompletedJobBatch, CancellationToken, Task> consume,
        int fileBatchSize = 256,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(consume);
        if (fileBatchSize <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(fileBatchSize));
        }

        return WithLockAsync(async connection =>
        {
            var command = connection.CreateCommand();
            command.CommandText = """
                SELECT j.created_at AS sort_created,j.job_id AS sort_job,0 AS row_kind,
                    j.job_id,j.created_at,j.updated_at,j.state,j.manifest_json,j.completed_at,
                    j.completion_request_json,j.report_json,j.abandon_removed_partial_files,
                    NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,
                    0 AS file_order
                FROM jobs AS j
                WHERE j.state IN ('completed','completedWithFailures')

                UNION ALL

                SELECT j.created_at,j.job_id,1,
                    NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,
                    f.job_id,f.file_id,f.asset_id,f.source_revision,f.kind,f.proposed_path,
                    f.relative_path,f.original_filename,f.capture_date,f.expected_bytes,
                    f.expected_sha256,f.state,f.committed_sha256,f.committed_bytes,
                    f.committed_at,f.observed_write_ticks,f.bytes_transferred,
                    f.rowid
                FROM jobs AS j
                INNER JOIN files AS f ON f.job_id=j.job_id
                WHERE j.state IN ('completed','completedWithFailures')
                ORDER BY sort_created,sort_job,row_kind,file_order
                """;

            LedgerJob? currentJob = null;
            var files = new List<LedgerFile>(fileBatchSize);
            var isFirst = true;

            async Task EmitAsync(bool isLast)
            {
                if (currentJob is null)
                {
                    return;
                }

                var batch = new LedgerCompletedJobBatch(currentJob, files, isFirst, isLast);
                await consume(batch, cancellationToken);
                files = new List<LedgerFile>(fileBatchSize);
                isFirst = false;
            }

            await using var reader = await command.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken))
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (reader.GetInt32(2) == 0)
                {
                    await EmitAsync(isLast: true);
                    currentJob = ReadJob(reader, 3);
                    files = new List<LedgerFile>(fileBatchSize);
                    isFirst = true;
                    continue;
                }

                if (currentJob is null)
                {
                    throw new InvalidDataException("A completed ledger file appeared before its job snapshot.");
                }

                if (files.Count == fileBatchSize)
                {
                    await EmitAsync(isLast: false);
                }

                var file = ReadFile(reader, 12);
                if (file.JobId != currentJob.JobId)
                {
                    throw new InvalidDataException("A completed ledger file was grouped under the wrong job.");
                }
                files.Add(file);
            }

            await EmitAsync(isLast: true);
            return true;
        }, cancellationToken);
    }

    public Task PauseActiveJobsAsync(CancellationToken cancellationToken = default) =>
        WithLockAsync(async connection =>
        {
            var command = connection.CreateCommand();
            command.CommandText = """
                UPDATE jobs SET state='paused',updated_at=$updated
                WHERE state IN ('planned','transferring')
                """;
            command.Parameters.AddWithValue("$updated", Date(DateTimeOffset.UtcNow));
            await command.ExecuteNonQueryAsync(cancellationToken);
            return true;
        }, cancellationToken);

    public Task ResumeJobAsync(Guid jobId, CancellationToken cancellationToken = default) =>
        WithLockAsync(async connection =>
        {
            var command = connection.CreateCommand();
            command.CommandText = """
                UPDATE jobs SET state='transferring',updated_at=$updated
                WHERE job_id=$job AND state='paused'
                """;
            command.Parameters.AddWithValue("$updated", Date(DateTimeOffset.UtcNow));
            command.Parameters.AddWithValue("$job", Id(jobId));
            await command.ExecuteNonQueryAsync(cancellationToken);
            return true;
        }, cancellationToken);

    public ValueTask DisposeAsync()
    {
        using var connection = new SqliteConnection(connectionString);
        SqliteConnection.ClearPool(connection);
        gate.Dispose();
        return ValueTask.CompletedTask;
    }

    private Task SetJobStateAsync(
        Guid jobId,
        string state,
        DateTimeOffset? completedAt,
        string? reason,
        CancellationToken cancellationToken) =>
        WithLockAsync(async connection =>
        {
            var command = connection.CreateCommand();
            command.CommandText = """
                UPDATE jobs SET state=$state,completed_at=$completed,updated_at=$updated,abandon_reason=$reason
                WHERE job_id=$job
                """;
            command.Parameters.AddWithValue("$state", state);
            command.Parameters.AddWithValue("$completed", Db(completedAt is null ? null : Date(completedAt.Value)));
            command.Parameters.AddWithValue("$updated", Date(completedAt ?? DateTimeOffset.UtcNow));
            command.Parameters.AddWithValue("$reason", Db(reason));
            command.Parameters.AddWithValue("$job", Id(jobId));
            await command.ExecuteNonQueryAsync(cancellationToken);
            return true;
        }, cancellationToken);

    private Task ExecuteUpdateAsync(
        string sql,
        Guid jobId,
        Guid fileId,
        (string Name, object Value) extra,
        CancellationToken cancellationToken) =>
        WithLockAsync(async connection =>
        {
            var command = connection.CreateCommand();
            command.CommandText = sql;
            command.Parameters.AddWithValue("$job", Id(jobId));
            command.Parameters.AddWithValue("$file", Id(fileId));
            command.Parameters.AddWithValue(extra.Name, extra.Value);
            await command.ExecuteNonQueryAsync(cancellationToken);
            return true;
        }, cancellationToken);

    private async Task<T> WithLockAsync<T>(
        Func<SqliteConnection, Task<T>> action,
        CancellationToken cancellationToken)
    {
        await gate.WaitAsync(cancellationToken);
        try
        {
            await using var connection = new SqliteConnection(connectionString);
            await connection.OpenAsync(cancellationToken);
            await ExecuteAsync(connection, "PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;", cancellationToken);
            return await action(connection);
        }
        finally
        {
            gate.Release();
        }
    }

    private static async Task ExecuteAsync(SqliteConnection connection, string sql, CancellationToken cancellationToken)
    {
        var command = connection.CreateCommand();
        command.CommandText = sql;
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    private static async Task<object?> ScalarAsync(SqliteConnection connection, string sql, CancellationToken cancellationToken)
    {
        var command = connection.CreateCommand();
        command.CommandText = sql;
        return await command.ExecuteScalarAsync(cancellationToken);
    }

    private static async Task<int> CountFailuresAsync(SqliteConnection connection, Guid jobId, CancellationToken cancellationToken)
    {
        var command = connection.CreateCommand();
        command.CommandText = "SELECT COUNT(*) FROM failures WHERE job_id=$job";
        command.Parameters.AddWithValue("$job", Id(jobId));
        return Convert.ToInt32(await command.ExecuteScalarAsync(cancellationToken));
    }

    private static async Task TouchJobAsync(
        SqliteConnection connection,
        SqliteTransaction? transaction,
        Guid jobId,
        DateTimeOffset updatedAt,
        CancellationToken cancellationToken)
    {
        var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "UPDATE jobs SET updated_at=$updated WHERE job_id=$job";
        command.Parameters.AddWithValue("$updated", Date(updatedAt));
        command.Parameters.AddWithValue("$job", Id(jobId));
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    private static LedgerJob ReadJob(SqliteDataReader reader, int offset = 0) => new(
        Guid.Parse(reader.GetString(offset)),
        ParseDate(reader.GetString(offset + 1)),
        ParseDate(reader.GetString(offset + 2)),
        Enum.Parse<JobState>(reader.GetString(offset + 3), true),
        reader.GetString(offset + 4),
        reader.IsDBNull(offset + 5) ? null : ParseDate(reader.GetString(offset + 5)),
        reader.IsDBNull(offset + 6) ? null : reader.GetString(offset + 6),
        reader.IsDBNull(offset + 7) ? null : reader.GetString(offset + 7),
        reader.IsDBNull(offset + 8) ? null : reader.GetInt32(offset + 8));

    private static LedgerFile ReadFile(SqliteDataReader reader, int offset = 0) => new(
        Guid.Parse(reader.GetString(offset)),
        Guid.Parse(reader.GetString(offset + 1)),
        Guid.Parse(reader.GetString(offset + 2)),
        reader.GetString(offset + 3),
        Enum.Parse<ExportFileKind>(reader.GetString(offset + 4), true),
        reader.GetString(offset + 5),
        reader.GetString(offset + 6),
        reader.GetString(offset + 7),
        reader.IsDBNull(offset + 8) ? null : ParseDate(reader.GetString(offset + 8)),
        reader.IsDBNull(offset + 9) ? null : reader.GetInt64(offset + 9),
        reader.IsDBNull(offset + 10) ? null : reader.GetString(offset + 10),
        reader.GetString(offset + 11),
        reader.IsDBNull(offset + 12) ? null : reader.GetString(offset + 12),
        reader.IsDBNull(offset + 13) ? null : reader.GetInt64(offset + 13),
        reader.IsDBNull(offset + 14) ? null : ParseDate(reader.GetString(offset + 14)),
        reader.IsDBNull(offset + 15) ? null : reader.GetInt64(offset + 15),
        reader.GetInt64(offset + 16));

    private const string FileColumns = """
        SELECT job_id,file_id,asset_id,source_revision,kind,proposed_path,relative_path,original_filename,
            capture_date,expected_bytes,expected_sha256,state,committed_sha256,committed_bytes,
            committed_at,observed_write_ticks,bytes_transferred FROM files
        """;

    private static string Id(Guid value) => value.ToString("D");
    private static string Date(DateTimeOffset value) => value.ToUniversalTime().ToString("O");
    private static DateTimeOffset ParseDate(string value) => DateTimeOffset.Parse(value, null, System.Globalization.DateTimeStyles.RoundtripKind);
    private static string EnumName<T>(T value) where T : struct, Enum => char.ToLowerInvariant(value.ToString()[0]) + value.ToString()[1..];
    private static object Db(object? value) => value ?? DBNull.Value;
    private static int IntOrZero(SqliteDataReader reader, int ordinal) => reader.IsDBNull(ordinal) ? 0 : reader.GetInt32(ordinal);
    private static long LongOrZero(SqliteDataReader reader, int ordinal) => reader.IsDBNull(ordinal) ? 0 : reader.GetInt64(ordinal);
}
