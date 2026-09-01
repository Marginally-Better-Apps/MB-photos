using System.Text;
using System.Text.Json;
using MBPhotos.Receiver.Models;
using MBPhotos.Receiver.Storage;
using Microsoft.Data.Sqlite;

namespace MBPhotos.Receiver.Transfer;

public sealed class ManifestWriter
{
    private const string BuildPrefix = "manifest-build-";

    private readonly DestinationContext destination;
    private readonly Ledger ledger;
    private readonly WindowsPathPolicy pathPolicy;
    private readonly JsonSerializerOptions jsonOptions;
    private readonly SemaphoreSlim writeGate = new(1, 1);

    public ManifestWriter(
        DestinationContext destination,
        Ledger ledger,
        WindowsPathPolicy pathPolicy,
        JsonSerializerOptions jsonOptions)
    {
        this.destination = destination;
        this.ledger = ledger;
        this.pathPolicy = pathPolicy;
        this.jsonOptions = jsonOptions;
        RemoveStaleBuildFiles();
    }

    public async Task WriteAsync(CompletionReport report, CancellationToken cancellationToken = default)
    {
        await writeGate.WaitAsync(cancellationToken);
        try
        {
        var buildPath = Path.Combine(
            destination.ControlPath,
            BuildPrefix + Guid.NewGuid().ToString("N") + ".sqlite");
        pathPolicy.EnsureNoReparsePoints(destination.RootPath, buildPath);
        try
        {
            using var index = new ManifestIndex(buildPath, jsonOptions);
            await ledger.StreamCompletedJobsAsync(
                (batch, token) =>
                {
                    if (batch.IsFirst)
                    {
                        index.BeginJob();
                    }
                    index.AddReceivedFiles(batch.Files, token);
                    if (batch.IsLast)
                    {
                        var job = JsonSerializer.Deserialize<ExportJob>(batch.Job.ManifestJson, jsonOptions)
                            ?? throw new InvalidDataException("A completed job manifest is invalid.");
                        index.Apply(job, token);
                    }
                    return Task.CompletedTask;
                },
                cancellationToken: cancellationToken);

            await SafeWriteAsync(
                pathPolicy.ResolveUnderRoot(destination.RootPath, report.CatalogGeneration.AssetsRelativePath),
                index.WriteAssetsAsync,
                cancellationToken);
            await SafeWriteAsync(
                pathPolicy.ResolveUnderRoot(destination.RootPath, report.CatalogGeneration.AlbumsRelativePath),
                index.WriteAlbumsJsonAsync,
                cancellationToken);
            await SafeWriteAsync(
                pathPolicy.ResolveUnderRoot(destination.RootPath, report.ReportRelativePath),
                (stream, token) => JsonSerializer.SerializeAsync(
                    stream,
                    report,
                    new JsonSerializerOptions(jsonOptions) { WriteIndented = true },
                    token),
                cancellationToken);
            var pointer = new CatalogPointer(
                2,
                report.CatalogGeneration.GenerationId,
                report.CompletedAt,
                report.CatalogGeneration.AssetsRelativePath,
                report.CatalogGeneration.AlbumsRelativePath);
            await SafeWriteAsync(
                pathPolicy.ResolveUnderRoot(
                    destination.RootPath,
                    report.CatalogGeneration.CatalogPointerRelativePath),
                (stream, token) => JsonSerializer.SerializeAsync(
                    stream,
                    pointer,
                    new JsonSerializerOptions(jsonOptions) { WriteIndented = true },
                    token),
                cancellationToken);
        }
        finally
        {
            DeleteBuildFiles(buildPath);
        }
        }
        finally
        {
            writeGate.Release();
        }
    }

