namespace MBPhotos.Receiver.Transfer;

public sealed record ReceiverActivityEnvelope(long Generation, ReceiverActivity Activity);

/// <summary>
/// Converts the receiver's synchronous, potentially high-frequency activity event
/// into a bounded latest-value feed. Producers never wait for a UI subscriber.
/// </summary>
public sealed class ReceiverActivityFeed : IDisposable
{
    private static readonly TimeSpan PublishInterval = TimeSpan.FromMilliseconds(100);

    private readonly object sync = new();
    private readonly Timer timer;
    private ReceiverActivityEnvelope? latest;
    private ReceiverActivityEnvelope? urgentLatest;
    private long activeGeneration;
    private bool active;
    private bool terminalSeen;
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
            terminalSeen = false;
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
            terminalSeen = false;
            latest = null;
            urgentLatest = null;
        }
    }

    public void Publish(long generation, ReceiverActivity activity)
    {
        ArgumentNullException.ThrowIfNull(activity);
        lock (sync)
        {
            if (disposed || !active || activeGeneration != generation ||
                (terminalSeen && !IsTerminal(activity.State)))
            {
                return;
            }

            terminalSeen |= IsTerminal(activity.State);
            var envelope = new ReceiverActivityEnvelope(generation, activity);
            latest = envelope;
            if (IsUrgent(activity))
            {
                urgentLatest = envelope;
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
                envelope = urgentLatest ?? latest;
                if (ReferenceEquals(urgentLatest, envelope))
                {
                    urgentLatest = null;
                }
                if (ReferenceEquals(latest, envelope))
                {
                    latest = null;
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
                hasUrgent = urgentLatest is not null && !disposed;
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
        IsTerminal(activity.State) || activity.ErrorMessage is not null;

    private void ThrowIfDisposed()
    {
        if (disposed)
        {
            throw new ObjectDisposedException(nameof(ReceiverActivityFeed));
        }
    }
}
