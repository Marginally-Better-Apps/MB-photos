using MBPhotos.Receiver.Models;
using MBPhotos.Receiver.Storage;
using MBPhotos.Receiver.Transfer;

namespace MBPhotos.Receiver.Library;

public sealed record VariantExportResult(
    Guid AssetId,
    Guid FileId,
    string ExportedPath,
    long ByteCount,
    string Sha256,
    bool ExistingVerified);

/// <summary>Exports an available representation as a verified exact byte copy.</summary>
public sealed class VariantExportService
{
    public async Task<VariantExportResult> ExportAsync(
        PortableLibraryFile file,
        string targetDirectory,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(file);
        if (string.IsNullOrWhiteSpace(targetDirectory))
        {
            throw new ArgumentException("An export folder is required.", nameof(targetDirectory));
        }
        if (file.Catalog.Availability != Availability.Available ||
            file.AbsolutePath is not { } sourcePath ||
            file.Catalog.ByteCount is not { } byteCount ||
            file.Catalog.Sha256 is not { } sha256)
        {
            throw new InvalidOperationException("This representation is not available for exact-copy export.");
        }

        EnsureSourceIsContained(file.LibraryRoot, sourcePath);
        await RequireExactAsync(sourcePath, byteCount, sha256, cancellationToken);
        var directory = Path.GetFullPath(targetDirectory);
        EnsureOutsideLibrary(file.LibraryRoot, directory);
        EnsureResolvedOutsideLibrary(file.LibraryRoot, directory);
        Directory.CreateDirectory(directory);
        EnsureResolvedOutsideLibrary(file.LibraryRoot, directory);
        var baseName = SafeLeafName(file.Catalog.OriginalFilename, file.FileId);
        var targetPath = Path.Combine(directory, baseName);
        if (File.Exists(targetPath))
        {
            if (await IsExactAsync(targetPath, byteCount, sha256, cancellationToken))
            {
                return new VariantExportResult(file.AssetId, file.FileId, targetPath, byteCount, sha256, true);
            }
            targetPath = AllocateCollisionPath(directory, baseName, file.FileId);
        }
        else if (Directory.Exists(targetPath))
        {
            targetPath = AllocateCollisionPath(directory, baseName, file.FileId);
        }

        var stagingPath = Path.Combine(directory, $".mbphotos-export-{Guid.NewGuid():N}.tmp");
        try
        {
            // Re-check immediately before opening the source so a swapped
            // directory link cannot redirect this exact-copy export.
            EnsureSourceIsContained(file.LibraryRoot, sourcePath);
            await using (var input = new FileStream(
                             sourcePath,
                             FileMode.Open,
                             FileAccess.Read,
                             FileShare.Read,
                             128 * 1024,
                             FileOptions.Asynchronous | FileOptions.SequentialScan))
            await using (var output = new FileStream(
                             stagingPath,
                             FileMode.CreateNew,
                             FileAccess.Write,
                             FileShare.None,
                             128 * 1024,
                             FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                await input.CopyToAsync(output, 128 * 1024, cancellationToken);
                await output.FlushAsync(cancellationToken);
                output.Flush(true);
            }
            await RequireExactAsync(stagingPath, byteCount, sha256, cancellationToken);
            File.Move(stagingPath, targetPath, false);
            ApplyCaptureTimestamp(targetPath, file.Catalog.CaptureDate);
            return new VariantExportResult(file.AssetId, file.FileId, targetPath, byteCount, sha256, false);
        }
        finally
        {
            if (File.Exists(stagingPath))
            {
                File.Delete(stagingPath);
            }
        }
    }

    public Task<VariantExportResult> ExportAsync(
        PortableLibrarySnapshot library,
        Guid assetId,
        VariantKind variant,
        string targetDirectory,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(library);
        var asset = library.Assets.SingleOrDefault(candidate => candidate.AssetId == assetId)
            ?? throw new KeyNotFoundException($"Asset {assetId:D} is not in this library.");
        var role = variant switch
        {
            VariantKind.CurrentMaster => RepresentationRole.MasterCurrent,
            VariantKind.RootOriginal => RepresentationRole.RootOriginal,
            VariantKind.CurrentLiveMotion => RepresentationRole.CurrentLiveMotion,
            VariantKind.OriginalLiveMotion => RepresentationRole.OriginalLiveMotion,
            _ => throw new ArgumentOutOfRangeException(nameof(variant)),
        };
        var file = variant == VariantKind.CurrentMaster
            ? asset.MasterFile
            : asset.Files.FirstOrDefault(candidate =>
                candidate.Catalog.Availability == Availability.Available &&
                candidate.Catalog.Roles.Contains(role));
        if (file is null)
        {
            throw new InvalidOperationException($"The {variant} representation is unavailable for this asset.");
        }
        return ExportAsync(file, targetDirectory, cancellationToken);
    }

    private static string AllocateCollisionPath(string directory, string filename, Guid fileId)
    {
        var extension = Path.GetExtension(filename);
        var stem = Path.GetFileNameWithoutExtension(filename);
        var suffix = fileId.ToString("N")[..8];
        for (var attempt = 1; attempt <= 10_000; attempt++)
        {
            var ordinal = attempt == 1 ? string.Empty : $"-{attempt}";
            var candidate = Path.Combine(directory, $"{stem}~{suffix}{ordinal}{extension}");
            if (!File.Exists(candidate) && !Directory.Exists(candidate))
            {
                return candidate;
            }
        }
        throw new IOException("No deterministic export filename is available.");
    }

    private static void EnsureOutsideLibrary(string libraryRoot, string targetDirectory)
    {
        var root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(libraryRoot));
        var target = Path.TrimEndingDirectorySeparator(Path.GetFullPath(targetDirectory));
        var comparison = OperatingSystem.IsWindows()
            ? StringComparison.OrdinalIgnoreCase
            : StringComparison.Ordinal;
        var prefix = root + Path.DirectorySeparatorChar;
        if (string.Equals(root, target, comparison) || target.StartsWith(prefix, comparison))
        {
            throw new InvalidOperationException("Variants must be exported outside the portable library root.");
        }
    }

