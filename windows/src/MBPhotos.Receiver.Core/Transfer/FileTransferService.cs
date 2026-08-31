using System.Collections.Concurrent;
using System.Security.Cryptography;
using MBPhotos.Receiver.Models;
using MBPhotos.Receiver.Storage;

namespace MBPhotos.Receiver.Transfer;

public sealed class FileTransferService
{
    private readonly DestinationContext destination;
    private readonly DestinationManager destinationManager;
    private readonly Ledger ledger;
    private readonly WindowsPathPolicy pathPolicy;
    private readonly ConcurrentDictionary<string, SemaphoreSlim> fileLocks = new(StringComparer.Ordinal);

    public FileTransferService(
        DestinationContext destination,
        DestinationManager destinationManager,
        Ledger ledger,
        WindowsPathPolicy pathPolicy)
    {
        this.destination = destination;
        this.destinationManager = destinationManager;
        this.ledger = ledger;
        this.pathPolicy = pathPolicy;
    }

    public async Task<ChunkReceipt> PutChunkAsync(
        Guid jobId,
        Guid fileId,
        int chunkIndex,
        long start,
        long end,
        long total,
        string suppliedSha256,
        Stream requestBody,
        CancellationToken cancellationToken = default)
    {
        suppliedSha256 = ModelValidation.RequireSha256(suppliedSha256, "X-Chunk-SHA256");
        var length = checked(end - start + 1);
        if (chunkIndex < 0 || start != (long)chunkIndex * ProtocolConstants.ChunkSize ||
            length <= 0 || length > ProtocolConstants.ChunkSize ||
            (end + 1 < total && length != ProtocolConstants.ChunkSize))
        {
            throw new ReceiverApiException(400, ErrorCodes.InvalidRequest, "The chunk index and Content-Range do not describe a valid sequential 8 MiB chunk.");
        }

        var fileLock = GetLock(jobId, fileId);
        await fileLock.WaitAsync(cancellationToken);
        try
        {
            var file = await GetPendingFileAsync(jobId, fileId, cancellationToken);
            if (file.ExpectedBytes is not null && file.ExpectedBytes != total)
            {
                throw new ReceiverApiException(409, ErrorCodes.ChangedDestination, "The upload byte count differs from the frozen manifest.");
            }

            var chunkState = await ledger.GetChunkStateAsync(jobId, fileId, chunkIndex, cancellationToken)
                ?? throw new ReceiverApiException(404, ErrorCodes.FileNotFound, "The export file does not exist.");
            if (chunkState.TotalBytes is not null && chunkState.TotalBytes != total)
            {
                throw new ReceiverApiException(409, ErrorCodes.ChunkConflict, "The whole-file length differs from the first acknowledged chunk.");
            }

            if (chunkIndex < chunkState.NextChunkIndex)
            {
                var prior = chunkState.RequestedChunk
                    ?? throw new ReceiverApiException(409, ErrorCodes.ChangedDestination, "The acknowledged chunk ledger is incomplete.", true);
                if (prior.Offset != start || prior.Length != length || prior.TotalBytes != total ||
                    !string.Equals(prior.Sha256, suppliedSha256, StringComparison.Ordinal))
                {
                    throw new ReceiverApiException(409, ErrorCodes.ChunkConflict, "The retried chunk differs from the acknowledged chunk.");
                }

                await VerifyIncomingChunkAsync(requestBody, length, suppliedSha256, Stream.Null, cancellationToken);
                return new ChunkReceipt(jobId, fileId, chunkIndex, start, end + 1, length, suppliedSha256, chunkState.NextChunkIndex, prior.ReceivedAt);
            }

            if (chunkIndex != chunkState.NextChunkIndex)
            {
                throw new ReceiverApiException(400, ErrorCodes.ChunkOutOfOrder, $"Sequential chunks are required. The next chunk is {chunkState.NextChunkIndex}.");
            }

            if (chunkState.BytesTransferred != start)
            {
                throw new ReceiverApiException(409, ErrorCodes.ChangedDestination, "The durable upload cursor does not match the requested byte offset.", true);
            }

            var freeBytes = destinationManager.RefreshInfo(destination).FreeBytes;
            if (freeBytes > 0 && freeBytes < length + (1024 * 1024))
            {
                throw new ReceiverApiException(507, ErrorCodes.DiskFull, "The destination does not have enough free space for this chunk.", true);
            }

            var partialPath = PartialPath(jobId, fileId);
            pathPolicy.EnsureNoReparsePoints(destination.RootPath, partialPath);
            Directory.CreateDirectory(Path.GetDirectoryName(partialPath)!);
            pathPolicy.EnsureNoReparsePoints(destination.RootPath, Path.GetDirectoryName(partialPath)!);
            try
            {
                await using var stream = new FileStream(
                    partialPath,
                    FileMode.OpenOrCreate,
                    FileAccess.Write,
                    FileShare.None,
                    128 * 1024,
                    FileOptions.Asynchronous | FileOptions.WriteThrough);
                if (stream.Length < start)
                {
                    throw new ReceiverApiException(409, ErrorCodes.ChangedDestination, "The partial file length does not match the chunk ledger.", true);
                }

                if (stream.Length > start)
                {
                    // A crash may occur after durable file flush but before the
                    // receipt transaction. Only ledger-acknowledged bytes count.
                    stream.SetLength(start);
                    stream.Flush(true);
                }

                stream.Position = start;
                try
                {
                    await VerifyIncomingChunkAsync(requestBody, length, suppliedSha256, stream, cancellationToken);
                }
                catch
                {
                    stream.SetLength(start);
                    throw;
                }

                await stream.FlushAsync(cancellationToken);
                stream.Flush(true);
            }
            catch (IOException exception) when (IsDiskFull(exception))
            {
                throw new ReceiverApiException(507, ErrorCodes.DiskFull, "The destination ran out of space while writing a chunk.", true);
            }

            var receivedAt = DateTimeOffset.UtcNow;
            await ledger.RecordChunkAsync(
                jobId,
                fileId,
                new LedgerChunk(chunkIndex, start, length, total, suppliedSha256, receivedAt),
                cancellationToken);
            return new ChunkReceipt(jobId, fileId, chunkIndex, start, end + 1, length, suppliedSha256, chunkIndex + 1, receivedAt);
        }
        finally
        {
            fileLock.Release();
        }
    }

