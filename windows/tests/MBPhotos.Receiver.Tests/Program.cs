using System.Collections.Concurrent;
using System.Net;
using System.Net.Http.Json;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using MBPhotos.Receiver.Diagnostics;
using MBPhotos.Receiver.Hosting;
using MBPhotos.Receiver.Library;
using MBPhotos.Receiver.Models;
using MBPhotos.Receiver.Pairing;
using MBPhotos.Receiver.Storage;
using MBPhotos.Receiver.Transfer;
using Microsoft.Data.Sqlite;
using Microsoft.Extensions.Logging;

namespace MBPhotos.Receiver.Tests;

internal static class Program
{
    private static readonly JsonSerializerOptions JsonOptions = JsonDefaults.Create();
    private static int passed;
    private static int failed;
    private static int skipped;

    public static async Task<int> Main()
    {
        var tests = new (string Name, Func<Task> Run)[]
        {
            ("shared Windows path vectors", TestPathVectorsAsync),
            ("shared protocol fixtures", TestProtocolFixturesAsync),
            ("v2 manifest semantic invariants", TestV2ManifestSemanticsAsync),
            ("pair token expiry, replay, and session auth", TestPairingAsync),
            ("verified thumbnails and completion counts flow through receiver activity", TestThumbnailActivityAsync),
            ("destination initialization and schema migration", TestDestinationAndLedgerAsync),
            ("v2 ledger migration backfills chunk cursors and progress counters", TestLedgerV2MigrationAsync),
            ("receiver-owned and escaping paths are rejected without mutation", TestProtectedReceiverPathsAsync),
            ("chunk retry, commit, completion, and incremental skip", TestTransferAndIncrementalAsync),
            ("external mutation and changed revision never overwrite", TestExternalMutationAsync),
            ("durable tail and moved-file crash reconciliation", TestCrashReconciliationAsync),
            ("unknown-size upload freezes first total", TestUnknownSizeAsync),
            ("hash mismatch quarantine and retry reset", TestHashMismatchAsync),
            ("durable progress counters unwind and recover exactly", TestDurableProgressCountersAsync),
            ("abandon removes only uncommitted partials", TestAbandonAsync),
            ("reparse-point containment", TestReparsePointAsync),
            ("HTTPS pairing and authentication middleware", TestServerIntegrationAsync),
            ("CSV formula neutralization and lossless JSON metadata", TestMetadataSafetyAsync),
            ("completion failures and terminal retry recovery", TestCompletionFailuresAsync),
            ("activity feed is bounded, prompt, and observer-isolated", TestActivityFeedAsync),
            ("activity feed rejects stale and deactivated generations", TestActivityFeedGenerationIsolationAsync),
            ("receiver lifecycle stop fences the Running commit", TestLifecycleStopBeforeCommitAsync),
            ("receiver lifecycle disposal fences the Running commit", TestLifecycleDisposeBeforeCommitAsync),
            ("receiver lifecycle orders rapid stop and start requests", TestLifecycleRapidStopStartAsync),
            ("receiver lifecycle generations are monotonic", TestLifecycleGenerationsAreMonotonicAsync),
            ("older stop requests do not stop newer starts", TestLifecycleOlderStopDoesNotStopNewerStartAsync),
            ("activity dispatcher coalesces UI callbacks without losing urgent state", TestActivityDispatcherAsync),
            ("application close hides and explicit exit is ordered and idempotent", TestApplicationLifetimeAsync),
            ("application exit cleans up after lifecycle disposal failure", TestApplicationLifetimeFailureAsync),
            ("receiver activity observers never block coordinator gates", TestCoordinatorActivityIsolationAsync),
            ("receiver activity observers start only after coordinator gate release", TestCoordinatorActivityGateReleaseAsync),
            ("diagnostics logging is background, bounded, and flushed", TestBackgroundDiagnosticsAsync),
            ("100,000-asset finalization streams bounded metadata", TestHundredThousandAssetFinalizationAsync),
            ("completed ledger history streams in bounded ordered batches", TestCompletedLedgerStreamingAsync),
            ("portable Master transitions reuse originals and export exact variants", TestPortableTransitionsAndExportsAsync),
            ("current Live motion revisions clean superseded receiver files", TestLiveMotionRevisionCleanupAsync),
            ("Master conflicts are per-asset failures and preserve prior catalog", TestMasterConflictPreservesPriorAsync),
            ("terminal status republishes a missing catalog pointer", TestTerminalCatalogRecoveryAsync),
            ("activated Master retry completes without staged bytes", TestActivatedPromotionRetryAsync),
            ("unavailable Master placeholders plan a source conflict", TestUnavailableMasterPlaceholderAsync),
            ("version 1 destinations are rejected untouched", TestV1DestinationRejectedAsync),
        };

        foreach (var test in tests)
        {
            try
            {
                await test.Run();
                passed++;
                Console.WriteLine($"PASS {test.Name}");
            }
            catch (Exception exception)
            {
                if (exception is SkipException)
                {
                    skipped++;
                    Console.WriteLine($"SKIP {test.Name}: {exception.Message}");
                    continue;
                }

                failed++;
                Console.Error.WriteLine($"FAIL {test.Name}: {exception}");
            }
        }

        Console.WriteLine($"{passed} passed; {skipped} skipped; {failed} failed");
        return failed == 0 ? 0 : 1;
    }

    private static Task TestPathVectorsAsync()
    {
        using var document = JsonDocument.Parse(File.ReadAllText(DataPath("windows-paths.json")));
        var root = document.RootElement;
        var policy = new WindowsPathPolicy();
        var defaultId = Guid.Parse("12345678-1234-4234-8234-1234567890ab");

        foreach (var vector in root.GetProperty("sanitizeFilename").EnumerateArray())
        {
            Equal(vector.GetProperty("expected").GetString(), policy.SanitizeFileName(vector.GetProperty("input").GetString()!, defaultId), vector.GetProperty("id").GetString());
        }

        foreach (var vector in root.GetProperty("validateRelativePath").EnumerateArray())
        {
            var path = Expression(vector, "path", "pathExpression");
            var valid = vector.GetProperty("valid").GetBoolean();
            try
            {
                policy.ValidateRelativePath(path);
                True(valid, vector.GetProperty("id").GetString() + " should have failed");
            }
            catch (ReceiverApiException exception)
            {
                True(!valid, vector.GetProperty("id").GetString() + " unexpectedly failed");
                Equal(vector.GetProperty("error").GetString(), exception.Error.Code, vector.GetProperty("id").GetString());
            }
        }

        foreach (var vector in root.GetProperty("shortenRelativePath").EnumerateArray())
        {
            var path = Expression(vector, "path", "pathExpression");
            var fileId = vector.GetProperty("fileId").GetGuid();
            if (vector.TryGetProperty("error", out var expectedError))
            {
                var exception = Throws<ReceiverApiException>(() => policy.ShortenRelativePath(path, fileId));
                Equal(expectedError.GetString(), exception.Error.Code, vector.GetProperty("id").GetString());
            }
            else
            {
                Equal(Expression(vector, "expectedPath", "expectedPathExpression"), policy.ShortenRelativePath(path, fileId), vector.GetProperty("id").GetString());
            }
        }

        foreach (var vector in root.GetProperty("resolveCaseInsensitiveCollision").EnumerateArray())
        {
            var proposed = vector.GetProperty("proposedPath").GetString()!;
            var fileId = vector.GetProperty("fileId").GetGuid();
            var existing = vector.GetProperty("existingPaths").EnumerateArray()
                .Select(static item => item.GetString()!)
                .ToHashSet(StringComparer.OrdinalIgnoreCase);
            string? result = null;
            ReceiverApiException? error = null;
            if (!existing.Contains(proposed))
            {
                result = proposed;
            }
            else
            {
                var suffixed = policy.AddStableCollisionSuffix(proposed, fileId);
                if (existing.Contains(suffixed))
                {
                    error = new ReceiverApiException(409, ErrorCodes.PathConflict, "collision");
                }
                else
                {
                    result = suffixed;
                }
            }

            if (vector.TryGetProperty("error", out var expectedError))
            {
                Equal(expectedError.GetString(), error?.Error.Code, vector.GetProperty("id").GetString());
            }
            else
            {
                Equal(vector.GetProperty("expectedPath").GetString(), result, vector.GetProperty("id").GetString());
            }
        }

        var thumbnailAssetId = Guid.NewGuid();
        var thumbnailFileId = Guid.NewGuid();
        var overlongThumbnail = "MB Photos Data/Thumbnails/" +
            string.Join('/', Enumerable.Repeat(new string('x', 200), 2)) + "/thumb.jpg";
        Equal(
            $"MB Photos Data/Thumbnails/{thumbnailAssetId:D}/{thumbnailFileId:D}.jpg",
            policy.NormalizeProposedPath(
                overlongThumbnail,
                null,
                "thumb.jpg",
                thumbnailFileId,
                StorageArea.LibraryData,
                thumbnailAssetId,
                Provenance.GeneratedThumbnail));

        return Task.CompletedTask;
    }

    private static Task TestProtocolFixturesAsync()
    {
        var fixtures = Path.Combine(AppContext.BaseDirectory, "Protocol", "Fixtures");
        var pairRequest = Fixture<PairRequest>(fixtures, "pair.request.json");
        Equal(ProtocolConstants.Version, pairRequest.ProtocolVersion);
        var pair = Fixture<PairResponse>(fixtures, "pair.response.json");
        Equal(ProtocolConstants.Version, pair.ProtocolVersion);
        var job = Fixture<ExportJob>(fixtures, "create-job.request.json");
        ModelValidation.Validate(job);
        Equal(5, job.Assets.Sum(static asset => asset.Files.Count));
        var plan = Fixture<JobPlan>(fixtures, "create-job.response.json");
        Equal(JobFileAction.Resume, plan.Decisions[0].Action);
        var status = Fixture<JobStatus>(fixtures, "job-status.response.json");
        Equal(JobState.Transferring, status.State);
        var receipt = Fixture<ChunkReceipt>(fixtures, "chunk-receipt.response.json");
        Equal(8_388_608L, receipt.EndOffsetExclusive);
        _ = Fixture<CommitFileRequest>(fixtures, "commit-file.request.json");
        _ = Fixture<CommittedFile>(fixtures, "commit-file.response.json");
        _ = Fixture<CompleteJobRequest>(fixtures, "complete-job.request.json");
        var failedCompletion = Fixture<CompleteJobRequest>(fixtures, "complete-job-with-failures.request.json");
        Equal(1, failedCompletion.Failures?.Count);
        var report = Fixture<CompletionReport>(fixtures, "completion-report.response.json");
        Equal(2, report.Counts.AssetsPromoted);
        var failedReport = Fixture<CompletionReport>(fixtures, "completion-report-with-failures.response.json");
        Equal("completedWithFailures", failedReport.State);
        _ = Fixture<AbandonJobRequest>(fixtures, "abandon-job.request.json");
        _ = Fixture<AbandonJobResponse>(fixtures, "abandon-job.response.json");
        _ = Fixture<ApiError>(fixtures, "api-error.response.json");
        var scenarios = Fixture<ExportJob>(fixtures, "scenario-matrix.request.json");
        ModelValidation.Validate(scenarios);
        Equal(6, scenarios.Assets.Count);
        _ = Fixture<LibraryDescriptor>(fixtures, "library.json");
        _ = Fixture<CatalogPointer>(fixtures, "catalog-current.json");
        _ = Fixture<CatalogAsset>(fixtures, "catalog-asset.json");
        _ = Fixture<CatalogAlbumMembership>(fixtures, "catalog-album.json");
        Equal(1024L * 1024 * 1024, ReceiverServer.MaximumJobManifestBytes);
        var emptyAbandon = JsonSerializer.Serialize(new AbandonJobRequest(null), JsonOptions);
        True(!emptyAbandon.Contains("reason", StringComparison.Ordinal));
        return Task.CompletedTask;
    }

    private static T Fixture<T>(string fixtures, string name)
    {
        var value = JsonSerializer.Deserialize<T>(File.ReadAllText(Path.Combine(fixtures, name)), JsonOptions);
        return value ?? throw new InvalidDataException($"Fixture {name} decoded as null.");
    }

    private static Task TestV2ManifestSemanticsAsync()
    {
        var bytes = Encoding.UTF8.GetBytes("semantic validation");
        var baseline = Job(bytes, new StableIds(), Guid.NewGuid(), new string('a', 64));
        var asset = baseline.Assets.Single();
        var file = asset.Files.Single();

        Equal(ErrorCodes.InvalidRequest, Throws<ReceiverApiException>(() =>
            ModelValidation.Validate(baseline with { SourceTimeZone = new string('x', 65) })).Error.Code);
        Equal(ErrorCodes.InvalidRequest, Throws<ReceiverApiException>(() =>
            ModelValidation.Validate(baseline with
            {
                Assets = new[] { asset with { Files = new[] { file with { PhotoKitResourceTypeRaw = null } } } },
            })).Error.Code);
        Equal(ErrorCodes.InvalidRequest, Throws<ReceiverApiException>(() =>
            ModelValidation.Validate(baseline with
            {
                Assets = new[]
                {
                    asset with
                    {
                        Files = new[]
                        {
                            file with
                            {
                                Roles = new[] { RepresentationRole.MasterCurrent, RepresentationRole.AdjustmentRecipe },
                            },
                        },
                    },
                },
            })).Error.Code);
        Equal(ErrorCodes.InvalidRequest, Throws<ReceiverApiException>(() =>
            ModelValidation.Validate(baseline with
            {
                Assets = new[] { asset with { MediaSubtypes = new[] { "livePhoto" } } },
            })).Error.Code);
        Equal(ErrorCodes.InvalidRequest, Throws<ReceiverApiException>(() =>
            ModelValidation.Validate(baseline with
            {
                Assets = new[]
                {
                    asset with
                    {
                        MasterFileId = null,
                        Files = new[]
                        {
                            file with { Availability = Availability.SourceUnavailable, Sha256 = Sha(bytes) },
                        },
                    },
                },
            })).Error.Code);

        return Task.CompletedTask;
    }

