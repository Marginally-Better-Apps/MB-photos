namespace MBPhotos.Receiver.Transfer;

public sealed record ReceiverActivityEnvelope(long Generation, ReceiverActivity Activity);

/// <summary>
/// Converts the receiver's synchronous, potentially high-frequency activity event
/// into a bounded latest-value feed. Producers never wait for a UI subscriber.
/// </summary>
public sealed class ReceiverActivityFeed : IDisposable
{
    private const int MaximumPendingTerminalActivities = 64;
    private static readonly TimeSpan PublishInterval = TimeSpan.FromMilliseconds(100);

    private readonly object sync = new();
    private readonly Timer timer;
    private ReceiverActivityEnvelope? latest;
    private ReceiverActivityEnvelope? urgentLatest;
    private readonly Queue<ReceiverActivityEnvelope> terminalQueue = new();
    private readonly HashSet<Guid> terminalJobs = new();
    private long activeGeneration;
    private bool active;
    private int publishing;
    private int urgentQueued;
    private bool disposed;

    public ReceiverActivityFeed()
    {
        timer = new Timer(PublishLatest, null, PublishInterval, PublishInterval);
    }

    public event EventHandler<ReceiverActivityEnvelope>? ActivityAvailable;

    public void Activate(long generation)
    {
        lock (sync)
        {
            ThrowIfDisposed();
            activeGeneration = generation;
            active = true;
            terminalJobs.Clear();
            terminalQueue.Clear();
            latest = null;
            urgentLatest = null;
        }
    }

    public void Deactivate(long generation)
    {
        lock (sync)
        {
            if (!active || activeGeneration != generation)
            {
                return;
            }

            active = false;
            terminalJobs.Clear();
            terminalQueue.Clear();
            latest = null;
            urgentLatest = null;
        }
    }

    public void Publish(long generation, ReceiverActivity activity)
    {
        ArgumentNullException.ThrowIfNull(activity);
        lock (sync)
        {
            var terminal = IsTerminal(activity.State);
            if (disposed || !active || activeGeneration != generation)
            {
                return;
            }
            if (terminalJobs.Contains(activity.JobId))
            {
                return;
            }

            if (terminal)
            {
                terminalJobs.Add(activity.JobId);
                var terminalEnvelope = new ReceiverActivityEnvelope(generation, activity);
                if (latest?.Activity.JobId == activity.JobId)
                {
                    latest = null;
                }
                if (urgentLatest?.Activity.JobId == activity.JobId)
                {
                    urgentLatest = null;
                }
                terminalQueue.Enqueue(terminalEnvelope);
                while (terminalQueue.Count > MaximumPendingTerminalActivities)
                {
                    terminalQueue.Dequeue();
                }
            }
            else
            {
                var envelope = new ReceiverActivityEnvelope(generation, activity);
                if (activity.State == "rejected")
                {
                    // A rejected sibling request must not erase an already
                    // established transfer that is still waiting in the coalesced
                    // slot. It may erase its own unestablished planning placeholder.
                    if (latest?.Activity.JobId == activity.JobId &&
                        latest.Activity.State == "planning")
                    {
                        latest = null;
                    }
                    urgentLatest = envelope;
                }
                else
                {
                    var preservesEstablishedSibling = activity.State == "planning" &&
                        latest?.Activity.JobId == activity.JobId &&
                        latest.Activity.State is "transferring" or "finalizing";
                    if (!preservesEstablishedSibling)
                    {
                        latest = envelope;
                    }
                    if (IsUrgent(activity))
                    {
                        urgentLatest = envelope;
                    }
                }
            }
        }

        if (IsUrgent(activity))
        {
            QueueUrgentPublish();
        }
    }

    public void Dispose()
    {
        lock (sync)
        {
            if (disposed)
            {
                return;
            }

            disposed = true;
            active = false;
            terminalJobs.Clear();
            terminalQueue.Clear();
            latest = null;
            urgentLatest = null;
        }

        timer.Dispose();
    }

    private void PublishLatest(object? state)
    {
        if (Interlocked.Exchange(ref publishing, 1) != 0)
        {
            return;
        }

        try
        {
            ReceiverActivityEnvelope? envelope;
            lock (sync)
            {
                if (!terminalQueue.TryDequeue(out envelope))
                {
                    envelope = urgentLatest ?? latest;
                    if (ReferenceEquals(urgentLatest, envelope))
                    {
                        urgentLatest = null;
                    }
                    if (ReferenceEquals(latest, envelope))
                    {
                        latest = null;
                    }
                }
                if (envelope is null || !active || envelope.Generation != activeGeneration)
                {
                    return;
                }
            }

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
                    // Activity is advisory. A UI or diagnostics observer must never
                    // fail an otherwise successful transfer request.
                }
            }
        }
        finally
        {
            Volatile.Write(ref publishing, 0);
            var hasUrgent = false;
            lock (sync)
            {
                hasUrgent = (terminalQueue.Count > 0 || urgentLatest is not null) && !disposed;
            }
            if (hasUrgent)
            {
                QueueUrgentPublish();
            }
        }
    }

    private void QueueUrgentPublish()
    {
        if (Interlocked.Exchange(ref urgentQueued, 1) != 0)
        {
            return;
        }

        ThreadPool.QueueUserWorkItem(static state =>
        {
            var feed = (ReceiverActivityFeed)state!;
            Volatile.Write(ref feed.urgentQueued, 0);
            feed.PublishLatest(null);
        }, this);
    }

    private static bool IsTerminal(string state) =>
        state is "completed" or "completedWithFailures" or "abandoned";

    private static bool IsUrgent(ReceiverActivity activity) =>
        IsTerminal(activity.State) || activity.State == "rejected" || activity.ErrorMessage is not null;

    private void ThrowIfDisposed()
    {
        if (disposed)
        {
            throw new ObjectDisposedException(nameof(ReceiverActivityFeed));
        }
    }
}
