using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Extensions.Logging;

namespace MBPhotos.Receiver.Diagnostics;

public sealed class RedactingFileLoggerProvider : ILoggerProvider, IAsyncDisposable
{
    private const long MaximumLogBytes = 2 * 1024 * 1024;
    private const int MaximumQueuedCommands = 2048;
    private const int MaximumUrgentGroups = 256;
    private const int MaximumMessageCharacters = 16 * 1024;
    private const int FlushEveryEntries = 128;

    private readonly string logPath;
    private readonly object queueSync = new();
    private readonly Queue<LogCommand> commands = new();
    private readonly Dictionary<UrgentKey, UrgentAggregate> coalescedUrgent = new();
    private readonly SemaphoreSlim commandSlots = new(MaximumQueuedCommands, MaximumQueuedCommands);
    private readonly SemaphoreSlim commandsAvailable = new(0);
    private readonly Task writerTask;
    private long droppedEntries;
    private bool urgentWakePending;
    private bool accepting = true;
    private int disposed;

    public RedactingFileLoggerProvider(string? logDirectory = null)
    {
        var directory = logDirectory ?? Path.GetDirectoryName(GetDefaultLogPath())!;
        Directory.CreateDirectory(directory);
        logPath = Path.Combine(directory, "receiver.log");
        writerTask = Task.Run(ProcessCommandsAsync);
    }

    public string LogPath => logPath;