    private static Task TestPairingAsync()
    {
        var pairing = new PairingSessionManager();
        var observed = new List<PairingSessionSnapshot>();
        pairing.StateChanged += (_, _) => throw new InvalidOperationException("observer failure");
        pairing.StateChanged += (_, snapshot) => observed.Add(snapshot);

        var expired = pairing.StartRun(TimeSpan.FromSeconds(-1));
        var request = PairRequest(expired.Token);
        Equal(ErrorCodes.TokenExpired, Throws<ReceiverApiException>(() => pairing.Redeem(request)).Error.Code);

        var renewed = pairing.RefreshExpiredInvitation(expired.ExpiresAt, TimeSpan.FromMinutes(1));
        True(renewed.InvitationToken is not null);
        True(!string.Equals(expired.Token, renewed.InvitationToken, StringComparison.Ordinal));
        var session = pairing.Redeem(PairRequest(renewed.InvitationToken!));
        True(pairing.Authorize("Bearer " + session), "the redeemed bearer was not authorized");
        True(!pairing.Authorize("Bearer wrong"));
        Equal(ErrorCodes.TokenConsumed,
            Throws<ReceiverApiException>(() => pairing.Redeem(PairRequest(renewed.InvitationToken!))).Error.Code);

        var consumed = pairing.RefreshExpiredInvitation(DateTimeOffset.MaxValue);
        True(consumed.InvitationToken is null,
            "an expiry refresh recreated an invitation after concurrent-style redemption");

        var invitation = pairing.EnsureInvitation();
        var unchanged = pairing.EnsureInvitation();
        Equal(invitation.InvitationToken, unchanged.InvitationToken,
            "ensuring an invitation rotated an already displayed QR");
        True(pairing.Authorize("Bearer " + session), "creating an invitation invalidated the current bearer");

        var replacement = pairing.Redeem(PairRequest(invitation.InvitationToken!));
        True(!pairing.Authorize("Bearer " + session), "a new pairing did not replace the prior bearer");
        True(pairing.Authorize("Bearer " + replacement));

        var staleEnsure = pairing.EnsureInvitationForAuthorizedSession("Bearer " + session);
        True(staleEnsure.InvitationToken is null,
            "a stale bearer recreated an invitation after a newer pairing");
        var authorizedInvitation = pairing.EnsureInvitationForAuthorizedSession("Bearer " + replacement);
        True(authorizedInvitation.InvitationToken is not null,
            "the current bearer could not create its next invitation");
        var newest = pairing.Redeem(PairRequest(authorizedInvitation.InvitationToken!));
        var lateCompletion = pairing.EnsureInvitationForAuthorizedSession("Bearer " + replacement);
        True(lateCompletion.InvitationToken is null && pairing.Authorize("Bearer " + newest),
            "a late completion callback resurrected a QR after a newer phone paired");

        var idle = pairing.RefreshInvitation();
        True(idle.InvitationToken is not null && idle.HasActiveSession);
        var retracted = pairing.RetractInvitation();
        True(retracted.InvitationToken is null && retracted.HasActiveSession);
        True(pairing.Authorize("Bearer " + newest), "retracting an idle invitation invalidated the bearer");
        True(observed.Count >= 7, "pairing state changes were not observable");
        pairing.EndRun();
        True(observed.Zip(observed.Skip(1), static (before, after) => after.Revision > before.Revision).All(static increasing => increasing),
            "pairing observer revisions were not strictly monotonic");
        return Task.CompletedTask;
    }

    private static async Task TestThumbnailActivityAsync()
    {
        await using var context = await TestContext.CreateAsync();
        var ids = new StableIds();
        var masterBytes = Encoding.UTF8.GetBytes("verified master");
        var thumbnailBytes = new byte[] { 0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0xff, 0xd9 };
        var baseline = Job(masterBytes, ids, Guid.NewGuid(), new string('b', 64));
        var asset = baseline.Assets.Single();
        var thumbnailId = Guid.NewGuid();
        var thumbnailRelativePath = $"MB Photos Data/Thumbnails/{ids.AssetId:D}/{thumbnailId:D}.jpg";
        var thumbnail = new ExportFile(
            thumbnailId,
            ids.AssetId,
            new string('b', 64),
            StorageArea.LibraryData,
            new[] { RepresentationRole.Auxiliary },
            Criticality.Optional,
            Provenance.GeneratedThumbnail,
            null,
            null,
            "thumbnail.jpg",
            thumbnailRelativePath,
            "public.jpeg",
            "image/jpeg",
            160,
            160,
            null,
            thumbnailBytes.LongLength,
            Sha(thumbnailBytes),
            asset.CreationDate,
            Availability.Available);
        var job = baseline with
        {
            Assets = new[] { asset with { Files = new[] { asset.Files.Single(), thumbnail } } },
        };

        var masterActivity = new TaskCompletionSource<ReceiverActivity>(TaskCreationOptions.RunContinuationsAsynchronously);
        var thumbnailActivity = new TaskCompletionSource<ReceiverActivity>(TaskCreationOptions.RunContinuationsAsynchronously);
        var resumedActivity = new TaskCompletionSource<ReceiverActivity>(TaskCreationOptions.RunContinuationsAsynchronously);
        var terminalActivity = new TaskCompletionSource<ReceiverActivity>(TaskCreationOptions.RunContinuationsAsynchronously);
        context.Coordinator.ActivityChanged += (_, activity) =>
        {
            if (activity.CurrentRelativePath == asset.Files.Single().ProposedRelativePath)
            {
                masterActivity.TrySetResult(activity);
            }
            if (activity.CurrentRelativePath == thumbnailRelativePath &&
                activity.LatestThumbnailRelativePath is not null)
            {
                thumbnailActivity.TrySetResult(activity);
            }
            if (activity.State == "planning" && activity.LatestThumbnailRelativePath is not null)
            {
                resumedActivity.TrySetResult(activity);
            }
            if (activity.State == "completed")
            {
                terminalActivity.TrySetResult(activity);
            }
        };

        await context.Coordinator.CreateJobAsync(job);
        await context.Coordinator.PutChunkAsync(
            job.JobId,
            ids.FileId,
            0,
            0,
            masterBytes.Length - 1,
            masterBytes.Length,
            Sha(masterBytes),
            new MemoryStream(masterBytes));
        await context.Coordinator.CommitAsync(
            job.JobId,
            ids.FileId,
            new CommitFileRequest(masterBytes.Length, Sha(masterBytes)));
        var beforeThumbnail = await masterActivity.Task.WaitAsync(TimeSpan.FromSeconds(2));
        True(beforeThumbnail.LatestThumbnailRelativePath is null,
            "a non-thumbnail commit was projected as a preview");

        await context.Coordinator.PutChunkAsync(
            job.JobId,
            thumbnailId,
            0,
            0,
            thumbnailBytes.Length - 1,
            thumbnailBytes.Length,
            Sha(thumbnailBytes),
            new MemoryStream(thumbnailBytes));
        await context.Coordinator.CommitAsync(
            job.JobId,
            thumbnailId,
            new CommitFileRequest(thumbnailBytes.Length, Sha(thumbnailBytes)));
        var committedThumbnail = await thumbnailActivity.Task.WaitAsync(TimeSpan.FromSeconds(2));
        Equal(thumbnailRelativePath, committedThumbnail.LatestThumbnailRelativePath);
        True(File.Exists(context.PathPolicy.ResolveUnderRoot(context.Root, thumbnailRelativePath)),
            "the projected thumbnail was not committed beneath the library root");

        var resumed = await context.Coordinator.CreateJobAsync(job);
        Equal(JobState.Transferring, resumed.State);
        var resumedPreview = await resumedActivity.Task.WaitAsync(TimeSpan.FromSeconds(2));
        Equal(thumbnailRelativePath, resumedPreview.LatestThumbnailRelativePath,
            "resume activity did not retain the latest verified thumbnail");

        var report = await context.Coordinator.CompleteAsync(
            job.JobId,
            new CompleteJobRequest(DateTimeOffset.UtcNow));
        var terminal = await terminalActivity.Task.WaitAsync(TimeSpan.FromSeconds(2));
        Equal(thumbnailRelativePath, terminal.LatestThumbnailRelativePath);
        Equal(report.Counts, terminal.CompletionCounts,
            "terminal activity did not project durable completion counts");
        Equal(2, terminal.CompletionCounts!.FilesPlanned);
    }

    private static async Task TestActivityFeedAsync()
    {
        using var feed = new ReceiverActivityFeed();
        feed.Activate(7);
        var firstJobId = Guid.NewGuid();
        var secondJobId = Guid.NewGuid();
        var siblingJobId = Guid.NewGuid();
        var calls = 0;
        var concurrent = 0;
        var maximumConcurrent = 0;
        var urgentError = new TaskCompletionSource<ReceiverActivityEnvelope>(TaskCreationOptions.RunContinuationsAsynchronously);
        var terminal = new TaskCompletionSource<ReceiverActivityEnvelope>(TaskCreationOptions.RunContinuationsAsynchronously);
        var secondJob = new TaskCompletionSource<ReceiverActivityEnvelope>(TaskCreationOptions.RunContinuationsAsynchronously);
        var siblingRejected = new TaskCompletionSource<ReceiverActivityEnvelope>(TaskCreationOptions.RunContinuationsAsynchronously);
        var siblingTransfer = new TaskCompletionSource<ReceiverActivityEnvelope>(TaskCreationOptions.RunContinuationsAsynchronously);

        feed.ActivityAvailable += (_, _) => throw new InvalidOperationException("observer failure");
        feed.ActivityAvailable += (_, envelope) =>
        {
            var active = Interlocked.Increment(ref concurrent);
            maximumConcurrent = Math.Max(maximumConcurrent, active);
            Interlocked.Increment(ref calls);
            Thread.Sleep(10);
            Interlocked.Decrement(ref concurrent);
            if (envelope.Activity.State == "completed")
            {
                terminal.TrySetResult(envelope);
            }
            if (envelope.Activity.ErrorMessage is not null)
            {
                urgentError.TrySetResult(envelope);
            }
            if (envelope.Activity.JobId == secondJobId)
            {
                secondJob.TrySetResult(envelope);
            }
            if (envelope.Activity.JobId == siblingJobId && envelope.Activity.State == "rejected")
            {
                siblingRejected.TrySetResult(envelope);
            }
            if (envelope.Activity.JobId == siblingJobId && envelope.Activity.State == "transferring")
            {
                siblingTransfer.TrySetResult(envelope);
            }
        };

        for (var index = 0; index < 10_000; index++)
        {
            feed.Publish(7, new ReceiverActivity(
                firstJobId,
                "transferring",
                index,
                10_000,
                index,
                null,
                1));
        }

        await Task.Delay(250);
        True(calls <= 3, $"ordinary progress was delivered {calls} times in 250 ms");

        var errorStarted = System.Diagnostics.Stopwatch.StartNew();
        feed.Publish(7, new ReceiverActivity(firstJobId, "transferring", 1, 10_000, 1, null, 1, "retryable error"));
        var deliveredError = await urgentError.Task.WaitAsync(TimeSpan.FromSeconds(2));
        Equal("retryable error", deliveredError.Activity.ErrorMessage);
        True(errorStarted.Elapsed < TimeSpan.FromMilliseconds(500), "error activity was not delivered promptly");

        var started = System.Diagnostics.Stopwatch.StartNew();
        feed.Publish(7, new ReceiverActivity(firstJobId, "completed", 10_000, 10_000, 10_000, null, 1));
        feed.Publish(7, new ReceiverActivity(firstJobId, "transferring", 1, 1, 1, null, 1));
        var delivered = await terminal.Task.WaitAsync(TimeSpan.FromSeconds(2));
        Equal("completed", delivered.Activity.State);
        True(started.Elapsed < TimeSpan.FromMilliseconds(500), "terminal activity was not delivered promptly");

        feed.Publish(7, new ReceiverActivity(secondJobId, "transferring", 1, 2, 1, null, 1, "second job"));
        var deliveredSecondJob = await secondJob.Task.WaitAsync(TimeSpan.FromSeconds(2));
        Equal(secondJobId, deliveredSecondJob.Activity.JobId,
            "a terminal job suppressed a later job in the same receiver generation");

        feed.Publish(7, new ReceiverActivity(siblingJobId, "transferring", 1, 2, 1, null, 1));
        feed.Publish(7, new ReceiverActivity(siblingJobId, "planning", 0, 2, 0, null, 1));
        feed.Publish(7, new ReceiverActivity(siblingJobId, "rejected", 0, 2, 0, null, 1));
        await siblingRejected.Task.WaitAsync(TimeSpan.FromSeconds(2));
        var retainedSibling = await siblingTransfer.Task.WaitAsync(TimeSpan.FromSeconds(2));
        Equal("transferring", retainedSibling.Activity.State,
            "a rejected sibling erased the established transfer snapshot");
        Equal(1, maximumConcurrent, "activity observers must not run concurrently");
    }

    private static async Task TestActivityFeedGenerationIsolationAsync()
    {
        using var feed = new ReceiverActivityFeed();
        var delivered = new List<ReceiverActivityEnvelope>();
        var deliveredCurrent = new TaskCompletionSource<ReceiverActivityEnvelope>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        feed.ActivityAvailable += (_, envelope) =>
        {
            lock (delivered)
            {
                delivered.Add(envelope);
            }
            if (envelope.Generation == 2)
            {
                deliveredCurrent.TrySetResult(envelope);
            }
        };

        feed.Activate(1);
        feed.Activate(2);
        feed.Publish(1, new ReceiverActivity(
            Guid.Empty,
            "transferring",
            1,
            2,
            1,
            null,
            1,
            "stale generation error"));
        feed.Publish(1, new ReceiverActivity(
            Guid.Empty,
            "completed",
            2,
            2,
            2,
            null,
            1));

        await Task.Delay(250);
        lock (delivered)
        {
            Equal(0, delivered.Count, "stale urgent or terminal activity escaped the generation gate");
        }

        feed.Publish(2, new ReceiverActivity(
            Guid.Empty,
            "transferring",
            1,
            2,
            1,
            null,
            1,
            "current generation error"));
        var current = await deliveredCurrent.Task.WaitAsync(TimeSpan.FromSeconds(2));
        Equal(2L, current.Generation);
        Equal("current generation error", current.Activity.ErrorMessage);

        int deliveredBeforeDeactivation;
        lock (delivered)
        {
            deliveredBeforeDeactivation = delivered.Count;
            True(delivered.All(static envelope => envelope.Generation == 2),
                "an event from a superseded generation was delivered");
        }

        feed.Deactivate(2);
        feed.Publish(2, new ReceiverActivity(
            Guid.Empty,
            "transferring",
            1,
            2,
            1,
            null,
            1,
            "deactivated generation error"));
        feed.Publish(2, new ReceiverActivity(
            Guid.Empty,
            "completed",
            2,
            2,
            2,
            null,
            1));

        await Task.Delay(250);
        lock (delivered)
        {
            Equal(deliveredBeforeDeactivation, delivered.Count,
                "activity was delivered after its generation was deactivated");
        }
    }

    private static Task TestLifecycleStopBeforeCommitAsync()
    {
        var fence = new ReceiverLifecycleGenerationFence();
        True(fence.TryReserveStart(out var generation));
        var stop = fence.RecordStop();
        var callbackRan = false;

        True(!fence.TryCommitRunning(
            generation,
            cancellationRequested: false,
            ownsStartup: true,
            () => callbackRan = true));
        True(!callbackRan, "A stop recorded before commit must prevent the Running assignment.");
        True(stop.Includes(generation));
        Equal(ReceiverLifecycleStartStatus.StopRequested, fence.StatusFor(generation));
        return Task.CompletedTask;
    }

    private static Task TestLifecycleDisposeBeforeCommitAsync()
    {
        var fence = new ReceiverLifecycleGenerationFence();
        True(fence.TryReserveStart(out var generation));
        True(fence.TryRecordDisposal(out var stop));
        var callbackRan = false;

        True(!fence.TryCommitRunning(
            generation,
            cancellationRequested: false,
            ownsStartup: true,
            () => callbackRan = true));
        True(!callbackRan, "Disposal recorded before commit must prevent the Running assignment.");
        True(stop.Includes(generation));
        Equal(ReceiverLifecycleStartStatus.Disposed, fence.StatusFor(generation));
        True(!fence.TryReserveStart(out _), "A disposed lifecycle must reject later starts.");
        True(!fence.TryRecordDisposal(out _), "Disposal must be idempotent.");
        Equal(stop, fence.RecordStop(), "A stop racing after disposal must remain an idempotent fence.");
        return Task.CompletedTask;
    }

