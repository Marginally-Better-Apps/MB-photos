using MBPhotos.Receiver.Models;
using MBPhotos.Receiver.Storage;

namespace MBPhotos.Receiver.Transfer;

/// <summary>
/// Reuses a previously verified stable file when only its representation roles
/// or storage area changed. This is what makes unedited -&gt; edited -&gt; reverted
/// transitions transfer only the newly changed rendition.
/// </summary>
public sealed class RepresentationReuseService
{
    private readonly DestinationContext destination;
    private readonly Ledger ledger;
    private readonly WindowsPathPolicy pathPolicy;

    public RepresentationReuseService(
        DestinationContext destination,
        Ledger ledger,
        WindowsPathPolicy pathPolicy)
    {
        this.destination = destination;
        this.ledger = ledger;
        this.pathPolicy = pathPolicy;
    }

    public async Task<IReadOnlyList<CompletionFailure>> PrepareAsync(
        ExportJob job,
        IReadOnlyList<LedgerFile> ledgerFiles,
        IReadOnlySet<Guid>? blockedAssetIds = null,
        CancellationToken cancellationToken = default)
    {
        var failures = new List<CompletionFailure>();
        var pending = await ledger.GetPendingReusesAsync(job.JobId, cancellationToken);
        if (pending.Count == 0)
        {
            return failures;
        }

        var byId = ledgerFiles.ToDictionary(static file => file.FileId);
        var masterFileIds = job.Assets
            .Where(static asset => asset.MasterFileId is not null)
            .Select(static asset => asset.MasterFileId!.Value)
            .ToHashSet();
        foreach (var reuse in pending)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!byId.TryGetValue(reuse.FileId, out var current))
            {
                throw new InvalidDataException("A pending representation reuse has no job file.");
            }

            if (blockedAssetIds?.Contains(current.AssetId) == true)
            {
                await ledger.MarkReuseFailedAsync(job.JobId, current.FileId, cancellationToken);
                // The Master file already has the preflight failure. Support
                // representations receive their own visible archive failure.
                if (!masterFileIds.Contains(current.FileId))
                {
                    failures.Add(new CompletionFailure(
                        current.FileId,
                        current.Criticality == Criticality.ArchiveRequired
                            ? ErrorCodes.ArchiveIncomplete
                            : ErrorCodes.FileConflict,
                        "The representation was not reused because this asset's active Master conflicted.",
                        false));
                }
                continue;
            }

            try
            {
                var sourcePath = pathPolicy.ResolveUnderRoot(destination.RootPath, reuse.SourceRelativePath);
                await RequireExactAsync(
                    sourcePath,
                    reuse.ByteCount,
                    reuse.Sha256,
                    "A previously verified representation changed before it could be reused.",
                    cancellationToken);

                if (current.StorageArea == StorageArea.Master)
                {
                    var stagedPath = StagedPath(job.JobId, current.FileId);
                    await CopyVerifiedAsync(sourcePath, stagedPath, reuse.ByteCount, reuse.Sha256, cancellationToken);
                    // Keep a Library Data source until a later catalog-aware
                    // cleanup can prove that the promoted Master is active.
                    // Retaining a verified duplicate is safer than deleting the
                    // only archived original after a late Master collision.
                    await ledger.CompleteReuseAsync(
                        job.JobId,
                        current.FileId,
                        preparedMaster: true,
                        File.GetLastWriteTimeUtc(stagedPath).Ticks,
                        cancellationToken);
                }
                else
                {
                    var targetPath = pathPolicy.ResolveUnderRoot(destination.RootPath, current.RelativePath);
                    await CopyVerifiedAsync(sourcePath, targetPath, reuse.ByteCount, reuse.Sha256, cancellationToken);
                    // Stable Library Data relocations deliberately retain their
                    // prior verified source. A later Master failure must never
                    // strand the catalog by deleting its last support copy.
                    await ledger.CompleteReuseAsync(
                        job.JobId,
                        current.FileId,
                        preparedMaster: false,
                        File.GetLastWriteTimeUtc(targetPath).Ticks,
                        cancellationToken);
                }
            }
            catch (ReceiverApiException exception)
            {
                await ledger.MarkReuseFailedAsync(job.JobId, current.FileId, cancellationToken);
                failures.Add(new CompletionFailure(
                    current.FileId,
                    current.Criticality == Criticality.MasterRequired
                        ? ErrorCodes.MasterConflict
                        : current.Criticality == Criticality.ArchiveRequired
                            ? ErrorCodes.ArchiveIncomplete
                            : ErrorCodes.FileConflict,
                    exception.Message,
                    false));
            }
        }

        return failures;
    }

    private async Task CopyVerifiedAsync(
        string sourcePath,
        string targetPath,
        long byteCount,
        string sha256,
        CancellationToken cancellationToken)
    {
        pathPolicy.EnsureNoReparsePoints(destination.RootPath, targetPath);
        if (File.Exists(targetPath))
        {
            await RequireExactAsync(
                targetPath,
                byteCount,
                sha256,
                "A different file occupies the representation's new path.",
                cancellationToken);
            return;
        }

        Directory.CreateDirectory(Path.GetDirectoryName(targetPath)!);
        pathPolicy.EnsureNoReparsePoints(destination.RootPath, Path.GetDirectoryName(targetPath)!);
        var temporaryPath = targetPath + ".mbphotos-reuse";
        pathPolicy.EnsureNoReparsePoints(destination.RootPath, temporaryPath);
        if (File.Exists(temporaryPath))
        {
            if (await IsExactAsync(temporaryPath, byteCount, sha256, cancellationToken))
            {
                File.Move(temporaryPath, targetPath, false);
                return;
            }
            throw new ReceiverApiException(409, ErrorCodes.FileConflict,
                "An interrupted representation reuse contains unexpected bytes.");
        }

        await using (var input = new FileStream(
                         sourcePath,
                         FileMode.Open,
                         FileAccess.Read,
                         FileShare.Read,
                         128 * 1024,
                         FileOptions.Asynchronous | FileOptions.SequentialScan))
        await using (var output = new FileStream(
                         temporaryPath,
                         FileMode.CreateNew,
                         FileAccess.Write,
                         FileShare.None,
                         128 * 1024,
                         FileOptions.Asynchronous | FileOptions.WriteThrough))
        {
            await input.CopyToAsync(output, 128 * 1024, cancellationToken);
            await output.FlushAsync(cancellationToken);
            output.Flush(true);
        }
        await RequireExactAsync(
            temporaryPath,
            byteCount,
            sha256,
            "The locally reused representation failed verification.",
            cancellationToken);
        File.Move(temporaryPath, targetPath, false);
    }

    private string StagedPath(Guid jobId, Guid fileId) => Path.Combine(
        destination.StagingPath,
        jobId.ToString("D"),
        fileId.ToString("D") + ".partial");

    private static async Task RequireExactAsync(
        string path,
        long byteCount,
        string sha256,
        string message,
        CancellationToken cancellationToken)
    {
        if (!await IsExactAsync(path, byteCount, sha256, cancellationToken))
        {
            throw new ReceiverApiException(409, ErrorCodes.FileConflict, message);
        }
    }

    private static async Task<bool> IsExactAsync(
        string path,
        long byteCount,
        string sha256,
        CancellationToken cancellationToken) =>
        File.Exists(path) &&
        new FileInfo(path).Length == byteCount &&
        string.Equals(await Hashing.Sha256FileAsync(path, cancellationToken), sha256, StringComparison.Ordinal);
}
