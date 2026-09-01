using System.Collections.Concurrent;
using System.Text.Json;
using MBPhotos.Receiver.Models;
using MBPhotos.Receiver.Storage;

namespace MBPhotos.Receiver.Transfer;

public sealed class JobCoordinator
{
    private const int MaximumPendingActivities = 64;

    private readonly DestinationContext destination;
    private readonly DestinationManager destinationManager;
    private readonly Ledger ledger;
    private readonly WindowsPathPolicy pathPolicy;
    private readonly FileTransferService transfers;
    private readonly ManifestWriter manifestWriter;
    private readonly MasterPromotionService masterPromotion;
    private readonly RepresentationReuseService representationReuse;
    private readonly SupersededRepresentationService supersededRepresentations;
    private readonly JsonSerializerOptions jsonOptions;
    private readonly SemaphoreSlim planningGate = new(1, 1);
    private readonly SemaphoreSlim observerExclusion = new(1, 1);
    private readonly ConcurrentQueue<ReceiverActivity> pendingActivities = new();
    private int activityDrainScheduled;
    private int pendingActivityCount;

    public JobCoordinator(
        DestinationContext destination,
        DestinationManager destinationManager,
        Ledger ledger,
        WindowsPathPolicy pathPolicy,
        FileTransferService transfers,
        ManifestWriter manifestWriter,
        MasterPromotionService masterPromotion,
        RepresentationReuseService representationReuse,
        SupersededRepresentationService supersededRepresentations,
        JsonSerializerOptions jsonOptions)
    {
        this.destination = destination;
        this.destinationManager = destinationManager;
        this.ledger = ledger;
        this.pathPolicy = pathPolicy;
        this.transfers = transfers;
        this.manifestWriter = manifestWriter;
        this.masterPromotion = masterPromotion;
        this.representationReuse = representationReuse;
        this.supersededRepresentations = supersededRepresentations;
        this.jsonOptions = jsonOptions;
    }

    /// <summary>
    /// Raised from a bounded FIFO worker only while the planning gate is free.
    /// The operation that produced an activity never waits for its observers;
    /// a later mutation can briefly wait for the current observer dispatch boundary.
    /// Observer failures are isolated from protocol and durability results.
    /// </summary>
    public event EventHandler<ReceiverActivity>? ActivityChanged;

