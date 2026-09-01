using System.Text.Json;
using MBPhotos.Receiver.Models;

namespace MBPhotos.Receiver.Storage;

public sealed record DestinationContext(string RootPath, DestinationInfo Info)
{
    public const string DataDirectoryName = "MB Photos Data";
    public string MasterPath => Path.Combine(RootPath, "Master");
    public string DataPath => Path.Combine(RootPath, DataDirectoryName);
    public string ResourcesPath => Path.Combine(DataPath, "Resources");
    public string CatalogPath => Path.Combine(DataPath, "Catalog");
    public string CatalogGenerationsPath => Path.Combine(CatalogPath, "generations");
    public string ReportsPath => Path.Combine(DataPath, "Reports");
    public string ThumbnailsPath => Path.Combine(DataPath, "Thumbnails");
    public string ControlPath => Path.Combine(DataPath, ".mbphotos");
    public string DatabasePath => Path.Combine(ControlPath, "ledger.sqlite");
    public string StagingPath => Path.Combine(ControlPath, "staging");
    public string PromotionJournalPath => Path.Combine(ControlPath, "promotion-journal");
    // Kept as a source-compatible alias for receiver internals while v2 names
    // the receiver-owned upload area "staging".
    public string PartialPath => StagingPath;
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

        var legacyControlPath = Path.Combine(rootPath, ".mbphotos");
        var legacyDestinationPath = Path.Combine(legacyControlPath, DestinationFilename);
        pathPolicy.EnsureNoReparsePoints(rootPath, legacyControlPath);
        pathPolicy.EnsureNoReparsePoints(rootPath, legacyDestinationPath);
        if (File.Exists(legacyDestinationPath))
        {
            throw new InvalidDataException(
                "This is a version 1 MB Photos destination. It was left untouched; choose an empty folder to create a fresh portable library.");
        }

        var dataPath = Path.Combine(rootPath, DestinationContext.DataDirectoryName);
        var controlPath = Path.Combine(dataPath, ".mbphotos");
        foreach (var protectedPath in new[]
                 {
                     Path.Combine(rootPath, "Master"),
                     dataPath,
                     controlPath,
                     Path.Combine(dataPath, "Resources"),
                     Path.Combine(dataPath, "Catalog"),
                     Path.Combine(dataPath, "Reports"),
                     Path.Combine(dataPath, "Thumbnails"),
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
            if (stored.FormatVersion != 2 || stored.PathPolicyVersion != WindowsPathPolicy.Version || stored.DestinationId == Guid.Empty)
            {
                throw new InvalidDataException("The portable library uses an unsupported format and was left untouched.");
            }
        }
        else
        {
            if (!allowInitialize)
            {
                throw new InvalidOperationException("This folder is not an initialized MB Photos destination.");
            }

            if (Directory.Exists(dataPath) && Directory.EnumerateFileSystemEntries(dataPath).Any())
            {
                throw new InvalidDataException("The existing MB Photos Data folder is not a valid portable library and was left untouched.");
            }

            foreach (var reservedDirectory in new[] { "Master" })
            {
                var reservedPath = Path.Combine(rootPath, reservedDirectory);
                if (File.Exists(reservedPath) ||
                    (Directory.Exists(reservedPath) && Directory.EnumerateFileSystemEntries(reservedPath).Any()))
                {
                    throw new InvalidDataException($"The existing {reservedDirectory} path is not empty. It was left untouched because the folder is not an initialized backup.");
                }
            }

            if (File.Exists(dataPath))
            {
                throw new InvalidDataException("An unrelated file named MB Photos Data blocks library initialization and was left untouched.");
            }

            Directory.CreateDirectory(controlPath);
            stored = new StoredDestination(Guid.NewGuid(), DateTimeOffset.UtcNow, 2, WindowsPathPolicy.Version);
            await AtomicFile.WriteTextAsync(
                destinationPath,
                JsonSerializer.Serialize(stored, jsonOptions),
                cancellationToken);
            await AtomicFile.WriteTextAsync(
                Path.Combine(dataPath, "library.json"),
                JsonSerializer.Serialize(
                    new LibraryDescriptor(
                        2,
                        stored.DestinationId,
                        stored.CreatedAt,
                        "Master",
                        DestinationContext.DataDirectoryName,
                        "MB Photos Data/Catalog/current.json"),
                    jsonOptions),
                cancellationToken);
        }
        pathPolicy.EnsureNoReparsePoints(rootPath, destinationPath);

        var libraryPath = Path.Combine(dataPath, "library.json");
        pathPolicy.EnsureNoReparsePoints(rootPath, libraryPath);
        if (!File.Exists(libraryPath))
        {
            throw new InvalidDataException("The portable library descriptor is missing; the folder was left untouched.");
        }
        await using (var libraryStream = File.OpenRead(libraryPath))
        {
            var library = await JsonSerializer.DeserializeAsync<LibraryDescriptor>(
                libraryStream,
                jsonOptions,
                cancellationToken) ?? throw new InvalidDataException("The portable library descriptor is empty.");
            if (library.LibraryFormatVersion != 2 || library.DestinationId != stored.DestinationId ||
                library.MasterRelativePath != "Master" ||
                library.DataRelativePath != DestinationContext.DataDirectoryName ||
                library.CatalogPointerRelativePath != "MB Photos Data/Catalog/current.json")
            {
                throw new InvalidDataException("The portable library descriptor does not match this destination.");
            }
        }

        Directory.CreateDirectory(Path.Combine(rootPath, "Master"));
        Directory.CreateDirectory(Path.Combine(dataPath, "Resources"));
        Directory.CreateDirectory(Path.Combine(dataPath, "Catalog", "generations"));
        Directory.CreateDirectory(Path.Combine(dataPath, "Reports"));
        Directory.CreateDirectory(Path.Combine(dataPath, "Thumbnails"));
        Directory.CreateDirectory(Path.Combine(controlPath, "staging"));
        Directory.CreateDirectory(Path.Combine(controlPath, "promotion-journal"));
        pathPolicy.EnsureNoReparsePoints(rootPath, Path.Combine(controlPath, "staging"));
        pathPolicy.EnsureNoReparsePoints(rootPath, Path.Combine(controlPath, "promotion-journal"));
        var ledgerPath = Path.Combine(controlPath, "ledger.sqlite");
        pathPolicy.EnsureNoReparsePoints(rootPath, ledgerPath);
        pathPolicy.EnsureNoReparsePoints(rootPath, ledgerPath + "-wal");
        pathPolicy.EnsureNoReparsePoints(rootPath, ledgerPath + "-shm");
        pathPolicy.EnsureNoReparsePoints(rootPath, Path.Combine(controlPath, "receiver.lock"));

        var info = new DestinationInfo(
            stored.DestinationId,
            LimitDisplayName(new DirectoryInfo(rootPath).Name),
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

    private static string LimitDisplayName(string value) => value.Length <= 120 ? value : value[..120];

    private sealed record StoredDestination(
        Guid DestinationId,
        DateTimeOffset CreatedAt,
        int FormatVersion,
        int PathPolicyVersion);

}
