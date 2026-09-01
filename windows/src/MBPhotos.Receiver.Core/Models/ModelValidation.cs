using System.Globalization;
using System.Diagnostics.CodeAnalysis;
using System.Text.RegularExpressions;

namespace MBPhotos.Receiver.Models;

public static partial class ModelValidation
{
    private static readonly Regex IdentifierRegex = CreateIdentifierRegex();
    private static readonly Regex Sha256Regex = CreateSha256Regex();
    private static readonly HashSet<string> MediaSubtypes = new(StringComparer.Ordinal)
    {
        "panorama", "screenshot", "livePhoto", "depthEffect", "raw", "hdr",
        "slowMotion", "highFrameRate", "timelapse", "cinematic", "screenRecording", "spatialMedia",
    };
    private static readonly HashSet<string> PhotoKitResourceTypes = new(StringComparer.Ordinal)
    {
        "photo", "video", "audio", "alternatePhoto", "fullSizePhoto", "fullSizeVideo",
        "adjustmentData", "adjustmentBasePhoto", "pairedVideo", "fullSizePairedVideo",
        "adjustmentBasePairedVideo", "adjustmentBaseVideo", "unknown",
    };

    public static void Validate(ExportJob job)
    {
        if (job.Profile is null || job.Selection is null || job.Assets is null || job.AlbumMemberships is null)
        {
            Invalid("profile, selection, assets, and albumMemberships are required.");
        }

        if (job.ProtocolVersion != ProtocolConstants.Version)
        {
            throw new ReceiverApiException(426, ErrorCodes.ProtocolMismatch, "Only protocol version 2 is supported. Create a fresh portable library and replan the transfer.");
        }

        RequireGuid(job.JobId, "jobId");
        if (job.CreatedAt == default)
        {
            Invalid("createdAt is required.");
        }

        if (string.IsNullOrWhiteSpace(job.SourceTimeZone) || job.SourceTimeZone.Length > 64)
        {
            Invalid("sourceTimeZone is required and must be at most 64 characters.");
        }

        if (job.Assets.Count is 0 or > 100_000)
        {
            Invalid("A job must contain between 1 and 100,000 assets.");
        }

        if (job.Profile.Kind != ExportProfileKind.PortableLibrary || job.Profile.ProfileVersion != 2)
        {
            Invalid("Only the portableLibrary profileVersion 2 profile is supported.");
        }

        if (!Enum.IsDefined(typeof(SelectionKind), job.Selection.Kind) ||
            job.Selection.AssetCount != job.Assets.Count)
        {
            Invalid("selection.kind must be supported and assetCount must equal the number of assets.");
        }
        if (job.Selection.Kind == SelectionKind.DateRange && job.Selection.DateRange is null)
        {
            Invalid("A dateRange selection requires start and end values.");
        }
        if (job.Selection.DateRange is { } dateRange && dateRange.Start > dateRange.End)
        {
            Invalid("selection.dateRange start must not be after end.");
        }
        if (job.Selection.Kind == SelectionKind.Albums &&
            (job.Selection.SourceAlbumIdentifiers is null || job.Selection.SourceAlbumIdentifiers.Count == 0))
        {
            Invalid("An albums selection requires sourceAlbumIdentifiers.");
        }

        var assetIds = new HashSet<Guid>();
        var fileIds = new HashSet<Guid>();
        foreach (var asset in job.Assets)
        {
            if (asset.MediaSubtypes is null || asset.RecoveryFingerprint is null || asset.Files is null)
            {
                Invalid("Each asset requires mediaSubtypes, recoveryFingerprint, and files.");
            }
            RequireGuid(asset.AssetId, "assetId");
            if (!assetIds.Add(asset.AssetId))
            {
                Invalid($"Duplicate assetId '{asset.AssetId}'.");
            }

            if (string.IsNullOrWhiteSpace(asset.SourceLocalIdentifier) || asset.SourceLocalIdentifier.Length > 1024)
            {
                Invalid("sourceLocalIdentifier is required.");
            }

            if (string.IsNullOrWhiteSpace(asset.SourceRevision) || asset.SourceRevision.Length > 512)
            {
                Invalid("sourceRevision is required.");
            }

            RequireSha256(asset.SourceRevision, "sourceRevision");
            if (asset.MediaType is not ("photo" or "video") ||
                asset.RecoveryFingerprint.MediaType is not ("photo" or "video"))
            {
                Invalid("Asset and recovery fingerprint mediaType must be photo or video.");
            }
            if (asset.MediaSubtypes.Distinct(StringComparer.Ordinal).Count() != asset.MediaSubtypes.Count ||
                asset.MediaSubtypes.Any(subtype => !MediaSubtypes.Contains(subtype)))
            {
                Invalid("mediaSubtypes contains a duplicate or unsupported value.");
            }
            if (asset.Files.Count == 0 ||
                asset.RecoveryFingerprint.OriginalFilenames is null ||
                asset.RecoveryFingerprint.ResourceByteCounts is null ||
                asset.RecoveryFingerprint.OriginalFilenames.Count == 0 ||
                asset.RecoveryFingerprint.ResourceByteCounts.Count == 0 ||
                asset.RecoveryFingerprint.PixelWidth < 0 ||
                asset.RecoveryFingerprint.PixelHeight < 0 ||
                asset.RecoveryFingerprint.DurationMilliseconds is < 0)
            {
                Invalid("The asset files and recovery fingerprint are incomplete.");
            }
            if (asset.Location is { } location &&
                (double.IsNaN(location.Latitude) || double.IsInfinity(location.Latitude) ||
                 double.IsNaN(location.Longitude) || double.IsInfinity(location.Longitude) ||
                 location.Latitude is < -90 or > 90 || location.Longitude is < -180 or > 180 ||
                 (location.AltitudeMeters is { } altitude && (double.IsNaN(altitude) || double.IsInfinity(altitude)))))
            {
                Invalid("Asset location coordinates are outside their valid ranges.");
            }

            var assetFileIds = asset.Files.Select(static file => file.FileId).ToHashSet();
            var masterFiles = asset.Files.Where(static file =>
                file.StorageArea == StorageArea.Master || file.Roles.Contains(RepresentationRole.MasterCurrent)).ToArray();
            if (masterFiles.Length > 1)
            {
                Invalid("Each asset may contain at most one Master representation.");
            }
            if (asset.MasterFileId is { } masterFileId &&
                (masterFileId == Guid.Empty || masterFiles.Length != 1 || masterFiles[0].FileId != masterFileId ||
                 masterFiles[0].Availability != Availability.Available))
            {
                Invalid("masterFileId must reference the asset's single available Master representation.");
            }
            if (asset.MasterFileId is null && masterFiles.Length != 0)
            {
                if (masterFiles.Length != 1 || masterFiles[0].Availability == Availability.Available)
                {
                    Invalid("An available Master representation must declare masterFileId.");
                }
            }

            var isLivePhoto = asset.MediaSubtypes.Contains("livePhoto", StringComparer.Ordinal);
            if (isLivePhoto != (asset.LivePhotoRelationships is not null))
            {
                Invalid("mediaSubtypes must contain livePhoto exactly when livePhotoRelationships is present.");
            }
            ValidateLivePhotoRelationships(asset.LivePhotoRelationships, assetFileIds, asset.Files);
            if (asset.MasterFileId is { } activeMaster &&
                asset.LivePhotoRelationships is { } relationships &&
                relationships.CurrentStillFileId != activeMaster)
            {
                Invalid("A Live Photo's currentStillFileId must equal its active masterFileId.");
            }

            foreach (var file in asset.Files)
            {
                if (!Enum.IsDefined(typeof(StorageArea), file.StorageArea) ||
                    !Enum.IsDefined(typeof(Criticality), file.Criticality) ||
                    !Enum.IsDefined(typeof(Provenance), file.Provenance) ||
                    !Enum.IsDefined(typeof(Availability), file.Availability) ||
                    file.Roles is null || file.Roles.Count == 0 ||
                    file.Roles.Any(static role => !Enum.IsDefined(typeof(RepresentationRole), role)) ||
                    file.Roles.Distinct().Count() != file.Roles.Count)
                {
                    Invalid("The export file storage area, roles, criticality, provenance, or availability is unsupported.");
                }
                RequireGuid(file.FileId, "fileId");
                if (!fileIds.Add(file.FileId))
                {
                    Invalid($"Duplicate fileId '{file.FileId}'.");
                }

                if (string.IsNullOrWhiteSpace(file.OriginalFilename) || file.OriginalFilename.Length > 1024)
                {
                    Invalid("originalFilename is required.");
                }
                if (string.IsNullOrWhiteSpace(file.ProposedRelativePath) ||
                    file.ProposedRelativePath.Length > ProtocolConstants.MaximumRelativePathLength)
                {
                    Invalid("proposedRelativePath is required and must be at most 239 UTF-16 code units.");
                }

                if (file.ByteCount is < 0)
                {
                    Invalid("byteCount cannot be negative.");
                }

                if (file.PixelWidth is < 0 || file.PixelHeight is < 0 || file.DurationMilliseconds is < 0)
                {
                    Invalid("File dimensions and duration cannot be negative.");
                }

                if (file.AssetId != asset.AssetId)
                {
                    Invalid("ExportFile.assetId must match its containing asset.");
                }

                RequireSha256(file.ContentRevision, "contentRevision");
                if (file.Provenance == Provenance.ExactPhotoKitResource &&
                    (file.PhotoKitResourceType is null || !PhotoKitResourceTypes.Contains(file.PhotoKitResourceType) ||
                     file.PhotoKitResourceTypeRaw is null or < 0))
                {
                    Invalid("An exact PhotoKit resource requires a supported photoKitResourceType and nonnegative raw code.");
                }
                if (file.Sha256 is not null)
                {
                    RequireSha256(file.Sha256, "sha256");
                }
                if (file.Availability != Availability.Available && file.Sha256 is not null)
                {
                    Invalid("An unavailable representation cannot claim a verified sha256 digest.");
                }

                if (file.StorageArea == StorageArea.Master)
                {
                    if (!file.Roles.Contains(RepresentationRole.MasterCurrent) ||
                        file.Roles.Any(static role => role is not (RepresentationRole.MasterCurrent or RepresentationRole.RootOriginal)) ||
                        file.Criticality != Criticality.MasterRequired ||
                        file.Provenance != Provenance.ExactPhotoKitResource)
                    {
                        Invalid("A Master file must be a masterRequired exact PhotoKit masterCurrent representation.");
                    }
                }
                else if (file.Roles.Contains(RepresentationRole.MasterCurrent))
                {
                    Invalid("masterCurrent files must use the Master storage area.");
                }
                if (file.Roles.Any(static role => role is RepresentationRole.CurrentLiveMotion or RepresentationRole.OriginalLiveMotion) &&
                    file.StorageArea != StorageArea.LibraryData)
                {
                    Invalid("Live Photo motion representations must use Library Data.");
                }
                if (file.Criticality == Criticality.MasterRequired &&
                    !file.Roles.Contains(RepresentationRole.MasterCurrent))
                {
                    Invalid("masterRequired files must carry the masterCurrent role.");
                }

                if (file.Provenance == Provenance.GeneratedThumbnail &&
                    (file.StorageArea != StorageArea.LibraryData ||
                     file.Criticality != Criticality.Optional ||
                     file.Roles.Count != 1 || file.Roles[0] != RepresentationRole.Auxiliary ||
                     file.PhotoKitResourceType is not null || file.PhotoKitResourceTypeRaw is not null ||
                     !string.Equals(
                         file.ProposedRelativePath,
                         $"MB Photos Data/Thumbnails/{asset.AssetId:D}/{file.FileId:D}.jpg",
                         StringComparison.Ordinal)))
                {
                    Invalid("Generated thumbnails must be canonical optional Library Data auxiliary JPEGs without PhotoKit resource types.");
                }
            }
        }

        foreach (var membership in job.AlbumMemberships)
        {
            RequireGuid(membership.AlbumId, "albumId");
            if (membership.ParentAlbumId == Guid.Empty ||
                string.IsNullOrWhiteSpace(membership.SourceAlbumIdentifier) ||
                string.IsNullOrWhiteSpace(membership.AlbumTitle))
            {
                Invalid("Album membership identifiers and titles are invalid.");
            }
            if (!assetIds.Contains(membership.AssetId))
            {
                Invalid($"Album membership references unknown asset '{membership.AssetId}'.");
            }
        }
    }