    public async Task<JobPlan> CreateJobAsync(ExportJob job, CancellationToken cancellationToken = default)
    {
        ModelValidation.Validate(job);
        var totalFiles = job.Assets.Sum(static asset => asset.Files.Count);
        var manifestJson = JsonSerializer.Serialize(job, jsonOptions);
        await AcquirePlanningGateAsync(cancellationToken);
        try
        {
            PublishActivity(new ReceiverActivity(
                job.JobId,
                "planning",
                0,
                totalFiles,
                0,
                null,
                destinationManager.RefreshInfo(destination).FreeBytes));
            var existing = await ledger.GetJobAsync(job.JobId, cancellationToken);
            if (existing is not null)
            {
                if (!string.Equals(existing.ManifestJson, manifestJson, StringComparison.Ordinal))
                {
                    throw new ReceiverApiException(409, ErrorCodes.JobConflict, "The jobId already identifies a different frozen manifest.");
                }

                if (existing.State == JobState.Paused)
                {
                    await ledger.ResumeJobAsync(job.JobId, cancellationToken);
                }

                if (existing.State is JobState.Transferring or JobState.Paused)
                {
                    await ReconcilePendingSkipsAsync(job, cancellationToken);
                }

                return await BuildPlanAsync(job.JobId, cancellationToken);
            }

            var acceptedPaths = new Dictionary<Guid, string>();
            var proposedPaths = new Dictionary<Guid, string>();
            var priorSkips = new Dictionary<Guid, (LedgerFile Prior, long ObservedTicks, bool Reuse)>();
            var reservedPaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var manifestFiles = job.Assets.SelectMany(static asset => asset.Files).ToArray();
            var priorFiles = await ledger.FindPriorCommittedAsync(
                manifestFiles.Select(static file => (file.FileId, file.ContentRevision)).ToArray(),
                cancellationToken);
            foreach (var asset in job.Assets)
            {
                foreach (var file in asset.Files)
                {
                    var proposed = pathPolicy.NormalizeProposedPath(
                        file.ProposedRelativePath,
                        file.CaptureDate,
                        file.OriginalFilename,
                        file.FileId,
                        file.StorageArea,
                        file.AssetId,
                        file.Provenance);
                    proposedPaths[file.FileId] = proposed;
                    priorFiles.TryGetValue((file.FileId, file.ContentRevision), out var prior);
                    if (prior is not null &&
                        (file.ByteCount is null || file.ByteCount == prior.CommittedBytes) &&
                        await ValidatePriorAsync(prior, cancellationToken) is { } observedTicks)
                    {
                        var samePlacement =
                            prior.StorageArea == file.StorageArea &&
                            prior.Roles.SequenceEqual(file.Roles) &&
                            prior.Criticality == file.Criticality &&
                            prior.Provenance == file.Provenance &&
                            string.Equals(prior.ProposedPath, proposed, StringComparison.OrdinalIgnoreCase);
                        var reusedAccepted = samePlacement
                            ? prior.RelativePath
                            : AllocatePath(proposed, file.FileId, reservedPaths);
                        acceptedPaths[file.FileId] = reusedAccepted;
                        priorSkips[file.FileId] = (prior, observedTicks, !samePlacement);
                        reservedPaths.Add(reusedAccepted);
                        continue;
                    }

                    var accepted = AllocatePath(proposed, file.FileId, reservedPaths);
                    acceptedPaths[file.FileId] = accepted;
                    reservedPaths.Add(accepted);
                }
            }

            var uploadBytes = job.Assets
                .SelectMany(static asset => asset.Files)
                .Where(file => file.Availability == Availability.Available && !priorSkips.ContainsKey(file.FileId))
                .Sum(static file => file.ByteCount ?? 0);
            var freeBytes = destinationManager.RefreshInfo(destination).FreeBytes;
            if (freeBytes > 0 && uploadBytes > freeBytes)
            {
                throw new ReceiverApiException(
                    507,
                    ErrorCodes.DiskFull,
                    $"The planned files need {uploadBytes} bytes but only {freeBytes} bytes are available.",
                    true);
            }

            await ledger.CreateJobAsync(job, manifestJson, proposedPaths, acceptedPaths, cancellationToken);
            await ledger.MarkSkippedAsync(
                job.JobId,
                priorSkips.Select(static skip => new LedgerSkip(
                    skip.Key,
                    skip.Value.Prior,
                    skip.Value.ObservedTicks,
                    skip.Value.Reuse)).ToArray(),
                cancellationToken);

            PublishActivity(new ReceiverActivity(
                job.JobId,
                "transferring",
                0,
                totalFiles,
                0,
                null,
                destinationManager.RefreshInfo(destination).FreeBytes));
            return await BuildPlanAsync(job.JobId, cancellationToken);
        }
        finally
        {
            ReleasePlanningGate();
        }
    }

