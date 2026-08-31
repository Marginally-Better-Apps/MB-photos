namespace MBPhotos.Receiver.Hosting;

/// <summary>
/// Owns the window-close and explicit-exit policy without depending on WPF.
/// Exit is single-flight: receiver disposal finishes before application-owned
/// observers and tray resources are cleaned up, and shutdown always runs last.
/// </summary>
public sealed class ApplicationLifetimeCoordinator
{
    private readonly object sync = new();
    private readonly Action hideWindow;
    private readonly Func<ValueTask> disposeLifecycle;
    private readonly Action cleanupApplicationResources;
    private readonly Action<Exception> reportError;
    private readonly Action shutdown;
    private Task? exitTask;
    private bool exiting;

    public ApplicationLifetimeCoordinator(
        Action hideWindow,
        Func<ValueTask> disposeLifecycle,
        Action cleanupApplicationResources,
        Action<Exception> reportError,
        Action shutdown)
    {
        this.hideWindow = hideWindow ?? throw new ArgumentNullException(nameof(hideWindow));
        this.disposeLifecycle = disposeLifecycle ?? throw new ArgumentNullException(nameof(disposeLifecycle));
        this.cleanupApplicationResources = cleanupApplicationResources ?? throw new ArgumentNullException(nameof(cleanupApplicationResources));
        this.reportError = reportError ?? throw new ArgumentNullException(nameof(reportError));
        this.shutdown = shutdown ?? throw new ArgumentNullException(nameof(shutdown));
    }

    public bool IsExiting
    {
        get
        {
            lock (sync)
            {
                return exiting;
            }
        }
    }

    /// <summary>
    /// Returns true when the platform close event should be canceled. Explicit
    /// exit has already taken ownership when this returns false.
    /// </summary>
    public bool HandleCloseRequested()
    {
        lock (sync)
        {
            if (exiting)
            {
                return false;
            }
        }

        try
        {
            hideWindow();
        }
        catch (Exception exception)
        {
            Report(exception);
        }

        return true;
    }

    public Task ExitAsync()
    {
        TaskCompletionSource<object?>? completion = null;
        lock (sync)
        {
            if (exitTask is not null)
            {
                return exitTask;
            }

            exiting = true;
            completion = new TaskCompletionSource<object?>(
                TaskCreationOptions.RunContinuationsAsynchronously);
            exitTask = completion.Task;
        }

        // Start on the caller's context after releasing the state lock. WPF
        // cleanup therefore returns to its dispatcher after asynchronous stop.
        _ = ExitCoreAsync(completion);
        return completion.Task;
    }

    private async Task ExitCoreAsync(TaskCompletionSource<object?> completion)
    {
        try
        {
            try
            {
                await disposeLifecycle();
            }
            catch (Exception exception)
            {
                Report(exception);
            }

            try
            {
                cleanupApplicationResources();
            }
            catch (Exception exception)
            {
                Report(exception);
            }

            try
            {
                shutdown();
            }
            catch (Exception exception)
            {
                Report(exception);
            }
        }
        finally
        {
            completion.TrySetResult(null);
        }
    }

    private void Report(Exception exception)
    {
        try
        {
            reportError(exception);
        }
        catch
        {
            // Reporting is best-effort during close and must never prevent the
            // remaining orderly-exit steps.
        }
    }
}
