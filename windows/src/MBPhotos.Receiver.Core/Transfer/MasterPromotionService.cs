using System.Text.Json;
using MBPhotos.Receiver.Models;
using MBPhotos.Receiver.Storage;

namespace MBPhotos.Receiver.Transfer;

public sealed record MasterPromotionPreflight(
    IReadOnlySet<Guid> BlockedAssetIds,
    IReadOnlyList<CompletionFailure> Failures);

/// <summary>
/// Promotes verified Master bytes only after every job file has reached a
/// terminal state. Every replacement is journaled before the filesystem swap,
/// and the previously cataloged Master is hash-verified before it is touched.
/// </summary>
public sealed class MasterPromotionService
{
    private readonly DestinationContext destination;
    private readonly Ledger ledger;
    private readonly WindowsPathPolicy pathPolicy;
    private readonly JsonSerializerOptions jsonOptions;

    public MasterPromotionService(
        DestinationContext destination,
        Ledger ledger,
        WindowsPathPolicy pathPolicy,
        JsonSerializerOptions jsonOptions)
    {
        this.destination = destination;
        this.ledger = ledger;
        this.pathPolicy = pathPolicy;
        this.jsonOptions = jsonOptions;
    }

    public async Task<MasterPromotionPreflight> PreflightAsync(
        ExportJob job,
        IReadOnlyList<LedgerFile> ledgerFiles,
        CancellationToken cancellationToken = default)
    {
        var blocked = new HashSet<Guid>();
        var failures = new List<CompletionFailure>();
        var filesById = ledgerFiles.ToDictionary(static file => file.FileId);
        foreach (var asset in job.Assets)
        {
            if (asset.MasterFileId is not { } masterFileId ||
                !filesById.TryGetValue(masterFileId, out var next) ||
                next.State is not ("committed" or "skipped"))
            {
                continue;
            }
            var active = await ledger.GetActiveMasterAsync(asset.AssetId, cancellationToken);
            if (active is null ||
                (active.FileId == next.FileId &&
                 string.Equals(active.ContentRevision, next.ContentRevision, StringComparison.Ordinal) &&
                 string.Equals(active.RelativePath, next.RelativePath, StringComparison.OrdinalIgnoreCase)))
            {
                continue;
            }
            try
            {
                await RequireExactFileAsync(
                    pathPolicy.ResolveUnderRoot(destination.RootPath, active.RelativePath),
                    active.ByteCount,
                    active.Sha256,
                    "The active Master was changed outside MB Photos; this asset was not updated.",
                    cancellationToken);
            }
            catch (ReceiverApiException exception)
            {
                await ledger.MarkPromotionFailedAsync(next.JobId, next.FileId, cancellationToken);
                blocked.Add(asset.AssetId);
                failures.Add(new CompletionFailure(
                    next.FileId,
                    ErrorCodes.MasterConflict,
                    exception.Message,
                    false));
            }
        }
        return new MasterPromotionPreflight(blocked, failures);
    }