    private static void ValidateLivePhotoRelationships(
        LivePhotoRelationships? relationships,
        IReadOnlySet<Guid> fileIds,
        IReadOnlyList<ExportFile> files)
    {
        if (relationships is null)
        {
            return;
        }

        var byId = files.ToDictionary(static file => file.FileId);
        foreach (var (id, role, name) in new[]
                 {
                     (relationships.CurrentStillFileId, (RepresentationRole?)null, "currentStillFileId"),
                     (relationships.CurrentMotionFileId, RepresentationRole.CurrentLiveMotion, "currentMotionFileId"),
                     (relationships.OriginalStillFileId, RepresentationRole.RootOriginal, "originalStillFileId"),
                     (relationships.OriginalMotionFileId, RepresentationRole.OriginalLiveMotion, "originalMotionFileId"),
                 })
        {
            if (id is null)
            {
                continue;
            }
            if (id == Guid.Empty || !fileIds.Contains(id.Value))
            {
                Invalid($"{name} must reference a file in the same asset.");
            }
            if (role is { } requiredRole && !byId[id.Value].Roles.Contains(requiredRole))
            {
                Invalid($"{name} must reference a file with the {requiredRole} role.");
            }
        }

        if (relationships.CurrentStillFileId is { } currentStill &&
            !byId[currentStill].Roles.Contains(RepresentationRole.MasterCurrent))
        {
            Invalid("currentStillFileId must reference the Master still representation.");
        }
    }

