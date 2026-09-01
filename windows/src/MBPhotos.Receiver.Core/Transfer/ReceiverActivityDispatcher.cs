namespace MBPhotos.Receiver.Transfer;

/// <summary>
/// Bounds the final hop from an activity feed to a single-threaded consumer.
/// Ordinary activity is latest-value only, urgent activity has a separate slot,
/// and no more than one consumer callback is scheduled at a time.
/// </summary>
public sealed class ReceiverActivityDispatcher : IDisposable
{
    private const int MaximumPendingTerminalActivities = 64;
    private readonly object sync = new();
    private readonly Func<Action, bool> schedule;
    private readonly Action<ReceiverActivityEnvelope> deliver;
    private ReceiverActivityEnvelope? latest;
    private ReceiverActivityEnvelope? urgent;
    private readonly Queue<ReceiverActivityEnvelope> terminalQueue = new();
    private readonly HashSet<Guid> terminalJobs = new();
    private long activeGeneration = long.MinValue;
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
                terminalJobs.Clear();
                terminalQueue.Clear();
                latest = null;
                urgent = null;
            }

            var terminal = IsTerminal(envelope.Activity.State);
            if (terminalJobs.Contains(envelope.Activity.JobId))
            {
                return;
            }

            if (terminal)
            {
                terminalJobs.Add(envelope.Activity.JobId);
                if (latest?.Activity.JobId == envelope.Activity.JobId)
                {
                    latest = null;
                }
                if (urgent?.Activity.JobId == envelope.Activity.JobId)
                {
                    urgent = null;
                }
                terminalQueue.Enqueue(envelope);
                while (terminalQueue.Count > MaximumPendingTerminalActivities)
                {
                    terminalQueue.Dequeue();
                }
            }
            else if (envelope.Activity.State == "rejected")
            {
                // Rejection is terminal for one request, not for the durable job.
                // Keep an established sibling snapshot queued behind it, but
                // discard a planning placeholder owned by the failed attempt.
                if (latest?.Activity.JobId == envelope.Activity.JobId &&
                    latest.Activity.State == "planning")
                {
                    latest = null;
                }
                urgent = envelope;
            }
            else if (envelope.Activity.ErrorMessage is not null)
            {
                // Do not let progress that predates the error render after it.
                if (latest?.Activity.JobId == envelope.Activity.JobId)
                {
                    latest = null;
                }
                urgent = envelope;
            }
            else
            {
                var preservesEstablishedSibling = envelope.Activity.State == "planning" &&
                    latest?.Activity.JobId == envelope.Activity.JobId &&
                    latest.Activity.State is "transferring" or "finalizing";
                if (!preservesEstablishedSibling)
                {
                    latest = envelope;
                }
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
            terminalJobs.Clear();
            terminalQueue.Clear();
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

            if (!terminalQueue.TryDequeue(out envelope))
            {
                envelope = urgent ?? latest;
                if (ReferenceEquals(envelope, urgent))
                {
                    urgent = null;
                }
                else
                {
                    latest = null;
                }
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
                terminalQueue.Clear();
                callbackScheduled = false;
            }
            else if (terminalQueue.Count > 0 || urgent is not null || latest is not null)
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
