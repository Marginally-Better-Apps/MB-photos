using System.Globalization;
using System.Text;
using MBPhotos.Receiver.Models;

namespace MBPhotos.Receiver.Storage;

public sealed class WindowsPathPolicy
{
    public const int Version = 2;

    private static readonly HashSet<string> ReservedNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    };

    public string SanitizeFileName(string originalName, Guid fileId)
    {
        var normalized = (originalName ?? string.Empty).Normalize(NormalizationForm.FormC);
        var builder = new StringBuilder(normalized.Length);
        foreach (var character in normalized)
        {
            builder.Append(IsInvalidCharacter(character) ? '_' : character);
        }

        var result = builder.ToString().TrimEnd(' ', '.');
        if (result is "" or "." or "..")
        {
            result = "_";
        }

        var firstPeriod = result.IndexOf('.', StringComparison.Ordinal);
        var stem = firstPeriod < 0 ? result : result[..firstPeriod];
        if (ReservedNames.Contains(stem))
        {
            result = "_" + result;
        }

        return result;
    }

    public string CreateDefaultRelativePath(DateTimeOffset? captureDate, string originalName, Guid fileId)
        => CreateDefaultRelativePath(captureDate, originalName, fileId, StorageArea.Master, null);

    public string CreateDefaultRelativePath(
        DateTimeOffset? captureDate,
        string originalName,
        Guid fileId,
        StorageArea storageArea,
        Guid? assetId,
        Provenance provenance = Provenance.ExactPhotoKitResource)
    {
        var timestamp = captureDate ?? DateTimeOffset.UnixEpoch;
        var safeName = SanitizeFileName(originalName, fileId);
        var path = storageArea == StorageArea.Master
            ? FormattableString.Invariant(
                $"Master/{timestamp:yyyy}/{timestamp:yyyy-MM}/{timestamp:yyyy-MM-dd}/{safeName}")
            : provenance == Provenance.GeneratedThumbnail
                ? $"MB Photos Data/Thumbnails/{(assetId ?? Guid.Empty):D}/{fileId:D}{Path.GetExtension(safeName)}"
                : $"MB Photos Data/Resources/{(assetId ?? Guid.Empty):D}/{fileId:D}{Path.GetExtension(safeName)}";
        return ShortenRelativePath(path, fileId);
    }

    public string NormalizeProposedPath(
        string? proposedPath,
        DateTimeOffset? captureDate,
        string originalName,
        Guid fileId) => NormalizeProposedPath(
            proposedPath,
            captureDate,
            originalName,
            fileId,
            StorageArea.Master,
            null,
            Provenance.ExactPhotoKitResource);

    public string NormalizeProposedPath(
        string? proposedPath,
        DateTimeOffset? captureDate,
        string originalName,
        Guid fileId,
        StorageArea storageArea,
        Guid? assetId,
        Provenance provenance)
    {
        var fallback = CreateDefaultRelativePath(captureDate, originalName, fileId, storageArea, assetId, provenance);
        if (string.IsNullOrWhiteSpace(proposedPath))
        {
            return fallback;
        }

        var normalized = proposedPath.Normalize(NormalizationForm.FormC);
        if (normalized[0] == '/' ||
            normalized.Contains('\\') ||
            normalized.Contains(':') ||
            normalized.IndexOf('\0') >= 0)
        {
            throw new ReceiverApiException(400, ErrorCodes.UnsafePath, "The proposed path is rooted, drive-qualified, or uses a Windows separator.");
        }

        var rawSegments = normalized.Split('/', StringSplitOptions.None);
        if (rawSegments.Length < 2 || rawSegments.Any(static segment => segment is "" or "." or ".."))
        {
            throw new ReceiverApiException(400, ErrorCodes.UnsafePath, "The proposed path contains an unsafe segment.");
        }

        var validArea = storageArea == StorageArea.Master
            ? rawSegments.Length >= 2 && string.Equals(rawSegments[0], "Master", StringComparison.Ordinal)
            : rawSegments.Length >= 3 &&
                string.Equals(rawSegments[0], "MB Photos Data", StringComparison.Ordinal) &&
                ((provenance == Provenance.GeneratedThumbnail && string.Equals(rawSegments[1], "Thumbnails", StringComparison.Ordinal)) ||
                 (provenance != Provenance.GeneratedThumbnail && string.Equals(rawSegments[1], "Resources", StringComparison.Ordinal)));
        if (!validArea)
        {
            throw new ReceiverApiException(400, ErrorCodes.UnsafePath,
                storageArea == StorageArea.Master
                    ? "Master media must be written below the Master directory."
                    : "Support resources must be written below the receiver-owned Resources or Thumbnails directory.");
        }

        var safeSegments = new List<string>(rawSegments.Length);
        for (var i = 0; i < rawSegments.Length; i++)
        {
            var safe = SanitizeFileName(rawSegments[i], fileId);
            safeSegments.Add(safe);
        }

        var relativePath = string.Join('/', safeSegments);
        try
        {
            return ShortenRelativePath(relativePath, fileId);
        }
        catch (ReceiverApiException)
        {
            return fallback;
        }
    }

    public string ShortenRelativePath(string relativePath, Guid fileId)
    {
        ValidateRelativePath(relativePath, enforceLength: false);
        if (relativePath.Length <= ProtocolConstants.MaximumRelativePathLength)
        {
            return relativePath;
        }

        return AddSuffixAndFit(relativePath, fileId, string.Empty);
    }

    public string AddStableCollisionSuffix(string relativePath, Guid fileId, int attempt = 1)
    {
        ValidateRelativePath(relativePath);
        var ordinal = attempt <= 1 ? string.Empty : "-" + attempt.ToString(CultureInfo.InvariantCulture);
        return AddSuffixAndFit(relativePath, fileId, ordinal);
    }

    public string ResolveUnderRoot(string rootPath, string relativePath)
    {
        ValidateRelativePath(relativePath);
        var canonicalRoot = Path.TrimEndingDirectorySeparator(Path.GetFullPath(rootPath));
        var platformRelative = relativePath.Replace('/', Path.DirectorySeparatorChar);
        var candidate = Path.GetFullPath(Path.Combine(canonicalRoot, platformRelative));
        var prefix = Path.EndsInDirectorySeparator(canonicalRoot)
            ? canonicalRoot
            : canonicalRoot + Path.DirectorySeparatorChar;
        var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        if (!candidate.StartsWith(prefix, comparison))
        {
            throw new ReceiverApiException(400, ErrorCodes.PathConflict, "The destination path escapes the backup root.");
        }

        EnsureNoReparsePoints(canonicalRoot, candidate);

        return candidate;
    }

    public void EnsureNoReparsePoints(string rootPath, string targetPath)
    {
        var canonicalRoot = Path.TrimEndingDirectorySeparator(Path.GetFullPath(rootPath));
        var canonicalTarget = Path.GetFullPath(targetPath);
        var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        var prefix = Path.EndsInDirectorySeparator(canonicalRoot)
            ? canonicalRoot
            : canonicalRoot + Path.DirectorySeparatorChar;
        if (!string.Equals(canonicalRoot, canonicalTarget, comparison) &&
            !canonicalTarget.StartsWith(prefix, comparison))
        {
            throw new ReceiverApiException(400, ErrorCodes.UnsafePath, "The destination path escapes the selected backup root.");
        }

        RejectIfReparsePoint(canonicalRoot);
        if (string.Equals(canonicalRoot, canonicalTarget, comparison))
        {
            return;
        }

        var relative = Path.GetRelativePath(canonicalRoot, canonicalTarget);
        var current = canonicalRoot;
        foreach (var segment in relative.Split(
            new[] { Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar },
            StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, segment);
            RejectIfReparsePoint(current);
        }
    }

    public void ValidateRelativePath(string relativePath) => ValidateRelativePath(relativePath, enforceLength: true);

    private void ValidateRelativePath(string relativePath, bool enforceLength)
    {
        if (string.IsNullOrWhiteSpace(relativePath) ||
            relativePath[0] == '/' ||
            relativePath.Contains('\\') ||
            relativePath.Contains(':') ||
            relativePath.IndexOf('\0') >= 0)
        {
            throw new ReceiverApiException(400, ErrorCodes.UnsafePath, "The relative path is not valid for Windows.");
        }

        if (enforceLength && relativePath.Length > ProtocolConstants.MaximumRelativePathLength)
        {
            throw new ReceiverApiException(409, ErrorCodes.PathConflict, "The relative path exceeds 239 UTF-16 code units.");
        }

        foreach (var segment in relativePath.Split('/', StringSplitOptions.None))
        {
            if (segment is "" or "." or ".." ||
                segment != segment.Normalize(NormalizationForm.FormC) ||
                segment != segment.TrimEnd(' ', '.'))
            {
                throw new ReceiverApiException(400, ErrorCodes.UnsafePath, "The relative path contains an unsafe segment.");
            }

            var firstPeriod = segment.IndexOf('.', StringComparison.Ordinal);
            var stem = firstPeriod < 0 ? segment : segment[..firstPeriod];
            if (segment.Any(IsInvalidCharacter) || ReservedNames.Contains(stem))
            {
                throw new ReceiverApiException(400, ErrorCodes.UnsafePath, "The relative path contains a Windows-reserved name or character.");
            }
        }
    }

    private static string AddSuffixAndFit(string relativePath, Guid fileId, string ordinal)
    {
        var slash = relativePath.LastIndexOf('/');
        var directory = slash < 0 ? string.Empty : relativePath[..(slash + 1)];
        var filename = slash < 0 ? relativePath : relativePath[(slash + 1)..];
        var period = filename.LastIndexOf('.');
        var extension = period <= 0 ? string.Empty : filename[period..];
        var stem = period <= 0 ? filename : filename[..period];
        var suffix = "~" + FileSuffix(fileId) + ordinal;
        var allowedStemUnits = ProtocolConstants.MaximumRelativePathLength - directory.Length - extension.Length - suffix.Length;
        if (allowedStemUnits < 1)
        {
            throw new ReceiverApiException(409, ErrorCodes.PathConflict, "The parent path leaves no room for a safe filename.");
        }

        while (stem.Length > allowedStemUnits)
        {
            var lastScalarStart = stem.Length - 1;
            if (lastScalarStart > 0 && char.IsLowSurrogate(stem[lastScalarStart]) && char.IsHighSurrogate(stem[lastScalarStart - 1]))
            {
                lastScalarStart--;
            }

            stem = stem[..lastScalarStart];
        }

        if (stem.Length == 0)
        {
            throw new ReceiverApiException(409, ErrorCodes.PathConflict, "The parent path leaves no room for a safe filename.");
        }

        return directory + stem + suffix + extension;
    }

    private static void RejectIfReparsePoint(string path)
    {
        try
        {
            if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
            {
                throw new ReceiverApiException(409, ErrorCodes.ChangedDestination, "A symbolic link or junction is not allowed inside the backup destination.");
            }
        }
        catch (FileNotFoundException)
        {
        }
        catch (DirectoryNotFoundException)
        {
        }
    }

    private static string FileSuffix(Guid fileId) => fileId.ToString("N", CultureInfo.InvariantCulture)[..8];

    private static bool IsInvalidCharacter(char character) =>
        character < 32 || character is '<' or '>' or ':' or '"' or '/' or '\\' or '|' or '?' or '*';
}
