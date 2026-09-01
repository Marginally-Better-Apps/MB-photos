using System.Windows.Media.Imaging;
using System.Runtime.ExceptionServices;
using MBPhotos.Receiver.Hosting;
using MBPhotos.Receiver.Transfer;

namespace MBPhotos.Receiver.Wpf;

/// <summary>
/// Owns receiver presentation state independently of the window. Pairing-code
/// renewal and post-transfer readiness therefore continue while the window is
/// hidden in the notification area.
/// </summary>
internal sealed class ReceiverOrchestrator : IAsyncDisposable
{
    private readonly object sync = new();
    private readonly SemaphoreSlim operationGate = new(1, 1);
    private readonly ReceiverLifecycleController lifecycle;
    private readonly ReceiverActivityFeed activityFeed;
    private readonly ReceiverSettingsStore settingsStore;
    private readonly HashSet<Guid> terminalResponseJobs = [];

    private ReceiverOrchestrationSnapshot snapshot = ReceiverOrchestrationSnapshot.Initial;
    private volatile ReceiverServer? observedReceiver;
    private CancellationTokenSource? invitationExpiryCancellation;
    private bool initialized;
    private volatile bool manualPause;
    private volatile bool libraryMode;
    private bool resumeAfterLibrary;
    private volatile bool disposed;
    private long pairingRevision;
    private long observedPairingStateRevision;
    private long stateRevision;

    public ReceiverOrchestrator(
        ReceiverLifecycleController lifecycle,
        ReceiverActivityFeed activityFeed,
        ReceiverSettingsStore settingsStore)
    {
        this.lifecycle = lifecycle ?? throw new ArgumentNullException(nameof(lifecycle));
        this.activityFeed = activityFeed ?? throw new ArgumentNullException(nameof(activityFeed));
        this.settingsStore = settingsStore ?? throw new ArgumentNullException(nameof(settingsStore));
        lifecycle.StateChanged += Lifecycle_StateChanged;
        activityFeed.ActivityAvailable += ActivityFeed_ActivityAvailable;
    }

    public event EventHandler<ReceiverOrchestrationSnapshot>? StateChanged;

    public event EventHandler<ReceiverActivityEnvelope>? ActivityAvailable;

    public ReceiverOrchestrationSnapshot Snapshot
    {
        get
        {
            lock (sync)
            {
                return snapshot;
            }
        }
    }