    public async Task EnsurePublishedAsync(
        CompletionReport report,
        CancellationToken cancellationToken = default)
    {
        var pointerPath = pathPolicy.ResolveUnderRoot(
            destination.RootPath,
            report.CatalogGeneration.CatalogPointerRelativePath);
        if (File.Exists(pointerPath))
        {
            try
            {
                await using var stream = File.OpenRead(pointerPath);
                var pointer = await JsonSerializer.DeserializeAsync<CatalogPointer>(
                    stream,
                    jsonOptions,
                    cancellationToken);
                if (pointer?.GenerationId == report.CatalogGeneration.GenerationId &&
                    File.Exists(pathPolicy.ResolveUnderRoot(destination.RootPath, pointer.AssetsRelativePath)) &&
                    File.Exists(pathPolicy.ResolveUnderRoot(destination.RootPath, pointer.AlbumsRelativePath)) &&
                    File.Exists(pathPolicy.ResolveUnderRoot(destination.RootPath, report.ReportRelativePath)))
                {
                    return;
                }
            }
            catch (JsonException)
            {
                // Rebuild the immutable generation and pointer from the ledger.
            }
        }
        await WriteAsync(report, cancellationToken);
    }

    public async Task<CompletionReport?> ReadReportAsync(Guid jobId, CancellationToken cancellationToken = default)
    {
        var path = Path.Combine(destination.ReportsPath, jobId.ToString("D") + ".json");
        pathPolicy.EnsureNoReparsePoints(destination.RootPath, path);
        if (!File.Exists(path))
        {
            var job = await ledger.GetJobAsync(jobId, cancellationToken);
            return job?.ReportJson is null
                ? null
                : JsonSerializer.Deserialize<CompletionReport>(job.ReportJson, jsonOptions);
        }

        await using var stream = File.OpenRead(path);
        return await JsonSerializer.DeserializeAsync<CompletionReport>(stream, jsonOptions, cancellationToken);
    }

    private async Task SafeWriteAsync(
        string path,
        Func<Stream, CancellationToken, Task> write,
        CancellationToken cancellationToken)
    {
        pathPolicy.EnsureNoReparsePoints(destination.RootPath, path);
        pathPolicy.EnsureNoReparsePoints(destination.RootPath, Path.GetDirectoryName(path)!);
        await AtomicFile.WriteAsync(path, write, cancellationToken);
        pathPolicy.EnsureNoReparsePoints(destination.RootPath, path);
    }

    private void RemoveStaleBuildFiles()
    {
        if (!Directory.Exists(destination.ControlPath))
        {
            return;
        }

        foreach (var path in Directory.EnumerateFiles(destination.ControlPath, BuildPrefix + "*.sqlite*"))
        {
            pathPolicy.EnsureNoReparsePoints(destination.RootPath, path);
            File.Delete(path);
        }
    }