    public async Task<JobStatus> GetStatusAsync(Guid jobId, CancellationToken cancellationToken = default)
    {
        var job = await ledger.GetJobAsync(jobId, cancellationToken)
            ?? throw new ReceiverApiException(404, ErrorCodes.JobNotFound, "The export job does not exist.");
        var files = await ledger.GetJobFilesAsync(jobId, cancellationToken);
        var decisions = await BuildDecisionsAsync(files, cancellationToken);
        var committed = files
            .Where(static file => file.State is "committed" or "skipped")
            .Select(static file => new CommittedFile(
                file.FileId,
                "committed",
                file.RelativePath,
                file.CommittedBytes ?? 0,
                file.CommittedSha256 ?? string.Empty,
                file.CommittedAt ?? DateTimeOffset.UnixEpoch))
            .ToArray();
        var report = job.State is JobState.Completed or JobState.CompletedWithFailures
            ? await manifestWriter.ReadReportAsync(jobId, cancellationToken)
            : null;
        if (report is not null)
        {
            // A crash may occur after the terminal ledger transaction but before
            // the immutable catalog generation/current pointer is published.
            // Never expose terminal status until that boundary is recovered.
            await manifestWriter.EnsurePublishedAsync(report, cancellationToken);
            await masterPromotion.CleanupSupersededAsync(cancellationToken);
        }
        return new JobStatus(
            ProtocolConstants.Version,
            jobId,
            destinationManager.RefreshInfo(destination),
            job.State,
            decisions,
            committed,
            job.CreatedAt,
            job.UpdatedAt,
            report);
    }

    public async Task<ChunkReceipt> PutChunkAsync(
        Guid jobId,
        Guid fileId,
        int chunkIndex,
        long start,
        long end,
        long total,
        string suppliedSha256,
        Stream body,
        CancellationToken cancellationToken = default)
    {
        await AcquirePlanningGateAsync(cancellationToken);
        try
        {
            var job = await ledger.GetJobAsync(jobId, cancellationToken)
                ?? throw new ReceiverApiException(404, ErrorCodes.JobNotFound, "The export job does not exist.");
            if (job.State != JobState.Transferring)
            {
                throw new ReceiverApiException(409, ErrorCodes.JobConflict, "The export job is not accepting chunks.");
            }

            var file = await ledger.GetFileAsync(jobId, fileId, cancellationToken);
            var receipt = await transfers.PutChunkAsync(jobId, fileId, chunkIndex, start, end, total, suppliedSha256, body, cancellationToken);
            await PublishActivityAsync(jobId, file?.RelativePath, null, cancellationToken);
            return receipt;
        }
        catch (ReceiverApiException exception)
        {
            await PublishActivityAsync(jobId, null, exception.Message, cancellationToken);
            throw;
        }
        finally
        {
            ReleasePlanningGate();
        }
    }

    public async Task<CommittedFile> CommitAsync(
        Guid jobId,
        Guid fileId,
        CommitFileRequest request,
        CancellationToken cancellationToken = default)
    {
        await AcquirePlanningGateAsync(cancellationToken);
        try
        {
            var job = await ledger.GetJobAsync(jobId, cancellationToken)
                ?? throw new ReceiverApiException(404, ErrorCodes.JobNotFound, "The export job does not exist.");
            if (job.State != JobState.Transferring)
            {
                throw new ReceiverApiException(409, ErrorCodes.JobConflict, "The export job is not accepting commits.");
            }

            var file = await ledger.GetFileAsync(jobId, fileId, cancellationToken);
            var result = await transfers.CommitAsync(jobId, fileId, request, cancellationToken);
            await PublishActivityAsync(jobId, result.RelativePath, null, cancellationToken);
            return result;
        }
        catch (ReceiverApiException exception)
        {
            await PublishActivityAsync(jobId, null, exception.Message, cancellationToken);
            throw;
        }
        finally
        {
            ReleasePlanningGate();
        }
    }