    private static Task TestLifecycleRapidStopStartAsync()
    {
        var fence = new ReceiverLifecycleGenerationFence();
        True(fence.TryReserveStart(out var first));
        var firstStop = fence.RecordStop();
        True(fence.TryReserveStart(out var second));
        var secondStop = fence.RecordStop();
        True(fence.TryReserveStart(out var third));
        var committed = false;

        True(firstStop.Includes(first));
        True(!firstStop.Includes(second));
        True(secondStop.Includes(first));
        True(secondStop.Includes(second));
        True(!secondStop.Includes(third));
        Equal(ReceiverLifecycleStartStatus.StopRequested, fence.StatusFor(first));
        Equal(ReceiverLifecycleStartStatus.StopRequested, fence.StatusFor(second));
        Equal(ReceiverLifecycleStartStatus.Allowed, fence.StatusFor(third));
        True(fence.TryCommitRunning(
            third,
            cancellationRequested: false,
            ownsStartup: true,
            () => committed = true));
        True(committed);
        return Task.CompletedTask;
    }

    private static Task TestLifecycleGenerationsAreMonotonicAsync()
    {
        var fence = new ReceiverLifecycleGenerationFence();
        for (var expected = 1L; expected <= 10_000; expected++)
        {
            True(fence.TryReserveStart(out var generation));
            Equal(expected, generation);
            if (expected % 7 == 0)
            {
                Equal(generation, fence.RecordStop().ThroughGeneration);
            }
        }

        return Task.CompletedTask;
    }

    private static Task TestLifecycleOlderStopDoesNotStopNewerStartAsync()
    {
        var fence = new ReceiverLifecycleGenerationFence();
        True(fence.TryReserveStart(out var oldGeneration));
        var oldStop = fence.RecordStop();
        True(fence.TryReserveStart(out var newerGeneration));
        var committed = false;

        True(oldStop.Includes(oldGeneration));
        True(!oldStop.Includes(newerGeneration));
        Equal(ReceiverLifecycleStartStatus.Allowed, fence.StatusFor(newerGeneration));
        True(fence.TryCommitRunning(
            newerGeneration,
            cancellationRequested: false,
            ownsStartup: true,
            () => committed = true));
        True(committed, "A stop request may only stop generations that existed when it was recorded.");
        return Task.CompletedTask;
    }

    private static Task TestActivityDispatcherAsync()
    {
        var callbacks = new Queue<Action>();
        var delivered = new List<ReceiverActivityEnvelope>();
        using var dispatcher = new ReceiverActivityDispatcher(
            callback =>
            {
                callbacks.Enqueue(callback);
                return true;
            },
            delivered.Add);

        for (var index = 0; index < 10_000; index++)
        {
            dispatcher.Post(ActivityEnvelope(4, "transferring", index));
        }

        Equal(1, callbacks.Count, "progress flood queued more than one UI callback");
        callbacks.Dequeue()();
        Equal(1, delivered.Count);
        Equal(9_999, delivered[0].Activity.CompletedFiles, "latest progress was not retained");
        Equal(0, callbacks.Count);

        dispatcher.Post(ActivityEnvelope(4, "transferring", 10_000));
        dispatcher.Post(ActivityEnvelope(4, "transferring", 10_001, "retryable error"));
        dispatcher.Post(ActivityEnvelope(4, "transferring", 10_002));
        Equal(1, callbacks.Count, "error activity queued a second UI callback");

        callbacks.Dequeue()();
        Equal("retryable error", delivered[^1].Activity.ErrorMessage);
        Equal(1, callbacks.Count, "post-error progress did not remain bounded behind the urgent callback");
        callbacks.Dequeue()();
        Equal(10_002, delivered[^1].Activity.CompletedFiles);

        var siblingJobId = Guid.NewGuid();
        dispatcher.Post(ActivityEnvelope(4, "transferring", 1, jobId: siblingJobId));
        dispatcher.Post(ActivityEnvelope(4, "planning", 0, jobId: siblingJobId));
        dispatcher.Post(ActivityEnvelope(4, "rejected", 0, jobId: siblingJobId));
        Equal(1, callbacks.Count, "sibling rejection queued concurrent UI callbacks");
        callbacks.Dequeue()();
        Equal("rejected", delivered[^1].Activity.State);
        Equal(1, callbacks.Count, "established sibling was lost behind rejection");
        callbacks.Dequeue()();
        Equal("transferring", delivered[^1].Activity.State,
            "rejected sibling erased the established dispatcher snapshot");

        dispatcher.Post(ActivityEnvelope(4, "transferring", 10_003));
        dispatcher.Post(ActivityEnvelope(4, "completed", 10_004));
        dispatcher.Post(ActivityEnvelope(4, "transferring", 10_005));
        var rejectedJobId = Guid.NewGuid();
        dispatcher.Post(ActivityEnvelope(4, "rejected", 0, jobId: rejectedJobId));
        Equal(1, callbacks.Count, "terminal activity queued a second UI callback");
        callbacks.Dequeue()();
        Equal("completed", delivered[^1].Activity.State);
        Equal(1, callbacks.Count, "rejection overwrote or lost its place behind terminal activity");
        callbacks.Dequeue()();
        Equal("rejected", delivered[^1].Activity.State);
        Equal(rejectedJobId, delivered[^1].Activity.JobId);
        Equal(0, callbacks.Count, "progress survived a terminal activity");

        var secondJobId = Guid.NewGuid();
        dispatcher.Post(ActivityEnvelope(4, "transferring", 1, jobId: secondJobId));
        Equal(1, callbacks.Count, "a later job in the same generation was suppressed");
        callbacks.Dequeue()();
        Equal(secondJobId, delivered[^1].Activity.JobId);
        dispatcher.Post(ActivityEnvelope(4, "transferring", 10_006));
        Equal(0, callbacks.Count, "late progress from a terminal job reached the UI queue");

        dispatcher.Post(ActivityEnvelope(3, "transferring", 1, "stale"));
        Equal(0, callbacks.Count, "a superseded generation reached the UI queue");
        dispatcher.Post(ActivityEnvelope(5, "transferring", 1));
        Equal(1, callbacks.Count);
        callbacks.Dequeue()();
        Equal(5L, delivered[^1].Generation);

        return Task.CompletedTask;
    }

    private static ReceiverActivityEnvelope ActivityEnvelope(
        long generation,
        string state,
        int completed,
        string? error = null,
        Guid? jobId = null) =>
        new(
            generation,
            new ReceiverActivity(
                jobId ?? Guid.Empty,
                state,
                completed,
                20_000,
                completed,
                null,
                1,
                error));

    private static async Task TestApplicationLifetimeAsync()
    {
        var order = new List<string>();
        var disposalRelease = new TaskCompletionSource<object?>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var disposalCalls = 0;
        var lifetime = new ApplicationLifetimeCoordinator(
            hideWindow: () => order.Add("hide"),
            disposeLifecycle: async () =>
            {
                Interlocked.Increment(ref disposalCalls);
                order.Add("dispose-start");
                await disposalRelease.Task;
                order.Add("dispose-end");
            },
            cleanupApplicationResources: () => order.Add("cleanup"),
            reportError: exception => order.Add("error:" + exception.Message),
            shutdown: () => order.Add("shutdown"));

        True(lifetime.HandleCloseRequested(), "ordinary close was not canceled for tray lifetime");
        Equal(1, order.Count(static item => item == "hide"));

        var firstExit = lifetime.ExitAsync();
        var duplicateExit = lifetime.ExitAsync();
        True(ReferenceEquals(firstExit, duplicateExit), "duplicate exit did not share the in-flight task");
        True(lifetime.IsExiting);
        True(!lifetime.HandleCloseRequested(), "close was canceled after explicit exit took ownership");
        Equal(1, order.Count(static item => item == "hide"), "exit-time close hid the window again");
        Equal(1, disposalCalls);
        True(!order.Contains("cleanup"), "tray resources were cleaned before lifecycle disposal completed");
        True(!order.Contains("shutdown"), "shutdown ran before lifecycle disposal completed");

        disposalRelease.SetResult(null);
        await Task.WhenAll(firstExit, duplicateExit);
        Equal(
            "hide,dispose-start,dispose-end,cleanup,shutdown",
            string.Join(',', order),
            "application exit sequence was not durable and ordered");
        Equal(1, disposalCalls, "lifecycle disposal ran more than once");
    }

    private static async Task TestApplicationLifetimeFailureAsync()
    {
        var order = new List<string>();
        var failure = new InvalidOperationException("startup disposal failed");
        var lifetime = new ApplicationLifetimeCoordinator(
            hideWindow: () => order.Add("hide"),
            disposeLifecycle: () =>
            {
                order.Add("dispose");
                return ValueTask.FromException(failure);
            },
            cleanupApplicationResources: () => order.Add("cleanup"),
            reportError: exception => order.Add("error:" + exception.Message),
            shutdown: () => order.Add("shutdown"));

        await lifetime.ExitAsync();
        Equal(
            "dispose,error:startup disposal failed,cleanup,shutdown",
            string.Join(',', order),
            "disposal failure prevented ordered cleanup and shutdown");
    }

    private static async Task TestBackgroundDiagnosticsAsync()
    {
        var root = TempDirectory();
        var provider = new RedactingFileLoggerProvider(root);
        try
        {
            var logger = provider.CreateLogger("test");
            var enqueueTimer = System.Diagnostics.Stopwatch.StartNew();
            for (var index = 0; index < 50_000; index++)
            {
                logger.LogInformation("low priority diagnostic event {Index} with bounded padding xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", index);
            }
            enqueueTimer.Stop();
            True(enqueueTimer.Elapsed < TimeSpan.FromSeconds(2),
                $"diagnostic producers blocked for {enqueueTimer.Elapsed}");

            // The queue should reserve/coalesce urgent diagnostics even when a
            // low-priority flood has filled every ordinary slot.
            logger.LogError("urgent-marker token=secret filename=private.jpg latitude=44.1");
            try
            {
                ThrowDiagnosticFailureWithPrivateMessage();
            }
            catch (Exception exception)
            {
                logger.LogCritical(exception, "managed-crash-marker");
            }

            var exported = Path.Combine(root, "export.log");
            await provider.ExportAsync(exported);
            var contents = await File.ReadAllTextAsync(exported);
            True(contents.Contains("urgent-marker", StringComparison.Ordinal));
            True(contents.Contains("token=[redacted]", StringComparison.Ordinal));
            True(contents.Contains("filename=[redacted]", StringComparison.Ordinal));
            True(contents.Contains("latitude=[redacted]", StringComparison.Ordinal));
            True(!contents.Contains("secret", StringComparison.Ordinal));
            True(!contents.Contains("private.jpg", StringComparison.Ordinal));
            True(contents.Contains("managed-crash-marker", StringComparison.Ordinal));
            True(contents.Contains("System.InvalidOperationException", StringComparison.Ordinal));
            True(contents.Contains(nameof(ThrowDiagnosticFailureWithPrivateMessage), StringComparison.Ordinal));
            True(!contents.Contains("private-exception-message", StringComparison.Ordinal));
            True(new FileInfo(provider.LogPath).Length <= (2 * 1024 * 1024) + (64 * 1024),
                "the bounded current diagnostic log exceeded its rotation allowance");
        }
        finally
        {
            await provider.DisposeAsync();
            Directory.Delete(root, true);
        }
    }

    private static void ThrowDiagnosticFailureWithPrivateMessage() =>
        throw new InvalidOperationException("private-exception-message filename=private.jpg");

    private static async Task TestHundredThousandAssetFinalizationAsync()
    {
        const int assetCount = 100_000;
        const long maximumManagedBytes = 3_000L * 1024 * 1024;
        var elapsed = System.Diagnostics.Stopwatch.StartNew();
        long maximumManaged = GC.GetTotalMemory(false);
        using var monitorCancellation = new CancellationTokenSource();
        var monitor = Task.Run(async () =>
        {
            try
            {
                while (true)
                {
                    ObserveMaximum(ref maximumManaged, GC.GetTotalMemory(false));
                    await Task.Delay(25, monitorCancellation.Token);
                }
            }
            catch (OperationCanceledException) when (monitorCancellation.IsCancellationRequested)
            {
            }
        });

        try
        {
            await using var context = await TestContext.CreateAsync();
            var jobId = await CreateStressJobAsync(context, assetCount);
            await MarkStressFilesCommittedAsync(context.Destination.DatabasePath, jobId);

            var report = await context.Coordinator.CompleteAsync(
                jobId,
                new CompleteJobRequest(DateTimeOffset.UtcNow));
            Equal(assetCount, report.Counts.AssetsPlanned);
            Equal(assetCount, report.Counts.FilesPlanned);
            Equal(assetCount, report.Counts.FilesCommitted);
            Equal(0, report.Counts.FilesFailed);

            var reportPath = Path.Combine(context.Destination.ReportsPath, jobId.ToString("D") + ".json");
            True(new FileInfo(reportPath).Length < 64 * 1024,
                "the completion report unexpectedly materialized asset history");
            await using (var reportStream = new FileStream(
                reportPath,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                64 * 1024,
                FileOptions.Asynchronous | FileOptions.SequentialScan))
            {
                var streamedReport = await JsonSerializer.DeserializeAsync<CompletionReport>(
                    reportStream,
                    JsonOptions);
                Equal(assetCount, streamedReport?.Counts.FilesCommitted ?? -1);
            }

            var pointer = JsonSerializer.Deserialize<CatalogPointer>(
                await File.ReadAllTextAsync(Path.Combine(context.Destination.CatalogPath, "current.json")), JsonOptions)!;
            var assetsPath = context.PathPolicy.ResolveUnderRoot(context.Root, pointer.AssetsRelativePath);
            Equal((long)assetCount, await CountLinesAsync(assetsPath));
            True(new FileInfo(assetsPath).Length > assetCount,
                "the asset manifest was not populated");
            True(!Directory.EnumerateFiles(
                    context.Destination.MasterPath,
                    "*",
                    SearchOption.AllDirectories).Any(),
                "the metadata stress test must not create payload files");
            True(!Directory.EnumerateFiles(
                    context.Destination.ControlPath,
                    "manifest-build-*",
                    SearchOption.TopDirectoryOnly).Any(),
                "streaming finalization left a scratch manifest index behind");

            ObserveMaximum(ref maximumManaged, GC.GetTotalMemory(false));
            True(Volatile.Read(ref maximumManaged) < maximumManagedBytes,
                $"managed memory peaked at {Volatile.Read(ref maximumManaged):N0} bytes");
            True(elapsed.Elapsed < TimeSpan.FromMinutes(5),
                $"100,000-asset finalization took {elapsed.Elapsed}");
        }
        finally
        {
            monitorCancellation.Cancel();
            await monitor;
        }
    }