    public static void RequireIdentifier(string value, string field)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Length > 128 || !IdentifierRegex.IsMatch(value))
        {
            Invalid($"{field} must contain 1-128 letters, digits, periods, underscores, or hyphens.");
        }
    }

    public static void RequireGuid(Guid value, string field)
    {
        if (value == Guid.Empty)
        {
            Invalid($"{field} must be a non-empty UUID.");
        }
    }

    public static string RequireSha256(string? value, string field)
    {
        if (value is null || !Sha256Regex.IsMatch(value))
        {
            Invalid($"{field} must be a lowercase hexadecimal SHA-256 digest.");
        }

        return value;
    }

    public static (long Start, long End, long Total) ParseContentRange(string? value)
    {
        if (string.IsNullOrWhiteSpace(value) || !value.StartsWith("bytes ", StringComparison.Ordinal))
        {
            Invalid("Content-Range must use 'bytes start-end/total'.");
        }

        var parts = value[6..].Split(new[] { '-', '/' }, StringSplitOptions.None);
        long start = -1;
        long end = -1;
        long total = -1;
        if (parts.Length != 3 ||
            !long.TryParse(parts[0], NumberStyles.None, CultureInfo.InvariantCulture, out start) ||
            !long.TryParse(parts[1], NumberStyles.None, CultureInfo.InvariantCulture, out end) ||
            !long.TryParse(parts[2], NumberStyles.None, CultureInfo.InvariantCulture, out total) ||
            start < 0 || end < start || total <= end)
        {
            Invalid("Content-Range is invalid.");
        }

        return (start, end, total);
    }

    [DoesNotReturn]
    private static void Invalid(string message) =>
        throw new ReceiverApiException(400, ErrorCodes.InvalidRequest, message);

#if NET7_0
    private static Regex CreateIdentifierRegex() => new("^[A-Za-z0-9._-]+$", RegexOptions.CultureInvariant);
    private static Regex CreateSha256Regex() => new("^[0-9a-f]{64}$", RegexOptions.CultureInvariant);
#else
    [GeneratedRegex("^[A-Za-z0-9._-]+$", RegexOptions.CultureInvariant)]
    private static partial Regex CreateIdentifierRegex();

    [GeneratedRegex("^[0-9a-f]{64}$", RegexOptions.CultureInvariant)]
    private static partial Regex CreateSha256Regex();
#endif
}