    public async Task<CompletionReport> CompleteAsync(
        Guid jobId,
        CompleteJobRequest request,
        CancellationToken cancellationToken = default)
    {
        await AcquirePlanningGateAsync(cancellationToken);
        try
        {
        var jobRecord = await ledger.GetJobAsync(jobId, cancellationToken)
            ?? throw new ReceiverApiException(404, ErrorCodes.JobNotFound, "The export job does not exist.");
        if (request.CompletedAt == default)
        {
            throw new ReceiverApiException(400, ErrorCodes.InvalidRequest, "completedAt is required.");
        }

        var failures = request.Failures ?? Array.Empty<CompletionFailure>();
        var normalizedRequest = request with { Failures = failures };
        var completionRequestJson = JsonSerializer.Serialize(normalizedRequest, jsonOptions);
        if (jobRecord.State is JobState.Completed or JobState.CompletedWithFailures)
        {
            if (!string.Equals(jobRecord.CompletionRequestJson, completionRequestJson, StringComparison.Ordinal) || jobRecord.ReportJson is null)
            {
                throw new ReceiverApiException(409, ErrorCodes.JobConflict, "The job was already completed with a different completion request.");
            }

            var storedReport = JsonSerializer.Deserialize<CompletionReport>(jobRecord.ReportJson, jsonOptions)
                ?? throw new InvalidDataException("The stored completion report is invalid.");
            PublishActivity(new ReceiverActivity(
                jobId,
                "finalizing",
                storedReport.Counts.FilesCommitted + storedReport.Counts.FilesSkipped,
                storedReport.Counts.FilesPlanned,
                storedReport.Counts.BytesTransferred,
                null,
                destinationManager.RefreshInfo(destination).FreeBytes));
            await transfers.RemoveUncommittedPartialsAsync(jobId, CancellationToken.None);
            await manifestWriter.WriteAsync(storedReport, cancellationToken);
            await masterPromotion.CleanupSupersededAsync(cancellationToken);
            PublishActivity(new ReceiverActivity(
                jobId,
                storedReport.State,
                storedReport.Counts.FilesPlanned,
                storedReport.Counts.FilesPlanned,
                storedReport.Counts.BytesTransferred,
                null,
                destinationManager.RefreshInfo(destination).FreeBytes));
            return storedReport;
        }

        if (jobRecord.State == JobState.Abandoned)
        {
            throw new ReceiverApiException(409, ErrorCodes.JobConflict, "An abandoned job cannot be completed.");
        }

        var job = JsonSerializer.Deserialize<ExportJob>(jobRecord.ManifestJson, jsonOptions)
            ?? throw new InvalidDataException("The stored job manifest is invalid.");
        var files = await ledger.GetJobFilesAsync(jobId, cancellationToken);
        var filesById = files.ToDictionary(static file => file.FileId);
        var failureIds = new HashSet<Guid>();
        foreach (var failure in failures)
        {
            if (!failureIds.Add(failure.FileId))
            {
                throw new ReceiverApiException(400, ErrorCodes.InvalidRequest, "A failed file may be listed only once.");
            }

            if (!filesById.TryGetValue(failure.FileId, out var file))
            {
                throw new ReceiverApiException(404, ErrorCodes.FileNotFound, "A reported failed file does not belong to this job.");
            }

            if (file.State != "pending")
            {
                throw new ReceiverApiException(409, ErrorCodes.FileConflict, "A reported failed file is already terminal.");
            }

            ValidateCompletionFailure(failure);
        }

        if (files.Any(file => file.State == "pending" && !failureIds.Contains(file.FileId)))
        {
            throw new ReceiverApiException(409, ErrorCodes.JobConflict, "Every pending file must be committed, skipped, or reported as a failure.");
        }

        var preflight = await masterPromotion.PreflightAsync(job, files, cancellationToken);
        var reuseFailures = await representationReuse.PrepareAsync(
            job,
            files,
            preflight.BlockedAssetIds,
            cancellationToken);
        files = await ledger.GetJobFilesAsync(jobId, cancellationToken);
        var promotionFailures = await masterPromotion.PromoteAsync(job, files, cancellationToken);
        var allFailures = failures
            .Concat(preflight.Failures)
            .Concat(reuseFailures)
            .Concat(promotionFailures)
            .ToArray();
        files = await ledger.GetJobFilesAsync(jobId, cancellationToken);
        await supersededRepresentations.StageCleanupAsync(job, files, cancellationToken);
        var stats = await ledger.GetStatsAsync(jobId, cancellationToken);
        var completedAt = request.CompletedAt;
        var reportState = allFailures.Length == 0 ? "completed" : "completedWithFailures";
        filesById = files.ToDictionary(static file => file.FileId);
        var assetsPromoted = job.Assets.Count(asset =>
            asset.MasterFileId is { } masterId &&
            filesById.TryGetValue(masterId, out var master) &&
            master.State is "committed" or "skipped");
        var assetsArchiveIncomplete = job.Assets.Count(asset => asset.Files.Any(manifestFile =>
            manifestFile.Criticality == Criticality.ArchiveRequired &&
            (!filesById.TryGetValue(manifestFile.FileId, out var stored) ||
             stored.State is not ("committed" or "skipped"))));
        var counts = new CompletionCounts(
            job.Assets.Count,
            assetsPromoted,
            assetsArchiveIncomplete,
            stats.TotalFiles,
            stats.CommittedFiles,
            stats.SkippedFiles,
            allFailures.Length,
            stats.BytesTransferred,
            stats.BytesCommitted);
        var generationId = Guid.NewGuid();
        var generationRoot = $"MB Photos Data/Catalog/generations/{generationId:D}";
        var report = new CompletionReport(
            ProtocolConstants.Version,
            jobId,
            destination.Info.DestinationId,
            reportState,
            jobRecord.CreatedAt,
            completedAt,
            counts,
            allFailures,
            $"MB Photos Data/Reports/{jobId:D}.json",
            new CatalogGeneration(
                generationId,
                "MB Photos Data/Catalog/current.json",
                generationRoot + "/assets.jsonl",
                generationRoot + "/albums.jsonl"));
        var reportJson = JsonSerializer.Serialize(report, jsonOptions);
        PublishActivity(new ReceiverActivity(
            jobId,
            "finalizing",
            stats.CommittedFiles + stats.SkippedFiles,
            stats.TotalFiles,
            stats.BytesTransferred,
            null,
            destinationManager.RefreshInfo(destination).FreeBytes));
        await ledger.FinalizeJobAsync(
            jobId,
            completedAt,
            reportState,
            completionRequestJson,
            reportJson,
            allFailures,
            cancellationToken);
        // Once a job is terminal, no staged or quarantined bytes are useful.
        // Committed files live outside this exact job-scoped directory.
        await transfers.RemoveUncommittedPartialsAsync(jobId, CancellationToken.None);
        await manifestWriter.WriteAsync(report, cancellationToken);
        await masterPromotion.CleanupSupersededAsync(cancellationToken);
        PublishActivity(new ReceiverActivity(
            jobId,
            reportState,
            stats.TotalFiles,
            stats.TotalFiles,
            stats.BytesTransferred,
            null,
            destinationManager.RefreshInfo(destination).FreeBytes));
        return report;
        }
        finally
        {
            ReleasePlanningGate();
        }
    }

