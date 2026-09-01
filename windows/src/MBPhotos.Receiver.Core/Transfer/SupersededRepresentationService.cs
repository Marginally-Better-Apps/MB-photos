using MBPhotos.Receiver.Models;
using MBPhotos.Receiver.Storage;

namespace MBPhotos.Receiver.Transfer;

/// <summary>
/// Stages cleanup of receiver-owned, replaceable Library Data renditions. Root
/// originals and original Live motion are never selected for cleanup.
/// </summary>
public sealed class SupersededRepresentationService
{
    private readonly DestinationContext destination;
    private readonly Ledger ledger;
    private readonly WindowsPathPolicy pathPolicy;

    public SupersededRepresentationService(
        DestinationContext destination,
        Ledger ledger,
        WindowsPathPolicy pathPolicy)
    {
        this.destination = destination;
        this.ledger = ledger;
        this.pathPolicy = pathPolicy;
    }

    public async Task StageCleanupAsync(
        ExportJob job,
        IReadOnlyList<LedgerFile> files,
        CancellationToken cancellationToken = default)
    {
        var assetsById = job.Assets.ToDictionary(static asset => asset.AssetId);
        var filesById = files.ToDictionary(static file => file.FileId);
        foreach (var current in files)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (current.StorageArea == StorageArea.Master &&
                current.State is ("committed" or "skipped") &&
                current.Roles.Contains(RepresentationRole.RootOriginal) &&
                assetsById.TryGetValue(current.AssetId, out var masterAsset) &&
                masterAsset.MasterFileId == current.FileId)
            {
                var active = await ledger.GetActiveMasterAsync(current.AssetId, cancellationToken);
                if (active is not null && active.FileId == current.FileId &&
                    string.Equals(active.ContentRevision, current.ContentRevision, StringComparison.Ordinal) &&
                    string.Equals(active.RelativePath, current.RelativePath, StringComparison.OrdinalIgnoreCase))
                {
                    var priorOriginal = await ledger.FindPriorCommittedSameRevisionAsync(
                        current.FileId,
                        current.ContentRevision,
                        job.JobId,
                        cancellationToken);
                    if (priorOriginal is not null &&
                        priorOriginal.StorageArea == StorageArea.LibraryData &&
                        priorOriginal.Roles.Contains(RepresentationRole.RootOriginal) &&
                        !string.Equals(priorOriginal.RelativePath, current.RelativePath, StringComparison.OrdinalIgnoreCase))
                    {
                        await StageVerifiedCleanupAsync(current.AssetId, priorOriginal, cancellationToken);
                    }
                }
            }

            if (current.StorageArea != StorageArea.LibraryData ||
                current.State is not ("committed" or "skipped") ||
                IsDurableOriginal(current.Roles))
            {
                continue;
            }
            if (!assetsById.TryGetValue(current.AssetId, out var asset) ||
                asset.MasterFileId is not { } masterFileId ||
                !filesById.TryGetValue(masterFileId, out var master) ||
                master.State is not ("committed" or "skipped"))
            {
                // Superseded edit support remains intact when the asset's new
                // required Master could not be promoted.
                continue;
            }

            var prior = await ledger.FindLatestCommittedDifferentRevisionAsync(
                current.FileId,
                current.ContentRevision,
                job.JobId,
                cancellationToken);
            if (prior is null ||
                prior.StorageArea != StorageArea.LibraryData ||
                IsDurableOriginal(prior.Roles) ||
                prior.CommittedBytes is null || prior.CommittedSha256 is null ||
                string.Equals(prior.RelativePath, current.RelativePath, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            await StageVerifiedCleanupAsync(current.AssetId, prior, cancellationToken);
        }
    }

    private async Task StageVerifiedCleanupAsync(
        Guid assetId,
        LedgerFile prior,
        CancellationToken cancellationToken)
    {
        if (prior.CommittedBytes is null || prior.CommittedSha256 is null)
        {
            return;
        }
        var priorPath = pathPolicy.ResolveUnderRoot(destination.RootPath, prior.RelativePath);
        if (!File.Exists(priorPath) || new FileInfo(priorPath).Length != prior.CommittedBytes ||
            !string.Equals(
                await Hashing.Sha256FileAsync(priorPath, cancellationToken),
                prior.CommittedSha256,
                StringComparison.Ordinal))
        {
            // Never delete a receiver path that no longer matches its
            // cataloged bytes. The new rendition can still be published.
            return;
        }

        await ledger.RememberSupersededAsync(
            new LedgerSupersededMaster(
                assetId,
                prior.FileId,
                prior.RelativePath,
                prior.CommittedBytes.Value,
                prior.CommittedSha256,
                prior.ObservedWriteTicks ?? File.GetLastWriteTimeUtc(priorPath).Ticks),
            cancellationToken);
    }

    private static bool IsDurableOriginal(IReadOnlyList<RepresentationRole> roles) =>
        roles.Contains(RepresentationRole.RootOriginal) ||
        roles.Contains(RepresentationRole.AlternateOriginal) ||
        roles.Contains(RepresentationRole.OriginalLiveMotion);
}