    private static async Task TestCompletedLedgerStreamingAsync()
    {
        await using var context = await TestContext.CreateAsync();
        var ids = new StableIds();
        var template = Job(Array.Empty<byte>(), ids, Guid.NewGuid(), new string('b', 64));
        var templateAsset = template.Assets.Single();
        var files = Enumerable.Range(0, 17)
            .Select(index => index == 0
                ? templateAsset.Files.Single() with
                {
                    OriginalFilename = $"stream-{index:D2}.jpg",
                    ProposedRelativePath = $"Master/stream/{index:D2}.jpg",
                }
                : templateAsset.Files.Single() with
                {
                    FileId = Guid.NewGuid(),
                    StorageArea = StorageArea.LibraryData,
                    Roles = new[] { RepresentationRole.Auxiliary },
                    Criticality = Criticality.Optional,
                    OriginalFilename = $"stream-{index:D2}.jpg",
                    ProposedRelativePath = $"MB Photos Data/Resources/{templateAsset.AssetId:D}/stream-{index:D2}.jpg",
                })
            .ToArray();
        var job = template with { Assets = new[] { templateAsset with { Files = files } } };
        await context.Coordinator.CreateJobAsync(job);
        foreach (var file in files)
        {
            await context.Coordinator.CommitAsync(
                job.JobId,
                file.FileId,
                new CommitFileRequest(0, HashOfEmptyFile));
        }
        await context.Coordinator.CompleteAsync(job.JobId, new CompleteJobRequest(DateTimeOffset.UtcNow));

        var callbackCount = 0;
        var firstCount = 0;
        var lastCount = 0;
        var maximumBatch = 0;
        var streamedFiles = new List<Guid>();
        await context.Ledger.StreamCompletedJobsAsync(
            (batch, _) =>
            {
                Equal(job.JobId, batch.Job.JobId);
                callbackCount++;
                firstCount += batch.IsFirst ? 1 : 0;
                lastCount += batch.IsLast ? 1 : 0;
                maximumBatch = Math.Max(maximumBatch, batch.Files.Count);
                streamedFiles.AddRange(batch.Files.Select(static file => file.FileId));
                return Task.CompletedTask;
            },
            fileBatchSize: 3);

        Equal(6, callbackCount);
        Equal(1, firstCount);
        Equal(1, lastCount);
        True(maximumBatch <= 3, "the completed ledger snapshot exceeded its requested batch bound");
        True(files.Select(static file => file.FileId).SequenceEqual(streamedFiles),
            "the completed ledger snapshot did not preserve frozen file order");
    }

    private static async Task TestPortableTransitionsAndExportsAsync()
    {
        await using var context = await TestContext.CreateAsync();
        var assetId = Guid.NewGuid();
        var originalId = Guid.NewGuid();
        var editedId = Guid.NewGuid();
        var originalBytes = Encoding.UTF8.GetBytes("untouched original bytes");
        var editedBytes = Encoding.UTF8.GetBytes("full-size edited bytes");
        const string masterPath = "Master/2026/2026-08/2026-08-24/photo.jpg";
        var resourcePath = $"MB Photos Data/Resources/{assetId:D}/{originalId:D}.jpg";

        var originalMaster = PortableFile(
            originalId,
            assetId,
            new string('1', 64),
            StorageArea.Master,
            new[] { RepresentationRole.MasterCurrent, RepresentationRole.RootOriginal },
            Criticality.MasterRequired,
            "photo.jpg",
            masterPath,
            originalBytes);
        var first = PortableJob(assetId, new string('a', 64), false, new[] { originalMaster }, originalId);
        await context.Coordinator.CreateJobAsync(first);
        await UploadAndCommitAsync(context, first, originalId, originalBytes);
        await context.Coordinator.CompleteAsync(first.JobId, new CompleteJobRequest(DateTimeOffset.UtcNow));

        var archivedOriginal = originalMaster with
        {
            StorageArea = StorageArea.LibraryData,
            Roles = new[] { RepresentationRole.RootOriginal },
            Criticality = Criticality.ArchiveRequired,
            ProposedRelativePath = resourcePath,
        };
        var editedMaster = PortableFile(
            editedId,
            assetId,
            new string('2', 64),
            StorageArea.Master,
            new[] { RepresentationRole.MasterCurrent },
            Criticality.MasterRequired,
            "photo.jpg",
            masterPath,
            editedBytes,
            "fullSizePhoto");
        var second = PortableJob(
            assetId,
            new string('b', 64),
            true,
            new[] { archivedOriginal, editedMaster },
            editedId);
        var secondPlan = await context.Coordinator.CreateJobAsync(second);
        Equal(JobFileAction.Skip, secondPlan.Decisions.Single(decision => decision.FileId == originalId).Action);
        Equal(JobFileAction.Upload, secondPlan.Decisions.Single(decision => decision.FileId == editedId).Action);
        await UploadAndCommitAsync(context, second, editedId, editedBytes);
        await context.Coordinator.CompleteAsync(second.JobId, new CompleteJobRequest(DateTimeOffset.UtcNow));

        var masters = Directory.EnumerateFiles(context.Destination.MasterPath, "*", SearchOption.AllDirectories).ToArray();
        Equal(1, masters.Length);
        Equal(Sha(editedBytes), await Hashing.Sha256FileAsync(masters[0]));
        var archivedPath = context.PathPolicy.ResolveUnderRoot(context.Root, resourcePath);
        Equal(Sha(originalBytes), await Hashing.Sha256FileAsync(archivedPath));

        var library = await new PortableLibraryService().OpenAsync(context.Root);
        var libraryAsset = library.Assets.Single(asset => asset.AssetId == assetId);
        True(libraryAsset.AvailableVariants.Contains(VariantKind.CurrentMaster));
        True(libraryAsset.AvailableVariants.Contains(VariantKind.RootOriginal));
        var exportDirectory = TempDirectory();
        try
        {
            var exporter = new VariantExportService();
            var exported = await exporter.ExportAsync(library, assetId, VariantKind.RootOriginal, exportDirectory);
            Equal(Sha(originalBytes), exported.Sha256);
            Equal(Sha(originalBytes), await Hashing.Sha256FileAsync(exported.ExportedPath));
            var rootVariant = libraryAsset.Files.Single(file => file.Catalog.Roles.Contains(RepresentationRole.RootOriginal));
            await ThrowsAsync<InvalidOperationException>(() =>
                exporter.ExportAsync(rootVariant, context.Destination.MasterPath));

            var linkedExportRoot = TempDirectory();
            var linkedIntoLibrary = Path.Combine(linkedExportRoot, "linked-master");
            try
            {
                Directory.CreateSymbolicLink(linkedIntoLibrary, context.Destination.MasterPath);
                await ThrowsAsync<InvalidOperationException>(() =>
                    exporter.ExportAsync(rootVariant, linkedIntoLibrary));
            }
            finally
            {
                if (Directory.Exists(linkedIntoLibrary) || File.Exists(linkedIntoLibrary))
                {
                    Directory.Delete(linkedIntoLibrary);
                }
                Directory.Delete(linkedExportRoot, true);
            }
        }
        finally
        {
            Directory.Delete(exportDirectory, true);
        }

        var revertedMaster = originalMaster with { ProposedRelativePath = masterPath };
        var conflictedRevert = PortableJob(assetId, new string('c', 64), false, new[] { revertedMaster }, originalId);
        var conflictedPlan = await context.Coordinator.CreateJobAsync(conflictedRevert);
        Equal(JobFileAction.Skip, conflictedPlan.Decisions.Single().Action);
        var acceptedRevertPath = conflictedPlan.Decisions.Single().AcceptedRelativePath!;
        var occupiedRevertPath = context.PathPolicy.ResolveUnderRoot(context.Root, acceptedRevertPath);
        Directory.CreateDirectory(Path.GetDirectoryName(occupiedRevertPath)!);
        var unrelatedBytes = Encoding.UTF8.GetBytes("unrelated external collision");
        await File.WriteAllBytesAsync(occupiedRevertPath, unrelatedBytes);
        var conflictReport = await context.Coordinator.CompleteAsync(
            conflictedRevert.JobId,
            new CompleteJobRequest(DateTimeOffset.UtcNow));
        Equal("completedWithFailures", conflictReport.State);
        Equal(ErrorCodes.MasterConflict, conflictReport.Failures.Single().Code);
        Equal(Sha(unrelatedBytes), await Hashing.Sha256FileAsync(occupiedRevertPath));
        Equal(Sha(originalBytes), await Hashing.Sha256FileAsync(archivedPath));
        masters = Directory.EnumerateFiles(context.Destination.MasterPath, "*", SearchOption.AllDirectories).ToArray();
        True(masters.Any(path => Hashing.Sha256FileAsync(path).GetAwaiter().GetResult() == Sha(editedBytes)));

        File.Delete(occupiedRevertPath);
        var successfulRevert = PortableJob(assetId, new string('d', 64), false, new[] { revertedMaster }, originalId);
        var successfulPlan = await context.Coordinator.CreateJobAsync(successfulRevert);
        Equal(JobFileAction.Skip, successfulPlan.Decisions.Single().Action);
        await context.Coordinator.CompleteAsync(successfulRevert.JobId, new CompleteJobRequest(DateTimeOffset.UtcNow));

        masters = Directory.EnumerateFiles(context.Destination.MasterPath, "*", SearchOption.AllDirectories).ToArray();
        Equal(1, masters.Length);
        Equal(Sha(originalBytes), await Hashing.Sha256FileAsync(masters[0]));
        True(!File.Exists(archivedPath),
            "the verified Resources duplicate should be removed only after successful Master activation and catalog publish");
    }

    private static async Task TestLiveMotionRevisionCleanupAsync()
    {
        await using var context = await TestContext.CreateAsync();
        var assetId = Guid.NewGuid();
        var masterId = Guid.NewGuid();
        var motionId = Guid.NewGuid();
        var masterBytes = Encoding.UTF8.GetBytes("stable live still");
        var masterPath = "Master/2026/2026-08/2026-08-24/live.jpg";
        var motionPath = $"MB Photos Data/Resources/{assetId:D}/current.mov";

        async Task SyncAsync(char revision, byte[] motionBytes, bool first)
        {
            var master = PortableFile(
                masterId,
                assetId,
                new string('4', 64),
                StorageArea.Master,
                new[] { RepresentationRole.MasterCurrent, RepresentationRole.RootOriginal },
                Criticality.MasterRequired,
                "live.jpg",
                masterPath,
                masterBytes);
            var motion = PortableFile(
                motionId,
                assetId,
                new string(revision, 64),
                StorageArea.LibraryData,
                new[] { RepresentationRole.CurrentLiveMotion },
                Criticality.ArchiveRequired,
                "live.mov",
                motionPath,
                motionBytes,
                "fullSizePairedVideo",
                "video/quicktime");
            var job = PortableJob(
                assetId,
                new string(revision, 64),
                true,
                new[] { master, motion },
                masterId,
                new LivePhotoRelationships(masterId, motionId, masterId, null));
            var plan = await context.Coordinator.CreateJobAsync(job);
            if (first)
            {
                await UploadAndCommitAsync(context, job, masterId, masterBytes);
            }
            else
            {
                Equal(JobFileAction.Skip, plan.Decisions.Single(decision => decision.FileId == masterId).Action);
            }
            Equal(JobFileAction.Upload, plan.Decisions.Single(decision => decision.FileId == motionId).Action);
            await UploadAndCommitAsync(context, job, motionId, motionBytes);
            await context.Coordinator.CompleteAsync(job.JobId, new CompleteJobRequest(DateTimeOffset.UtcNow));
            var motions = Directory.EnumerateFiles(context.Destination.ResourcesPath, "*.mov", SearchOption.AllDirectories).ToArray();
            Equal(1, motions.Length);
            Equal(Sha(motionBytes), await Hashing.Sha256FileAsync(motions[0]));
        }

        await SyncAsync('5', Encoding.UTF8.GetBytes("motion edit one"), true);
        await SyncAsync('6', Encoding.UTF8.GetBytes("motion edit two"), false);
        await SyncAsync('7', Encoding.UTF8.GetBytes("motion edit three"), false);
    }

    private static async Task TestMasterConflictPreservesPriorAsync()
    {
        await using var context = await TestContext.CreateAsync();
        var assetId = Guid.NewGuid();
        var originalId = Guid.NewGuid();
        var originalBytes = Encoding.UTF8.GetBytes("cataloged Master");
        var masterPath = "Master/2026/2026-08/2026-08-24/conflict.jpg";
        var original = PortableFile(
            originalId,
            assetId,
            new string('8', 64),
            StorageArea.Master,
            new[] { RepresentationRole.MasterCurrent, RepresentationRole.RootOriginal },
            Criticality.MasterRequired,
            "conflict.jpg",
            masterPath,
            originalBytes);
        var first = PortableJob(assetId, new string('8', 64), false, new[] { original }, originalId);
        await context.Coordinator.CreateJobAsync(first);
        await UploadAndCommitAsync(context, first, originalId, originalBytes);
        await context.Coordinator.CompleteAsync(first.JobId, new CompleteJobRequest(DateTimeOffset.UtcNow));

        var physicalMaster = Directory.EnumerateFiles(context.Destination.MasterPath, "*", SearchOption.AllDirectories).Single();
        var externalBytes = Encoding.UTF8.GetBytes("user changed this outside the app");
        await File.WriteAllBytesAsync(physicalMaster, externalBytes);

        var editedId = Guid.NewGuid();
        var editedBytes = Encoding.UTF8.GetBytes("new phone edit");
        var edited = PortableFile(
            editedId,
            assetId,
            new string('9', 64),
            StorageArea.Master,
            new[] { RepresentationRole.MasterCurrent },
            Criticality.MasterRequired,
            "conflict.jpg",
            masterPath,
            editedBytes,
            "fullSizePhoto");
        var second = PortableJob(assetId, new string('9', 64), true, new[] { edited }, editedId);
        await context.Coordinator.CreateJobAsync(second);
        await UploadAndCommitAsync(context, second, editedId, editedBytes);
        var report = await context.Coordinator.CompleteAsync(second.JobId, new CompleteJobRequest(DateTimeOffset.UtcNow));
        Equal("completedWithFailures", report.State);
        Equal(ErrorCodes.MasterConflict, report.Failures.Single().Code);
        Equal(Sha(externalBytes), await Hashing.Sha256FileAsync(physicalMaster));
        True(!Directory.EnumerateFiles(context.Destination.MasterPath, "*", SearchOption.AllDirectories)
            .Any(path => Hashing.Sha256FileAsync(path).GetAwaiter().GetResult() == Sha(editedBytes)));
        var library = await new PortableLibraryService().OpenAsync(context.Root);
        Equal(first.Assets.Single().SourceRevision, library.Assets.Single().Catalog.SourceRevision);
    }

    private static async Task TestTerminalCatalogRecoveryAsync()
    {
        await using var context = await TestContext.CreateAsync();
        var bytes = Encoding.UTF8.GetBytes("catalog recovery");
        var job = Job(bytes, new StableIds(), Guid.NewGuid(), new string('a', 64));
        await context.Coordinator.CreateJobAsync(job);
        await UploadAndCommitAsync(context, job, job.Assets.Single().MasterFileId!.Value, bytes);
        var report = await context.Coordinator.CompleteAsync(job.JobId, new CompleteJobRequest(DateTimeOffset.UtcNow));
        File.Delete(context.PathPolicy.ResolveUnderRoot(context.Root, report.CatalogGeneration.AssetsRelativePath));
        File.Delete(context.PathPolicy.ResolveUnderRoot(context.Root, report.CatalogGeneration.AlbumsRelativePath));
        File.Delete(context.PathPolicy.ResolveUnderRoot(context.Root, report.CatalogGeneration.CatalogPointerRelativePath));
        File.Delete(context.PathPolicy.ResolveUnderRoot(context.Root, report.ReportRelativePath));

        var status = await context.Coordinator.GetStatusAsync(job.JobId);
        Equal(JobState.Completed, status.State);
        True(File.Exists(context.PathPolicy.ResolveUnderRoot(context.Root, report.CatalogGeneration.AssetsRelativePath)));
        True(File.Exists(context.PathPolicy.ResolveUnderRoot(context.Root, report.CatalogGeneration.AlbumsRelativePath)));
        True(File.Exists(context.PathPolicy.ResolveUnderRoot(context.Root, report.CatalogGeneration.CatalogPointerRelativePath)));
        True(File.Exists(context.PathPolicy.ResolveUnderRoot(context.Root, report.ReportRelativePath)));
    }