    public async Task<CommittedFile> CommitAsync(
        Guid jobId,
        Guid fileId,
        CommitFileRequest request,
        CancellationToken cancellationToken = default)
    {
        var expectedHash = ModelValidation.RequireSha256(request.Sha256, "sha256");
        if (request.ByteCount < 0)
        {
            throw new ReceiverApiException(400, ErrorCodes.InvalidRequest, "byteCount cannot be negative.");
        }

        var fileLock = GetLock(jobId, fileId);
        await fileLock.WaitAsync(cancellationToken);
        try
        {
            var file = await ledger.GetFileAsync(jobId, fileId, cancellationToken)
                ?? throw new ReceiverApiException(404, ErrorCodes.FileNotFound, "The export file does not exist.");
            if (file.State is "committed" or "skipped")
            {
                if (file.CommittedBytes == request.ByteCount &&
                    string.Equals(file.CommittedSha256, expectedHash, StringComparison.Ordinal))
                {
                    return ToCommitted(file);
                }

                throw new ReceiverApiException(409, ErrorCodes.FileConflict, "The file was already committed with different content.");
            }

            if (file.ExpectedBytes is not null && file.ExpectedBytes != request.ByteCount)
            {
                throw new ReceiverApiException(409, ErrorCodes.ChangedDestination, "The commit byte count differs from the frozen manifest.");
            }

            if (file.ExpectedSha256 is not null && !string.Equals(file.ExpectedSha256, expectedHash, StringComparison.Ordinal))
            {
                throw new ReceiverApiException(422, ErrorCodes.HashMismatch, "The commit digest differs from the frozen manifest digest.");
            }

            var chunks = await ledger.GetChunksAsync(jobId, fileId, cancellationToken);
            var acknowledgedBytes = chunks.Sum(static chunk => chunk.Length);
            if (acknowledgedBytes != request.ByteCount ||
                (chunks.Count > 0 && chunks[0].TotalBytes != request.ByteCount) ||
                chunks.Select((chunk, index) => chunk.ChunkIndex == index).Any(static sequential => !sequential))
            {
                throw new ReceiverApiException(400, ErrorCodes.ChunkOutOfOrder, "All sequential chunks must be acknowledged before commit.", true);
            }

            var partialPath = PartialPath(jobId, fileId);
            pathPolicy.EnsureNoReparsePoints(destination.RootPath, partialPath);
            var targetPath = pathPolicy.ResolveUnderRoot(destination.RootPath, file.RelativePath);
            if (!File.Exists(partialPath) && File.Exists(targetPath))
            {
                var targetInfo = new FileInfo(targetPath);
                var targetHash = targetInfo.Length == request.ByteCount
                    ? await Hashing.Sha256FileAsync(targetPath, cancellationToken)
                    : string.Empty;
                if (!string.Equals(targetHash, expectedHash, StringComparison.Ordinal))
                {
                    throw new ReceiverApiException(409, ErrorCodes.ChangedDestination, "The partial file is missing and a different file occupies its accepted path.");
                }

                ApplyCaptureTimestamp(targetPath, file.CaptureDate);
                var recoveredAt = DateTimeOffset.UtcNow;
                await ledger.MarkCommittedAsync(
                    jobId,
                    fileId,
                    targetHash,
                    request.ByteCount,
                    recoveredAt,
                    File.GetLastWriteTimeUtc(targetPath).Ticks,
                    cancellationToken);
                return new CommittedFile(fileId, "committed", file.RelativePath, request.ByteCount, targetHash, recoveredAt);
            }

            if (request.ByteCount == 0 && !File.Exists(partialPath))
            {
                Directory.CreateDirectory(Path.GetDirectoryName(partialPath)!);
                await File.WriteAllBytesAsync(partialPath, Array.Empty<byte>(), cancellationToken);
            }

            if (!File.Exists(partialPath) || new FileInfo(partialPath).Length != request.ByteCount)
            {
                throw new ReceiverApiException(409, ErrorCodes.ChangedDestination, "The partial file does not match its ledger.", true);
            }

            var actualHash = await Hashing.Sha256FileAsync(partialPath, cancellationToken);
            if (!string.Equals(actualHash, expectedHash, StringComparison.Ordinal))
            {
                var quarantinePath = partialPath + ".hash-mismatch-" + DateTimeOffset.UtcNow.ToString("yyyyMMddHHmmssfff");
                File.Move(partialPath, quarantinePath, false);
                await ledger.ClearChunksAsync(jobId, fileId, cancellationToken);
                await ledger.AddFailureAsync(jobId, fileId, ErrorCodes.HashMismatch, "Whole-file SHA-256 verification failed.", true, cancellationToken);
                throw new ReceiverApiException(422, ErrorCodes.HashMismatch, "Whole-file SHA-256 verification failed. The received bytes were quarantined.", true);
            }

            Directory.CreateDirectory(Path.GetDirectoryName(targetPath)!);
            pathPolicy.EnsureNoReparsePoints(destination.RootPath, Path.GetDirectoryName(targetPath)!);
            if (File.Exists(targetPath))
            {
                var existingHash = await Hashing.Sha256FileAsync(targetPath, cancellationToken);
                if (!string.Equals(existingHash, expectedHash, StringComparison.Ordinal))
                {
                    throw new ReceiverApiException(409, ErrorCodes.ChangedDestination, "A different file now occupies the accepted destination path.");
                }

                File.Delete(partialPath);
            }
            else
            {
                File.Move(partialPath, targetPath, false);
            }

            ApplyCaptureTimestamp(targetPath, file.CaptureDate);
            var committedAt = DateTimeOffset.UtcNow;
            var observedTicks = File.GetLastWriteTimeUtc(targetPath).Ticks;
            await ledger.MarkCommittedAsync(jobId, fileId, actualHash, request.ByteCount, committedAt, observedTicks, cancellationToken);
            return new CommittedFile(fileId, "committed", file.RelativePath, request.ByteCount, actualHash, committedAt);
        }
        finally
        {
            fileLock.Release();
        }
    }