    public async Task InitializeAsync(CancellationToken cancellationToken = default)
    {
        await operationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ThrowIfDisposed();
            if (initialized)
            {
                return;
            }

            initialized = true;
            var settings = await settingsStore.LoadAsync(cancellationToken).ConfigureAwait(false);
            if (settings is null)
            {
                Publish(current => current with
                {
                    State = ReceiverPresentationState.Setup,
                    LibraryRoot = null,
                    Error = null,
                });
                return;
            }

            Publish(current => current with { LibraryRoot = settings.LibraryRoot });
            await StartUnderGateAsync(settings.LibraryRoot, allowInitialize: false, persist: false, cancellationToken)
                .ConfigureAwait(false);
        }
        finally
        {
            operationGate.Release();
        }
    }

    public async Task StartOrResumeAsync(CancellationToken cancellationToken = default)
    {
        await operationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ThrowIfDisposed();
            manualPause = false;
            libraryMode = false;
            var root = Snapshot.LibraryRoot;
            if (string.IsNullOrWhiteSpace(root))
            {
                var settings = await settingsStore.LoadAsync(cancellationToken).ConfigureAwait(false);
                root = settings?.LibraryRoot;
            }

            if (string.IsNullOrWhiteSpace(root))
            {
                Publish(current => current with
                {
                    State = ReceiverPresentationState.Setup,
                    LibraryRoot = null,
                    Error = null,
                    IsManualPause = false,
                });
                return;
            }

            await StartUnderGateAsync(root, allowInitialize: false, persist: false, cancellationToken)
                .ConfigureAwait(false);
        }
        finally
        {
            operationGate.Release();
        }
    }

    public async Task ChangeLibraryAsync(
        string path,
        bool allowInitialize,
        CancellationToken cancellationToken = default)
    {
        var candidate = new ReceiverSettings(path);
        await operationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ThrowIfDisposed();
            var current = Snapshot;
            if (current.State is ReceiverPresentationState.Transferring or ReceiverPresentationState.Finalizing)
            {
                throw new InvalidOperationException("Wait for the current transfer to finish before changing the library.");
            }
            if (observedReceiver is { } runningReceiver && !runningReceiver.TryQuiesceJobAdmissions())
            {
                throw new InvalidOperationException("A transfer just started. Wait for it to finish before changing the library.");
            }

            manualPause = false;
            libraryMode = false;
            await StartUnderGateAsync(
                    candidate.LibraryRoot,
                    allowInitialize,
                    persist: true,
                    cancellationToken)
                .ConfigureAwait(false);
        }
        finally
        {
            operationGate.Release();
        }
    }

    public async Task StopAsync(bool manualPause = true, CancellationToken cancellationToken = default)
    {
        lock (sync)
        {
            ThrowIfDisposed();
            this.manualPause |= manualPause;
        }

        // Record the lifecycle stop before waiting for the orchestration gate.
        // Startup deliberately holds that gate while it crosses the worker
        // boundary, so waiting first would make Cancel during Starting unable to
        // fence the pending Running commit.
        CancelInvitationExpiry();
        Exception? stopFailure = null;
        try
        {
            await lifecycle.StopAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (Exception exception)
        {
            stopFailure = exception;
        }

        await operationGate.WaitAsync(CancellationToken.None).ConfigureAwait(false);
        try
        {
            // Another start intent may have acquired the orchestration gate after
            // the first lifecycle stop completed. Stop once more while this gate
            // is held so the final Paused presentation and the host lifetime have
            // one linearization point.
            this.manualPause |= manualPause;
            try
            {
                await lifecycle.StopAsync(CancellationToken.None).ConfigureAwait(false);
            }
            catch (Exception exception)
            {
                stopFailure = stopFailure is null
                    ? exception
                    : new AggregateException(
                        "The receiver could not be stopped cleanly.",
                        stopFailure,
                        exception);
            }
            DetachReceiver();
            PublishStoppedState();
        }
        finally
        {
            operationGate.Release();
        }

        if (stopFailure is not null)
        {
            ExceptionDispatchInfo.Capture(stopFailure).Throw();
        }
    }

    public async Task EnterLibraryAsync(CancellationToken cancellationToken = default)
    {
        await operationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ThrowIfDisposed();
            var current = Snapshot;
            if (current.State is ReceiverPresentationState.Transferring or ReceiverPresentationState.Finalizing)
            {
                throw new InvalidOperationException("Wait for the current transfer to finish before opening Library.");
            }
            if (observedReceiver is { } runningReceiver && !runningReceiver.TryQuiesceJobAdmissions())
            {
                throw new InvalidOperationException("A transfer just started. Wait for it to finish before opening Library.");
            }

            resumeAfterLibrary = !manualPause;
            libraryMode = true;
            CancelInvitationExpiry();
            DetachReceiver();
            await lifecycle.StopAsync(cancellationToken).ConfigureAwait(false);
            Publish(current => current with
            {
                State = ReceiverPresentationState.Library,
                Receiver = null,
                PairingQrBitmap = null,
                PairingPayload = null,
                Activity = null,
                Error = null,
                IsManualPause = manualPause,
            });
        }
        finally
        {
            operationGate.Release();
        }
    }

    public async Task ExitLibraryAsync(CancellationToken cancellationToken = default)
    {
        await operationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ThrowIfDisposed();
            libraryMode = false;
            var shouldResume = resumeAfterLibrary && !manualPause;
            resumeAfterLibrary = false;
            var root = Snapshot.LibraryRoot;
            if (string.IsNullOrWhiteSpace(root))
            {
                Publish(current => current with { State = ReceiverPresentationState.Setup });
                return;
            }

            if (!shouldResume)
            {
                Publish(current => current with
                {
                    State = ReceiverPresentationState.Paused,
                    Receiver = null,
                    PairingQrBitmap = null,
                    PairingPayload = null,
                    Activity = null,
                    Error = null,
                    IsManualPause = true,
                });
                return;
            }

            manualPause = false;
            await StartUnderGateAsync(root, allowInitialize: false, persist: false, cancellationToken)
                .ConfigureAwait(false);
        }
        finally
        {
            operationGate.Release();
        }
    }

    public Task RetryAsync(CancellationToken cancellationToken = default) =>
        StartOrResumeAsync(cancellationToken);

    public async Task RefreshPairingAsync(CancellationToken cancellationToken = default)
    {
        await operationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ThrowIfDisposed();
            var receiver = observedReceiver;
            if (receiver is null || manualPause || libraryMode ||
                Snapshot.State is ReceiverPresentationState.Transferring or ReceiverPresentationState.Finalizing)
            {
                return;
            }

            ApplyPairingState(receiver, receiver.RefreshPairingInvitation());
        }
        finally
        {
            operationGate.Release();
        }
    }

    public async ValueTask DisposeAsync()
    {
        lock (sync)
        {
            if (disposed)
            {
                return;
            }

            disposed = true;
            manualPause = true;
        }

        // Lifecycle disposal is also the cancellation signal for an in-flight
        // startup. Send it before taking operationGate for the same reason as a
        // manual stop.
        CancelInvitationExpiry();
        Exception? lifecycleFailure = null;
        try
        {
            await lifecycle.DisposeAsync().ConfigureAwait(false);
        }
        catch (Exception exception)
        {
            lifecycleFailure = exception;
        }

        await operationGate.WaitAsync().ConfigureAwait(false);
        try
        {
            DetachReceiver();
            lifecycle.StateChanged -= Lifecycle_StateChanged;
            activityFeed.ActivityAvailable -= ActivityFeed_ActivityAvailable;
        }
        finally
        {
            operationGate.Release();
        }

        if (lifecycleFailure is not null)
        {
            ExceptionDispatchInfo.Capture(lifecycleFailure).Throw();
        }
    }

    private async Task StartUnderGateAsync(
        string root,
        bool allowInitialize,
        bool persist,
        CancellationToken cancellationToken)
    {
        CancelInvitationExpiry();
        DetachReceiver();
        Publish(current =>
        {
            terminalResponseJobs.Clear();
            return current with
            {
                State = ReceiverPresentationState.Starting,
                PairingQrBitmap = null,
                PairingPayload = null,
                Activity = null,
                Error = null,
                Receiver = null,
                IsManualPause = false,
            };
        });

        try
        {
            var result = await lifecycle.StartAsync(root, allowInitialize, cancellationToken).ConfigureAwait(false);
            var lifecycleSnapshot = lifecycle.Snapshot;
            if (lifecycleSnapshot.State != ReceiverLifecycleState.Running ||
                lifecycleSnapshot.Generation != result.Generation)
            {
                return;
            }

            var actualRoot = result.Receiver.Destination.RootPath;
            if (persist)
            {
                try
                {
                    // A location change is not successful until the exact root
                    // that opened is durable for the next launch.
                    await settingsStore.SaveAsync(new ReceiverSettings(actualRoot), cancellationToken)
                        .ConfigureAwait(false);
                }
                catch (Exception persistenceException)
                {
                    Exception reported = persistenceException;
                    try
                    {
                        await lifecycle.StopAsync(CancellationToken.None).ConfigureAwait(false);
                    }
                    catch (Exception cleanupException)
                    {
                        reported = new AggregateException(
                            "The library location could not be saved and the temporary receiver could not be stopped cleanly.",
                            persistenceException,
                            cleanupException);
                    }

                    Publish(current => current with
                    {
                        State = ReceiverPresentationState.Error,
                        PairingQrBitmap = null,
                        PairingPayload = null,
                        Activity = null,
                        Error = reported,
                        Receiver = null,
                        IsManualPause = false,
                    });
                    return;
                }
            }

            manualPause = false;
            libraryMode = false;
            AttachReceiver(result.Receiver);
            Publish(current =>
            {
                var rootChanged = !string.Equals(
                    current.LibraryRoot,
                    actualRoot,
                    StringComparison.OrdinalIgnoreCase);
                return current with
                {
                    State = ReceiverPresentationState.Ready,
                    Generation = result.Generation,
                    LibraryRoot = actualRoot,
                    PairingQrBitmap = result.PairingQrBitmap,
                    PairingPayload = result.Receiver.PairingState.QrPayload,
                    Activity = null,
                    LastTransfer = rootChanged ? null : current.LastTransfer,
                    Error = null,
                    Receiver = result.Receiver,
                    IsManualPause = false,
                };
            });

            ApplyPairingState(result.Receiver, result.Receiver.PairingState, result.PairingQrBitmap);
        }
        catch (OperationCanceledException) when (manualPause || libraryMode)
        {
            PublishStoppedState();
        }
        catch (Exception exception)
        {
            Publish(current => current with
            {
                State = ReceiverPresentationState.Error,
                PairingQrBitmap = null,
                PairingPayload = null,
                Activity = null,
                Error = exception,
                Receiver = null,
                IsManualPause = manualPause,
            });
        }
    }

    private void AttachReceiver(ReceiverServer receiver)
    {
        Volatile.Write(ref observedPairingStateRevision, 0);
        observedReceiver = receiver;
        receiver.PairingStateChanged += Receiver_PairingStateChanged;
        receiver.TerminalResponseCompleted += Receiver_TerminalResponseCompleted;
    }

    private void DetachReceiver()
    {
        var receiver = observedReceiver;
        observedReceiver = null;
        if (receiver is null)
        {
            return;
        }

        receiver.PairingStateChanged -= Receiver_PairingStateChanged;
        receiver.TerminalResponseCompleted -= Receiver_TerminalResponseCompleted;
    }

    private void Receiver_PairingStateChanged(object? sender, ReceiverPairingState pairingState)
    {
        if (sender is ReceiverServer receiver)
        {
            ApplyPairingState(receiver, pairingState);
        }
    }

    private void Receiver_TerminalResponseCompleted(
        object? sender,
        ReceiverTerminalResponseCompletedEventArgs args)
    {
        if (sender is not ReceiverServer receiver || !ReferenceEquals(receiver, observedReceiver))
        {
            return;
        }

        var pairingState = receiver.PairingState;
        var firstTerminalSignal = Publish(current =>
        {
            if (!terminalResponseJobs.Add(args.JobId))
            {
                // An idempotent terminal HTTP retry is authentication
                // compatibility, not a newer user-visible transfer summary.
                // Its final in-flight response can still be the transition that
                // makes the receiver idle, so never deduplicate readiness.
                if (!args.ReceiverIdle)
                {
                    return null;
                }

                return current with
                {
                    State = pairingState.QrPayload is not null
                        ? ReceiverPresentationState.Ready
                        : pairingState.HasActiveSession
                            ? ReceiverPresentationState.Connected
                            : ReceiverPresentationState.Starting,
                    Activity = current.Activity?.JobId == args.JobId ? null : current.Activity,
                    Error = null,
                };
            }

            var thumbnail = current.Activity?.LatestThumbnailRelativePath ??
                current.LastTransfer?.ThumbnailRelativePath;
            var anotherJobIsActive = current.Activity is { } activeActivity &&
                activeActivity.JobId != args.JobId &&
                current.State is ReceiverPresentationState.Transferring or ReceiverPresentationState.Finalizing;
            return current with
            {
                State = !args.ReceiverIdle || anotherJobIsActive
                    ? current.State
                    : pairingState.QrPayload is not null
                        ? ReceiverPresentationState.Ready
                        : pairingState.HasActiveSession
                            ? ReceiverPresentationState.Connected
                            : ReceiverPresentationState.Starting,
                Activity = current.Activity?.JobId == args.JobId ? null : current.Activity,
                LastTransfer = new LastTransferPresentation(args.State, args.Counts, thumbnail),
                Error = null,
            };
        });
        if (firstTerminalSignal)
        {
            ApplyPairingState(receiver, pairingState);
        }
    }

    private void ApplyPairingState(
        ReceiverServer receiver,
        ReceiverPairingState pairingState,
        BitmapImage? alreadyRendered = null)
    {
        if (!ReferenceEquals(receiver, observedReceiver) || manualPause || libraryMode)
        {
            return;
        }

        while (true)
        {
            var observedRevision = Volatile.Read(ref observedPairingStateRevision);
            if (pairingState.Revision < observedRevision)
            {
                return;
            }
            if (pairingState.Revision == observedRevision ||
                Interlocked.CompareExchange(
                    ref observedPairingStateRevision,
                    pairingState.Revision,
                    observedRevision) == observedRevision)
            {
                break;
            }
        }

        var revision = Interlocked.Increment(ref pairingRevision);
        CancelInvitationExpiry();
        if (pairingState.QrPayload is null)
        {
            Publish(current =>
            {
                if (!ReferenceEquals(receiver, observedReceiver) || manualPause || libraryMode)
                {
                    return null;
                }

                var nextState = current.State is ReceiverPresentationState.Transferring or ReceiverPresentationState.Finalizing
                    ? current.State
                    : pairingState.HasActiveSession
                        ? ReceiverPresentationState.Connected
                        : ReceiverPresentationState.Starting;
                return current with
                {
                    State = nextState,
                    PairingQrBitmap = null,
                    PairingPayload = null,
                    Receiver = receiver,
                };
            });
            return;
        }

        var accepted = Publish(current =>
        {
            if (!ReferenceEquals(receiver, observedReceiver) || manualPause || libraryMode)
            {
                return null;
            }

            return current with
            {
                // Invitations are issued only at an idle admission boundary.
                // Treat that server signal as authoritative even if an older
                // queued planning/finalizing activity reached presentation first.
                State = ReceiverPresentationState.Ready,
                PairingQrBitmap = alreadyRendered,
                PairingPayload = pairingState.QrPayload,
                Activity = null,
                Error = null,
                Receiver = receiver,
            };
        });
        if (!accepted)
        {
            return;
        }
        ScheduleInvitationExpiry(receiver, pairingState, revision);

        if (alreadyRendered is null)
        {
            _ = RenderQrAsync(receiver, pairingState.QrPayload, revision);
        }
    }

    private async Task RenderQrAsync(ReceiverServer receiver, string payload, long revision)
    {
        try
        {
            var bitmap = await Task.Run(() => QrBitmapFactory.Create(payload)).ConfigureAwait(false);
            if (revision != Volatile.Read(ref pairingRevision) ||
                !ReferenceEquals(receiver, observedReceiver))
            {
                return;
            }

            Publish(current =>
                string.Equals(current.PairingPayload, payload, StringComparison.Ordinal) &&
                revision == Volatile.Read(ref pairingRevision) &&
                ReferenceEquals(receiver, observedReceiver)
                    ? current with { PairingQrBitmap = bitmap }
                    : null);
        }
        catch
        {
            // A later refresh or explicit retry can recreate the presentation.
            // QR rendering must never stop the already-running receiver.
        }
    }

    private void ScheduleInvitationExpiry(
        ReceiverServer receiver,
        ReceiverPairingState pairingState,
        long revision)
    {
        if (pairingState.QrPayload is null || pairingState.InvitationExpiresAt is null)
        {
            return;
        }

        var cancellation = new CancellationTokenSource();
        invitationExpiryCancellation = cancellation;
        _ = RefreshAtExpiryAsync(receiver, pairingState, revision, cancellation.Token);
    }

    private async Task RefreshAtExpiryAsync(
        ReceiverServer receiver,
        ReceiverPairingState pairingState,
        long revision,
        CancellationToken cancellationToken)
    {
        try
        {
            var delay = pairingState.InvitationExpiresAt!.Value - DateTimeOffset.UtcNow;
            if (delay > TimeSpan.Zero)
            {
                await Task.Delay(delay, cancellationToken).ConfigureAwait(false);
            }

            await operationGate.WaitAsync(cancellationToken).ConfigureAwait(false);
            try
            {
                if (disposed || manualPause || libraryMode ||
                    revision != Volatile.Read(ref pairingRevision) ||
                    !ReferenceEquals(receiver, observedReceiver))
                {
                    return;
                }

                var refreshed = receiver.RefreshExpiredPairingInvitation(DateTimeOffset.UtcNow);
                if (string.Equals(refreshed.QrPayload, pairingState.QrPayload, StringComparison.Ordinal))
                {
                    ApplyPairingState(receiver, refreshed);
                }
            }
            finally
            {
                operationGate.Release();
            }
        }
        catch (OperationCanceledException)
        {
        }
        catch (ObjectDisposedException)
        {
        }
    }

    private void Lifecycle_StateChanged(object? sender, ReceiverLifecycleSnapshot lifecycleSnapshot)
    {
        switch (lifecycleSnapshot.State)
        {
            case ReceiverLifecycleState.Starting:
                Publish(current => lifecycleSnapshot.Generation >= current.Generation
                    ? current with
                {
                    State = ReceiverPresentationState.Starting,
                    Generation = lifecycleSnapshot.Generation,
                    Error = null,
                }
                    : null);
                break;
            case ReceiverLifecycleState.Faulted when lifecycleSnapshot.Error is not null:
                Publish(current => lifecycleSnapshot.Generation >= current.Generation
                    ? current with
                {
                    State = ReceiverPresentationState.Error,
                    Generation = lifecycleSnapshot.Generation,
                    Error = lifecycleSnapshot.Error,
                    Receiver = null,
                }
                    : null);
                break;
            case ReceiverLifecycleState.Stopped:
                var latest = lifecycle.Snapshot;
                if (latest.State == ReceiverLifecycleState.Stopped &&
                    latest.Generation == lifecycleSnapshot.Generation)
                {
                    PublishStoppedState();
                }
                break;
        }
    }

    private void ActivityFeed_ActivityAvailable(object? sender, ReceiverActivityEnvelope envelope)
    {
        var lifecycleSnapshot = lifecycle.Snapshot;
        if (lifecycleSnapshot.State != ReceiverLifecycleState.Running ||
            lifecycleSnapshot.Generation != envelope.Generation)
        {
            return;
        }

        var activity = envelope.Activity;
        var terminal = activity.State is "completed" or "completedWithFailures" or "abandoned";
        Publish(current =>
        {
            if (current.Generation != envelope.Generation)
            {
                return null;
            }

            if (terminalResponseJobs.Contains(activity.JobId))
            {
                // Coordinator observers are intentionally asynchronous. A
                // terminal activity can arrive after HTTP OnCompleted has already
                // returned the UI to Ready. Enrich the summary only.
                return terminal
                    ? current with
                    {
                        Activity = current.Activity?.JobId == activity.JobId ? null : current.Activity,
                        LastTransfer = new LastTransferPresentation(
                            activity.State,
                            activity.CompletionCounts ?? current.LastTransfer?.Counts,
                            activity.LatestThumbnailRelativePath ?? current.LastTransfer?.ThumbnailRelativePath),
                        Error = null,
                    }
                    : null;
            }

            var rejectedAtIdle = activity.State == "rejected" &&
                current.Receiver?.PairingState.QrPayload is not null;
            var nextState = activity.State switch
            {
                "planning" or "transferring" => ReceiverPresentationState.Transferring,
                "finalizing" => ReceiverPresentationState.Finalizing,
                "completed" or "completedWithFailures" or "abandoned" => ReceiverPresentationState.Finalizing,
                "rejected" when rejectedAtIdle => ReceiverPresentationState.Ready,
                "rejected" => current.State,
                _ => current.State,
            };
            return current with
            {
                State = nextState,
                Generation = envelope.Generation,
                // Rejection is scoped to one manifest request. A concurrent
                // request for the same durable job may already own the live
                // transfer, so only clear presentation when the server has
                // authoritatively re-issued its idle invitation.
                Activity = rejectedAtIdle
                    ? null
                    : activity.State == "rejected"
                        ? current.Activity
                        : activity,
                LastTransfer = terminal
                    ? new LastTransferPresentation(
                        activity.State,
                        activity.CompletionCounts,
                        activity.LatestThumbnailRelativePath ?? current.LastTransfer?.ThumbnailRelativePath)
                    : activity.State == "planning" ? null : current.LastTransfer,
                Error = null,
            };
        });
        PublishActivity(envelope);
    }

    private void PublishStoppedState()
    {
        Publish(current => current with
        {
            State = libraryMode
                ? ReceiverPresentationState.Library
                : current.LibraryRoot is null
                    ? ReceiverPresentationState.Setup
                    : ReceiverPresentationState.Paused,
            PairingQrBitmap = null,
            PairingPayload = null,
            Activity = null,
            Receiver = null,
            IsManualPause = manualPause,
        });
    }

    private void CancelInvitationExpiry()
    {
        var cancellation = Interlocked.Exchange(ref invitationExpiryCancellation, null);
        if (cancellation is null)
        {
            return;
        }

        try
        {
            cancellation.Cancel();
        }
        finally
        {
            cancellation.Dispose();
        }
    }

    private bool Publish(
        Func<ReceiverOrchestrationSnapshot, ReceiverOrchestrationSnapshot?> update)
    {
        ArgumentNullException.ThrowIfNull(update);
        EventHandler<ReceiverOrchestrationSnapshot>? handlers;
        ReceiverOrchestrationSnapshot value;
        lock (sync)
        {
            if (disposed)
            {
                return false;
            }

            var next = update(snapshot);
            if (next is null)
            {
                return false;
            }

            value = next with { Revision = ++stateRevision };
            snapshot = value;
            handlers = StateChanged;
        }

        if (handlers is null)
        {
            return true;
        }
        foreach (EventHandler<ReceiverOrchestrationSnapshot> handler in handlers.GetInvocationList())
        {
            try
            {
                handler(this, value);
            }
            catch
            {
                // Presentation observers cannot own receiver lifetime.
            }
        }
        return true;
    }

    private void PublishActivity(ReceiverActivityEnvelope envelope)
    {
        var handlers = ActivityAvailable;
        if (handlers is null)
        {
            return;
        }
        foreach (EventHandler<ReceiverActivityEnvelope> handler in handlers.GetInvocationList())
        {
            try
            {
                handler(this, envelope);
            }
            catch
            {
                // Activity observers are advisory.
            }
        }
    }

    private void ThrowIfDisposed()
    {
        lock (sync)
        {
            if (disposed)
            {
                throw new ObjectDisposedException(nameof(ReceiverOrchestrator));
            }
        }
    }
}
