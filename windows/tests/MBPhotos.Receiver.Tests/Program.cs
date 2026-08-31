using System.Collections.Concurrent;
using System.Net;
using System.Net.Http.Json;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using MBPhotos.Receiver.Diagnostics;
using MBPhotos.Receiver.Hosting;
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
            ("pair token expiry, replay, and session auth", TestPairingAsync),
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
        Equal(4, job.Assets.Sum(static asset => asset.Files.Count));
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
        Equal(3, report.Counts.VerifiedOriginalFiles);
        var failedReport = Fixture<CompletionReport>(fixtures, "completion-report-with-failures.response.json");
        Equal("completedWithFailures", failedReport.State);
        _ = Fixture<AbandonJobRequest>(fixtures, "abandon-job.request.json");
        _ = Fixture<AbandonJobResponse>(fixtures, "abandon-job.response.json");
        _ = Fixture<ApiError>(fixtures, "api-error.response.json");
        var emptyAbandon = JsonSerializer.Serialize(new AbandonJobRequest(null), JsonOptions);
        True(!emptyAbandon.Contains("reason", StringComparison.Ordinal));
        return Task.CompletedTask;
    }

    private static T Fixture<T>(string fixtures, string name)
    {
        var value = JsonSerializer.Deserialize<T>(File.ReadAllText(Path.Combine(fixtures, name)), JsonOptions);
        return value ?? throw new InvalidDataException($"Fixture {name} decoded as null.");
    }

    private static Task TestPairingAsync()
    {
        var pairing = new PairingSessionManager();
        var expired = pairing.StartRun(TimeSpan.FromSeconds(-1));
        var request = PairRequest(expired.Token);
        Equal(ErrorCodes.TokenExpired, Throws<ReceiverApiException>(() => pairing.Redeem(request)).Error.Code);

        var run = pairing.StartRun();
        var session = pairing.Redeem(PairRequest(run.Token));
        True(pairing.Authorize("Bearer " + session));
        True(!pairing.Authorize("Bearer wrong"));
        Equal(ErrorCodes.TokenConsumed, Throws<ReceiverApiException>(() => pairing.Redeem(PairRequest(run.Token))).Error.Code);
        pairing.EndRun();
        return Task.CompletedTask;
    }

    private static async Task TestActivityFeedAsync()
    {
        using var feed = new ReceiverActivityFeed();
        feed.Activate(7);
        var calls = 0;
        var concurrent = 0;
        var maximumConcurrent = 0;
        var urgentError = new TaskCompletionSource<ReceiverActivityEnvelope>(TaskCreationOptions.RunContinuationsAsynchronously);
        var terminal = new TaskCompletionSource<ReceiverActivityEnvelope>(TaskCreationOptions.RunContinuationsAsynchronously);

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
        };

        for (var index = 0; index < 10_000; index++)
        {
            feed.Publish(7, new ReceiverActivity(
                Guid.Empty,
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
        feed.Publish(7, new ReceiverActivity(Guid.Empty, "transferring", 1, 10_000, 1, null, 1, "retryable error"));
        var deliveredError = await urgentError.Task.WaitAsync(TimeSpan.FromSeconds(2));
        Equal("retryable error", deliveredError.Activity.ErrorMessage);
        True(errorStarted.Elapsed < TimeSpan.FromMilliseconds(500), "error activity was not delivered promptly");

        var started = System.Diagnostics.Stopwatch.StartNew();
        feed.Publish(7, new ReceiverActivity(Guid.Empty, "completed", 10_000, 10_000, 10_000, null, 1));
        feed.Publish(7, new ReceiverActivity(Guid.Empty, "transferring", 1, 1, 1, null, 1));
        var delivered = await terminal.Task.WaitAsync(TimeSpan.FromSeconds(2));
        Equal("completed", delivered.Activity.State);
        True(started.Elapsed < TimeSpan.FromMilliseconds(500), "terminal activity was not delivered promptly");
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

        dispatcher.Post(ActivityEnvelope(4, "transferring", 10_003));
        dispatcher.Post(ActivityEnvelope(4, "completed", 10_004));
        dispatcher.Post(ActivityEnvelope(4, "transferring", 10_005));
        Equal(1, callbacks.Count, "terminal activity queued a second UI callback");
        callbacks.Dequeue()();
        Equal("completed", delivered[^1].Activity.State);
        Equal(0, callbacks.Count, "progress survived a terminal activity");

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
        string? error = null) =>
        new(
            generation,
            new ReceiverActivity(
                Guid.Empty,
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

            var exported = Path.Combine(root, "export.log");
            await provider.ExportAsync(exported);
            var contents = await File.ReadAllTextAsync(exported);
            True(contents.Contains("urgent-marker", StringComparison.Ordinal));
            True(contents.Contains("token=[redacted]", StringComparison.Ordinal));
            True(contents.Contains("filename=[redacted]", StringComparison.Ordinal));
            True(contents.Contains("latitude=[redacted]", StringComparison.Ordinal));
            True(!contents.Contains("secret", StringComparison.Ordinal));
            True(!contents.Contains("private.jpg", StringComparison.Ordinal));
            True(new FileInfo(provider.LogPath).Length <= (2 * 1024 * 1024) + (64 * 1024),
                "the bounded current diagnostic log exceeded its rotation allowance");
        }
        finally
        {
            await provider.DisposeAsync();
            Directory.Delete(root, true);
        }
    }

    private static async Task TestHundredThousandAssetFinalizationAsync()
    {
        const int assetCount = 100_000;
        const long maximumManagedBytes = 1_500L * 1024 * 1024;
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

            var reportPath = Path.Combine(context.Root, "Reports", jobId.ToString("D") + ".json");
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

            var assetsPath = Path.Combine(context.Root, "Metadata", "assets.jsonl");
            Equal((long)assetCount, await CountLinesAsync(assetsPath));
            True(new FileInfo(assetsPath).Length > assetCount,
                "the asset manifest was not populated");
            True(!Directory.EnumerateFiles(
                    Path.Combine(context.Root, "Photos"),
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
            .Select(index => templateAsset.Files.Single() with
            {
                FileId = Guid.NewGuid(),
                OriginalFilename = $"stream-{index:D2}.jpg",
                ProposedRelativePath = $"Photos/stream/{index:D2}.jpg",
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
        True(File.Exists(Path.Combine(context.Root, ".mbphotos", "destination.json")));
        True(File.Exists(Path.Combine(context.Root, ".mbphotos", "ledger.sqlite")));
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
            Equal(3L, Convert.ToInt64(await versionCommand.ExecuteScalarAsync()));
        }
        finally
        {
            Directory.Delete(root, true);
        }
    }

    private static async Task TestProtectedReceiverPathsAsync()
    {
        await using var context = await TestContext.CreateAsync();
        var metadataPath = Path.Combine(context.Root, "Metadata", "assets.jsonl");
        Directory.CreateDirectory(Path.GetDirectoryName(metadataPath)!);
        await File.WriteAllTextAsync(metadataPath, "receiver-owned metadata");
        var destinationPath = Path.Combine(context.Root, ".mbphotos", "destination.json");
        var destinationBefore = await File.ReadAllBytesAsync(destinationPath);
        var outside = TempDirectory();
        var outsideSentinel = Path.Combine(outside, "sentinel.txt");
        await File.WriteAllTextAsync(outsideSentinel, "outside backup root");

        try
        {
            var attacks = new[]
            {
                "Metadata/assets.jsonl",
                ".mbphotos/destination.json",
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
        var noAssociation = Job(bytes, unrelatedIds, Guid.NewGuid(), new string('a', 64), "Photos/2026/2026-08/2026-08-24/new-id.jpg");
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
        var moveJob = Job(moveBytes, moveIds, Guid.NewGuid(), new string('d', 64), "Photos/2026/2026-08/2026-08-24/moved.jpg");
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

        var pendingIds = new StableIds();
        var pendingBytes = Encoding.UTF8.GetBytes("discard partial");
        var pendingJob = Job(pendingBytes, pendingIds, Guid.NewGuid(), new string('2', 64), "Photos/2026/2026-08/2026-08-24/pending.jpg");
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
        var link = Path.Combine(context.Root, "Photos", "linked");
        try
        {
            Directory.CreateSymbolicLink(link, outside);
            var exception = Throws<ReceiverApiException>(() => context.PathPolicy.ResolveUnderRoot(context.Root, "Photos/linked/escape.jpg"));
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
        var unauthorized = await client.GetAsync("v1/jobs/11111111-1111-4111-8111-111111111111");
        Equal(HttpStatusCode.Unauthorized, unauthorized.StatusCode);
        var unauthorizedError = await unauthorized.Content.ReadFromJsonAsync<ApiError>(JsonOptions);
        Equal(ErrorCodes.AuthenticationRequired, unauthorizedError!.Code);

        var token = QueryValue(server.QrPayload, "token");
        var response = await client.PostAsJsonAsync("v1/pair", PairRequest(token), JsonOptions);
        response.EnsureSuccessStatusCode();
        Equal("no-store", response.Headers.CacheControl?.ToString());
        var paired = await response.Content.ReadFromJsonAsync<PairResponse>(JsonOptions);
        client.DefaultRequestHeaders.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", paired!.SessionToken);
        var missing = await client.GetAsync("v1/jobs/11111111-1111-4111-8111-111111111111");
        Equal(HttpStatusCode.NotFound, missing.StatusCode);
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
        var csv = await File.ReadAllTextAsync(Path.Combine(context.Root, "Metadata", "albums.csv"));
        True(csv.Contains("'=HYPERLINK", StringComparison.Ordinal));
        var jsonl = await File.ReadAllTextAsync(Path.Combine(context.Root, "Metadata", "albums.jsonl"));
        True(jsonl.Contains("=HYPERLINK", StringComparison.Ordinal));
        var assets = await File.ReadAllTextAsync(Path.Combine(context.Root, "Metadata", "assets.jsonl"));
        True(assets.Contains(Sha(bytes), StringComparison.Ordinal));
        True(!Directory.EnumerateFiles(Path.Combine(context.Root, ".mbphotos"), "manifest-build-*").Any(),
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
            ProposedRelativePath = "Photos/2026/2026-08/2026-08-24/unavailable.jpg",
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
        var assetsJsonl = await File.ReadAllTextAsync(Path.Combine(context.Root, "Metadata", "assets.jsonl"));
        True(assetsJsonl.Contains(Sha(bytes), StringComparison.Ordinal));
        True(assetsJsonl.Contains(failedFileId.ToString("D"), StringComparison.Ordinal));
        var repeatedPlan = await context.Coordinator.CreateJobAsync(job);
        Equal(JobState.CompletedWithFailures, repeatedPlan.State);

        var differentRequest = request with { CompletedAt = completedAt.AddSeconds(1) };
        Equal(ErrorCodes.JobConflict, (await ThrowsAsync<ReceiverApiException>(() => context.Coordinator.CompleteAsync(job.JobId, differentRequest))).Error.Code);
        var changedJob = job with { SourceTimeZone = "America/Chicago" };
        Equal(ErrorCodes.JobConflict, (await ThrowsAsync<ReceiverApiException>(() => context.Coordinator.CreateJobAsync(changedJob))).Error.Code);

        var duplicateJob = Job(bytes, new StableIds(), Guid.NewGuid(), new string('8', 64), "Photos/2026/2026-08/2026-08-24/failure.jpg");
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
                ExportFileKind.OriginalResource,
                ResourceType.Photo,
                "asset.jpg",
                $"Photos/stress/{index:D6}.jpg",
                0,
                HashOfEmptyFile,
                revision,
                timestamp,
                "image/jpeg");
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
                new[] { file });
        }

        var job = new ExportJob(
            ProtocolConstants.Version,
            Guid.NewGuid(),
            DateTimeOffset.UtcNow,
            "Etc/UTC",
            new ExportProfile(ExportProfileKind.PreserveOriginals, 1, true),
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
        string proposed = "Photos/2026/2026-08/2026-08-24/photo.jpg",
        string albumTitle = "Test Album")
    {
        var timestamp = new DateTimeOffset(2026, 8, 24, 12, 0, 0, TimeSpan.Zero);
        var file = new ExportFile(
            ids.FileId,
            ids.AssetId,
            ExportFileKind.OriginalResource,
            ResourceType.Photo,
            "photo.jpg",
            proposed,
            bytes.LongLength,
            null,
            revision,
            timestamp,
            "image/jpeg");
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
            new[] { file });
        return new ExportJob(
            ProtocolConstants.Version,
            jobId,
            DateTimeOffset.UtcNow,
            "Etc/UTC",
            new ExportProfile(ExportProfileKind.PreserveOriginals, 1, true),
            new SelectionSnapshot(SelectionKind.Manual, 1),
            new[] { asset },
            new[] { new AlbumMembership(ids.AlbumId, "album/L0/001", albumTitle, null, ids.AssetId) });
    }

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
            var coordinator = new JobCoordinator(destination, manager, ledger, policy, transfer, writer, JsonOptions);
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