    private static async Task TestActivatedPromotionRetryAsync()
    {
        await using var context = await TestContext.CreateAsync();
        var bytes = Encoding.UTF8.GetBytes("activated before finalize");
        var job = Job(bytes, new StableIds(), Guid.NewGuid(), new string('b', 64));
        await context.Coordinator.CreateJobAsync(job);
        await UploadAndCommitAsync(context, job, job.Assets.Single().MasterFileId!.Value, bytes);
        var promotion = new MasterPromotionService(context.Destination, context.Ledger, context.PathPolicy, JsonOptions);
        var failures = await promotion.PromoteAsync(job, await context.Ledger.GetJobFilesAsync(job.JobId));
        Equal(0, failures.Count);
        True(!File.Exists(Partial(context, job.JobId, job.Assets.Single().MasterFileId!.Value)));

        var report = await context.Coordinator.CompleteAsync(job.JobId, new CompleteJobRequest(DateTimeOffset.UtcNow));
        Equal("completed", report.State);
    }

    private static async Task TestUnavailableMasterPlaceholderAsync()
    {
        await using var context = await TestContext.CreateAsync();
        var assetId = Guid.NewGuid();
        var placeholderId = Guid.NewGuid();
        var placeholder = PortableFile(
            placeholderId,
            assetId,
            new string('c', 64),
            StorageArea.Master,
            new[] { RepresentationRole.MasterCurrent },
            Criticality.MasterRequired,
            "missing.heic",
            "Master/2026/2026-08/2026-08-24/missing.heic",
            null,
            "fullSizePhoto",
            "image/heic",
            Availability.SourceUnavailable);
        var job = PortableJob(assetId, new string('c', 64), true, new[] { placeholder }, null);
        var plan = await context.Coordinator.CreateJobAsync(job);
        var decision = plan.Decisions.Single();
        Equal(JobFileAction.Conflict, decision.Action);
        Equal("sourceUnavailable", decision.Reason);
        True(decision.AcceptedRelativePath is null);
        var report = await context.Coordinator.CompleteAsync(
            job.JobId,
            new CompleteJobRequest(
                DateTimeOffset.UtcNow,
                new[] { new CompletionFailure(placeholderId, ErrorCodes.UnavailableSource, "Missing full-size current resource.", false) }));
        Equal("completedWithFailures", report.State);
        Equal(0, report.Counts.AssetsPromoted);
        Equal(0, report.Counts.AssetsArchiveIncomplete);
        var library = await new PortableLibraryService().OpenAsync(context.Root);
        var catalogAsset = library.Assets.Single().Catalog;
        True(catalogAsset.MasterFileId is null);
        Equal(ArchiveState.Complete, catalogAsset.ArchiveState);
        Equal(Availability.SourceUnavailable, catalogAsset.Files.Single().Availability);
    }

    private static async Task TestV1DestinationRejectedAsync()
    {
        var root = TempDirectory();
        try
        {
            var control = Path.Combine(root, ".mbphotos");
            Directory.CreateDirectory(control);
            var descriptor = Path.Combine(control, "destination.json");
            await File.WriteAllTextAsync(descriptor,
                "{\"destinationId\":\"11111111-1111-4111-8111-111111111111\",\"createdAt\":\"2026-01-01T00:00:00Z\",\"formatVersion\":1,\"pathPolicyVersion\":1}");
            var before = await File.ReadAllBytesAsync(descriptor);
            await ThrowsAsync<InvalidDataException>(() =>
                new DestinationManager(JsonOptions).OpenOrInitializeAsync(root, true));
            var after = await File.ReadAllBytesAsync(descriptor);
            True(before.SequenceEqual(after));
            True(!Directory.Exists(Path.Combine(root, DestinationContext.DataDirectoryName)));
        }
        finally
        {
            Directory.Delete(root, true);
        }
    }

    private static async Task TestCoordinatorActivityIsolationAsync()
    {
        await using var context = await TestContext.CreateAsync();
        using var observerEntered = new ManualResetEventSlim();
        using var releaseObserver = new ManualResetEventSlim();
        context.Coordinator.ActivityChanged += (_, _) =>
        {
            observerEntered.Set();
            releaseObserver.Wait(TimeSpan.FromSeconds(5));
        };

        try
        {
            var job = Job(
                Encoding.UTF8.GetBytes("observer isolation"),
                new StableIds(),
                Guid.NewGuid(),
                new string('d', 64));
            var createTask = context.Coordinator.CreateJobAsync(job);
            var completed = await Task.WhenAny(createTask, Task.Delay(TimeSpan.FromSeconds(2)));
            True(ReferenceEquals(completed, createTask), "a receiver activity observer blocked CreateJobAsync");
            await createTask;
            True(observerEntered.Wait(TimeSpan.FromSeconds(2)), "the asynchronous activity drain did not run");
        }
        finally
        {
            releaseObserver.Set();
        }
    }

    private static async Task TestCoordinatorActivityGateReleaseAsync()
    {
        const int jobCount = 8;
        const int activitiesPerJob = 2;
        await using var context = await TestContext.CreateAsync();
        var planningGate = (SemaphoreSlim?)typeof(JobCoordinator)
            .GetField("planningGate", BindingFlags.Instance | BindingFlags.NonPublic)?
            .GetValue(context.Coordinator)
            ?? throw new InvalidOperationException("The coordinator planning gate could not be inspected.");
        using var observerEntered = new ManualResetEventSlim();
        using var activitiesObserved = new CountdownEvent(jobCount * activitiesPerJob);
        var competingOperations = new ConcurrentQueue<Task>();
        var observerEnteredWithGateHeld = 0;
        context.Coordinator.ActivityChanged += (_, _) =>
        {
            // Start a new operation at the callback boundary. It must be held
            // outside planningGate until this observer returns; otherwise the
            // callback and a coordinator mutation can overlap.
            competingOperations.Enqueue(ProbeMissingJobAsync(context.Coordinator));
            if (!planningGate.Wait(0))
            {
                Interlocked.Exchange(ref observerEnteredWithGateHeld, 1);
            }
            else
            {
                planningGate.Release();
            }

            observerEntered.Set();
            activitiesObserved.Signal();
        };

        await planningGate.WaitAsync();
        Task<JobPlan>? createTask = null;
        try
        {
            var job = Job(
                Encoding.UTF8.GetBytes("gate release ordering"),
                new StableIds(),
                Guid.NewGuid(),
                new string('e', 64));
            createTask = context.Coordinator.CreateJobAsync(job);
            True(!observerEntered.Wait(TimeSpan.FromMilliseconds(500)),
                "an activity observer ran while the planning gate was held");
        }
        finally
        {
            planningGate.Release();
        }

        await (createTask ?? throw new InvalidOperationException("The job creation task was not started."));
        for (var index = 1; index < jobCount; index++)
        {
            await context.Coordinator.CreateJobAsync(Job(
                Encoding.UTF8.GetBytes($"gate release ordering {index}"),
                new StableIds(),
                Guid.NewGuid(),
                new string('e', 64)));
        }

        True(observerEntered.Wait(TimeSpan.FromSeconds(2)),
            "the activity observer did not run after the planning gate was released");
        True(activitiesObserved.Wait(TimeSpan.FromSeconds(5)),
            "not all queued activity callbacks were delivered");
        await Task.WhenAll(competingOperations.ToArray());
        Equal(0, Volatile.Read(ref observerEnteredWithGateHeld));
    }

    private static async Task ProbeMissingJobAsync(JobCoordinator coordinator)
    {
        var exception = await ThrowsAsync<ReceiverApiException>(() =>
            coordinator.AbandonAsync(Guid.NewGuid(), null));
        Equal(ErrorCodes.JobNotFound, exception.Error.Code);
    }

    private static async Task TestDestinationAndLedgerAsync()
    {
        await using var context = await TestContext.CreateAsync();
        True(File.Exists(Path.Combine(context.Destination.ControlPath, "destination.json")));
        True(File.Exists(Path.Combine(context.Destination.ControlPath, "ledger.sqlite")));
        True(File.Exists(Path.Combine(context.Destination.DataPath, "library.json")));
        var reopened = await context.DestinationManager.OpenOrInitializeAsync(context.Root, false);
        Equal(context.Destination.Info.DestinationId, reopened.Info.DestinationId);
    }

    private static async Task TestLedgerV2MigrationAsync()
    {
        var root = TempDirectory();
        var databasePath = Path.Combine(root, "ledger.sqlite");
        var jobId = Guid.NewGuid();
        var pendingFileId = Guid.NewGuid();
        var committedFileId = Guid.NewGuid();
        var corruptFileId = Guid.NewGuid();
        var now = DateTimeOffset.UtcNow.ToUniversalTime().ToString("O");
        try
        {
            await using (var connection = new SqliteConnection(new SqliteConnectionStringBuilder
            {
                DataSource = databasePath,
                Pooling = false,
            }.ToString()))
            {
                await connection.OpenAsync();
                var command = connection.CreateCommand();
                command.CommandText = """
                    CREATE TABLE jobs (
                        job_id TEXT PRIMARY KEY,created_at TEXT NOT NULL,updated_at TEXT NOT NULL,
                        state TEXT NOT NULL,manifest_json TEXT NOT NULL,completed_at TEXT NULL,
                        abandon_reason TEXT NULL,abandon_removed_partial_files INTEGER NULL,
                        completion_request_json TEXT NULL,report_json TEXT NULL);
                    CREATE TABLE files (
                        job_id TEXT NOT NULL,file_id TEXT NOT NULL,asset_id TEXT NOT NULL,
                        source_revision TEXT NOT NULL,kind TEXT NOT NULL,proposed_path TEXT NOT NULL,
                        relative_path TEXT NOT NULL,original_filename TEXT NOT NULL,capture_date TEXT NULL,
                        expected_bytes INTEGER NULL,expected_sha256 TEXT NULL,state TEXT NOT NULL,
                        committed_sha256 TEXT NULL,committed_bytes INTEGER NULL,committed_at TEXT NULL,
                        observed_write_ticks INTEGER NULL,bytes_transferred INTEGER NOT NULL DEFAULT 0,
                        PRIMARY KEY(job_id,file_id));
                    CREATE TABLE chunks (
                        job_id TEXT NOT NULL,file_id TEXT NOT NULL,chunk_index INTEGER NOT NULL,
                        byte_offset INTEGER NOT NULL,byte_length INTEGER NOT NULL,total_bytes INTEGER NOT NULL,
                        sha256 TEXT NOT NULL,received_at TEXT NOT NULL,
                        PRIMARY KEY(job_id,file_id,chunk_index));
                    CREATE TABLE failures (
                        job_id TEXT NOT NULL,file_id TEXT NOT NULL,code TEXT NOT NULL,message TEXT NOT NULL,
                        retryable INTEGER NOT NULL,occurred_at TEXT NOT NULL);
                    PRAGMA user_version=2;
                    """;
                await command.ExecuteNonQueryAsync();

                command.CommandText = """
                    INSERT INTO jobs(job_id,created_at,updated_at,state,manifest_json)
                    VALUES($job,$now,$now,'transferring','{}');
                    INSERT INTO files(
                        job_id,file_id,asset_id,source_revision,kind,proposed_path,relative_path,
                        original_filename,state,bytes_transferred)
                    VALUES($job,$pending,$asset1,'revision','originalResource','a.jpg','a.jpg','a.jpg','pending',1),
                          ($job,$committed,$asset2,'revision','originalResource','b.jpg','b.jpg','b.jpg','committed',0),
                          ($job,$corrupt,$asset3,'revision','originalResource','c.jpg','c.jpg','c.jpg','pending',999);
                    INSERT INTO chunks(job_id,file_id,chunk_index,byte_offset,byte_length,total_bytes,sha256,received_at)
                    VALUES($job,$pending,0,0,$chunkSize,$total,$sha,$now),
                          ($job,$pending,1,$chunkSize,3,$total,$sha,$now),
                          ($job,$corrupt,1,$chunkSize,3,$total,$sha,$now);
                    INSERT INTO failures(job_id,file_id,code,message,retryable,occurred_at)
                    VALUES($job,$pending,'hashMismatch','retry',1,$now);
                    UPDATE files SET committed_sha256=$sha,committed_bytes=10,committed_at=$now
                    WHERE job_id=$job AND file_id=$committed;
                    """;
                command.Parameters.AddWithValue("$job", jobId.ToString("D"));
                command.Parameters.AddWithValue("$now", now);
                command.Parameters.AddWithValue("$pending", pendingFileId.ToString("D"));
                command.Parameters.AddWithValue("$committed", committedFileId.ToString("D"));
                command.Parameters.AddWithValue("$corrupt", corruptFileId.ToString("D"));
                command.Parameters.AddWithValue("$asset1", Guid.NewGuid().ToString("D"));
                command.Parameters.AddWithValue("$asset2", Guid.NewGuid().ToString("D"));
                command.Parameters.AddWithValue("$asset3", Guid.NewGuid().ToString("D"));
                command.Parameters.AddWithValue("$chunkSize", ProtocolConstants.ChunkSize);
                command.Parameters.AddWithValue("$total", ProtocolConstants.ChunkSize + 3L);
                command.Parameters.AddWithValue("$sha", new string('a', 64));
                await command.ExecuteNonQueryAsync();
            }

            await using var ledger = new Ledger(databasePath);
            await ledger.InitializeAsync();
            var chunkState = await ledger.GetChunkStateAsync(jobId, pendingFileId, 1)
                ?? throw new InvalidOperationException("The migrated chunk state is missing.");
            Equal(2, chunkState.NextChunkIndex);
            Equal(ProtocolConstants.ChunkSize + 3L, chunkState.TotalBytes);
            Equal(ProtocolConstants.ChunkSize + 3L, chunkState.BytesTransferred);
            Equal(1, chunkState.RequestedChunk?.ChunkIndex ?? -1);
            var recoveredState = await ledger.GetChunkStateAsync(jobId, corruptFileId, 0)
                ?? throw new InvalidOperationException("The recovered chunk state is missing.");
            Equal(0, recoveredState.NextChunkIndex);
            True(recoveredState.TotalBytes is null);
            Equal(0L, recoveredState.BytesTransferred);

            var stats = await ledger.GetStatsAsync(jobId);
            Equal(3, stats.TotalFiles);
            Equal(1, stats.CommittedFiles);
            Equal(0, stats.SkippedFiles);
            Equal(1, stats.FailedFiles);
            Equal(ProtocolConstants.ChunkSize + 3L, stats.BytesTransferred);
            Equal(10L, stats.BytesCommitted);
            Equal(1, stats.VerifiedOriginalFiles);

            await using var verify = new SqliteConnection(new SqliteConnectionStringBuilder
            {
                DataSource = databasePath,
                Pooling = false,
            }.ToString());
            await verify.OpenAsync();
            var versionCommand = verify.CreateCommand();
            versionCommand.CommandText = "PRAGMA user_version";
            Equal(4L, Convert.ToInt64(await versionCommand.ExecuteScalarAsync()));
        }
        finally
        {
            Directory.Delete(root, true);
        }
    }