    private void DeleteBuildFiles(string buildPath)
    {
        foreach (var path in new[] { buildPath, buildPath + "-journal", buildPath + "-wal", buildPath + "-shm" })
        {
            pathPolicy.EnsureNoReparsePoints(destination.RootPath, path);
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
    }

    private static string Csv(string value)
    {
        // Quoting alone does not prevent spreadsheet formula execution. The
        // lossless value remains in albums.jsonl; CSV is deliberately neutralized.
        var safe = value.Length > 0 && value[0] is '=' or '+' or '-' or '@' or '\t' or '\r'
            ? "'" + value
            : value;
        return '"' + safe.Replace("\"", "\"\"", StringComparison.Ordinal) + '"';
    }

    private sealed class ManifestIndex : IDisposable
    {
        private readonly SqliteConnection connection;
        private readonly SqliteCommand upsertAsset;
        private readonly SqliteCommand upsertMembership;
        private readonly SqliteCommand insertReceivedFile;
        private readonly JsonSerializerOptions jsonOptions;
        private long receivedFileCount;

        public ManifestIndex(string path, JsonSerializerOptions jsonOptions)
        {
            this.jsonOptions = jsonOptions;
            connection = new SqliteConnection(new SqliteConnectionStringBuilder
            {
                DataSource = path,
                Mode = SqliteOpenMode.ReadWriteCreate,
                Cache = SqliteCacheMode.Private,
                Pooling = false,
            }.ToString());
            connection.Open();
            using (var command = connection.CreateCommand())
            {
                command.CommandText = """
                    PRAGMA journal_mode=DELETE;
                    PRAGMA synchronous=OFF;
                    CREATE TABLE assets(
                        asset_id TEXT PRIMARY KEY,
                        creation_date TEXT NULL,
                        json TEXT NOT NULL
                    );
                    CREATE TABLE memberships(
                        membership_key TEXT PRIMARY KEY,
                        album_title TEXT NOT NULL,
                        asset_id TEXT NOT NULL,
                        album_id TEXT NOT NULL,
                        source_album_identifier TEXT NOT NULL,
                        parent_album_id TEXT NULL,
                        json TEXT NOT NULL
                    );
                    CREATE TABLE received_files(
                        ordinal INTEGER PRIMARY KEY,
                        file_id TEXT NOT NULL UNIQUE,
                        relative_path TEXT NOT NULL,
                        state TEXT NOT NULL,
                        committed_sha256 TEXT NULL,
                        committed_bytes INTEGER NULL
                    );
                    """;
                command.ExecuteNonQuery();
            }

            upsertAsset = connection.CreateCommand();
            upsertAsset.CommandText = """
                INSERT INTO assets(asset_id,creation_date,json) VALUES($asset,$created,$json)
                ON CONFLICT(asset_id) DO UPDATE SET creation_date=excluded.creation_date,json=excluded.json
                """;
            upsertAsset.Parameters.Add("$asset", SqliteType.Text);
            upsertAsset.Parameters.Add("$created", SqliteType.Text);
            upsertAsset.Parameters.Add("$json", SqliteType.Text);

            upsertMembership = connection.CreateCommand();
            upsertMembership.CommandText = """
                INSERT INTO memberships(
                    membership_key,album_title,asset_id,album_id,source_album_identifier,parent_album_id,json)
                VALUES($key,$title,$asset,$album,$source,$parent,$json)
                ON CONFLICT(membership_key) DO UPDATE SET
                    album_title=excluded.album_title,
                    asset_id=excluded.asset_id,
                    album_id=excluded.album_id,
                    source_album_identifier=excluded.source_album_identifier,
                    parent_album_id=excluded.parent_album_id,
                    json=excluded.json
                """;
            upsertMembership.Parameters.Add("$key", SqliteType.Text);
            upsertMembership.Parameters.Add("$title", SqliteType.Text);
            upsertMembership.Parameters.Add("$asset", SqliteType.Text);
            upsertMembership.Parameters.Add("$album", SqliteType.Text);
            upsertMembership.Parameters.Add("$source", SqliteType.Text);
            upsertMembership.Parameters.Add("$parent", SqliteType.Text);
            upsertMembership.Parameters.Add("$json", SqliteType.Text);

            insertReceivedFile = connection.CreateCommand();
            insertReceivedFile.CommandText = """
                INSERT INTO received_files(
                    ordinal,file_id,relative_path,state,committed_sha256,committed_bytes)
                VALUES($ordinal,$file,$path,$state,$sha,$bytes)
                """;
            insertReceivedFile.Parameters.Add("$ordinal", SqliteType.Integer);
            insertReceivedFile.Parameters.Add("$file", SqliteType.Text);
            insertReceivedFile.Parameters.Add("$path", SqliteType.Text);
            insertReceivedFile.Parameters.Add("$state", SqliteType.Text);
            insertReceivedFile.Parameters.Add("$sha", SqliteType.Text);
            insertReceivedFile.Parameters.Add("$bytes", SqliteType.Integer);
        }

        public void BeginJob()
        {
            using var command = connection.CreateCommand();
            command.CommandText = "DELETE FROM received_files";
            command.ExecuteNonQuery();
            receivedFileCount = 0;
        }

        public void AddReceivedFiles(IReadOnlyList<LedgerFile> files, CancellationToken cancellationToken)
        {
            if (files.Count == 0)
            {
                return;
            }

            using var transaction = connection.BeginTransaction();
            insertReceivedFile.Transaction = transaction;
            try
            {
                foreach (var file in files)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    insertReceivedFile.Parameters["$ordinal"].Value = receivedFileCount;
                    insertReceivedFile.Parameters["$file"].Value = file.FileId.ToString("D");
                    insertReceivedFile.Parameters["$path"].Value = file.RelativePath;
                    insertReceivedFile.Parameters["$state"].Value = file.State;
                    insertReceivedFile.Parameters["$sha"].Value = file.CommittedSha256 is null ? DBNull.Value : file.CommittedSha256;
                    insertReceivedFile.Parameters["$bytes"].Value = file.CommittedBytes is null ? DBNull.Value : file.CommittedBytes.Value;
                    insertReceivedFile.ExecuteNonQuery();
                    receivedFileCount++;
                }
                transaction.Commit();
            }
            finally
            {
                insertReceivedFile.Transaction = null;
            }
        }

        public void Apply(ExportJob job, CancellationToken cancellationToken)
        {
            const int assetBatchSize = 512;
            long receivedOffset = 0;
            for (var assetOffset = 0; assetOffset < job.Assets.Count; assetOffset += assetBatchSize)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var assetCount = Math.Min(assetBatchSize, job.Assets.Count - assetOffset);
                var fileCount = 0;
                for (var index = 0; index < assetCount; index++)
                {
                    fileCount = checked(fileCount + job.Assets[assetOffset + index].Files.Count);
                }

                var receivedFiles = ReadReceivedFiles(receivedOffset, fileCount, cancellationToken);
                var receivedIndex = 0;
                using var transaction = connection.BeginTransaction();
                upsertAsset.Transaction = transaction;
                try
                {
                    for (var index = 0; index < assetCount; index++)
                    {
                        cancellationToken.ThrowIfCancellationRequested();
                        var asset = job.Assets[assetOffset + index];
                        var catalogFiles = new CatalogFile[asset.Files.Count];
                        var receivedForAsset = new ReceivedFile[asset.Files.Count];
                        for (var fileIndex = 0; fileIndex < asset.Files.Count; fileIndex++)
                        {
                            var file = asset.Files[fileIndex];
                            if (receivedIndex >= receivedFiles.Count || receivedFiles[receivedIndex].FileId != file.FileId)
                            {
                                throw new InvalidDataException("A completed job's file order does not match its frozen manifest.");
                            }

                            var received = receivedFiles[receivedIndex++];
                            receivedForAsset[fileIndex] = received;
                            var isAvailable = received.State is "committed" or "skipped";
                            var availability = isAvailable
                                ? Availability.Available
                                : file.Availability == Availability.Available
                                    ? Availability.TransferFailed
                                    : file.Availability;
                            catalogFiles[fileIndex] = new CatalogFile(
                                file.FileId,
                                file.ContentRevision,
                                file.StorageArea,
                                file.Roles,
                                file.Criticality,
                                file.Provenance,
                                file.PhotoKitResourceType,
                                file.PhotoKitResourceTypeRaw,
                                file.OriginalFilename,
                                file.UniformTypeIdentifier,
                                file.ContentType,
                                file.PixelWidth,
                                file.PixelHeight,
                                file.DurationMilliseconds,
                                isAvailable ? received.CommittedBytes : file.ByteCount,
                                isAvailable ? received.CommittedSha256 : null,
                                file.CaptureDate,
                                isAvailable ? received.RelativePath : null,
                                availability);
                        }

                        var masterAvailable = asset.MasterFileId is { } masterId &&
                            receivedForAsset.Any(received =>
                                received.FileId == masterId && received.State is "committed" or "skipped");
                        if (!masterAvailable && AssetExists(asset.AssetId, transaction))
                        {
                            // A failed required current representation never
                            // replaces the last usable catalog generation for an
                            // already-known asset.
                            continue;
                        }
                        var archiveState = asset.Files.Select((file, fileIndex) => (file, receivedForAsset[fileIndex]))
                            .Any(pair => pair.file.Criticality == Criticality.ArchiveRequired &&
                                         pair.Item2.State is not ("committed" or "skipped"))
                            ? ArchiveState.Incomplete
                            : ArchiveState.Complete;
                        var catalogAsset = new CatalogAsset(
                            2,
                            asset.AssetId,
                            asset.SourceLocalIdentifier,
                            asset.SourceRevision,
                            asset.MediaType,
                            asset.MediaSubtypes,
                            asset.CreationDate,
                            asset.ModificationDate,
                            asset.Location,
                            asset.IsEdited,
                            masterAvailable ? asset.MasterFileId : null,
                            asset.LivePhotoRelationships,
                            archiveState,
                            catalogFiles);
                        upsertAsset.Parameters["$asset"].Value = asset.AssetId.ToString("D");
                        upsertAsset.Parameters["$created"].Value = asset.CreationDate is null
                            ? DBNull.Value
                            : asset.CreationDate.Value.ToUniversalTime().ToString("O");
                        upsertAsset.Parameters["$json"].Value = JsonSerializer.Serialize(catalogAsset, jsonOptions);
                        upsertAsset.ExecuteNonQuery();
                    }
                    transaction.Commit();
                }
                finally
                {
                    upsertAsset.Transaction = null;
                }

                if (receivedIndex != receivedFiles.Count)
                {
                    throw new InvalidDataException("A completed job contains files not present in its frozen manifest batch.");
                }
                receivedOffset += fileCount;
            }

            if (receivedOffset != receivedFileCount)
            {
                throw new InvalidDataException("A completed job contains files not present in its frozen manifest.");
            }

            using (var transaction = connection.BeginTransaction())
            {
                upsertMembership.Transaction = transaction;
                try
                {
                    foreach (var membership in job.AlbumMemberships)
                    {
                        cancellationToken.ThrowIfCancellationRequested();
                        upsertMembership.Parameters["$key"].Value = $"{membership.AlbumId:D}/{membership.AssetId:D}";
                        upsertMembership.Parameters["$title"].Value = membership.AlbumTitle;
                        upsertMembership.Parameters["$asset"].Value = membership.AssetId.ToString("D");
                        upsertMembership.Parameters["$album"].Value = membership.AlbumId.ToString("D");
                        upsertMembership.Parameters["$source"].Value = membership.SourceAlbumIdentifier;
                        upsertMembership.Parameters["$parent"].Value = membership.ParentAlbumId is null
                            ? DBNull.Value
                            : membership.ParentAlbumId.Value.ToString("D");
                        upsertMembership.Parameters["$json"].Value = JsonSerializer.Serialize(
                            new CatalogAlbumMembership(
                                2,
                                membership.AlbumId,
                                membership.SourceAlbumIdentifier,
                                membership.AlbumTitle,
                                membership.ParentAlbumId,
                                membership.AssetId),
                            jsonOptions);
                        upsertMembership.ExecuteNonQuery();
                    }
                    transaction.Commit();
                }
                finally
                {
                    upsertMembership.Transaction = null;
                }
            }
        }

