using System.Text.Json;
using MBPhotos.Receiver.Models;
using MBPhotos.Receiver.Storage;

namespace MBPhotos.Receiver.Library;

public enum VariantKind
{
    CurrentMaster,
    RootOriginal,
    CurrentLiveMotion,
    OriginalLiveMotion,
}

public sealed record PortableLibraryFile(
    Guid AssetId,
    CatalogFile Catalog,
    string LibraryRoot)
{
    public Guid FileId => Catalog.FileId;
    public string? AbsolutePath => Catalog.AcceptedRelativePath is null
        ? null
        : Path.GetFullPath(Path.Combine(
            LibraryRoot,
            Catalog.AcceptedRelativePath.Replace('/', Path.DirectorySeparatorChar)));
    public bool IsPresent => AbsolutePath is { } path && File.Exists(path);
}

public sealed record PortableLibraryAsset(
    CatalogAsset Catalog,
    IReadOnlyList<PortableLibraryFile> Files)
{
    public Guid AssetId => Catalog.AssetId;
    public bool IsEdited => Catalog.IsEdited;
    public bool IsLivePhoto => Catalog.LivePhotoRelationships is not null;
    public ArchiveState ArchiveState => Catalog.ArchiveState;
    public PortableLibraryFile? MasterFile => Catalog.MasterFileId is { } id
        ? Files.FirstOrDefault(file => file.FileId == id)
        : null;

    public IReadOnlyList<VariantKind> AvailableVariants
    {
        get
        {
            var variants = new List<VariantKind>(4);
            AddIfPresent(RepresentationRole.MasterCurrent, VariantKind.CurrentMaster);
            AddIfPresent(RepresentationRole.RootOriginal, VariantKind.RootOriginal);
            AddIfPresent(RepresentationRole.CurrentLiveMotion, VariantKind.CurrentLiveMotion);
            AddIfPresent(RepresentationRole.OriginalLiveMotion, VariantKind.OriginalLiveMotion);
            return variants;

            void AddIfPresent(RepresentationRole role, VariantKind variant)
            {
                if (Files.Any(file =>
                        file.Catalog.Availability == Availability.Available &&
                        file.Catalog.Roles.Contains(role) &&
                        file.Catalog.AcceptedRelativePath is not null))
                {
                    variants.Add(variant);
                }
            }
        }
    }
}

public sealed record PortableLibrarySnapshot(
    string RootPath,
    LibraryDescriptor Library,
    CatalogPointer Catalog,
    IReadOnlyList<PortableLibraryAsset> Assets);

/// <summary>Loads a movable v2 library using only root-relative catalog paths.</summary>
public sealed class PortableLibraryService
{
    private static readonly HashSet<string> PhotoKitResourceTypes = new(StringComparer.Ordinal)
    {
        "photo", "video", "audio", "alternatePhoto", "fullSizePhoto", "fullSizeVideo",
        "adjustmentData", "adjustmentBasePhoto", "pairedVideo", "fullSizePairedVideo",
        "adjustmentBasePairedVideo", "adjustmentBaseVideo", "unknown",
    };
    private readonly JsonSerializerOptions jsonOptions;
    private readonly WindowsPathPolicy pathPolicy = new();

    public PortableLibraryService(JsonSerializerOptions? jsonOptions = null)
    {
        this.jsonOptions = jsonOptions ?? JsonDefaults.Create();
    }

    public async Task<PortableLibrarySnapshot> OpenAsync(
        string libraryRoot,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(libraryRoot))
        {
            throw new ArgumentException("A portable library root is required.", nameof(libraryRoot));
        }