    private static async Task TestProtectedReceiverPathsAsync()
    {
        await using var context = await TestContext.CreateAsync();
        var metadataPath = Path.Combine(context.Destination.CatalogPath, "current.json");
        Directory.CreateDirectory(Path.GetDirectoryName(metadataPath)!);
        await File.WriteAllTextAsync(metadataPath, "receiver-owned metadata");
        var destinationPath = Path.Combine(context.Destination.ControlPath, "destination.json");
        var destinationBefore = await File.ReadAllBytesAsync(destinationPath);
        var outside = TempDirectory();
        var outsideSentinel = Path.Combine(outside, "sentinel.txt");
        await File.WriteAllTextAsync(outsideSentinel, "outside backup root");

        try
        {
            var attacks = new[]
            {
                "MB Photos Data/Catalog/current.json",
                "MB Photos Data/.mbphotos/destination.json",
                $"../{Path.GetFileName(outside)}/escape.jpg",
            };
            foreach (var proposedPath in attacks)
            {
                var ids = new StableIds();
                var job = Job(Encoding.UTF8.GetBytes("must not be written"), ids, Guid.NewGuid(), new string('0', 64), proposedPath);
                var exception = await ThrowsAsync<ReceiverApiException>(() => context.Coordinator.CreateJobAsync(job));
                Equal(ErrorCodes.UnsafePath, exception.Error.Code, proposedPath);
                True(await context.Ledger.GetJobAsync(job.JobId) is null, proposedPath + " must not create a ledger job");
            }

            Equal("receiver-owned metadata", await File.ReadAllTextAsync(metadataPath));
            var destinationAfter = await File.ReadAllBytesAsync(destinationPath);
            True(destinationBefore.SequenceEqual(destinationAfter), "destination.json must not be modified");
            Equal("outside backup root", await File.ReadAllTextAsync(outsideSentinel));
            True(!File.Exists(Path.Combine(outside, "escape.jpg")));
        }
        finally
        {
            Directory.Delete(outside, true);
        }
    }

    private static async Task TestTransferAndIncrementalAsync()
    {
        await using var context = await TestContext.CreateAsync();
        var bytes = Encoding.UTF8.GetBytes("verified photo bytes");
        var ids = new StableIds();
        var first = Job(bytes, ids, Guid.NewGuid(), new string('a', 64));
        var plan = await context.Coordinator.CreateJobAsync(first);
        Equal(JobFileAction.Upload, plan.Decisions.Single().Action);
        var sha = Sha(bytes);
        var receipt = await context.Coordinator.PutChunkAsync(first.JobId, ids.FileId, 0, 0, bytes.Length - 1, bytes.Length, sha, new MemoryStream(bytes));
        Equal(1, receipt.NextChunkIndex);
        await context.Ledger.PauseActiveJobsAsync();
        Equal(JobState.Paused, (await context.Coordinator.GetStatusAsync(first.JobId)).State);
        var resumedPlan = await context.Coordinator.CreateJobAsync(first);
        Equal(JobState.Transferring, resumedPlan.State);
        Equal(JobFileAction.Resume, resumedPlan.Decisions.Single().Action);
        var retried = await context.Coordinator.PutChunkAsync(first.JobId, ids.FileId, 0, 0, bytes.Length - 1, bytes.Length, sha, new MemoryStream(bytes));
        Equal(1, retried.NextChunkIndex);
        Equal(receipt.ReceivedAt, retried.ReceivedAt);
        var afterChunk = await context.Coordinator.GetStatusAsync(first.JobId);
        True(afterChunk.UpdatedAt >= receipt.ReceivedAt);
        var committed = await context.Coordinator.CommitAsync(first.JobId, ids.FileId, new CommitFileRequest(bytes.Length, sha));
        Equal(sha, committed.Sha256);
        _ = await context.Coordinator.CommitAsync(first.JobId, ids.FileId, new CommitFileRequest(bytes.Length, sha));
        var completedPartialDirectory = Path.GetDirectoryName(Partial(context, first.JobId, ids.FileId))!;
        Directory.CreateDirectory(completedPartialDirectory);
        await File.WriteAllTextAsync(Path.Combine(completedPartialDirectory, "old.hash-mismatch-artifact"), "quarantined");
        var completionRequest = new CompleteJobRequest(DateTimeOffset.UtcNow);
        var report = await context.Coordinator.CompleteAsync(first.JobId, completionRequest);
        Equal(1, report.Counts.FilesCommitted);
        True(File.Exists(Path.Combine(context.Root, committed.RelativePath.Replace('/', Path.DirectorySeparatorChar))));
        True(!Directory.Exists(completedPartialDirectory));
        Directory.CreateDirectory(completedPartialDirectory);
        await File.WriteAllTextAsync(Path.Combine(completedPartialDirectory, "stale-after-completion.partial"), "stale");
        var repeatedReport = await context.Coordinator.CompleteAsync(first.JobId, completionRequest);
        Equal(report.CompletedAt, repeatedReport.CompletedAt);
        True(!Directory.Exists(completedPartialDirectory), "an exact completion retry must remove recreated stale partials");

        var second = Job(bytes, ids, Guid.NewGuid(), new string('a', 64));
        var secondPlan = await context.Coordinator.CreateJobAsync(second);
        Equal(JobFileAction.Skip, secondPlan.Decisions.Single().Action);
        Equal("verified", secondPlan.Decisions.Single().Reason);
        var secondReport = await context.Coordinator.CompleteAsync(second.JobId, new CompleteJobRequest(DateTimeOffset.UtcNow));
        Equal(1, secondReport.Counts.FilesSkipped);
        Equal(0L, secondReport.Counts.BytesTransferred);
        var secondStatus = await context.Coordinator.GetStatusAsync(second.JobId);
        Equal(1, secondStatus.CommittedFiles.Count);
    }

    private static async Task TestExternalMutationAsync()
    {
        await using var context = await TestContext.CreateAsync();
        var bytes = Encoding.UTF8.GetBytes("first content");
        var ids = new StableIds();
        var first = Job(bytes, ids, Guid.NewGuid(), new string('a', 64));
        var commit = await UploadAndCommitAsync(context, first, ids.FileId, bytes);
        await context.Coordinator.CompleteAsync(first.JobId, new CompleteJobRequest(DateTimeOffset.UtcNow));
        var target = Path.Combine(context.Root, commit.RelativePath.Replace('/', Path.DirectorySeparatorChar));

        await File.WriteAllBytesAsync(target, bytes);
        File.SetLastWriteTimeUtc(target, DateTime.UtcNow.AddMinutes(2));
        var unchanged = Job(bytes, ids, Guid.NewGuid(), new string('a', 64));
        Equal(JobFileAction.Skip, (await context.Coordinator.CreateJobAsync(unchanged)).Decisions.Single().Action);
        await context.Coordinator.CompleteAsync(unchanged.JobId, new CompleteJobRequest(DateTimeOffset.UtcNow));

        await File.WriteAllTextAsync(target, "tampered destination");
        var changed = Job(bytes, ids, Guid.NewGuid(), new string('b', 64));
        var plan = await context.Coordinator.CreateJobAsync(changed);
        Equal(JobFileAction.Upload, plan.Decisions.Single().Action);
        True(plan.Decisions.Single().AcceptedRelativePath!.Contains("~" + ids.FileId.ToString("N")[..8], StringComparison.Ordinal));

        var unrelatedIds = new StableIds();
        var noAssociation = Job(bytes, unrelatedIds, Guid.NewGuid(), new string('a', 64), "Master/2026/2026-08/2026-08-24/new-id.jpg");
        Equal(JobFileAction.Upload, (await context.Coordinator.CreateJobAsync(noAssociation)).Decisions.Single().Action);
    }

    private static async Task TestCrashReconciliationAsync()
    {
        await using var context = await TestContext.CreateAsync();
        var ids = new StableIds();
        var bytes = new byte[ProtocolConstants.ChunkSize + 3];
        RandomNumberGenerator.Fill(bytes);
        var job = Job(bytes, ids, Guid.NewGuid(), new string('c', 64));
        var plan = await context.Coordinator.CreateJobAsync(job);
        var first = bytes.AsMemory(0, ProtocolConstants.ChunkSize).ToArray();
        await context.Coordinator.PutChunkAsync(job.JobId, ids.FileId, 0, 0, first.Length - 1, bytes.Length, Sha(first), new MemoryStream(first));
        var partial = Partial(context, job.JobId, ids.FileId);
        await using (var append = File.Open(partial, FileMode.Append, FileAccess.Write, FileShare.None))
        {
            await append.WriteAsync(new byte[] { 9, 9, 9, 9 });
        }

        var final = bytes.AsMemory(ProtocolConstants.ChunkSize).ToArray();
        await context.Coordinator.PutChunkAsync(job.JobId, ids.FileId, 1, ProtocolConstants.ChunkSize, bytes.Length - 1, bytes.Length, Sha(final), new MemoryStream(final));
        var committed = await context.Coordinator.CommitAsync(job.JobId, ids.FileId, new CommitFileRequest(bytes.Length, Sha(bytes)));
        Equal(Sha(bytes), committed.Sha256);

        var moveIds = new StableIds();
        var moveBytes = Encoding.UTF8.GetBytes("move then crash");
        var moveTemplate = Job(moveBytes, moveIds, Guid.NewGuid(), new string('d', 64));
        var moveAsset = moveTemplate.Assets.Single();
        var moveFile = moveAsset.Files.Single() with
        {
            StorageArea = StorageArea.LibraryData,
            Roles = new[] { RepresentationRole.Auxiliary },
            Criticality = Criticality.Optional,
            ProposedRelativePath = $"MB Photos Data/Resources/{moveIds.AssetId:D}/{moveIds.FileId:D}.jpg",
        };
        var moveJob = moveTemplate with
        {
            Assets = new[] { moveAsset with { Files = new[] { moveFile }, MasterFileId = null } },
        };
        var movePlan = await context.Coordinator.CreateJobAsync(moveJob);
        await context.Coordinator.PutChunkAsync(moveJob.JobId, moveIds.FileId, 0, 0, moveBytes.Length - 1, moveBytes.Length, Sha(moveBytes), new MemoryStream(moveBytes));
        var target = Path.Combine(context.Root, movePlan.Decisions.Single().AcceptedRelativePath!.Replace('/', Path.DirectorySeparatorChar));
        Directory.CreateDirectory(Path.GetDirectoryName(target)!);
        File.Move(Partial(context, moveJob.JobId, moveIds.FileId), target);
        var recovered = await context.Coordinator.CommitAsync(moveJob.JobId, moveIds.FileId, new CommitFileRequest(moveBytes.Length, Sha(moveBytes)));
        Equal(Sha(moveBytes), recovered.Sha256);
    }

    private static async Task TestHashMismatchAsync()
    {
        await using var context = await TestContext.CreateAsync();
        var ids = new StableIds();
        var bytes = Encoding.UTF8.GetBytes("hash me");
        var job = Job(bytes, ids, Guid.NewGuid(), new string('e', 64));
        await context.Coordinator.CreateJobAsync(job);
        await context.Coordinator.PutChunkAsync(job.JobId, ids.FileId, 0, 0, bytes.Length - 1, bytes.Length, Sha(bytes), new MemoryStream(bytes));
        var mismatch = await ThrowsAsync<ReceiverApiException>(() => context.Coordinator.CommitAsync(job.JobId, ids.FileId, new CommitFileRequest(bytes.Length, new string('f', 64))));
        Equal(ErrorCodes.HashMismatch, mismatch.Error.Code);
        var status = await context.Coordinator.GetStatusAsync(job.JobId);
        Equal(0, status.Decisions.Single().NextChunkIndex);
        True(Directory.EnumerateFiles(Path.GetDirectoryName(Partial(context, job.JobId, ids.FileId))!, "*.hash-mismatch-*").Any());
        Equal(ErrorCodes.InvalidRequest, Throws<ReceiverApiException>(() => ModelValidation.RequireSha256(new string('A', 64), "sha")).Error.Code);
        await context.Coordinator.AbandonAsync(job.JobId, new AbandonJobRequest("clientReset"));
        True(!Directory.Exists(Path.GetDirectoryName(Partial(context, job.JobId, ids.FileId))!));
    }

    private static async Task TestDurableProgressCountersAsync()
    {
        await using var context = await TestContext.CreateAsync();
        var ids = new StableIds();
        var bytes = Encoding.UTF8.GetBytes("durable counter bytes");
        var job = Job(bytes, ids, Guid.NewGuid(), new string('9', 64));
        await context.Coordinator.CreateJobAsync(job);

        var stats = await context.Ledger.GetStatsAsync(job.JobId);
        Equal(1, stats.TotalFiles);
        Equal(0L, stats.BytesTransferred);

        await context.Coordinator.PutChunkAsync(
            job.JobId,
            ids.FileId,
            0,
            0,
            bytes.Length - 1,
            bytes.Length,
            Sha(bytes),
            new MemoryStream(bytes));
        stats = await context.Ledger.GetStatsAsync(job.JobId);
        Equal(bytes.LongLength, stats.BytesTransferred);

        await context.Ledger.ClearChunksAsync(job.JobId, ids.FileId);
        stats = await context.Ledger.GetStatsAsync(job.JobId);
        Equal(0L, stats.BytesTransferred);
        Equal(0, (await context.Ledger.GetChunkStateAsync(job.JobId, ids.FileId, 0))?.NextChunkIndex ?? -1);

        await context.Coordinator.PutChunkAsync(
            job.JobId,
            ids.FileId,
            0,
            0,
            bytes.Length - 1,
            bytes.Length,
            Sha(bytes),
            new MemoryStream(bytes));
        await context.Ledger.AddFailureAsync(
            job.JobId,
            ids.FileId,
            ErrorCodes.HashMismatch,
            "retryable hash failure",
            true);
        stats = await context.Ledger.GetStatsAsync(job.JobId);
        Equal(1, stats.FailedFiles);

        await context.Coordinator.CommitAsync(
            job.JobId,
            ids.FileId,
            new CommitFileRequest(bytes.Length, Sha(bytes)));
        stats = await context.Ledger.GetStatsAsync(job.JobId);
        Equal(1, stats.CommittedFiles);
        Equal(0, stats.FailedFiles);
        Equal(bytes.LongLength, stats.BytesTransferred);
        Equal(bytes.LongLength, stats.BytesCommitted);
        Equal(1, stats.VerifiedOriginalFiles);
        await context.Coordinator.CompleteAsync(job.JobId, new CompleteJobRequest(DateTimeOffset.UtcNow));

        var skipJob = Job(bytes, ids, Guid.NewGuid(), new string('9', 64));
        await context.Coordinator.CreateJobAsync(skipJob);
        var skipStats = await context.Ledger.GetStatsAsync(skipJob.JobId);
        Equal(1, skipStats.SkippedFiles);
        Equal(0L, skipStats.BytesTransferred);
        Equal(bytes.LongLength, skipStats.BytesCommitted);
        Equal(1, skipStats.VerifiedOriginalFiles);
    }

