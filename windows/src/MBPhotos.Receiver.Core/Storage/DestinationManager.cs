using System.Text.Json;
using MBPhotos.Receiver.Models;

namespace MBPhotos.Receiver.Storage;

public sealed record DestinationContext(string RootPath, DestinationInfo Info)
{
    public string ControlPath => Path.Combine(RootPath, ".mbphotos");
    public string DatabasePath => Path.Combine(ControlPath, "ledger.sqlite");
    public string PartialPath => Path.Combine(ControlPath, "partial");
}

public sealed class DestinationManager
{
    private const string DestinationFilename = "destination.json";
    private readonly JsonSerializerOptions jsonOptions;

    public DestinationManager(JsonSerializerOptions? jsonOptions = null)
    {
        this.jsonOptions = jsonOptions ?? JsonDefaults.Create();
    }

    public async Task<DestinationContext> OpenOrInitializeAsync(
        string selectedPath,
        bool allowInitialize,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(selectedPath))
        {
            throw new ArgumentException("A destination folder is required.", nameof(selectedPath));
        }

        var rootPath = Path.GetFullPath(selectedPath);
        var pathPolicy = new WindowsPathPolicy();
        if (!Directory.Exists(rootPath))
        {
            if (!allowInitialize)
            {
                throw new DirectoryNotFoundException(rootPath);
            }

            Directory.CreateDirectory(rootPath);
        }

        pathPolicy.EnsureNoReparsePoints(rootPath, rootPath);

        var controlPath = Path.Combine(rootPath, ".mbphotos");
        foreach (var protectedPath in new[]
                 {
                     controlPath,
                     Path.Combine(rootPath, "Photos"),
                     Path.Combine(rootPath, "Metadata"),
                     Path.Combine(rootPath, "Reports"),
                 })
        {
            pathPolicy.EnsureNoReparsePoints(rootPath, protectedPath);
        }
        var destinationPath = Path.Combine(controlPath, DestinationFilename);
        pathPolicy.EnsureNoReparsePoints(rootPath, destinationPath);
        StoredDestination stored;
        if (File.Exists(destinationPath))
        {
            await using var stream = File.OpenRead(destinationPath);
            stored = await JsonSerializer.DeserializeAsync<StoredDestination>(stream, jsonOptions, cancellationToken)
                ?? throw new InvalidDataException("The destination metadata is empty.");
            if (stored.FormatVersion != 1 || stored.PathPolicyVersion != WindowsPathPolicy.Version || stored.DestinationId == Guid.Empty)
            {
                throw new InvalidDataException("The backup destination uses an unsupported format.");
            }
        }
        else
        {
            if (!allowInitialize)
            {
                throw new InvalidOperationException("This folder is not an initialized MB Photos destination.");
            }

            if (Directory.Exists(controlPath) && Directory.EnumerateFileSystemEntries(controlPath).Any())
            {
                throw new InvalidDataException("The existing .mbphotos folder is not a valid destination and was left untouched.");
            }


            foreach (var reservedDirectory in new[] { "Metadata", "Reports" })
            {
                var reservedPath = Path.Combine(rootPath, reservedDirectory);
                if (File.Exists(reservedPath) ||
                    (Directory.Exists(reservedPath) && Directory.EnumerateFileSystemEntries(reservedPath).Any()))
                {
                    throw new InvalidDataException($"The existing {reservedDirectory} path is not empty. It was left untouched because the folder is not an initialized backup.");
                }
            }

            if (File.Exists(Path.Combine(rootPath, "Photos")))
            {
                throw new InvalidDataException("An unrelated file named Photos blocks backup initialization and was left untouched.");
            }

            Directory.CreateDirectory(controlPath);
            stored = new StoredDestination(Guid.NewGuid(), DateTimeOffset.UtcNow, 1, WindowsPathPolicy.Version);
            await AtomicFile.WriteTextAsync(
                destinationPath,
                JsonSerializer.Serialize(stored, jsonOptions),
                cancellationToken);
        }
        pathPolicy.EnsureNoReparsePoints(rootPath, destinationPath);

        Directory.CreateDirectory(Path.Combine(rootPath, "Photos"));
        Directory.CreateDirectory(Path.Combine(rootPath, "Metadata"));
        Directory.CreateDirectory(Path.Combine(rootPath, "Reports"));
        Directory.CreateDirectory(Path.Combine(controlPath, "partial"));
        pathPolicy.EnsureNoReparsePoints(rootPath, Path.Combine(controlPath, "partial"));
        var ledgerPath = Path.Combine(controlPath, "ledger.sqlite");
        pathPolicy.EnsureNoReparsePoints(rootPath, ledgerPath);
        pathPolicy.EnsureNoReparsePoints(rootPath, ledgerPath + "-wal");
        pathPolicy.EnsureNoReparsePoints(rootPath, ledgerPath + "-shm");
        pathPolicy.EnsureNoReparsePoints(rootPath, Path.Combine(controlPath, "receiver.lock"));

        var info = new DestinationInfo(
            stored.DestinationId,
            new DirectoryInfo(rootPath).Name,
            stored.CreatedAt,
            GetFreeBytes(rootPath),
            stored.PathPolicyVersion);
        return new DestinationContext(rootPath, info);
    }

    public DestinationInfo RefreshInfo(DestinationContext destination) =>
        destination.Info with { FreeBytes = GetFreeBytes(destination.RootPath) };

    public static long GetFreeBytes(string rootPath)
    {
        try
        {
            var pathRoot = Path.GetPathRoot(Path.GetFullPath(rootPath));
            return string.IsNullOrEmpty(pathRoot) ? 0 : new DriveInfo(pathRoot).AvailableFreeSpace;
        }
        catch (IOException)
        {
            return 0;
        }
        catch (UnauthorizedAccessException)
        {
            return 0;
        }
    }

    private sealed record StoredDestination(
        Guid DestinationId,
        DateTimeOffset CreatedAt,
        int FormatVersion,
        int PathPolicyVersion);
}
