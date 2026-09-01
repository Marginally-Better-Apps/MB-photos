using System.IO;
using System.Text.Json;

namespace MBPhotos.Receiver.Wpf;

/// <summary>
/// Persists receiver settings without making a malformed or inaccessible settings file
/// a startup failure.
/// </summary>
public sealed class ReceiverSettingsStore
{
    private static readonly JsonSerializerOptions SerializerOptions = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = false,
        WriteIndented = true,
    };

    public ReceiverSettingsStore()
        : this(GetDefaultFilePath())
    {
    }

    public ReceiverSettingsStore(string filePath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(filePath);
        FilePath = Path.GetFullPath(filePath);
    }

    public string FilePath { get; }

    public static string GetDefaultFilePath() => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "MarginallyBetterPhotos",
        "Receiver",
        "settings.json");

    public async Task<ReceiverSettings?> LoadAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            await using var stream = new FileStream(
                FilePath,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read | FileShare.Delete,
                4096,
                FileOptions.Asynchronous | FileOptions.SequentialScan);
            var document = await JsonSerializer.DeserializeAsync<SettingsDocument>(
                stream,
                SerializerOptions,
                cancellationToken).ConfigureAwait(false);

            if (document is null ||
                document.Version != ReceiverSettings.CurrentVersion ||
                string.IsNullOrWhiteSpace(document.LibraryRoot))
            {
                return null;
            }

            return new ReceiverSettings(document.LibraryRoot);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception exception) when (IsRecoverableReadFailure(exception))
        {
            return null;
        }
    }

    public async Task SaveAsync(
        ReceiverSettings settings,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(settings);

        var directory = Path.GetDirectoryName(FilePath)
            ?? throw new InvalidOperationException("The settings path has no parent directory.");
        Directory.CreateDirectory(directory);

        var temporaryPath = Path.Combine(
            directory,
            $".{Path.GetFileName(FilePath)}.{Guid.NewGuid():N}.tmp");
        try
        {
            await using (var stream = new FileStream(
                temporaryPath,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                4096,
                FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                var document = new SettingsDocument
                {
                    Version = ReceiverSettings.CurrentVersion,
                    LibraryRoot = settings.LibraryRoot,
                };
                await JsonSerializer.SerializeAsync(
                    stream,
                    document,
                    SerializerOptions,
                    cancellationToken).ConfigureAwait(false);
                await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
                stream.Flush(flushToDisk: true);
            }

            cancellationToken.ThrowIfCancellationRequested();
            File.Move(temporaryPath, FilePath, overwrite: true);
        }
        finally
        {
            try
            {
                File.Delete(temporaryPath);
            }
            catch (IOException)
            {
                // A failed cleanup must not mask the result of the durable write.
            }
            catch (UnauthorizedAccessException)
            {
                // A failed cleanup must not mask the result of the durable write.
            }
        }
    }

    private static bool IsRecoverableReadFailure(Exception exception) => exception is
        FileNotFoundException or
        DirectoryNotFoundException or
        IOException or
        UnauthorizedAccessException or
        JsonException or
        NotSupportedException or
        ArgumentException;

    private sealed class SettingsDocument
    {
        public int Version { get; init; }

        public string? LibraryRoot { get; init; }
    }
}