    public async Task<AbandonJobResponse> AbandonAsync(
        Guid jobId,
        AbandonJobRequest? request,
        CancellationToken cancellationToken = default)
    {
        await AcquirePlanningGateAsync(cancellationToken);
        try
        {
        var job = await ledger.GetJobAsync(jobId, cancellationToken)
            ?? throw new ReceiverApiException(404, ErrorCodes.JobNotFound, "The export job does not exist.");
        if (job.State == JobState.Abandoned)
        {
            await transfers.RemoveUncommittedPartialsAsync(jobId, CancellationToken.None);
            return new AbandonJobResponse(
                jobId,
                "abandoned",
                job.AbandonRemovedPartialFiles ?? 0,
                job.CompletedAt ?? DateTimeOffset.UnixEpoch);
        }

        if (job.State is JobState.Completed or JobState.CompletedWithFailures)
        {
            throw new ReceiverApiException(409, ErrorCodes.JobConflict, "A completed job cannot be abandoned.");
        }

        if (request?.Reason is not null && request.Reason is not ("userDiscarded" or "sourceUnavailable" or "clientReset" or "protocolUpgradeRequired"))
        {
            throw new ReceiverApiException(400, ErrorCodes.InvalidRequest, "The abandonment reason is not supported.");
        }
        var removed = await transfers.CountUncommittedPartialsAsync(jobId, cancellationToken);
        var abandonedAt = DateTimeOffset.UtcNow;
        await ledger.MarkAbandonedAsync(jobId, request?.Reason, abandonedAt, removed, cancellationToken);
        await transfers.RemoveUncommittedPartialsAsync(jobId, CancellationToken.None);
        PublishActivity(new ReceiverActivity(
            jobId,
            "abandoned",
            0,
            0,
            0,
            null,
            destinationManager.RefreshInfo(destination).FreeBytes));
        return new AbandonJobResponse(jobId, "abandoned", removed, abandonedAt);
        }
        finally
        {
            ReleasePlanningGate();
        }
    }