    public async Task<IReadOnlyList<CompletionFailure>> PromoteAsync(
        ExportJob job,
        IReadOnlyList<LedgerFile> ledgerFiles,
        CancellationToken cancellationToken = default)
    {
        var failures = new List<CompletionFailure>();
        var filesById = ledgerFiles.ToDictionary(static file => file.FileId);
        foreach (var asset in job.Assets)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (asset.MasterFileId is not { } masterFileId)
            {
                // A missing expected current representation is intentionally not
                // replaced by a lower-quality generated fallback.
                continue;
            }

            if (!filesById.TryGetValue(masterFileId, out var file) || file.StorageArea != StorageArea.Master)
            {
                throw new InvalidDataException($"Asset {asset.AssetId:D} has an invalid Master ledger entry.");
            }
            if (file.State is "pending" or "promotionFailed" or "failed")
            {
                // CompleteJob validation guarantees this pending file has an
                // explicit failure. Preserve any prior active Master rather than
                // substituting another representation or deleting it.
                continue;
            }
            if (file.State is not ("committed" or "skipped") ||
                file.CommittedBytes is null || file.CommittedSha256 is null)
            {
                throw new ReceiverApiException(409, ErrorCodes.JobConflict,
                    $"The required Master for asset {asset.AssetId:D} is not verified.");
            }

            var manifestFile = asset.Files.Single(candidate => candidate.FileId == masterFileId);
            if (file.State == "skipped")
            {
                try
                {
                    await EnsureSkippedMasterIsActiveAsync(asset.AssetId, file, cancellationToken);
                }
                catch (ReceiverApiException exception)
                {
                    await ledger.MarkPromotionFailedAsync(file.JobId, file.FileId, cancellationToken);
                    failures.Add(new CompletionFailure(
                        file.FileId,
                        ErrorCodes.MasterConflict,
                        exception.Message,
                        false));
                }
                continue;
            }

            try
            {
                await PromoteOneAsync(asset.AssetId, manifestFile, file, cancellationToken);
            }
            catch (ReceiverApiException exception)
            {
                if (!await TryDiscardUnchangedPreparedJournalAsync(asset.AssetId, file, cancellationToken))
                {
                    // Once the filesystem swap may have happened, the journal
                    // must be recovered to an activated state. Do not finalize a
                    // failure that could leave the catalog pointing at old bytes.
                    throw;
                }
                await ledger.MarkPromotionFailedAsync(file.JobId, file.FileId, cancellationToken);
                failures.Add(new CompletionFailure(
                    file.FileId,
                    ErrorCodes.MasterConflict,
                    exception.Message,
                    false));
            }
        }
        return failures;
    }

    public async Task RecoverInterruptedAsync(CancellationToken cancellationToken = default)
    {
        if (!Directory.Exists(destination.PromotionJournalPath))
        {
            return;
        }
        foreach (var path in Directory.EnumerateFiles(destination.PromotionJournalPath, "*.json"))
        {
            cancellationToken.ThrowIfCancellationRequested();
            pathPolicy.EnsureNoReparsePoints(destination.RootPath, path);
            await using var stream = File.OpenRead(path);
            var journal = await JsonSerializer.DeserializeAsync<PromotionJournal>(stream, jsonOptions, cancellationToken)
                ?? throw new InvalidDataException("A Master promotion journal is empty.");
            var stagedPath = pathPolicy.ResolveUnderRoot(destination.RootPath, journal.StagedRelativePath);
            if (journal.Phase == "prepared" && File.Exists(stagedPath))
            {
                // No swap is known to have occurred. Completion will either
                // promote it or turn an external collision into an asset failure.
                continue;
            }
            await ContinuePromotionAsync(path, journal, cancellationToken);
        }
    }

    private async Task<bool> TryDiscardUnchangedPreparedJournalAsync(
        Guid assetId,
        LedgerFile file,
        CancellationToken cancellationToken)
    {
        var path = JournalPath(assetId);
        if (!File.Exists(path))
        {
            return true;
        }
        await using var stream = File.OpenRead(path);
        var journal = await JsonSerializer.DeserializeAsync<PromotionJournal>(stream, jsonOptions, cancellationToken);
        if (journal is not { Phase: "prepared" } || journal.JobId != file.JobId || journal.FileId != file.FileId)
        {
            return false;
        }
        var stagedPath = pathPolicy.ResolveUnderRoot(destination.RootPath, journal.StagedRelativePath);
        if (!File.Exists(stagedPath))
        {
            return false;
        }
        File.Delete(path);
        return true;
    }

    public async Task CleanupSupersededAsync(CancellationToken cancellationToken = default)
    {
        foreach (var superseded in await ledger.GetSupersededMastersAsync(cancellationToken))
        {
            cancellationToken.ThrowIfCancellationRequested();
            var path = pathPolicy.ResolveUnderRoot(destination.RootPath, superseded.RelativePath);
            if (File.Exists(path))
            {
                if (await IsExactFileAsync(path, superseded.ByteCount, superseded.Sha256, cancellationToken))
                {
                    File.Delete(path);
                    DeleteEmptyParents(path);
                }
                // A changed superseded path is user data now. Retain it, but
                // forget the cleanup intent so terminal Complete retries remain
                // idempotent instead of failing forever.
            }
            await ledger.ForgetSupersededMasterAsync(superseded, cancellationToken);
        }
    }

    private async Task EnsureSkippedMasterIsActiveAsync(
        Guid assetId,
        LedgerFile file,
        CancellationToken cancellationToken)
    {
        var targetPath = pathPolicy.ResolveUnderRoot(destination.RootPath, file.RelativePath);
        await RequireExactFileAsync(
            targetPath,
            file.CommittedBytes!.Value,
            file.CommittedSha256!,
            "The previously cataloged Master was changed outside MB Photos.",
            cancellationToken);

        var active = await ledger.GetActiveMasterAsync(assetId, cancellationToken);
        if (active is not null &&
            (active.FileId != file.FileId ||
             !string.Equals(active.ContentRevision, file.ContentRevision, StringComparison.Ordinal) ||
             !string.Equals(active.RelativePath, file.RelativePath, StringComparison.OrdinalIgnoreCase)))
        {
            throw new ReceiverApiException(409, ErrorCodes.FileConflict,
                "The unchanged Master does not match the active catalog entry.");
        }
        if (active is null)
        {
            await ledger.ActivateMasterAsync(
                new LedgerActiveMaster(
                    assetId,
                    file.FileId,
                    file.ContentRevision,
                    file.RelativePath,
                    file.CommittedBytes.Value,
                    file.CommittedSha256!,
                    File.GetLastWriteTimeUtc(targetPath).Ticks,
                    DateTimeOffset.UtcNow),
                null,
                cancellationToken);
        }
    }

    private async Task PromoteOneAsync(
        Guid assetId,
        ExportFile manifestFile,
        LedgerFile file,
        CancellationToken cancellationToken)
    {
        var journalPath = JournalPath(assetId);
        pathPolicy.EnsureNoReparsePoints(destination.RootPath, journalPath);
        PromotionJournal journal;
        if (File.Exists(journalPath))
        {
            await using var stream = File.OpenRead(journalPath);
            journal = await JsonSerializer.DeserializeAsync<PromotionJournal>(stream, jsonOptions, cancellationToken)
                ?? throw new InvalidDataException("A Master promotion journal is empty.");
            if (journal.AssetId != assetId || journal.FileId != file.FileId || journal.JobId != file.JobId)
            {
                throw new ReceiverApiException(409, ErrorCodes.FileConflict,
                    "A different interrupted Master promotion must be recovered first.");
            }
        }
        else
        {
            var stagedPath = StagedPath(file.JobId, file.FileId);
            var alreadyActive = await ledger.GetActiveMasterAsync(assetId, cancellationToken);
            if (alreadyActive is not null &&
                alreadyActive.FileId == file.FileId &&
                string.Equals(alreadyActive.ContentRevision, file.ContentRevision, StringComparison.Ordinal) &&
                string.Equals(alreadyActive.RelativePath, file.RelativePath, StringComparison.OrdinalIgnoreCase) &&
                alreadyActive.ByteCount == file.CommittedBytes &&
                string.Equals(alreadyActive.Sha256, file.CommittedSha256, StringComparison.Ordinal))
            {
                var activePath = pathPolicy.ResolveUnderRoot(destination.RootPath, alreadyActive.RelativePath);
                await RequireExactFileAsync(
                    activePath,
                    alreadyActive.ByteCount,
                    alreadyActive.Sha256,
                    "The already activated Master changed before job finalization.",
                    cancellationToken);
                if (File.Exists(stagedPath) &&
                    await IsExactFileAsync(stagedPath, alreadyActive.ByteCount, alreadyActive.Sha256, cancellationToken))
                {
                    File.Delete(stagedPath);
                }
                return;
            }
            await RequireExactFileAsync(
                stagedPath,
                file.CommittedBytes!.Value,
                file.CommittedSha256!,
                "The verified Master staging file is missing or changed.",
                cancellationToken);

            var active = await ledger.GetActiveMasterAsync(assetId, cancellationToken);
            LedgerSupersededMaster? superseded = null;
            string? backupRelativePath = null;
            if (active is not null)
            {
                var activePath = pathPolicy.ResolveUnderRoot(destination.RootPath, active.RelativePath);
                await RequireExactFileAsync(
                    activePath,
                    active.ByteCount,
                    active.Sha256,
                    "The active Master was changed outside MB Photos; the new edit was not promoted.",
                    cancellationToken);

                if (string.Equals(active.RelativePath, file.RelativePath, StringComparison.OrdinalIgnoreCase))
                {
                    var backupPath = stagedPath + ".previous";
                    backupRelativePath = ToRelativePath(backupPath);
                    superseded = new LedgerSupersededMaster(
                        active.AssetId,
                        active.FileId,
                        backupRelativePath,
                        active.ByteCount,
                        active.Sha256,
                        active.ObservedWriteTicks);
                }
                else
                {
                    superseded = new LedgerSupersededMaster(
                        active.AssetId,
                        active.FileId,
                        active.RelativePath,
                        active.ByteCount,
                        active.Sha256,
                        active.ObservedWriteTicks);
                }
            }

            journal = new PromotionJournal(
                file.JobId,
                assetId,
                file.FileId,
                file.ContentRevision,
                file.RelativePath,
                file.CommittedBytes!.Value,
                file.CommittedSha256!,
                ToRelativePath(stagedPath),
                backupRelativePath,
                superseded,
                manifestFile.CaptureDate,
                "prepared");
            await WriteJournalAsync(journalPath, journal, cancellationToken);
        }

        await ContinuePromotionAsync(journalPath, journal, cancellationToken);
    }

    private async Task ContinuePromotionAsync(
        string journalPath,
        PromotionJournal journal,
        CancellationToken cancellationToken)
    {
        var stagedPath = pathPolicy.ResolveUnderRoot(destination.RootPath, journal.StagedRelativePath);
        var targetPath = pathPolicy.ResolveUnderRoot(destination.RootPath, journal.TargetRelativePath);
        var backupPath = journal.BackupRelativePath is null
            ? null
            : pathPolicy.ResolveUnderRoot(destination.RootPath, journal.BackupRelativePath);

        if (journal.Phase == "prepared")
        {
            Directory.CreateDirectory(Path.GetDirectoryName(targetPath)!);
            pathPolicy.EnsureNoReparsePoints(destination.RootPath, Path.GetDirectoryName(targetPath)!);
            if (File.Exists(targetPath))
            {
                if (backupPath is null)
                {
                    var existingMatches = await IsExactFileAsync(
                        targetPath,
                        journal.ByteCount,
                        journal.Sha256,
                        cancellationToken);
                    if (!existingMatches)
                    {
                        throw new ReceiverApiException(409, ErrorCodes.FileConflict,
                            "An unrelated file occupies the planned Master path.");
                    }
                    if (File.Exists(stagedPath))
                    {
                        File.Delete(stagedPath);
                    }
                }
                else if (File.Exists(stagedPath))
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(backupPath)!);
                    File.Replace(stagedPath, targetPath, backupPath, ignoreMetadataErrors: true);
                }
            }
            else if (File.Exists(stagedPath))
            {
                File.Move(stagedPath, targetPath, false);
            }

            journal = journal with { Phase = "promoted" };
            await WriteJournalAsync(journalPath, journal, cancellationToken);
        }

        if (journal.Phase == "promoted")
        {
            await RequireExactFileAsync(
                targetPath,
                journal.ByteCount,
                journal.Sha256,
                "The promoted Master does not match the verified upload.",
                cancellationToken);
            ApplyCaptureTimestamp(targetPath, journal.CaptureDate);
            var active = new LedgerActiveMaster(
                journal.AssetId,
                journal.FileId,
                journal.ContentRevision,
                journal.TargetRelativePath,
                journal.ByteCount,
                journal.Sha256,
                File.GetLastWriteTimeUtc(targetPath).Ticks,
                DateTimeOffset.UtcNow);
            await ledger.ActivateMasterAsync(active, journal.Superseded, cancellationToken);
            journal = journal with { Phase = "activated" };
            await WriteJournalAsync(journalPath, journal, cancellationToken);
        }

        if (journal.Phase == "activated")
        {
            File.Delete(journalPath);
        }
    }

    private async Task WriteJournalAsync(
        string path,
        PromotionJournal journal,
        CancellationToken cancellationToken) =>
        await AtomicFile.WriteTextAsync(path, JsonSerializer.Serialize(journal, jsonOptions), cancellationToken);

    private string StagedPath(Guid jobId, Guid fileId) => Path.Combine(
        destination.StagingPath,
        jobId.ToString("D"),
        fileId.ToString("D") + ".partial");

    private string JournalPath(Guid assetId) => Path.Combine(
        destination.PromotionJournalPath,
        assetId.ToString("D") + ".json");

    private string ToRelativePath(string absolutePath) =>
        Path.GetRelativePath(destination.RootPath, absolutePath)
            .Replace(Path.DirectorySeparatorChar, '/');

    private static async Task RequireExactFileAsync(
        string path,
        long byteCount,
        string sha256,
        string message,
        CancellationToken cancellationToken)
    {
        if (!await IsExactFileAsync(path, byteCount, sha256, cancellationToken))
        {
            throw new ReceiverApiException(409, ErrorCodes.FileConflict, message);
        }
    }

    private static async Task<bool> IsExactFileAsync(
        string path,
        long byteCount,
        string sha256,
        CancellationToken cancellationToken) =>
        File.Exists(path) &&
        new FileInfo(path).Length == byteCount &&
        string.Equals(await Hashing.Sha256FileAsync(path, cancellationToken), sha256, StringComparison.Ordinal);

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
        }
    }

    private void DeleteEmptyParents(string path)
    {
        var parent = Path.GetDirectoryName(path);
        while (parent is not null &&
               !string.Equals(parent, destination.MasterPath, StringComparison.OrdinalIgnoreCase) &&
               !string.Equals(parent, destination.StagingPath, StringComparison.OrdinalIgnoreCase) &&
               Directory.Exists(parent) && !Directory.EnumerateFileSystemEntries(parent).Any())
        {
            Directory.Delete(parent);
            parent = Path.GetDirectoryName(parent);
        }
    }

    private sealed record PromotionJournal(
        Guid JobId,
        Guid AssetId,
        Guid FileId,
        string ContentRevision,
        string TargetRelativePath,
        long ByteCount,
        string Sha256,
        string StagedRelativePath,
        string? BackupRelativePath,
        LedgerSupersededMaster? Superseded,
        DateTimeOffset? CaptureDate,
        string Phase);
}