    public async Task<int> RemoveUncommittedPartialsAsync(Guid jobId, CancellationToken cancellationToken = default)
    {
        // One set-based transaction replaces a connection/transaction per file.
        // This keeps terminal cleanup linear and bounded for very large jobs.
        await ledger.ClearUncommittedChunksAsync(jobId, cancellationToken);

        var jobPartialPath = Path.Combine(destination.PartialPath, jobId.ToString("D"));
        pathPolicy.EnsureNoReparsePoints(destination.RootPath, jobPartialPath);
        var removed = 0;
        if (Directory.Exists(jobPartialPath))
        {
            var entries = Directory.EnumerateFileSystemEntries(jobPartialPath, "*", SearchOption.AllDirectories).ToArray();
            foreach (var entry in entries)
            {
                pathPolicy.EnsureNoReparsePoints(destination.RootPath, entry);
            }

            removed = entries.Count(File.Exists);
            Directory.Delete(jobPartialPath, true);
        }

        return removed;
    }

    public Task<int> CountUncommittedPartialsAsync(Guid jobId, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var jobPartialPath = Path.Combine(destination.PartialPath, jobId.ToString("D"));
        pathPolicy.EnsureNoReparsePoints(destination.RootPath, jobPartialPath);
        if (!Directory.Exists(jobPartialPath))
        {
            return Task.FromResult(0);
        }

        var entries = Directory.EnumerateFileSystemEntries(jobPartialPath, "*", SearchOption.AllDirectories).ToArray();
        foreach (var entry in entries)
        {
            pathPolicy.EnsureNoReparsePoints(destination.RootPath, entry);
        }

        return Task.FromResult(entries.Count(File.Exists));
    }