    private async Task<JobPlan> BuildPlanAsync(Guid jobId, CancellationToken cancellationToken)
    {
        var files = await ledger.GetJobFilesAsync(jobId, cancellationToken);
        var destinationInfo = destinationManager.RefreshInfo(destination);
        var job = await ledger.GetJobAsync(jobId, cancellationToken)
            ?? throw new ReceiverApiException(404, ErrorCodes.JobNotFound, "The export job does not exist.");
        return new JobPlan(
            ProtocolConstants.Version,
            jobId,
            destinationInfo,
            job.State,
            await BuildDecisionsAsync(files, cancellationToken),
            job.CreatedAt,
            job.UpdatedAt);
    }

    private async Task<IReadOnlyList<FileDecision>> BuildDecisionsAsync(
        IReadOnlyList<LedgerFile> files,
        CancellationToken cancellationToken)
    {
        var chunkCounts = files.Count == 0
            ? new Dictionary<Guid, int>()
            : new Dictionary<Guid, int>(await ledger.GetChunkCountsAsync(files[0].JobId, cancellationToken));
        var decisions = new List<FileDecision>(files.Count);
        foreach (var file in files)
        {
            var chunkCount = chunkCounts.GetValueOrDefault(file.FileId);
            var action = file.State switch
            {
                "committed" or "skipped" => JobFileAction.Skip,
                "failed" => JobFileAction.Conflict,
                _ when file.Availability != Availability.Available => JobFileAction.Conflict,
                _ when chunkCount > 0 => JobFileAction.Resume,
                _ => JobFileAction.Upload,
            };
            decisions.Add(new FileDecision(
                file.FileId,
                action,
                file.Availability == Availability.Available ? file.RelativePath : null,
                chunkCount,
                chunkCount == 0 ? Array.Empty<ChunkRange>() : new[] { new ChunkRange(0, chunkCount - 1) },
                file.Availability != Availability.Available
                    ? "sourceUnavailable"
                    : file.State is "committed" or "skipped"
                    ? "verified"
                    : file.State == "failed"
                        ? "unresolvableConflict"
                    : chunkCount > 0
                        ? "partial"
                        : !string.Equals(file.ProposedPath, file.RelativePath, StringComparison.Ordinal)
                            ? "pathAdjusted"
                            : "new"));
        }

        return decisions;
    }

    private async Task<long?> ValidatePriorAsync(LedgerFile prior, CancellationToken cancellationToken)
    {
        if (prior.CommittedSha256 is null || prior.CommittedBytes is null)
        {
            return null;
        }

        var targetPath = pathPolicy.ResolveUnderRoot(destination.RootPath, prior.RelativePath);
        if (!File.Exists(targetPath))
        {
            return null;
        }

        var info = new FileInfo(targetPath);
        if (info.Length != prior.CommittedBytes)
        {
            return null;
        }

        if (prior.ObservedWriteTicks == info.LastWriteTimeUtc.Ticks)
        {
            return info.LastWriteTimeUtc.Ticks;
        }

        var digest = await Hashing.Sha256FileAsync(targetPath, cancellationToken);
        if (!string.Equals(digest, prior.CommittedSha256, StringComparison.Ordinal))
        {
            return null;
        }

        return info.LastWriteTimeUtc.Ticks;
    }

