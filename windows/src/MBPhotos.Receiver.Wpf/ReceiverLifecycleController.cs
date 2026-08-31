using MBPhotos.Receiver.Hosting;
using MBPhotos.Receiver.Transfer;
using QRCoder;
using System.IO;
using System.Windows.Media.Imaging;

namespace MBPhotos.Receiver.Wpf;

internal enum ReceiverLifecycleState
{
    Stopped,
    Starting,
    Running,
    Stopping,
    Faulted,
}

internal sealed record ReceiverLifecycleSnapshot(
    ReceiverLifecycleState State,
    long Generation,
    ReceiverServer? Receiver,
    Exception? Error = null);

internal sealed record ReceiverStartResult(
    long Generation,
    ReceiverServer Receiver,
    BitmapImage PairingQrBitmap);

/// <summary>
/// Owns the receiver lifetime independently of the window lifetime. All host,
/// SQLite, filesystem, certificate, and shutdown work crosses a worker boundary.
/// </summary>
internal sealed class ReceiverLifecycleController : IAsyncDisposable
{
    private readonly object sync = new();
    private readonly SemaphoreSlim operationGate = new(1, 1);
    private readonly ReceiverActivityFeed activityFeed;
    private readonly ReceiverLifecycleGenerationFence generationFence = new();

    private ReceiverLifecycleSnapshot snapshot = new(ReceiverLifecycleState.Stopped, 0, null);
    private CancellationTokenSource? startCancellation;
    private Task<ReceiverServer>? startTask;
    private EventHandler<ReceiverActivity>? activityHandler;

    public ReceiverLifecycleController(ReceiverActivityFeed activityFeed)
    {
        this.activityFeed = activityFeed;
    }

    public event EventHandler<ReceiverLifecycleSnapshot>? StateChanged;

    public ReceiverLifecycleSnapshot Snapshot
    {
        get
        {
            lock (sync)
            {
                return snapshot;
            }
        }
    }

