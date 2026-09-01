using System.Text.Json.Serialization;

namespace MBPhotos.Receiver.Models;

public sealed record LibraryDescriptor(
    int LibraryFormatVersion,
    Guid DestinationId,
    DateTimeOffset CreatedAt,
    string MasterRelativePath,
    string DataRelativePath,
    string CatalogPointerRelativePath);

public sealed record CatalogPointer(
    int CatalogFormatVersion,
    Guid GenerationId,
    DateTimeOffset GeneratedAt,
    string AssetsRelativePath,
    string AlbumsRelativePath);

public enum ArchiveState
{
    Complete,
    Incomplete,
}

public sealed record CatalogFile(
    Guid FileId,
    string ContentRevision,
    StorageArea StorageArea,
    IReadOnlyList<RepresentationRole> Roles,
    Criticality Criticality,
    Provenance Provenance,
    string? PhotoKitResourceType,
    int? PhotoKitResourceTypeRaw,
    string OriginalFilename,
    string? UniformTypeIdentifier,
    string? ContentType,
    int? PixelWidth,
    int? PixelHeight,
    long? DurationMilliseconds,
    long? ByteCount,
    string? Sha256,
    DateTimeOffset? CaptureDate,
    string? AcceptedRelativePath,
    Availability Availability);

public sealed record CatalogAsset(
    int CatalogFormatVersion,
    Guid AssetId,
    string SourceLocalIdentifier,
    string SourceRevision,
    string MediaType,
    IReadOnlyList<string> MediaSubtypes,
    DateTimeOffset? CreationDate,
    DateTimeOffset? ModificationDate,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] AssetLocation? Location,
    bool IsEdited,
    Guid? MasterFileId,
    LivePhotoRelationships? LivePhotoRelationships,
    ArchiveState ArchiveState,
    IReadOnlyList<CatalogFile> Files);

public sealed record CatalogAlbumMembership(
    int CatalogFormatVersion,
    Guid AlbumId,
    string SourceAlbumIdentifier,
    string AlbumTitle,
    Guid? ParentAlbumId,
    Guid AssetId);
