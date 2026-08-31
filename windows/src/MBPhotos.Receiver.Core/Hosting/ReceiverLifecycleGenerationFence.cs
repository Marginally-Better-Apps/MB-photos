namespace MBPhotos.Receiver.Hosting;

/// <summary>
/// Identifies every receiver generation that had been requested when a stop
/// operation was recorded. A later generation is deliberately not included.
/// </summary>
public readonly record struct ReceiverLifecycleStopRequest(long ThroughGeneration)
{
    public bool Includes(long generation) => generation <= ThroughGeneration;
}

public enum ReceiverLifecycleStartStatus
{
    Allowed,
    StopRequested,
    Disposed,
}

/// <summary>
/// Owns the linearization policy for receiver start, stop, and disposal. The
/// callback supplied to <see cref="TryCommitRunning"/> executes while the fence
/// is locked, so a stop or disposal cannot land between its decision and the
/// controller's Running state assignment.
/// </summary>
public sealed class ReceiverLifecycleGenerationFence
{
    private readonly object sync = new();
    private long nextGeneration;
    private long stopRequestedThroughGeneration = -1;
    private bool disposed;

    public bool IsDisposed
    {
        get
        {
            lock (sync)
            {
                return disposed;
            }
        }
    }

    public bool TryReserveStart(out long generation)
    {
        lock (sync)
        {
            if (disposed)
            {
                generation = 0;
                return false;
            }

            generation = checked(nextGeneration + 1);
            nextGeneration = generation;
            return true;
        }
    }

    public ReceiverLifecycleStopRequest RecordStop()
    {
        lock (sync)
        {
            stopRequestedThroughGeneration = Math.Max(
                stopRequestedThroughGeneration,
                nextGeneration);
            return new ReceiverLifecycleStopRequest(nextGeneration);
        }
    }

    public bool TryRecordDisposal(out ReceiverLifecycleStopRequest stopRequest)
    {
        lock (sync)
        {
            stopRequest = new ReceiverLifecycleStopRequest(nextGeneration);
            if (disposed)
            {
                return false;
            }

            disposed = true;
            stopRequestedThroughGeneration = Math.Max(
                stopRequestedThroughGeneration,
                nextGeneration);
            return true;
        }
    }

    public ReceiverLifecycleStartStatus StatusFor(long generation)
    {
        lock (sync)
        {
            if (disposed)
            {
                return ReceiverLifecycleStartStatus.Disposed;
            }

            return stopRequestedThroughGeneration >= generation
                ? ReceiverLifecycleStartStatus.StopRequested
                : ReceiverLifecycleStartStatus.Allowed;
        }
    }

    public bool TryCommitRunning(
        long generation,
        bool cancellationRequested,
        bool ownsStartup,
        Action commit)
    {
        ArgumentNullException.ThrowIfNull(commit);

        lock (sync)
        {
            if (disposed ||
                stopRequestedThroughGeneration >= generation ||
                cancellationRequested ||
                !ownsStartup)
            {
                return false;
            }

            commit();
            return true;
        }
    }
}
