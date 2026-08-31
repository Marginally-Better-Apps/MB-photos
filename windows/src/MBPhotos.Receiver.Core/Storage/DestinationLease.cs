using System.Security.Cryptography;
using System.Text;

namespace MBPhotos.Receiver.Storage;

public sealed class DestinationInitializationLease : IDisposable
{
    private readonly FileStream stream;

    private DestinationInitializationLease(FileStream stream)
    {
        this.stream = stream;
    }

    public static DestinationInitializationLease Acquire(string selectedPath)
    {
        var canonical = Path.GetFullPath(selectedPath);
        if (OperatingSystem.IsWindows())
        {
            canonical = canonical.ToUpperInvariant();
        }

        var digest = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(canonical)));
        var lockDirectory = Path.Combine(Path.GetTempPath(), "MarginallyBetterPhotos", "InitializationLocks");
        Directory.CreateDirectory(lockDirectory);
        var lockPath = Path.Combine(lockDirectory, digest + ".lock");
        try
        {
            var stream = new FileStream(
                lockPath,
                FileMode.OpenOrCreate,
                FileAccess.ReadWrite,
                FileShare.None,
                4096,
                FileOptions.WriteThrough);
            stream.SetLength(0);
            using var writer = new StreamWriter(stream, new UTF8Encoding(false), 1024, true);
            writer.Write($"pid={Environment.ProcessId} destination={digest}");
            writer.Flush();
            stream.Flush(true);
            stream.Position = 0;
            return new DestinationInitializationLease(stream);
        }
        catch (IOException exception)
        {
            throw new InvalidOperationException("This backup folder is being initialized by another receiver process.", exception);
        }
    }

    public void Dispose() => stream.Dispose();
}

public sealed class DestinationLease : IDisposable
{
    private readonly FileStream stream;

    private DestinationLease(FileStream stream)
    {
        this.stream = stream;
    }

    public static DestinationLease Acquire(DestinationContext destination)
    {
        var path = Path.Combine(destination.ControlPath, "receiver.lock");
        try
        {
            var pathPolicy = new WindowsPathPolicy();
            pathPolicy.EnsureNoReparsePoints(destination.RootPath, path);
            var stream = new FileStream(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
            try
            {
                pathPolicy.EnsureNoReparsePoints(destination.RootPath, path);
            }
            catch
            {
                stream.Dispose();
                throw;
            }
            stream.SetLength(0);
            using var writer = new StreamWriter(stream, new System.Text.UTF8Encoding(false), 1024, true);
            writer.Write($"pid={Environment.ProcessId} started={DateTimeOffset.UtcNow:O}");
            writer.Flush();
            stream.Flush(true);
            stream.Position = 0;
            return new DestinationLease(stream);
        }
        catch (IOException exception)
        {
            throw new InvalidOperationException("This backup folder is already open in another receiver process.", exception);
        }
    }

    public void Dispose() => stream.Dispose();
}
