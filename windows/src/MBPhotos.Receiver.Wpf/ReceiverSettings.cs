using System.IO;

namespace MBPhotos.Receiver.Wpf;

/// <summary>
/// The small, versioned set of receiver preferences that may persist between launches.
/// </summary>
public sealed record ReceiverSettings
{
    public const int CurrentVersion = 1;

    public ReceiverSettings(string libraryRoot)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(libraryRoot);

        var fullPath = Path.GetFullPath(libraryRoot.Trim());
        if (!Path.IsPathFullyQualified(fullPath))
        {
            throw new ArgumentException("The library root must be an absolute path.", nameof(libraryRoot));
        }

        LibraryRoot = Path.TrimEndingDirectorySeparator(fullPath);
    }

    public int Version => CurrentVersion;

    public string LibraryRoot { get; }
}