        private bool AssetExists(Guid assetId, SqliteTransaction transaction)
        {
            using var command = connection.CreateCommand();
            command.Transaction = transaction;
            command.CommandText = "SELECT EXISTS(SELECT 1 FROM assets WHERE asset_id=$asset)";
            command.Parameters.AddWithValue("$asset", assetId.ToString("D"));
            return Convert.ToInt32(command.ExecuteScalar()) == 1;
        }

        private IReadOnlyList<ReceivedFile> ReadReceivedFiles(
            long offset,
            int count,
            CancellationToken cancellationToken)
        {
            var results = new List<ReceivedFile>(count);
            if (count == 0)
            {
                return results;
            }

            using var command = connection.CreateCommand();
            command.CommandText = """
                SELECT file_id,relative_path,state,committed_sha256,committed_bytes
                FROM received_files
                WHERE ordinal >= $start AND ordinal < $end
                ORDER BY ordinal
                """;
            command.Parameters.AddWithValue("$start", offset);
            command.Parameters.AddWithValue("$end", checked(offset + count));
            using var reader = command.ExecuteReader();
            while (reader.Read())
            {
                cancellationToken.ThrowIfCancellationRequested();
                results.Add(new ReceivedFile(
                    Guid.Parse(reader.GetString(0)),
                    reader.GetString(1),
                    reader.GetString(2),
                    reader.IsDBNull(3) ? null : reader.GetString(3),
                    reader.IsDBNull(4) ? null : reader.GetInt64(4)));
            }
            return results;
        }