    public async Task<ReceiverStartResult> StartAsync(
        string destinationPath,
        bool allowInitialize,
        CancellationToken cancellationToken = default)
    {
        long generation;
        lock (sync)
        {
            if (!generationFence.TryReserveStart(out generation))
            {
                throw new ObjectDisposedException(nameof(ReceiverLifecycleController));
            }
        }

        await operationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ThrowIfStartWasStopped(generation);
            await StopCurrentUnderGateAsync().ConfigureAwait(false);

            CancellationTokenSource localCancellation;
            lock (sync)
            {
                ThrowIfDisposed();
                if (generationFence.StatusFor(generation) == ReceiverLifecycleStartStatus.StopRequested)
                {
                    throw new OperationCanceledException("Receiver startup was superseded by a stop request.");
                }

                localCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                startCancellation = localCancellation;
                SetSnapshotUnderLock(new ReceiverLifecycleSnapshot(
                    ReceiverLifecycleState.Starting,
                    generation,
                    null));
            }
            PublishSnapshot();
            activityFeed.Activate(generation);

            var localTask = Task.Run(
                () => ReceiverServer.StartAsync(
                    destinationPath,
                    allowInitialize,
                    cancellationToken: localCancellation.Token),
                CancellationToken.None);
            lock (sync)
            {
                startTask = localTask;
            }

            ReceiverServer started;
            try
            {
                started = await localTask.ConfigureAwait(false);
            }
            catch (Exception exception)
            {
                activityFeed.Deactivate(generation);
                lock (sync)
                {
                    if (ReferenceEquals(startTask, localTask))
                    {
                        startTask = null;
                    }
                    if (ReferenceEquals(startCancellation, localCancellation))
                    {
                        startCancellation = null;
                    }

                    var state = exception is OperationCanceledException
                        ? ReceiverLifecycleState.Stopped
                        : ReceiverLifecycleState.Faulted;
                    SetSnapshotUnderLock(new ReceiverLifecycleSnapshot(
                        state,
                        generation,
                        null,
                        state == ReceiverLifecycleState.Faulted ? exception : null));
                }
                localCancellation.Dispose();
                PublishSnapshot();
                throw;
            }

            BitmapImage pairingQrBitmap;
            try
            {
                pairingQrBitmap = await Task.Run(
                    () => CreateQrBitmap(started.QrPayload),
                    CancellationToken.None).ConfigureAwait(false);
            }
            catch (Exception exception)
            {
                Exception reported = exception;
                try
                {
                    await DisposeReceiverOnWorkerAsync(started).ConfigureAwait(false);
                }
                catch (Exception cleanupException)
                {
                    reported = new AggregateException("QR generation and receiver cleanup both failed.", exception, cleanupException);
                }
                activityFeed.Deactivate(generation);
                lock (sync)
                {
                    if (ReferenceEquals(startTask, localTask))
                    {
                        startTask = null;
                    }
                    if (ReferenceEquals(startCancellation, localCancellation))
                    {
                        startCancellation = null;
                    }
                    SetSnapshotUnderLock(new ReceiverLifecycleSnapshot(
                        ReceiverLifecycleState.Faulted,
                        generation,
                        null,
                        reported));
                }
                localCancellation.Dispose();
                PublishSnapshot();
                throw reported;
            }

            EventHandler<ReceiverActivity> handler = (_, activity) => activityFeed.Publish(generation, activity);
            started.Coordinator.ActivityChanged += handler;
            bool committed;
            lock (sync)
            {
                // This lock is the Running linearization point. A stop/dispose
                // recorded before it must win even if startup ignored cancellation.
                var ownsStartup =
                    ReferenceEquals(startTask, localTask) &&
                    ReferenceEquals(startCancellation, localCancellation) &&
                    snapshot.State == ReceiverLifecycleState.Starting &&
                    snapshot.Generation == generation;
                committed = generationFence.TryCommitRunning(
                    generation,
                    localCancellation.IsCancellationRequested,
                    ownsStartup,
                    () =>
                    {
                        startTask = null;
                        startCancellation = null;
                        activityHandler = handler;
                        SetSnapshotUnderLock(new ReceiverLifecycleSnapshot(
                            ReceiverLifecycleState.Running,
                            generation,
                            started));
                    });
            }

            if (!committed)
            {
                started.Coordinator.ActivityChanged -= handler;
                var canceledToken = localCancellation.Token;
                Exception? cleanupFailure = null;
                try
                {
                    await DisposeReceiverOnWorkerAsync(started).ConfigureAwait(false);
                }
                catch (Exception exception)
                {
                    cleanupFailure = exception;
                }
                activityFeed.Deactivate(generation);
                lock (sync)
                {
                    if (ReferenceEquals(startTask, localTask))
                    {
                        startTask = null;
                    }
                    if (ReferenceEquals(startCancellation, localCancellation))
                    {
                        startCancellation = null;
                    }
                    if (snapshot.State == ReceiverLifecycleState.Starting &&
                        snapshot.Generation == generation)
                    {
                        SetSnapshotUnderLock(new ReceiverLifecycleSnapshot(
                            cleanupFailure is null ? ReceiverLifecycleState.Stopped : ReceiverLifecycleState.Faulted,
                            generation,
                            cleanupFailure is null ? null : started,
                            cleanupFailure));
                    }
                }
                localCancellation.Dispose();
                PublishSnapshot();
                if (cleanupFailure is not null)
                {
                    throw cleanupFailure;
                }
                throw new OperationCanceledException(
                    "Receiver startup was canceled before it became active.",
                    innerException: null,
                    canceledToken);
            }

            localCancellation.Dispose();
            PublishSnapshot();
            return new ReceiverStartResult(generation, started, pairingQrBitmap);
        }
        finally
        {
            operationGate.Release();
        }
    }

    public async Task StopAsync(CancellationToken cancellationToken = default)
    {
        var stopRequest = RecordStopRequest();
        RequestCancellation(stopRequest.Cancellation);
        await operationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await StopCurrentUnderGateAsync(stopRequest.StopRequest).ConfigureAwait(false);
        }
        finally
        {
            operationGate.Release();
        }
    }

    public async ValueTask DisposeAsync()
    {
        CancellationTokenSource? cancellation;
        lock (sync)
        {
            if (!generationFence.TryRecordDisposal(out _))
            {
                return;
            }
            cancellation = startCancellation;
        }

        RequestCancellation(cancellation);
        await operationGate.WaitAsync().ConfigureAwait(false);
        try
        {
            await StopCurrentUnderGateAsync().ConfigureAwait(false);
        }
        finally
        {
            operationGate.Release();
            // StopAsync may already be waiting here. SemaphoreSlim.Dispose is
            // not safe concurrently with waiters, so retain this tiny gate for
            // the controller's process-bounded lifetime.
        }
    }

    private async Task StopCurrentUnderGateAsync(ReceiverLifecycleStopRequest? stopRequest = null)
    {
        ReceiverServer? current;
        EventHandler<ReceiverActivity>? handler;
        long generation;
        lock (sync)
        {
            if (stopRequest is { } request && !request.Includes(snapshot.Generation))
            {
                return;
            }

            current = snapshot.Receiver;
            handler = activityHandler;
            generation = snapshot.Generation;
            activityHandler = null;

            if (current is null)
            {
                if (snapshot.State is not ReceiverLifecycleState.Starting and not ReceiverLifecycleState.Stopped)
                {
                    SetSnapshotUnderLock(new ReceiverLifecycleSnapshot(
                        ReceiverLifecycleState.Stopped,
                        generation,
                        null));
                }
                else
                {
                    return;
                }
            }
            else
            {
                SetSnapshotUnderLock(new ReceiverLifecycleSnapshot(
                    ReceiverLifecycleState.Stopping,
                    generation,
                    current));
            }
        }

        PublishSnapshot();
        activityFeed.Deactivate(generation);

        if (current is not null)
        {
            if (handler is not null)
            {
                current.Coordinator.ActivityChanged -= handler;
            }

            try
            {
                await DisposeReceiverOnWorkerAsync(current).ConfigureAwait(false);
            }
            catch (Exception exception)
            {
                lock (sync)
                {
                    SetSnapshotUnderLock(new ReceiverLifecycleSnapshot(
                        ReceiverLifecycleState.Faulted,
                        generation,
                        null,
                        exception));
                }
                PublishSnapshot();
                throw;
            }
        }

        lock (sync)
        {
            SetSnapshotUnderLock(new ReceiverLifecycleSnapshot(
                ReceiverLifecycleState.Stopped,
                generation,
                null));
        }
        PublishSnapshot();
    }

    private static Task DisposeReceiverOnWorkerAsync(ReceiverServer receiver) => Task.Run(async () =>
    {
        await receiver.DisposeAsync().ConfigureAwait(false);
    });

    private static BitmapImage CreateQrBitmap(string payload)
    {
        using var generator = new QRCodeGenerator();
        using var data = generator.CreateQrCode(payload, QRCodeGenerator.ECCLevel.Q);
        var png = new PngByteQRCode(data).GetGraphic(8, drawQuietZones: true);
        using var stream = new MemoryStream(png);
        var image = new BitmapImage();
        image.BeginInit();
        image.CacheOption = BitmapCacheOption.OnLoad;
        image.StreamSource = stream;
        image.EndInit();
        image.Freeze();
        return image;
    }

    private (ReceiverLifecycleStopRequest StopRequest, CancellationTokenSource? Cancellation) RecordStopRequest()
    {
        lock (sync)
        {
            return (generationFence.RecordStop(), startCancellation);
        }
    }

    private static void RequestCancellation(CancellationTokenSource? cancellation)
    {
        try
        {
            cancellation?.Cancel();
        }
        catch (ObjectDisposedException)
        {
        }
    }

    private void ThrowIfStartWasStopped(long generation)
    {
        switch (generationFence.StatusFor(generation))
        {
            case ReceiverLifecycleStartStatus.Disposed:
                throw new ObjectDisposedException(nameof(ReceiverLifecycleController));
            case ReceiverLifecycleStartStatus.StopRequested:
                throw new OperationCanceledException("Receiver startup was superseded by a stop request.");
        }
    }

    private void SetSnapshotUnderLock(ReceiverLifecycleSnapshot value) => snapshot = value;

    private void PublishSnapshot()
    {
        ReceiverLifecycleSnapshot current;
        EventHandler<ReceiverLifecycleSnapshot>? handlers;
        lock (sync)
        {
            current = snapshot;
            handlers = StateChanged;
        }

        if (handlers is null)
        {
            return;
        }

        foreach (EventHandler<ReceiverLifecycleSnapshot> handler in handlers.GetInvocationList())
        {
            try
            {
                handler(this, current);
            }
            catch
            {
                // Lifecycle observers are advisory and cannot own receiver cleanup.
            }
        }
    }

    private void ThrowIfDisposed()
    {
        if (generationFence.IsDisposed)
        {
            throw new ObjectDisposedException(nameof(ReceiverLifecycleController));
        }
    }
}
