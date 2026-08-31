namespace MBPhotos.Receiver.Transfer;

/// <summary>
/// Bounds the final hop from an activity feed to a single-threaded consumer.
/// Ordinary activity is latest-value only, urgent activity has a separate slot,
/// and no more than one consumer callback is scheduled at a time.
/// </summary>
public sealed class ReceiverActivityDispatcher : IDisposable
{
    private readonly object sync = new();
    private readonly Func<Action, bool> schedule;
    private readonly Action<ReceiverActivityEnvelope> deliver;
    private ReceiverActivityEnvelope? latest;
    private ReceiverActivityEnvelope? urgent;
    private long activeGeneration = long.MinValue;
    private bool terminalSeen;
    private bool callbackScheduled;
    private bool disposed;

    public ReceiverActivityDispatcher(
        Func<Action, bool> schedule,
        Action<ReceiverActivityEnvelope> deliver)
    {
        this.schedule = schedule ?? throw new ArgumentNullException(nameof(schedule));
        this.deliver = deliver ?? throw new ArgumentNullException(nameof(deliver));
    }

    public void Post(ReceiverActivityEnvelope envelope)
    {
        ArgumentNullException.ThrowIfNull(envelope);
        var shouldSchedule = false;

        lock (sync)
        {
            if (disposed || envelope.Generation < activeGeneration)
            {
                return;
            }

            if (envelope.Generation > activeGeneration)
            {
                // A newer receiver generation supersedes every pending UI value.
                activeGeneration = envelope.Generation;
                terminalSeen = false;
                latest = null;
                urgent = null;
            }

            if (terminalSeen)
            {
                return;
            }

            if (IsTerminal(envelope.Activity.State))
            {
                terminalSeen = true;
                latest = null;
                urgent = envelope;
            }
            else if (envelope.Activity.ErrorMessage is not null)
            {
                // Do not let progress that predates the error render after it.
                latest = null;
                urgent = envelope;
            }
            else
            {
                latest = envelope;
            }

            if (!callbackScheduled)
            {
                callbackScheduled = true;
                shouldSchedule = true;
            }
        }

        if (shouldSchedule)
        {
            ScheduleDispatch();
        }
    }

    public void Dispose()
    {
        lock (sync)
        {
            disposed = true;
            latest = null;
            urgent = null;
        }
    }

    private void DispatchOne()
    {
        ReceiverActivityEnvelope? envelope;
        lock (sync)
        {
            if (disposed)
            {
                callbackScheduled = false;
                return;
            }

            envelope = urgent ?? latest;
            if (ReferenceEquals(envelope, urgent))
            {
                urgent = null;
            }
            else
            {
                latest = null;
            }

            if (envelope is null)
            {
                callbackScheduled = false;
                return;
            }
        }

        try
        {
            deliver(envelope);
        }
        catch
        {
            // Activity is advisory. One presentation failure must not wedge the
            // callback gate or affect receiver work.
        }

        var shouldSchedule = false;
        lock (sync)
        {
            if (disposed)
            {
                latest = null;
                urgent = null;
                callbackScheduled = false;
            }
            else if (urgent is not null || latest is not null)
            {
                // Keep callbackScheduled true across the handoff so a producer
                // can never enqueue a second dispatcher operation concurrently.
                shouldSchedule = true;
            }
            else
            {
                callbackScheduled = false;
            }
        }

        if (shouldSchedule)
        {
            ScheduleDispatch();
        }
    }

    private void ScheduleDispatch()
    {
        var accepted = false;
        try
        {
            accepted = schedule(DispatchOne);
        }
        catch
        {
            // Dispatcher shutdown is expected during application teardown.
        }

        if (accepted)
        {
            return;
        }

        lock (sync)
        {
            callbackScheduled = false;
        }
    }

    private static bool IsTerminal(string state) =>
        state is "completed" or "completedWithFailures" or "abandoned";
}