    private static string SafeLeafName(string originalFilename, Guid fileId)
    {
        var value = Path.GetFileName(originalFilename);
        foreach (var invalid in Path.GetInvalidFileNameChars())
        {
            value = value.Replace(invalid, '_');
        }
        value = value.TrimEnd(' ', '.');
        if (string.IsNullOrWhiteSpace(value) || value is "." or "..")
        {
            value = fileId.ToString("D");
        }
        return new WindowsPathPolicy().SanitizeFileName(value, fileId);
    }

    private static void EnsureSourceIsContained(string libraryRoot, string sourcePath)
    {
        new WindowsPathPolicy().EnsureNoReparsePoints(libraryRoot, sourcePath);
    }

    private static void EnsureResolvedOutsideLibrary(string libraryRoot, string targetDirectory)
    {
        var resolvedRoot = Path.TrimEndingDirectorySeparator(ResolvePhysicalPath(libraryRoot));
        var resolvedTarget = Path.TrimEndingDirectorySeparator(ResolvePhysicalPath(targetDirectory));
        var comparison = OperatingSystem.IsWindows()
            ? StringComparison.OrdinalIgnoreCase
            : StringComparison.Ordinal;
        var prefix = resolvedRoot + Path.DirectorySeparatorChar;
        if (string.Equals(resolvedRoot, resolvedTarget, comparison) ||
            resolvedTarget.StartsWith(prefix, comparison))
        {
            throw new InvalidOperationException(
                "The export folder resolves inside the portable library root.");
        }
    }

    private static string ResolvePhysicalPath(string path)
    {
        var fullPath = Path.GetFullPath(path);
        var pathRoot = Path.GetPathRoot(fullPath)
            ?? throw new InvalidOperationException("The export path has no filesystem root.");
        var current = pathRoot;
        var relative = fullPath[pathRoot.Length..];
        foreach (var segment in relative.Split(
                     new[] { Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar },
                     StringSplitOptions.RemoveEmptyEntries))
        {
            var candidate = Path.Combine(current, segment);
            if (Directory.Exists(candidate))
            {
                var info = new DirectoryInfo(candidate);
                if ((info.Attributes & FileAttributes.ReparsePoint) != 0)
                {
                    var resolved = info.ResolveLinkTarget(returnFinalTarget: true)?.FullName
                        ?? throw new InvalidOperationException("An export path link could not be resolved safely.");
                    // The resolved target can itself contain a platform alias
                    // such as macOS /var -> /private/var. Canonicalize that
                    // hierarchy too before doing the containment comparison.
                    current = ResolvePhysicalPath(resolved);
                    continue;
                }
            }
            current = candidate;
        }
        return Path.GetFullPath(current);
    }

    private static async Task RequireExactAsync(
        string path,
        long byteCount,
        string sha256,
        CancellationToken cancellationToken)
    {
        if (!await IsExactAsync(path, byteCount, sha256, cancellationToken))
        {
            throw new InvalidDataException("The selected library representation is missing or does not match its catalog hash.");
        }
    }

    private static async Task<bool> IsExactAsync(
        string path,
        long byteCount,
        string sha256,
        CancellationToken cancellationToken) =>
        File.Exists(path) && new FileInfo(path).Length == byteCount &&
        string.Equals(await Hashing.Sha256FileAsync(path, cancellationToken), sha256, StringComparison.Ordinal);

    private static void ApplyCaptureTimestamp(string path, DateTimeOffset? captureDate)
    {
        if (captureDate is null)
        {
            return;
        }
        try
        {
            File.SetLastWriteTimeUtc(path, captureDate.Value.UtcDateTime);
            File.SetCreationTimeUtc(path, captureDate.Value.UtcDateTime);
        }
        catch (PlatformNotSupportedException)
        {
        }
    }
}