    public static string GetDefaultLogPath() => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "MarginallyBetterPhotos",
        "Receiver",
        "receiver.log");

    public ILogger CreateLogger(string categoryName) => new RedactingLogger(this, categoryName);

    public async Task ExportAsync(string destinationPath, CancellationToken cancellationToken = default)
    {
        await FlushAsync(cancellationToken).ConfigureAwait(false);
        await ExportLogFileAsync(logPath, destinationPath, cancellationToken).ConfigureAwait(false);
    }

    public static Task ExportExistingAsync(
        string destinationPath,
        CancellationToken cancellationToken = default) =>
        ExportLogFileAsync(GetDefaultLogPath(), destinationPath, cancellationToken);

    private static async Task ExportLogFileAsync(
        string sourcePath,
        string destinationPath,
        CancellationToken cancellationToken)
    {
        if (!File.Exists(sourcePath))
        {
            await File.WriteAllTextAsync(destinationPath, "No diagnostic events have been recorded.\n", cancellationToken).ConfigureAwait(false);
            return;
        }

        await using var input = new FileStream(
            sourcePath,
            FileMode.Open,
            FileAccess.Read,
            FileShare.ReadWrite | FileShare.Delete,
            16 * 1024,
            true);
        await using var output = new FileStream(destinationPath, FileMode.Create, FileAccess.Write, FileShare.None, 16 * 1024, true);
        await input.CopyToAsync(output, cancellationToken).ConfigureAwait(false);
    }

    public async Task FlushAsync(CancellationToken cancellationToken = default)
    {
        if (Volatile.Read(ref disposed) != 0)
        {
            await writerTask.ConfigureAwait(false);
            return;
        }

        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        await commandSlots.WaitAsync(cancellationToken).ConfigureAwait(false);
        lock (queueSync)
        {
            if (!accepting)
            {
                commandSlots.Release();
                throw new ObjectDisposedException(nameof(RedactingFileLoggerProvider));
            }

            commands.Enqueue(new LogCommand(null, completion));
        }
        commandsAvailable.Release();
        await completion.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
    }

    public void Dispose() => DisposeAsync().AsTask().GetAwaiter().GetResult();

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0)
        {
            await writerTask.ConfigureAwait(false);
            return;
        }

        lock (queueSync)
        {
            accepting = false;
        }
        // Wake the writer even when the queue is empty so it can drain any
        // coalesced urgent entries and close its buffered stream.
        commandsAvailable.Release();
        await writerTask.ConfigureAwait(false);
    }

    private void Enqueue(string category, LogLevel level, EventId eventId, string message, Exception? exception)
    {
        if (Volatile.Read(ref disposed) != 0)
        {
            return;
        }

        var entry = new LogEntry(
            DateTimeOffset.UtcNow,
            category,
            level,
            eventId,
            message.Length <= MaximumMessageCharacters
                ? message
                : message[..MaximumMessageCharacters] + " [truncated]",
            exception?.GetType().Name);

        if (commandSlots.Wait(0))
        {
            lock (queueSync)
            {
                if (!accepting)
                {
                    commandSlots.Release();
                    return;
                }

                commands.Enqueue(new LogCommand(entry, null));
            }
            commandsAvailable.Release();
            return;
        }

        if (level < LogLevel.Warning)
        {
            Interlocked.Increment(ref droppedEntries);
            return;
        }

        CoalesceUrgent(entry);
    }

    private void CoalesceUrgent(LogEntry entry)
    {
        var wakeWriter = false;
        lock (queueSync)
        {
            if (!accepting)
            {
                return;
            }

            var key = new UrgentKey(entry.Category, entry.Level, entry.EventId.Id, entry.ExceptionName);
            if (coalescedUrgent.TryGetValue(key, out var existing))
            {
                coalescedUrgent[key] = existing with
                {
                    Last = entry,
                    Count = existing.Count == long.MaxValue ? long.MaxValue : existing.Count + 1,
                };
            }
            else if (coalescedUrgent.Count < MaximumUrgentGroups - 1)
            {
                coalescedUrgent[key] = new UrgentAggregate(entry, 1);
            }
            else
            {
                // Keep the urgent overflow itself bounded while retaining its
                // severity, latest context, and the number of coalesced events.
                var overflowKey = UrgentKey.Overflow;
                var overflowEntry = entry with
                {
                    Category = "MBPhotos.Receiver.Diagnostics",
                    EventId = new EventId(0, "UrgentOverflow"),
                    Message = "Urgent diagnostic queue overflow; latest event: " + entry.Message,
                };
                if (coalescedUrgent.TryGetValue(overflowKey, out var overflow))
                {
                    coalescedUrgent[overflowKey] = overflow with
                    {
                        Last = overflowEntry,
                        Count = overflow.Count == long.MaxValue ? long.MaxValue : overflow.Count + 1,
                    };
                }
                else
                {
                    coalescedUrgent[overflowKey] = new UrgentAggregate(overflowEntry, 1);
                }
            }

            if (!urgentWakePending)
            {
                urgentWakePending = true;
                wakeWriter = true;
            }
        }

        if (wakeWriter)
        {
            commandsAvailable.Release();
        }
    }

    private async Task ProcessCommandsAsync()
    {
        FileStream? stream = null;
        StreamWriter? writer = null;
        Exception? lastWriteFailure = null;
        var entriesSinceFlush = 0;
        var lastFlushTicks = Environment.TickCount64;
        try
        {
            while (true)
            {
                await commandsAvailable.WaitAsync().ConfigureAwait(false);

                LogCommand? command = null;
                List<UrgentAggregate>? urgent = null;
                bool shouldStop;
                lock (queueSync)
                {
                    if (commands.Count > 0)
                    {
                        command = commands.Dequeue();
                    }

                    if (coalescedUrgent.Count > 0)
                    {
                        urgent = coalescedUrgent.Values.ToList();
                        coalescedUrgent.Clear();
                    }
                    urgentWakePending = false;
                    shouldStop = !accepting && commands.Count == 0 && coalescedUrgent.Count == 0;
                }

                if (command is not null)
                {
                    commandSlots.Release();
                }

                var pendingEntries = new List<LogEntry>((command?.Entry is null ? 0 : 1) + (urgent?.Count ?? 0));
                if (command?.Entry is not null)
                {
                    pendingEntries.Add(command.Entry);
                }
                if (urgent is not null)
                {
                    foreach (var aggregate in urgent)
                    {
                        pendingEntries.Add(aggregate.Count == 1
                            ? aggregate.Last
                            : aggregate.Last with
                            {
                                Message = aggregate.Last.Message + $" [coalesced {aggregate.Count:N0} urgent events]",
                            });
                    }
                }

                var dropped = Interlocked.Exchange(ref droppedEntries, 0);
                if (dropped > 0)
                {
                    pendingEntries.Insert(0, new LogEntry(
                        DateTimeOffset.UtcNow,
                        "MBPhotos.Receiver.Diagnostics",
                        LogLevel.Warning,
                        new EventId(0, "LowPriorityOverflow"),
                        $"Dropped {dropped:N0} low-priority diagnostic events because the bounded log queue was full.",
                        null));
                }

                foreach (var entry in pendingEntries)
                {
                    try
                    {
                        var safe = Redact(entry.Message);
                        var exceptionName = entry.ExceptionName is null ? string.Empty : $" exception={entry.ExceptionName}";
                        var line = $"{entry.Timestamp:O} {entry.Level} {entry.Category} event={entry.EventId.Id} {safe}{exceptionName}";
                        (stream, writer) = await WriteLineAsync(stream, writer, line).ConfigureAwait(false);
                        entriesSinceFlush++;
                        lastWriteFailure = null;
                    }
                    catch (Exception exception)
                    {
                        lastWriteFailure = exception;
                        await DisposeStreamsAsync(writer, stream).ConfigureAwait(false);
                        stream = null;
                        writer = null;
                        entriesSinceFlush = 0;
                    }
                }

                var periodicFlushDue = entriesSinceFlush >= FlushEveryEntries ||
                    (entriesSinceFlush > 0 && Environment.TickCount64 - lastFlushTicks >= 1000);
                if (command?.FlushCompletion is not null || periodicFlushDue || shouldStop)
                {
                    try
                    {
                        if (writer is not null)
                        {
                            await writer.FlushAsync().ConfigureAwait(false);
                            await stream!.FlushAsync().ConfigureAwait(false);
                        }
                        entriesSinceFlush = 0;
                        lastFlushTicks = Environment.TickCount64;

                        if (command?.FlushCompletion is not null && lastWriteFailure is null)
                        {
                            command.FlushCompletion.TrySetResult();
                        }
                        else if (command?.FlushCompletion is not null)
                        {
                            command.FlushCompletion.TrySetException(
                                new IOException("The diagnostic log could not be flushed.", lastWriteFailure));
                        }
                    }
                    catch (Exception exception)
                    {
                        lastWriteFailure = exception;
                        command?.FlushCompletion?.TrySetException(exception);
                    }
                }

                if (shouldStop)
                {
                    break;
                }
            }
        }
        finally
        {
            await DisposeStreamsAsync(writer, stream).ConfigureAwait(false);

            List<LogCommand> pending;
            lock (queueSync)
            {
                pending = commands.ToList();
                commands.Clear();
            }
            foreach (var item in pending)
            {
                item.FlushCompletion?.TrySetException(
                    lastWriteFailure ?? new ObjectDisposedException(nameof(RedactingFileLoggerProvider)));
            }
        }
    }

    private async Task<(FileStream Stream, StreamWriter Writer)> WriteLineAsync(
        FileStream? stream,
        StreamWriter? writer,
        string line)
    {
        var lineBytes = Encoding.UTF8.GetByteCount(line) + Environment.NewLine.Length;
        if (stream is null || writer is null || stream.Length + lineBytes > MaximumLogBytes)
        {
            var rotateCurrent = stream is not null && writer is not null;
            await DisposeStreamsAsync(writer, stream).ConfigureAwait(false);

            if (File.Exists(logPath) && (rotateCurrent || new FileInfo(logPath).Length >= MaximumLogBytes))
            {
                File.Move(logPath, logPath + ".previous", true);
            }

            stream = new FileStream(
                logPath,
                FileMode.Append,
                FileAccess.Write,
                FileShare.ReadWrite,
                16 * 1024,
                FileOptions.Asynchronous);
            writer = new StreamWriter(stream, new UTF8Encoding(false), 16 * 1024, leaveOpen: true);
        }

        await writer.WriteLineAsync(line.AsMemory()).ConfigureAwait(false);
        return (stream, writer);
    }

    private static async ValueTask DisposeStreamsAsync(StreamWriter? writer, FileStream? stream)
    {
        try
        {
            if (writer is not null)
            {
                await writer.DisposeAsync().ConfigureAwait(false);
            }
        }
        finally
        {
            if (stream is not null)
            {
                await stream.DisposeAsync().ConfigureAwait(false);
            }
        }
    }

    private static string Redact(string message)
    {
        var redacted = Regex.Replace(message, "(?i)(token|authorization|cert)=?[^ &]+", "$1=[redacted]");
        redacted = Regex.Replace(redacted, "(?i)(gps|latitude|longitude)=?[-+0-9.,]+", "$1=[redacted]");
        redacted = Regex.Replace(redacted, "(?i)(filename|album(name|title)?)=\"?[^\" ]+", "$1=[redacted]");
        return redacted;
    }

    private sealed record LogEntry(
        DateTimeOffset Timestamp,
        string Category,
        LogLevel Level,
        EventId EventId,
        string Message,
        string? ExceptionName);

    private sealed record LogCommand(LogEntry? Entry, TaskCompletionSource? FlushCompletion);

    private sealed record UrgentAggregate(LogEntry Last, long Count);

    private readonly record struct UrgentKey(
        string Category,
        LogLevel Level,
        int EventId,
        string? ExceptionName)
    {
        public static UrgentKey Overflow { get; } = new(
            "MBPhotos.Receiver.Diagnostics",
            LogLevel.Critical,
            0,
            "UrgentOverflow");
    }

    private sealed class RedactingLogger : ILogger
    {
        private readonly RedactingFileLoggerProvider provider;
        private readonly string category;

        public RedactingLogger(RedactingFileLoggerProvider provider, string category)
        {
            this.provider = provider;
            this.category = category;
        }

        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;

        public bool IsEnabled(LogLevel logLevel) => logLevel >= LogLevel.Information;

        public void Log<TState>(
            LogLevel logLevel,
            EventId eventId,
            TState state,
            Exception? exception,
            Func<TState, Exception?, string> formatter)
        {
            if (IsEnabled(logLevel))
            {
                provider.Enqueue(category, logLevel, eventId, formatter(state, exception), exception);
            }
        }
    }
}