    private async Task ReconcilePendingSkipsAsync(ExportJob job, CancellationToken cancellationToken)
    {
        var manifestFiles = job.Assets
            .SelectMany(static asset => asset.Files)
            .ToDictionary(static file => file.FileId);
        var storedFiles = await ledger.GetJobFilesAsync(job.JobId, cancellationToken);
        var pendingFiles = storedFiles.Where(static file => file.State == "pending").ToArray();
        var priorFiles = await ledger.FindPriorCommittedAsync(
            pendingFiles.Select(static file => (file.FileId, file.ContentRevision)).ToArray(),
            cancellationToken);
        var skips = new List<LedgerSkip>();
        foreach (var stored in pendingFiles)
        {
            if (!manifestFiles.TryGetValue(stored.FileId, out var manifestFile))
            {
                continue;
            }

            priorFiles.TryGetValue((stored.FileId, stored.ContentRevision), out var prior);
            if (prior is null ||
                (manifestFile.ByteCount is not null && manifestFile.ByteCount != prior.CommittedBytes) ||
                await ValidatePriorAsync(prior, cancellationToken) is not { } observedTicks)
            {
                continue;
            }

            var samePlacement =
                prior.StorageArea == stored.StorageArea &&
                prior.Roles.SequenceEqual(stored.Roles) &&
                prior.Criticality == stored.Criticality &&
                prior.Provenance == stored.Provenance &&
                string.Equals(prior.ProposedPath, stored.ProposedPath, StringComparison.OrdinalIgnoreCase);
            skips.Add(new LedgerSkip(stored.FileId, prior, observedTicks, !samePlacement));
        }

        await ledger.MarkSkippedAsync(job.JobId, skips, cancellationToken);
    }

    private string AllocatePath(string proposed, Guid fileId, ISet<string> reservedPaths)
    {
        pathPolicy.ValidateRelativePath(proposed);
        var physicalPath = pathPolicy.ResolveUnderRoot(destination.RootPath, proposed);
        if (!reservedPaths.Contains(proposed) && !File.Exists(physicalPath) && !Directory.Exists(physicalPath))
        {
            return proposed;
        }

        var suffixed = pathPolicy.AddStableCollisionSuffix(proposed, fileId);
        physicalPath = pathPolicy.ResolveUnderRoot(destination.RootPath, suffixed);
        if (!reservedPaths.Contains(suffixed) && !File.Exists(physicalPath) && !Directory.Exists(physicalPath))
        {
            return suffixed;
        }

        throw new ReceiverApiException(409, ErrorCodes.PathConflict, "The deterministic collision path is already occupied.");
    }

    private async Task PublishActivityAsync(
        Guid jobId,
        string? currentRelativePath,
        string? errorMessage,
        CancellationToken cancellationToken)
    {
        var stats = await ledger.GetStatsAsync(jobId, cancellationToken);
        PublishActivity(new ReceiverActivity(
            jobId,
            "transferring",
            stats.CommittedFiles + stats.SkippedFiles,
            stats.TotalFiles,
            stats.BytesTransferred,
            currentRelativePath,
            destinationManager.RefreshInfo(destination).FreeBytes,
            errorMessage));
    }

    private void PublishActivity(ReceiverActivity activity)
    {
        var count = Interlocked.Increment(ref pendingActivityCount);
        pendingActivities.Enqueue(activity);
        while (count > MaximumPendingActivities && pendingActivities.TryDequeue(out _))
        {
            count = Interlocked.Decrement(ref pendingActivityCount);
        }
        ScheduleActivityDrain();
    }