    private static async Task TestUnknownSizeAsync()
    {
        await using var context = await TestContext.CreateAsync();
        var ids = new StableIds();
        var bytes = new byte[ProtocolConstants.ChunkSize + 1];
        RandomNumberGenerator.Fill(bytes);
        var original = Job(bytes, ids, Guid.NewGuid(), new string('6', 64));
        var asset = original.Assets.Single();
        var unknownFile = asset.Files.Single() with { ByteCount = null };
        var job = original with { Assets = new[] { asset with { Files = new[] { unknownFile } } } };
        await context.Coordinator.CreateJobAsync(job);
        var first = bytes.AsMemory(0, ProtocolConstants.ChunkSize).ToArray();
        await context.Coordinator.PutChunkAsync(
            job.JobId,
            ids.FileId,
            0,
            0,
            ProtocolConstants.ChunkSize - 1,
            bytes.Length,
            Sha(first),
            new MemoryStream(first));
        var conflict = await ThrowsAsync<ReceiverApiException>(() => context.Coordinator.PutChunkAsync(
            job.JobId,
            ids.FileId,
            0,
            0,
            ProtocolConstants.ChunkSize - 1,
            bytes.Length + 1,
            Sha(first),
            new MemoryStream(first)));
        Equal(ErrorCodes.ChunkConflict, conflict.Error.Code);
        var final = new[] { bytes[^1] };
        await context.Coordinator.PutChunkAsync(
            job.JobId,
            ids.FileId,
            1,
            ProtocolConstants.ChunkSize,
            ProtocolConstants.ChunkSize,
            bytes.Length,
            Sha(final),
            new MemoryStream(final));
        var committed = await context.Coordinator.CommitAsync(job.JobId, ids.FileId, new CommitFileRequest(bytes.Length, Sha(bytes)));
        Equal(bytes.Length, committed.ByteCount);
    }

    private static async Task TestAbandonAsync()
    {
        await using var context = await TestContext.CreateAsync();
        var committedIds = new StableIds();
        var committedBytes = Encoding.UTF8.GetBytes("keep committed");
        var committedJob = Job(committedBytes, committedIds, Guid.NewGuid(), new string('1', 64));
        var committed = await UploadAndCommitAsync(context, committedJob, committedIds.FileId, committedBytes);
        await context.Coordinator.CompleteAsync(committedJob.JobId, new CompleteJobRequest(DateTimeOffset.UtcNow));

        var pendingIds = new StableIds();
        var pendingBytes = Encoding.UTF8.GetBytes("discard partial");
        var pendingJob = Job(pendingBytes, pendingIds, Guid.NewGuid(), new string('2', 64), "Master/2026/2026-08/2026-08-24/pending.jpg");
        await context.Coordinator.CreateJobAsync(pendingJob);
        await context.Coordinator.PutChunkAsync(pendingJob.JobId, pendingIds.FileId, 0, 0, pendingBytes.Length - 1, pendingBytes.Length, Sha(pendingBytes), new MemoryStream(pendingBytes));
        var abandoned = await context.Coordinator.AbandonAsync(pendingJob.JobId, new AbandonJobRequest("userDiscarded"));
        Equal(1, abandoned.RemovedPartialFiles);
        var abandonedAgain = await context.Coordinator.AbandonAsync(pendingJob.JobId, new AbandonJobRequest("userDiscarded"));
        Equal(abandoned.RemovedPartialFiles, abandonedAgain.RemovedPartialFiles);
        Equal(abandoned.AbandonedAt, abandonedAgain.AbandonedAt);
        Equal(abandoned.State, abandonedAgain.State);
        var uploadAfterAbandonment = await ThrowsAsync<ReceiverApiException>(() => context.Coordinator.PutChunkAsync(
            pendingJob.JobId,
            pendingIds.FileId,
            0,
            0,
            pendingBytes.Length - 1,
            pendingBytes.Length,
            Sha(pendingBytes),
            new MemoryStream(pendingBytes)));
        Equal(ErrorCodes.JobConflict, uploadAfterAbandonment.Error.Code);
        var commitAfterAbandonment = await ThrowsAsync<ReceiverApiException>(() => context.Coordinator.CommitAsync(
            pendingJob.JobId,
            pendingIds.FileId,
            new CommitFileRequest(pendingBytes.Length, Sha(pendingBytes))));
        Equal(ErrorCodes.JobConflict, commitAfterAbandonment.Error.Code);
        True(File.Exists(Path.Combine(context.Root, committed.RelativePath.Replace('/', Path.DirectorySeparatorChar))));
    }

    private static async Task TestReparsePointAsync()
    {
        await using var context = await TestContext.CreateAsync();
        var outside = Path.Combine(Path.GetTempPath(), "mbphotos-outside-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(outside);
        var link = Path.Combine(context.Root, "Master", "linked");
        try
        {
            Directory.CreateSymbolicLink(link, outside);
            var exception = Throws<ReceiverApiException>(() => context.PathPolicy.ResolveUnderRoot(context.Root, "Master/linked/escape.jpg"));
            Equal(ErrorCodes.ChangedDestination, exception.Error.Code);
            True(!File.Exists(Path.Combine(outside, "escape.jpg")));
        }
        finally
        {
            if (Directory.Exists(link) || File.Exists(link))
            {
                Directory.Delete(link);
            }

            Directory.Delete(outside, true);
        }
    }

    private static async Task TestServerIntegrationAsync()
    {
        var root = TempDirectory();
        var logs = TempDirectory();
        ReceiverServer server;
        try
        {
            server = await ReceiverServer.StartAsync(root, true, IPAddress.Loopback, logs);
        }
        catch (CryptographicException exception) when (OperatingSystem.IsMacOS())
        {
            Directory.Delete(root, true);
            Directory.Delete(logs, true);
            throw new SkipException("The sandboxed macOS .NET 7 runtime cannot create an ephemeral private-key certificate: " + exception.Message);
        }

        await using (server)
        {
        using var handler = new HttpClientHandler
        {
            ServerCertificateCustomValidationCallback = (_, certificate, _, _) =>
                certificate is not null &&
                string.Equals(Convert.ToHexString(SHA256.HashData(certificate.RawData)).ToLowerInvariant(), server.CertificateFingerprint, StringComparison.Ordinal),
        };
        using var client = new HttpClient(handler) { BaseAddress = server.BaseUri };
        var pairingEvents = new ConcurrentQueue<ReceiverPairingState>();
        server.PairingStateChanged += (_, _) => throw new InvalidOperationException("observer failure");
        server.PairingStateChanged += (_, state) => pairingEvents.Enqueue(state);
        var unauthorized = await client.GetAsync("v2/jobs/11111111-1111-4111-8111-111111111111");
        Equal(HttpStatusCode.Unauthorized, unauthorized.StatusCode);
        var unauthorizedError = await unauthorized.Content.ReadFromJsonAsync<ApiError>(JsonOptions);
        Equal(ErrorCodes.AuthenticationRequired, unauthorizedError!.Code);

        var token = QueryValue(server.QrPayload, "token");
        var response = await client.PostAsJsonAsync("v2/pair", PairRequest(token), JsonOptions);
        response.EnsureSuccessStatusCode();
        Equal("no-store", response.Headers.CacheControl?.ToString());
        var paired = await response.Content.ReadFromJsonAsync<PairResponse>(JsonOptions);
        var firstSession = paired!.SessionToken;
        client.DefaultRequestHeaders.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", firstSession);
        True(server.PairingState.QrPayload is null && server.PairingState.HasActiveSession,
            "redeeming a QR did not retract it immediately");

        var expiring = server.RefreshPairingInvitation(TimeSpan.Zero);
        var renewed = server.RefreshExpiredPairingInvitation(expiring.InvitationExpiresAt);
        True(renewed.QrPayload is not null && renewed.HasActiveSession);
        True(!string.Equals(expiring.QrPayload, renewed.QrPayload, StringComparison.Ordinal),
            "the exact-expiry refresh did not rotate the invitation");
        var missing = await client.GetAsync("v2/jobs/11111111-1111-4111-8111-111111111111");
        Equal(HttpStatusCode.NotFound, missing.StatusCode);

        var replacementPair = await client.PostAsJsonAsync(
            "v2/pair",
            PairRequest(QueryValue(renewed.QrPayload!, "token")),
            JsonOptions);
        replacementPair.EnsureSuccessStatusCode();
        var replacement = await replacementPair.Content.ReadFromJsonAsync<PairResponse>(JsonOptions);
        using var priorBearerRequest = new HttpRequestMessage(
            HttpMethod.Get,
            "v2/jobs/11111111-1111-4111-8111-111111111111");
        priorBearerRequest.Headers.Authorization =
            new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", firstSession);
        var rejectedPriorBearer = await client.SendAsync(priorBearerRequest);
        Equal(HttpStatusCode.Unauthorized, rejectedPriorBearer.StatusCode,
            "a new pairing did not replace the prior bearer");
        client.DefaultRequestHeaders.Authorization =
            new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", replacement!.SessionToken);

        var idleInvitation = server.RefreshPairingInvitation();
        True(idleInvitation.QrPayload is not null);
        var ids = new StableIds();
        var bytes = Array.Empty<byte>();
        var job = Job(bytes, ids, Guid.NewGuid(), new string('c', 64));
        var planResponse = await client.PostAsJsonAsync("v2/jobs", job, JsonOptions);
        planResponse.EnsureSuccessStatusCode();
        True(server.PairingState.QrPayload is null,
            "starting an authenticated job did not retract the idle invitation");

        var commitResponse = await client.PostAsJsonAsync(
            $"v2/jobs/{job.JobId:D}/files/{ids.FileId:D}/commit",
            new CommitFileRequest(0, Sha(bytes)),
            JsonOptions);
        commitResponse.EnsureSuccessStatusCode();

        var firstTerminal = new TaskCompletionSource<ReceiverTerminalResponseCompletedEventArgs>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var secondTerminal = new TaskCompletionSource<ReceiverTerminalResponseCompletedEventArgs>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var terminalCount = 0;
        server.TerminalResponseCompleted += (_, _) => throw new InvalidOperationException("observer failure");
        server.TerminalResponseCompleted += (_, terminal) =>
        {
            if (Interlocked.Increment(ref terminalCount) == 1)
            {
                firstTerminal.TrySetResult(terminal);
            }
            else
            {
                secondTerminal.TrySetResult(terminal);
            }
        };
        var completeRequest = new CompleteJobRequest(DateTimeOffset.UtcNow);
        var completeResponse = await client.PostAsJsonAsync(
            $"v2/jobs/{job.JobId:D}/complete",
            completeRequest,
            JsonOptions);
        completeResponse.EnsureSuccessStatusCode();
        var completed = await firstTerminal.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Equal(job.JobId, completed.JobId);
        Equal("completed", completed.State);
        Equal(1, completed.Counts!.FilesPlanned);
        var postTerminalQr = server.PairingState.QrPayload;
        True(postTerminalQr is not null && server.PairingState.HasActiveSession,
            "terminal response completion did not issue a fresh invitation while retaining the bearer");

        var retryResponse = await client.PostAsJsonAsync(
            $"v2/jobs/{job.JobId:D}/complete",
            completeRequest,
            JsonOptions);
        retryResponse.EnsureSuccessStatusCode();
        _ = await secondTerminal.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Equal(postTerminalQr, server.PairingState.QrPayload,
            "an idempotent terminal retry rotated the displayed invitation");
        True(pairingEvents.Any(static state => state.QrPayload is null && state.HasActiveSession),
            "pair-consumed/retracted state was not raised");
        }
        Directory.Delete(root, true);
        Directory.Delete(logs, true);
    }

    private static async Task TestMetadataSafetyAsync()
    {
        await using var context = await TestContext.CreateAsync();
        var ids = new StableIds();
        var bytes = Array.Empty<byte>();
        var job = Job(bytes, ids, Guid.NewGuid(), new string('9', 64), albumTitle: "=HYPERLINK(\"bad\")");
        await context.Coordinator.CreateJobAsync(job);
        await context.Coordinator.CommitAsync(job.JobId, ids.FileId, new CommitFileRequest(0, Sha(bytes)));
        await context.Coordinator.CompleteAsync(job.JobId, new CompleteJobRequest(DateTimeOffset.UtcNow));
        var pointer = JsonSerializer.Deserialize<CatalogPointer>(
            await File.ReadAllTextAsync(Path.Combine(context.Destination.CatalogPath, "current.json")), JsonOptions)!;
        var jsonl = await File.ReadAllTextAsync(context.PathPolicy.ResolveUnderRoot(context.Root, pointer.AlbumsRelativePath));
        True(jsonl.Contains("=HYPERLINK", StringComparison.Ordinal));
        var assets = await File.ReadAllTextAsync(context.PathPolicy.ResolveUnderRoot(context.Root, pointer.AssetsRelativePath));
        True(assets.Contains(Sha(bytes), StringComparison.Ordinal));
        True(!Directory.EnumerateFiles(context.Destination.ControlPath, "manifest-build-*").Any(),
            "manifest index scratch files must be removed after atomic output");
    }

    private static async Task TestCompletionFailuresAsync()
    {
        await using var context = await TestContext.CreateAsync();
        var ids = new StableIds();
        var bytes = Encoding.UTF8.GetBytes("unavailable source");
        var original = Job(bytes, ids, Guid.NewGuid(), new string('7', 64));
        var asset = original.Assets.Single();
        var failedFileId = Guid.NewGuid();
        var failedFile = asset.Files.Single() with
        {
            FileId = failedFileId,
            StorageArea = StorageArea.LibraryData,
            Roles = new[] { RepresentationRole.Auxiliary },
            Criticality = Criticality.Optional,
            ProposedRelativePath = $"MB Photos Data/Resources/{ids.AssetId:D}/{failedFileId:D}.jpg",
        };
        var job = original with { Assets = new[] { asset with { Files = new[] { asset.Files.Single(), failedFile } } } };
        await context.Coordinator.CreateJobAsync(job);
        await context.Coordinator.PutChunkAsync(job.JobId, ids.FileId, 0, 0, bytes.Length - 1, bytes.Length, Sha(bytes), new MemoryStream(bytes));
        await context.Coordinator.CommitAsync(job.JobId, ids.FileId, new CommitFileRequest(bytes.Length, Sha(bytes)));
        var completedAt = DateTimeOffset.UtcNow;
        var failure = new CompletionFailure(failedFileId, ErrorCodes.UnavailableSource, "The source is no longer available.", false);
        var request = new CompleteJobRequest(completedAt, new[] { failure });
        var report = await context.Coordinator.CompleteAsync(job.JobId, request);
        Equal("completedWithFailures", report.State);
        Equal(1, report.Counts.FilesCommitted);
        Equal(1, report.Counts.FilesFailed);
        var durableStats = await context.Ledger.GetStatsAsync(job.JobId);
        Equal(2, durableStats.TotalFiles);
        Equal(1, durableStats.CommittedFiles);
        Equal(1, durableStats.FailedFiles);
        Equal(bytes.LongLength, durableStats.BytesTransferred);
        Equal(bytes.LongLength, durableStats.BytesCommitted);
        var retry = await context.Coordinator.CompleteAsync(job.JobId, request);
        Equal(report.JobId, retry.JobId);
        Equal(report.State, retry.State);
        var status = await context.Coordinator.GetStatusAsync(job.JobId);
        Equal(JobState.CompletedWithFailures, status.State);
        True(status.Report is not null);
        Equal(1, status.CommittedFiles.Count);
        Equal(JobFileAction.Conflict, status.Decisions.Single(decision => decision.FileId == failedFileId).Action);
        var pointer = JsonSerializer.Deserialize<CatalogPointer>(
            await File.ReadAllTextAsync(Path.Combine(context.Destination.CatalogPath, "current.json")), JsonOptions)!;
        var assetsJsonl = await File.ReadAllTextAsync(
            context.PathPolicy.ResolveUnderRoot(context.Root, pointer.AssetsRelativePath));
        True(assetsJsonl.Contains(Sha(bytes), StringComparison.Ordinal));
        True(assetsJsonl.Contains(failedFileId.ToString("D"), StringComparison.Ordinal));
        var repeatedPlan = await context.Coordinator.CreateJobAsync(job);
        Equal(JobState.CompletedWithFailures, repeatedPlan.State);

        var differentRequest = request with { CompletedAt = completedAt.AddSeconds(1) };
        Equal(ErrorCodes.JobConflict, (await ThrowsAsync<ReceiverApiException>(() => context.Coordinator.CompleteAsync(job.JobId, differentRequest))).Error.Code);
        var changedJob = job with { SourceTimeZone = "America/Chicago" };
        Equal(ErrorCodes.JobConflict, (await ThrowsAsync<ReceiverApiException>(() => context.Coordinator.CreateJobAsync(changedJob))).Error.Code);

        var duplicateJob = Job(bytes, new StableIds(), Guid.NewGuid(), new string('8', 64), "Master/2026/2026-08/2026-08-24/failure.jpg");
        await context.Coordinator.CreateJobAsync(duplicateJob);
        var duplicateId = duplicateJob.Assets.Single().Files.Single().FileId;
        var duplicateFailure = new CompletionFailure(duplicateId, ErrorCodes.UnavailableSource, "Unavailable.", false);
        var duplicateRequest = new CompleteJobRequest(DateTimeOffset.UtcNow, new[] { duplicateFailure, duplicateFailure });
        Equal(ErrorCodes.InvalidRequest, (await ThrowsAsync<ReceiverApiException>(() => context.Coordinator.CompleteAsync(duplicateJob.JobId, duplicateRequest))).Error.Code);
    }

    private static async Task<Guid> CreateStressJobAsync(TestContext context, int assetCount)
    {
        var revision = new string('a', 64);
        var timestamp = new DateTimeOffset(2026, 8, 24, 12, 0, 0, TimeSpan.Zero);
        var emptySubtypes = Array.Empty<string>();
        IReadOnlyList<string> recoveryNames = new[] { "asset.jpg" };
        IReadOnlyList<long?> recoverySizes = new long?[] { 0 };
        var assets = new ExportAsset[assetCount];
        for (var index = 0; index < assetCount; index++)
        {
            var assetId = StressGuid(index, 0x41);
            var fileId = StressGuid(index, 0x46);
            var file = new ExportFile(
                fileId,
                assetId,
                revision,
                StorageArea.LibraryData,
                new[] { RepresentationRole.Auxiliary },
                Criticality.Optional,
                Provenance.ExactPhotoKitResource,
                "photo",
                1,
                "asset.jpg",
                $"MB Photos Data/Resources/{assetId:D}/{fileId:D}.jpg",
                "public.jpeg",
                "image/jpeg",
                1,
                1,
                null,
                0,
                HashOfEmptyFile,
                timestamp,
                Availability.Available);
            assets[index] = new ExportAsset(
                assetId,
                $"stress/L0/{index:D6}",
                revision,
                "photo",
                emptySubtypes,
                timestamp,
                null,
                false,
                new RecoveryFingerprint(timestamp, 1, 1, null, "photo", recoveryNames, recoverySizes),
                new[] { file },
                null,
                null,
                null);
        }

        var job = new ExportJob(
            ProtocolConstants.Version,
            Guid.NewGuid(),
            DateTimeOffset.UtcNow,
            "Etc/UTC",
            new ExportProfile(ExportProfileKind.PortableLibrary, 2),
            new SelectionSnapshot(SelectionKind.AllAccessible, assetCount),
            assets,
            Array.Empty<AlbumMembership>());
        var plan = await context.Coordinator.CreateJobAsync(job);
        Equal(assetCount, plan.Decisions.Count);
        Equal(JobState.Transferring, plan.State);
        return job.JobId;
    }

    private static async Task MarkStressFilesCommittedAsync(string databasePath, Guid jobId)
    {
        await using var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = databasePath,
            Mode = SqliteOpenMode.ReadWrite,
            Pooling = false,
        }.ToString());
        await connection.OpenAsync();
        using var transaction = connection.BeginTransaction();
        var files = connection.CreateCommand();
        files.Transaction = transaction;
        files.CommandText = """
            UPDATE files SET state='committed',committed_sha256=$sha,committed_bytes=0,
                committed_at=$committed,observed_write_ticks=0
            WHERE job_id=$job AND state='pending'
            """;
        files.Parameters.AddWithValue("$sha", HashOfEmptyFile);
        files.Parameters.AddWithValue("$committed", DateTimeOffset.UtcNow.ToUniversalTime().ToString("O"));
        files.Parameters.AddWithValue("$job", jobId.ToString("D"));
        Equal(100_000, await files.ExecuteNonQueryAsync());