        public async Task WriteAssetsAsync(Stream stream, CancellationToken cancellationToken)
        {
            await using var writer = new StreamWriter(stream, new UTF8Encoding(false), 128 * 1024, leaveOpen: true);
            writer.NewLine = "\n";
            using var command = connection.CreateCommand();
            command.CommandText = "SELECT json FROM assets ORDER BY creation_date,asset_id";
            using var reader = command.ExecuteReader();
            while (reader.Read())
            {
                cancellationToken.ThrowIfCancellationRequested();
                await writer.WriteLineAsync(reader.GetString(0).AsMemory(), cancellationToken);
            }
            await writer.FlushAsync();
        }

        public async Task WriteAlbumsCsvAsync(Stream stream, CancellationToken cancellationToken)
        {
            await using var writer = new StreamWriter(stream, new UTF8Encoding(false), 128 * 1024, leaveOpen: true);
            await writer.WriteAsync("albumId,sourceAlbumIdentifier,albumTitle,parentAlbumId,assetId\r\n".AsMemory(), cancellationToken);
            using var command = connection.CreateCommand();
            command.CommandText = """
                SELECT album_id,source_album_identifier,album_title,parent_album_id,asset_id
                FROM memberships ORDER BY album_title,asset_id
                """;
            using var reader = command.ExecuteReader();
            while (reader.Read())
            {
                cancellationToken.ThrowIfCancellationRequested();
                var line = string.Join(",",
                    Csv(reader.GetString(0)),
                    Csv(reader.GetString(1)),
                    Csv(reader.GetString(2)),
                    Csv(reader.IsDBNull(3) ? string.Empty : reader.GetString(3)),
                    Csv(reader.GetString(4))) + "\r\n";
                await writer.WriteAsync(line.AsMemory(), cancellationToken);
            }
            await writer.FlushAsync();
        }

        public async Task WriteAlbumsJsonAsync(Stream stream, CancellationToken cancellationToken)
        {
            await using var writer = new StreamWriter(stream, new UTF8Encoding(false), 128 * 1024, leaveOpen: true);
            writer.NewLine = "\n";
            using var command = connection.CreateCommand();
            command.CommandText = "SELECT json FROM memberships ORDER BY album_title,asset_id";
            using var reader = command.ExecuteReader();
            while (reader.Read())
            {
                cancellationToken.ThrowIfCancellationRequested();
                await writer.WriteLineAsync(reader.GetString(0).AsMemory(), cancellationToken);
            }
            await writer.FlushAsync();
        }

        public void Dispose()
        {
            insertReceivedFile.Dispose();
            upsertAsset.Dispose();
            upsertMembership.Dispose();
            connection.Dispose();
        }

        private sealed record ReceivedFile(
            Guid FileId,
            string RelativePath,
            string State,
            string? CommittedSha256,
            long? CommittedBytes);
    }
}
