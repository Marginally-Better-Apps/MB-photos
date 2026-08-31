using System.Globalization;
using System.Diagnostics.CodeAnalysis;
using System.Text.RegularExpressions;

namespace MBPhotos.Receiver.Models;

public static partial class ModelValidation
{
    private static readonly Regex IdentifierRegex = CreateIdentifierRegex();
    private static readonly Regex Sha256Regex = CreateSha256Regex();

    public static void Validate(ExportJob job)
    {
        if (job.Profile is null || job.Selection is null || job.Assets is null || job.AlbumMemberships is null)
        {
            Invalid("profile, selection, assets, and albumMemberships are required.");
        }

        if (job.ProtocolVersion != ProtocolConstants.Version)
        {
            throw new ReceiverApiException(426, ErrorCodes.ProtocolMismatch, "Only protocol version 1 is supported.");
        }

        RequireGuid(job.JobId, "jobId");
        if (job.CreatedAt == default)
        {
            Invalid("createdAt is required.");
        }

        if (string.IsNullOrWhiteSpace(job.SourceTimeZone) || job.SourceTimeZone.Length > 128)
        {
            Invalid("sourceTimeZone is required and must be at most 128 characters.");
        }

        if (job.Assets.Count is 0 or > 100_000)
        {
            Invalid("A job must contain between 1 and 100,000 assets.");
        }

        if (!Enum.IsDefined(typeof(ExportProfileKind), job.Profile.Kind) || job.Profile.ProfileVersion != 1)
        {
            Invalid("The export profile kind and profileVersion must be supported by protocol v1.");
        }

        if (job.Profile.Kind == ExportProfileKind.OriginalsAndCurrentJpegs &&
            string.IsNullOrWhiteSpace(job.Profile.JpegRendererVersion))
        {
            Invalid("jpegRendererVersion is required for the originalsAndCurrentJpegs profile.");
        }
        if (job.Profile.Kind == ExportProfileKind.PreserveOriginals && job.Profile.JpegRendererVersion is not null)
        {
            Invalid("jpegRendererVersion must be omitted for the preserveOriginals profile.");
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
            if (!job.Profile.PreserveLocation && asset.Location is not null)
            {
                Invalid("Asset location must be omitted when preserveLocation is false.");
            }
            if (asset.Location is { } location &&
                (double.IsNaN(location.Latitude) || double.IsInfinity(location.Latitude) ||
                 double.IsNaN(location.Longitude) || double.IsInfinity(location.Longitude) ||
                 location.Latitude is < -90 or > 90 || location.Longitude is < -180 or > 180 ||
                 (location.AltitudeMeters is { } altitude && (double.IsNaN(altitude) || double.IsInfinity(altitude)))))
            {
                Invalid("Asset location coordinates are outside their valid ranges.");
            }

            foreach (var file in asset.Files)
            {
                if (!Enum.IsDefined(typeof(ExportFileKind), file.Kind) ||
                    !Enum.IsDefined(typeof(ResourceType), file.ResourceType))
                {
                    Invalid("The export file kind or resourceType is unsupported.");
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

                if (file.ByteCount is < 0)
                {
                    Invalid("byteCount cannot be negative.");
                }

                if (file.AssetId != asset.AssetId)
                {
                    Invalid("ExportFile.assetId must match its containing asset.");
                }

                RequireSha256(file.SourceRevision, "sourceRevision");
                if (!string.Equals(file.SourceRevision, asset.SourceRevision, StringComparison.Ordinal))
                {
                    Invalid("ExportFile.sourceRevision must match its containing asset.");
                }
                if (file.Sha256 is not null)
                {
                    RequireSha256(file.Sha256, "sha256");
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