        var job = connection.CreateCommand();
        job.Transaction = transaction;
        job.CommandText = """
            UPDATE jobs SET committed_files=total_files,verified_original_files=total_files
            WHERE job_id=$job
            """;
        job.Parameters.AddWithValue("$job", jobId.ToString("D"));
        Equal(1, await job.ExecuteNonQueryAsync());
        transaction.Commit();
    }

    private static async Task<long> CountLinesAsync(string path)
    {
        await using var stream = new FileStream(
            path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            128 * 1024,
            FileOptions.Asynchronous | FileOptions.SequentialScan);
        var buffer = new byte[128 * 1024];
        long lines = 0;
        int read;
        while ((read = await stream.ReadAsync(buffer)) > 0)
        {
            for (var index = 0; index < read; index++)
            {
                if (buffer[index] == (byte)'\n')
                {
                    lines++;
                }
            }
        }
        return lines;
    }

    private static void ObserveMaximum(ref long target, long value)
    {
        var observed = Volatile.Read(ref target);
        while (value > observed)
        {
            var prior = Interlocked.CompareExchange(ref target, value, observed);
            if (prior == observed)
            {
                return;
            }
            observed = prior;
        }
    }

    private static Guid StressGuid(int index, byte discriminator)
    {
        Span<byte> bytes = stackalloc byte[16];
        bytes.Clear();
        BitConverter.TryWriteBytes(bytes, index + 1);
        bytes[4] = discriminator;
        bytes[7] = 0x40;
        bytes[8] = 0x80;
        return new Guid(bytes);
    }

    private static async Task<CommittedFile> UploadAndCommitAsync(TestContext context, ExportJob job, Guid fileId, byte[] bytes)
    {
        await context.Coordinator.CreateJobAsync(job);
        if (bytes.Length > 0)
        {
            await context.Coordinator.PutChunkAsync(job.JobId, fileId, 0, 0, bytes.Length - 1, bytes.Length, Sha(bytes), new MemoryStream(bytes));
        }

        return await context.Coordinator.CommitAsync(job.JobId, fileId, new CommitFileRequest(bytes.Length, Sha(bytes)));
    }

    private static ExportJob Job(
        byte[] bytes,
        StableIds ids,
        Guid jobId,
        string revision,
        string proposed = "Master/2026/2026-08/2026-08-24/photo.jpg",
        string albumTitle = "Test Album")
    {
        var timestamp = new DateTimeOffset(2026, 8, 24, 12, 0, 0, TimeSpan.Zero);
        var file = new ExportFile(
            ids.FileId,
            ids.AssetId,
            revision,
            StorageArea.Master,
            new[] { RepresentationRole.MasterCurrent, RepresentationRole.RootOriginal },
            Criticality.MasterRequired,
            Provenance.ExactPhotoKitResource,
            "photo",
            1,
            "photo.jpg",
            proposed,
            "public.jpeg",
            "image/jpeg",
            100,
            100,
            null,
            bytes.LongLength,
            null,
            timestamp,
            Availability.Available);
        var asset = new ExportAsset(
            ids.AssetId,
            "source/L0/001",
            revision,
            "photo",
            Array.Empty<string>(),
            timestamp,
            null,
            false,
            new RecoveryFingerprint(timestamp, 100, 100, null, "photo", new[] { "photo.jpg" }, new long?[] { bytes.LongLength }),
            new[] { file },
            null,
            ids.FileId,
            null);
        return new ExportJob(
            ProtocolConstants.Version,
            jobId,
            DateTimeOffset.UtcNow,
            "Etc/UTC",
            new ExportProfile(ExportProfileKind.PortableLibrary, 2),
            new SelectionSnapshot(SelectionKind.Manual, 1),
            new[] { asset },
            new[] { new AlbumMembership(ids.AlbumId, "album/L0/001", albumTitle, null, ids.AssetId) });
    }

    private static ExportFile PortableFile(
        Guid fileId,
        Guid assetId,
        string contentRevision,
        StorageArea storageArea,
        IReadOnlyList<RepresentationRole> roles,
        Criticality criticality,
        string originalFilename,
        string proposedRelativePath,
        byte[]? bytes,
        string photoKitResourceType = "photo",
        string contentType = "image/jpeg",
        Availability availability = Availability.Available) => new(
            fileId,
            assetId,
            contentRevision,
            storageArea,
            roles,
            criticality,
            Provenance.ExactPhotoKitResource,
            photoKitResourceType,
            photoKitResourceType == "photo" ? 1 : 3,
            originalFilename,
            proposedRelativePath,
            contentType == "video/quicktime" ? "com.apple.quicktime-movie" : "public.jpeg",
            contentType,
            contentType == "video/quicktime" ? null : 100,
            contentType == "video/quicktime" ? null : 100,
            contentType == "video/quicktime" ? 1_000 : null,
            bytes?.LongLength,
            bytes is null ? null : Sha(bytes),
            new DateTimeOffset(2026, 8, 24, 12, 0, 0, TimeSpan.Zero),
            availability);

    private static ExportJob PortableJob(
        Guid assetId,
        string sourceRevision,
        bool isEdited,
        IReadOnlyList<ExportFile> files,
        Guid? masterFileId,
        LivePhotoRelationships? livePhotoRelationships = null) => new(
            ProtocolConstants.Version,
            Guid.NewGuid(),
            DateTimeOffset.UtcNow,
            "Etc/UTC",
            new ExportProfile(ExportProfileKind.PortableLibrary, 2),
            new SelectionSnapshot(SelectionKind.Manual, 1),
            new[]
            {
                new ExportAsset(
                    assetId,
                    $"source/{assetId:D}",
                    sourceRevision,
                    "photo",
                    livePhotoRelationships is null ? Array.Empty<string>() : new[] { "livePhoto" },
                    new DateTimeOffset(2026, 8, 24, 12, 0, 0, TimeSpan.Zero),
                    null,
                    isEdited,
                    new RecoveryFingerprint(
                        new DateTimeOffset(2026, 8, 24, 12, 0, 0, TimeSpan.Zero),
                        100,
                        100,
                        null,
                        "photo",
                        files.Select(static file => file.OriginalFilename).ToArray(),
                        files.Select(static file => file.ByteCount).ToArray()),
                    files,
                    null,
                    masterFileId,
                    livePhotoRelationships),
            },
            Array.Empty<AlbumMembership>());

    private static PairRequest PairRequest(string token) => new(
        ProtocolConstants.Version,
        token,
        new ClientDescriptor("Tests", "1.0", Guid.NewGuid().ToString("D")));

    private static string Partial(TestContext context, Guid jobId, Guid fileId) => Path.Combine(
        context.Destination.PartialPath,
        jobId.ToString("D"),
        fileId.ToString("D") + ".partial");

    private static string Sha(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

    private const string HashOfEmptyFile = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

    private static string DataPath(string name) => Path.Combine(AppContext.BaseDirectory, "Protocol", name);

    private static string Expression(JsonElement vector, string literalName, string expressionName)
    {
        if (vector.TryGetProperty(literalName, out var literal))
        {
            return literal.GetString()!;
        }

        var builder = new StringBuilder();
        foreach (var part in vector.GetProperty(expressionName).EnumerateArray())
        {
            if (part.ValueKind == JsonValueKind.String)
            {
                builder.Append(part.GetString());
            }
            else
            {
                for (var index = 0; index < part.GetProperty("count").GetInt32(); index++)
                {
                    builder.Append(part.GetProperty("repeat").GetString());
                }
            }
        }

        return builder.ToString();
    }

    private static string QueryValue(string uri, string key)
    {
        var query = new Uri(uri).Query.TrimStart('?').Split('&');
        foreach (var pair in query)
        {
            var parts = pair.Split('=', 2);
            if (parts[0] == key)
            {
                return Uri.UnescapeDataString(parts[1]);
            }
        }

        throw new InvalidOperationException($"Missing query value {key}");
    }

    private static T Throws<T>(Action action) where T : Exception
    {
        try
        {
            action();
        }
        catch (T exception)
        {
            return exception;
        }

        throw new InvalidOperationException($"Expected {typeof(T).Name}.");
    }

    private static async Task<T> ThrowsAsync<T>(Func<Task> action) where T : Exception
    {
        try
        {
            await action();
        }
        catch (T exception)
        {
            return exception;
        }

        throw new InvalidOperationException($"Expected {typeof(T).Name}.");
    }

    private static void True(bool condition, string? message = null)
    {
        if (!condition)
        {
            throw new InvalidOperationException(message ?? "Expected true.");
        }
    }

    private static void Equal<T>(T expected, T actual, string? message = null)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
        {
            throw new InvalidOperationException($"{message ?? "Values differ"}: expected '{expected}', got '{actual}'.");
        }
    }

    private static string TempDirectory()
    {
        var path = Path.Combine(Path.GetTempPath(), "mbphotos-tests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(path);
        return path;
    }

    private sealed record StableIds(
        Guid AssetId,
        Guid FileId,
        Guid AlbumId)
    {
        public StableIds() : this(Guid.NewGuid(), Guid.NewGuid(), Guid.NewGuid())
        {
        }
    }

    private sealed class TestContext : IAsyncDisposable
    {
        private TestContext(
            string root,
            DestinationManager destinationManager,
            DestinationContext destination,
            WindowsPathPolicy pathPolicy,
            Ledger ledger,
            JobCoordinator coordinator)
        {
            Root = root;
            DestinationManager = destinationManager;
            Destination = destination;
            PathPolicy = pathPolicy;
            Ledger = ledger;
            Coordinator = coordinator;
        }

        public string Root { get; }
        public DestinationManager DestinationManager { get; }
        public DestinationContext Destination { get; }
        public WindowsPathPolicy PathPolicy { get; }
        public Ledger Ledger { get; }
        public JobCoordinator Coordinator { get; }

        public static async Task<TestContext> CreateAsync()
        {
            var root = TempDirectory();
            var manager = new DestinationManager(JsonOptions);
            var destination = await manager.OpenOrInitializeAsync(root, true);
            var ledger = new Ledger(destination.DatabasePath);
            await ledger.InitializeAsync();
            var policy = new WindowsPathPolicy();
            var transfer = new FileTransferService(destination, manager, ledger, policy);
            var writer = new ManifestWriter(destination, ledger, policy, JsonOptions);
            var promotion = new MasterPromotionService(destination, ledger, policy, JsonOptions);
            var reuse = new RepresentationReuseService(destination, ledger, policy);
            var superseded = new SupersededRepresentationService(destination, ledger, policy);
            var coordinator = new JobCoordinator(destination, manager, ledger, policy, transfer, writer, promotion, reuse, superseded, JsonOptions);
            return new TestContext(root, manager, destination, policy, ledger, coordinator);
        }

        public async ValueTask DisposeAsync()
        {
            await Ledger.DisposeAsync();
            if (Directory.Exists(Root))
            {
                Directory.Delete(Root, true);
            }
        }
    }

    private sealed class SkipException : Exception
    {
        public SkipException(string message) : base(message)
        {
        }
    }
}