        var root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(libraryRoot));
        if (!Directory.Exists(root))
        {
            throw new DirectoryNotFoundException(root);
        }
        pathPolicy.EnsureNoReparsePoints(root, root);

        var legacyDescriptor = Path.Combine(root, ".mbphotos", "destination.json");
        if (File.Exists(legacyDescriptor))
        {
            throw new InvalidDataException(
                "This is a version 1 destination, not a portable library. It was left untouched.");
        }

        var descriptorPath = Resolve(root, "MB Photos Data/library.json");
        var descriptor = await ReadJsonAsync<LibraryDescriptor>(descriptorPath, cancellationToken);
        if (descriptor.LibraryFormatVersion != 2 || descriptor.DestinationId == Guid.Empty ||
            descriptor.CreatedAt == default ||
            descriptor.MasterRelativePath != "Master" ||
            descriptor.DataRelativePath != "MB Photos Data" ||
            descriptor.CatalogPointerRelativePath != "MB Photos Data/Catalog/current.json")
        {
            throw new InvalidDataException("The selected folder is not a supported MB Photos portable library.");
        }

        var pointerPath = Resolve(root, descriptor.CatalogPointerRelativePath);
        var pointer = await ReadJsonAsync<CatalogPointer>(pointerPath, cancellationToken);
        var generationPrefix = $"MB Photos Data/Catalog/generations/{pointer.GenerationId:D}/";
        if (pointer.CatalogFormatVersion != 2 || pointer.GenerationId == Guid.Empty || pointer.GeneratedAt == default ||
            string.IsNullOrWhiteSpace(pointer.AssetsRelativePath) ||
            string.IsNullOrWhiteSpace(pointer.AlbumsRelativePath) ||
            !pointer.AssetsRelativePath.StartsWith(generationPrefix, StringComparison.Ordinal) ||
            !pointer.AlbumsRelativePath.StartsWith(generationPrefix, StringComparison.Ordinal))
        {
            throw new InvalidDataException("The current catalog pointer is invalid.");
        }

        var assetsPath = Resolve(root, pointer.AssetsRelativePath);
        var albumsPath = Resolve(root, pointer.AlbumsRelativePath);
        if (!File.Exists(albumsPath))
        {
            throw new InvalidDataException("The current catalog's albums generation is missing.");
        }
        var assets = new List<PortableLibraryAsset>();
        var assetIds = new HashSet<Guid>();
        await using var stream = new FileStream(
            assetsPath,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            128 * 1024,
            FileOptions.Asynchronous | FileOptions.SequentialScan);
        using var reader = new StreamReader(stream);
        while (await reader.ReadLineAsync(cancellationToken) is { } line)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (string.IsNullOrWhiteSpace(line))
            {
                throw new InvalidDataException("The asset catalog contains a blank record.");
            }
            var asset = JsonSerializer.Deserialize<CatalogAsset>(line, jsonOptions)
                ?? throw new InvalidDataException("The asset catalog contains an empty record.");
            if (!assetIds.Add(asset.AssetId))
            {
                throw new InvalidDataException("The asset catalog contains a duplicate asset ID.");
            }
            ValidateAsset(root, asset);
            assets.Add(new PortableLibraryAsset(
                asset,
                asset.Files.Select(file => new PortableLibraryFile(asset.AssetId, file, root)).ToArray()));
        }

        return new PortableLibrarySnapshot(root, descriptor, pointer, assets);
    }

    private void ValidateAsset(string root, CatalogAsset asset)
    {
        if (asset.CatalogFormatVersion != 2 || asset.AssetId == Guid.Empty || asset.Files is null ||
            asset.Files.Count == 0 || string.IsNullOrWhiteSpace(asset.SourceLocalIdentifier) ||
            asset.MediaSubtypes is null ||
            asset.MediaSubtypes.Any(string.IsNullOrWhiteSpace) ||
            asset.MediaSubtypes.Distinct(StringComparer.Ordinal).Count() != asset.MediaSubtypes.Count ||
            asset.MediaType is not ("photo" or "video") ||
            !Enum.IsDefined(typeof(ArchiveState), asset.ArchiveState))
        {
            throw new InvalidDataException("The asset catalog contains an unsupported record.");
        }
        ModelValidation.RequireSha256(asset.SourceRevision, "sourceRevision");
        if (asset.Location is { } location &&
            (double.IsNaN(location.Latitude) || double.IsInfinity(location.Latitude) ||
             double.IsNaN(location.Longitude) || double.IsInfinity(location.Longitude) ||
             location.Latitude is < -90 or > 90 || location.Longitude is < -180 or > 180 ||
             (location.AltitudeMeters is { } altitude &&
              (double.IsNaN(altitude) || double.IsInfinity(altitude)))))
        {
            throw new InvalidDataException("The asset catalog contains invalid location coordinates.");
        }
        var fileIds = new HashSet<Guid>();
        foreach (var file in asset.Files)
        {
            if (file.FileId == Guid.Empty || !fileIds.Add(file.FileId) ||
                string.IsNullOrWhiteSpace(file.OriginalFilename) ||
                file.Roles is null || file.Roles.Count == 0 ||
                file.Roles.Distinct().Count() != file.Roles.Count ||
                file.Roles.Any(static role => !Enum.IsDefined(typeof(RepresentationRole), role)) ||
                !Enum.IsDefined(typeof(StorageArea), file.StorageArea) ||
                !Enum.IsDefined(typeof(Criticality), file.Criticality) ||
                !Enum.IsDefined(typeof(Provenance), file.Provenance) ||
                !Enum.IsDefined(typeof(Availability), file.Availability))
            {
                throw new InvalidDataException("The asset catalog contains invalid file identity, roles, or enum values.");
            }
            ModelValidation.RequireSha256(file.ContentRevision, "contentRevision");
            if (file.Sha256 is not null)
            {
                ModelValidation.RequireSha256(file.Sha256, "sha256");
            }
            if (file.PixelWidth is < 0 || file.PixelHeight is < 0 ||
                file.DurationMilliseconds is < 0 || file.ByteCount is < 0)
            {
                throw new InvalidDataException("A catalog file contains a negative size, dimension, or duration.");
            }
            if (file.Availability == Availability.Available &&
                (file.ByteCount is null || file.Sha256 is null || file.AcceptedRelativePath is null))
            {
                throw new InvalidDataException("An available catalog file lacks bytes, digest, or accepted path.");
            }
            if (file.Availability != Availability.Available && file.Sha256 is not null)
            {
                throw new InvalidDataException("An unavailable catalog file claims a verified digest.");
            }

            if (file.StorageArea == StorageArea.Master)
            {
                if (!file.Roles.Contains(RepresentationRole.MasterCurrent) ||
                    file.Roles.Any(static role => role is not (RepresentationRole.MasterCurrent or RepresentationRole.RootOriginal)) ||
                    file.Criticality != Criticality.MasterRequired ||
                    file.Provenance != Provenance.ExactPhotoKitResource)
                {
                    throw new InvalidDataException("A catalog Master representation has invalid roles, criticality, or provenance.");
                }
            }
            else if (file.Roles.Contains(RepresentationRole.MasterCurrent))
            {
                throw new InvalidDataException("A catalog masterCurrent representation is outside Master.");
            }
            if (file.Roles.Any(static role => role is RepresentationRole.CurrentLiveMotion or RepresentationRole.OriginalLiveMotion) &&
                file.StorageArea != StorageArea.LibraryData)
            {
                throw new InvalidDataException("A catalog Live Photo motion representation is outside Library Data.");
            }
            if (file.Criticality == Criticality.MasterRequired &&
                !file.Roles.Contains(RepresentationRole.MasterCurrent))
            {
                throw new InvalidDataException("A catalog masterRequired representation lacks masterCurrent.");
            }

            if (file.Provenance == Provenance.GeneratedThumbnail)
            {
                if (file.StorageArea != StorageArea.LibraryData || file.Criticality != Criticality.Optional ||
                    file.Roles.Count != 1 || file.Roles[0] != RepresentationRole.Auxiliary ||
                    file.PhotoKitResourceType is not null || file.PhotoKitResourceTypeRaw is not null)
                {
                    throw new InvalidDataException("A catalog thumbnail violates its auxiliary representation contract.");
                }
            }
            else if (file.PhotoKitResourceType is null || !PhotoKitResourceTypes.Contains(file.PhotoKitResourceType) ||
                     file.PhotoKitResourceTypeRaw is null or < 0)
            {
                throw new InvalidDataException("A catalog PhotoKit resource lacks its known type or raw code.");
            }

            if (file.AcceptedRelativePath is { } relativePath)
            {
                var expectedPrefix = file.StorageArea == StorageArea.Master
                    ? "Master/"
                    : file.Provenance == Provenance.GeneratedThumbnail
                        ? "MB Photos Data/Thumbnails/"
                        : "MB Photos Data/Resources/";
                if (!relativePath.StartsWith(expectedPrefix, StringComparison.Ordinal))
                {
                    throw new InvalidDataException("A catalog file is outside its declared storage area.");
                }
                _ = Resolve(root, relativePath);
            }
        }

        var availableMasters = asset.Files.Where(file =>
            file.Availability == Availability.Available &&
            file.StorageArea == StorageArea.Master &&
            file.Roles.Contains(RepresentationRole.MasterCurrent)).ToArray();
        if (availableMasters.Length > 1 ||
            (asset.MasterFileId is null && availableMasters.Length != 0) ||
            (asset.MasterFileId is { } masterId &&
             (availableMasters.Length != 1 || availableMasters[0].FileId != masterId)))
        {
            throw new InvalidDataException("An asset's masterFileId does not identify its single available Master representation.");
        }

        var isLivePhoto = asset.MediaSubtypes.Contains("livePhoto", StringComparer.Ordinal);
        if (isLivePhoto != (asset.LivePhotoRelationships is not null))
        {
            throw new InvalidDataException("A catalog asset's Live Photo subtype and relationships disagree.");
        }
        if (asset.LivePhotoRelationships is { } relationships)
        {
            var byId = asset.Files.ToDictionary(static file => file.FileId);
            foreach (var (fileId, role, name) in new[]
                     {
                         (relationships.CurrentStillFileId, RepresentationRole.MasterCurrent, "currentStillFileId"),
                         (relationships.CurrentMotionFileId, RepresentationRole.CurrentLiveMotion, "currentMotionFileId"),
                         (relationships.OriginalStillFileId, RepresentationRole.RootOriginal, "originalStillFileId"),
                         (relationships.OriginalMotionFileId, RepresentationRole.OriginalLiveMotion, "originalMotionFileId"),
                     })
            {
                if (fileId is { } id && (!byId.TryGetValue(id, out var related) || !related.Roles.Contains(role)))
                {
                    throw new InvalidDataException($"A catalog asset's {name} relationship is invalid.");
                }
            }
            if (asset.MasterFileId is { } liveMasterId && relationships.CurrentStillFileId != liveMasterId)
            {
                throw new InvalidDataException("A catalog Live Photo's current still is not its active Master.");
            }
        }

        var expectedArchiveState = asset.Files.Any(file =>
            file.Criticality == Criticality.ArchiveRequired && file.Availability != Availability.Available)
            ? ArchiveState.Incomplete
            : ArchiveState.Complete;
        if (asset.ArchiveState != expectedArchiveState)
        {
            throw new InvalidDataException("A catalog asset's archiveState disagrees with its archive-required files.");
        }
    }

    private async Task<T> ReadJsonAsync<T>(string path, CancellationToken cancellationToken)
    {
        await using var stream = File.OpenRead(path);
        return await JsonSerializer.DeserializeAsync<T>(stream, jsonOptions, cancellationToken)
            ?? throw new InvalidDataException($"{Path.GetFileName(path)} is empty.");
    }

    private string Resolve(string root, string relativePath)
    {
        pathPolicy.ValidateRelativePath(relativePath);
        return pathPolicy.ResolveUnderRoot(root, relativePath);
    }
}