    private async Task<LedgerFile> GetPendingFileAsync(Guid jobId, Guid fileId, CancellationToken cancellationToken)
    {
        var file = await ledger.GetFileAsync(jobId, fileId, cancellationToken)
            ?? throw new ReceiverApiException(404, ErrorCodes.FileNotFound, "The export file does not exist.");
        if (file.State != "pending")
        {
            throw new ReceiverApiException(409, ErrorCodes.ChangedDestination, "The export file is already finalized.");
        }

        return file;
    }

    private string PartialPath(Guid jobId, Guid fileId) => Path.Combine(
        destination.PartialPath,
        jobId.ToString("D"),
        fileId.ToString("D") + ".partial");

    private SemaphoreSlim GetLock(Guid jobId, Guid fileId) =>
        fileLocks.GetOrAdd(jobId.ToString("D") + "/" + fileId.ToString("D"), static _ => new SemaphoreSlim(1, 1));

    private static async Task VerifyIncomingChunkAsync(
        Stream input,
        long expectedLength,
        string suppliedSha256,
        Stream output,
        CancellationToken cancellationToken)
    {
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        var buffer = new byte[128 * 1024];
        long remaining = expectedLength;
        while (remaining > 0)
        {
            var read = await input.ReadAsync(buffer.AsMemory(0, (int)Math.Min(buffer.Length, remaining)), cancellationToken);
            if (read == 0)
            {
                throw new ReceiverApiException(400, ErrorCodes.InvalidRequest, "The chunk body ended before Content-Range.");
            }

            hash.AppendData(buffer, 0, read);
            await output.WriteAsync(buffer.AsMemory(0, read), cancellationToken);
            remaining -= read;
        }

        if (await input.ReadAsync(buffer.AsMemory(0, 1), cancellationToken) != 0)
        {
            throw new ReceiverApiException(400, ErrorCodes.InvalidRequest, "The chunk body is longer than Content-Range.");
        }

        var actual = Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
        if (!string.Equals(actual, suppliedSha256, StringComparison.Ordinal))
        {
            throw new ReceiverApiException(422, ErrorCodes.HashMismatch, "Chunk SHA-256 verification failed.", true);
        }
    }

    private static CommittedFile ToCommitted(LedgerFile file) => new(
        file.FileId,
        file.State,
        file.RelativePath,
        file.CommittedBytes ?? 0,
        file.CommittedSha256 ?? string.Empty,
        file.CommittedAt ?? DateTimeOffset.UnixEpoch);

    private static void ApplyCaptureTimestamp(string path, DateTimeOffset? captureDate)
    {
        if (captureDate is null)
        {
            return;
        }

        try
        {
            File.SetLastWriteTimeUtc(path, captureDate.Value.UtcDateTime);
            File.SetCreationTimeUtc(path, captureDate.Value.UtcDateTime);
        }
        catch (PlatformNotSupportedException)
        {
            // Some removable filesystems do not support a creation timestamp.
        }
        catch (IOException)
        {
            // Timestamps are advisory and never invalidate verified content.
        }
    }

    private static bool IsDiskFull(IOException exception) =>
        (exception.HResult & 0xFFFF) is 0x27 or 0x70;
}