    private void ScheduleActivityDrain()
    {
        if (Interlocked.Exchange(ref activityDrainScheduled, 1) != 0)
        {
            return;
        }

        ThreadPool.QueueUserWorkItem(static state => ((JobCoordinator)state!).DrainActivities(), this);
    }

    private async Task AcquirePlanningGateAsync(CancellationToken cancellationToken)
    {
        await observerExclusion.WaitAsync(cancellationToken);
        try
        {
            await planningGate.WaitAsync(cancellationToken);
        }
        finally
        {
            observerExclusion.Release();
        }
    }

    private void ReleasePlanningGate()
    {
        planningGate.Release();
        if (!pendingActivities.IsEmpty)
        {
            ScheduleActivityDrain();
        }
    }

    private void DrainActivities()
    {
        try
        {
            while (true)
            {
                // Activity handlers are application/UI observers. A planner
                // must pass through observerExclusion before it can own the
                // mutation gate, so holding the exclusion through invocation
                // closes the probe-to-callback race without invoking under the
                // mutation gate itself.
                if (!observerExclusion.Wait(0))
                {
                    return;
                }

                try
                {
                    if (!planningGate.Wait(0))
                    {
                        return;
                    }

                    ReceiverActivity activity;
                    try
                    {
                        if (!pendingActivities.TryDequeue(out activity!))
                        {
                            return;
                        }
                    }
                    finally
                    {
                        planningGate.Release();
                    }

                    Interlocked.Decrement(ref pendingActivityCount);
                    var handlers = ActivityChanged;
                    if (handlers is null)
                    {
                        continue;
                    }

                    foreach (EventHandler<ReceiverActivity> handler in handlers.GetInvocationList())
                    {
                        try
                        {
                            handler(this, activity);
                        }
                        catch
                        {
                            // Progress observers must never change transfer durability or
                            // the HTTP result after bytes have been committed.
                        }
                    }
                }
                finally
                {
                    observerExclusion.Release();
                }
            }
        }
        finally
        {
            Volatile.Write(ref activityDrainScheduled, 0);
            if (!pendingActivities.IsEmpty && planningGate.CurrentCount > 0)
            {
                ScheduleActivityDrain();
            }
        }
    }

    private static void ValidateCompletionFailure(CompletionFailure failure)
    {
        var allowedCodes = new HashSet<string>(StringComparer.Ordinal)
        {
            ErrorCodes.InvalidRequest,
            ErrorCodes.AuthenticationRequired,
            ErrorCodes.AuthenticationInvalid,
            ErrorCodes.TokenExpired,
            ErrorCodes.TokenConsumed,
            ErrorCodes.ProtocolMismatch,
            ErrorCodes.DestinationFormatMismatch,
            ErrorCodes.JobNotFound,
            ErrorCodes.FileNotFound,
            ErrorCodes.JobConflict,
            ErrorCodes.FileConflict,
            ErrorCodes.ChunkConflict,
            ErrorCodes.ChunkOutOfOrder,
            ErrorCodes.DiskFull,
            ErrorCodes.PathConflict,
            ErrorCodes.UnsafePath,
            ErrorCodes.HashMismatch,
            ErrorCodes.UnavailableSource,
            ErrorCodes.MasterConflict,
            ErrorCodes.ArchiveIncomplete,
            ErrorCodes.NetworkLoss,
            ErrorCodes.ChangedDestination,
            ErrorCodes.InternalError,
        };
        if (!allowedCodes.Contains(failure.Code) ||
            string.IsNullOrWhiteSpace(failure.Message) ||
            failure.Message.Length > 500)
        {
            throw new ReceiverApiException(400, ErrorCodes.InvalidRequest, "A completion failure contains an invalid code or message.");
        }
    }
}

public sealed record ReceiverActivity(
    Guid JobId,
    string State,
    int CompletedFiles,
    int TotalFiles,
    long TransferredBytes,
    string? CurrentRelativePath,
    long FreeBytes,
    string? ErrorMessage = null);
