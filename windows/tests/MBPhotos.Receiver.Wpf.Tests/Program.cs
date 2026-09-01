using System.IO;
using System.Text.Json;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using MBPhotos.Receiver.Models;
using MBPhotos.Receiver.Transfer;

namespace MBPhotos.Receiver.Wpf.Tests;

internal static class Program
{
    private static int passed;
    private static int failed;

    [STAThread]
    public static int Main()
    {
        var tests = new (string Name, Func<Task> Run)[]
        {
            ("presentation state copy and preview fencing", TestPresentationStateAndPreviewFencingAsync),
            ("missing settings are treated as first launch", TestMissingSettingsAsync),
            ("corrupt settings are ignored", TestCorruptSettingsAsync),
            ("valid versioned settings load", TestValidSettingsAsync),
            ("settings replacement is atomic", TestAtomicSettingsReplacementAsync),
            ("failed settings save preserves the prior value", TestFailedSettingsSavePreservesPriorValueAsync),
            ("preview paths remain inside the active library", TestPreviewSafePathAsync),
            ("malformed JPEG previews fall back cleanly", TestMalformedPreviewAsync),
            ("loaded previews release their source file", TestPreviewFileHandleReleaseAsync),
        };

        foreach (var test in tests)
        {
            try
            {
                test.Run().GetAwaiter().GetResult();
                passed++;
                Console.WriteLine($"PASS {test.Name}");
            }
            catch (Exception exception)
            {
                failed++;
                Console.Error.WriteLine($"FAIL {test.Name}: {exception}");
            }
        }

        Console.WriteLine($"{passed} passed; {failed} failed");
        return failed == 0 ? 0 : 1;
    }

    private static Task TestPresentationStateAndPreviewFencingAsync()
    {
        using var temporaryDirectory = new TemporaryDirectory();
        var libraryRoot = Path.Combine(temporaryDirectory.Path, "Family Library");
        Directory.CreateDirectory(libraryRoot);
        var model = new ReceiverWindowPresentationModel();

        var stateExpectations = new[]
        {
            (ReceiverPresentationState.Setup, "Choose where photos are saved", "Set up", false, false),
            (ReceiverPresentationState.Starting, "Getting ready", "Starting", true, false),
            (ReceiverPresentationState.Ready, "Scan with MB Photos on your iPhone", "Ready", true, false),
            (ReceiverPresentationState.Connected, "iPhone connected", "Connected", true, false),
            (ReceiverPresentationState.Transferring, "Receiving photos", "Receiving", true, false),
            (ReceiverPresentationState.Finalizing, "Finishing up", "Finalizing", true, false),
            (ReceiverPresentationState.Paused, "Receiving is paused", "Paused", false, true),
            (ReceiverPresentationState.Error, "Receiver needs attention", "Needs attention", false, true),
        };

        foreach (var expectation in stateExpectations)
        {
            model.Apply(Snapshot(expectation.Item1, generation: 41, libraryRoot));
            Equal(expectation.Item2, model.Heading, $"heading for {expectation.Item1}");
            Equal(expectation.Item3, model.StatusText, $"status for {expectation.Item1}");
            Equal(expectation.Item4, model.CanStop, $"stop availability for {expectation.Item1}");
            Equal(expectation.Item5, model.CanRetry, $"retry availability for {expectation.Item1}");
        }

        var activity = new ReceiverActivity(
            Guid.NewGuid(),
            "transferring",
            CompletedFiles: 3,
            TotalFiles: 7,
            TransferredBytes: 1024,
            CurrentRelativePath: "Master/private-name.jpg",
            FreeBytes: 2048,
            LatestThumbnailRelativePath: "MB Photos Data/Thumbnails/current.jpg");
        var counts = new CompletionCounts(4, 4, 0, 7, 7, 0, 0, 1024, 1024);
        model.Apply(new ReceiverOrchestrationSnapshot(
            ReceiverPresentationState.Transferring,
            41,
            libraryRoot,
            null,
            null,
            activity,
            new LastTransferPresentation("completed", counts, activity.LatestThumbnailRelativePath),
            null,
            null));
        Equal("3 of 7 files", model.ProgressText, "simple transfer progress");
        Equal("Transfer complete", model.CompletionHeading, "completion copy");
        Equal("4 items saved to Family Library.", model.CompletionMessage, "completion count copy");

        var preview = new DrawingImage();
        preview.Freeze();
        const string requestedPath = "MB Photos Data/Thumbnails/current.jpg";
        model.BeginPreviewRequest(41, requestedPath);
        False(model.TrySetPreview(40, requestedPath, preview, completion: false), "stale generation was accepted");
        False(model.TrySetPreview(41, "MB Photos Data/Thumbnails/other.jpg", preview, completion: false), "stale path was accepted");
        True(model.TrySetPreview(41, requestedPath, preview, completion: true), "current preview was rejected");
        True(model.HasTransferPreview, "current preview was not retained");
        Same(preview, model.CompletionPreviewImage, "completion preview");

        model.BeginPreviewRequest(41, "MB Photos Data/Thumbnails/new.jpg");
        False(model.TrySetPreview(41, requestedPath, preview, completion: false), "superseded preview request was accepted");
        model.Apply(Snapshot(ReceiverPresentationState.Ready, generation: 42, libraryRoot));
        True(model.HasTransferPreview, "same-library restart discarded the last verified preview");
        Same(preview, model.CompletionPreviewImage, "same-library restart discarded the completion preview");
        False(
            model.TrySetPreview(41, "MB Photos Data/Thumbnails/new.jpg", preview, completion: false),
            "generation change did not fence pending preview work");

        model.Apply(Snapshot(
            ReceiverPresentationState.Ready,
            generation: 43,
            Path.Combine(Path.GetTempPath(), "Another MB Photos Library")));
        False(model.HasTransferPreview, "library change retained a preview from another root");
        Equal<ImageSource?>(null, model.CompletionPreviewImage, "library change retained a completion preview");

        model.Apply(Snapshot(ReceiverPresentationState.Library, generation: 43, libraryRoot));
        True(model.IsLibraryPage, "library state did not select the library page");
        model.Apply(Snapshot(ReceiverPresentationState.Ready, generation: 44, libraryRoot));
        True(model.IsReceiverPage, "leaving library did not restore the receiver page");

        return Task.CompletedTask;
    }

    private static async Task TestMissingSettingsAsync()
    {
        using var temporaryDirectory = new TemporaryDirectory();
        var store = StoreIn(temporaryDirectory.Path);
        Equal<ReceiverSettings?>(null, await store.LoadAsync(), "missing settings result");
    }

    private static async Task TestCorruptSettingsAsync()
    {
        using var temporaryDirectory = new TemporaryDirectory();
        var store = StoreIn(temporaryDirectory.Path);
        Directory.CreateDirectory(Path.GetDirectoryName(store.FilePath)!);
        await File.WriteAllTextAsync(store.FilePath, "{ definitely-not-json");
        Equal<ReceiverSettings?>(null, await store.LoadAsync(), "corrupt settings result");

        await File.WriteAllTextAsync(store.FilePath, "{\"version\":999,\"libraryRoot\":\"C:\\\\Photos\"}");
        Equal<ReceiverSettings?>(null, await store.LoadAsync(), "unknown settings version result");
    }

    private static async Task TestValidSettingsAsync()
    {
        using var temporaryDirectory = new TemporaryDirectory();
        var store = StoreIn(temporaryDirectory.Path);
        var libraryRoot = Path.Combine(temporaryDirectory.Path, "Photo Library") + Path.DirectorySeparatorChar;
        Directory.CreateDirectory(Path.GetDirectoryName(store.FilePath)!);
        var json = JsonSerializer.Serialize(new
        {
            version = ReceiverSettings.CurrentVersion,
            libraryRoot,
        });
        await File.WriteAllTextAsync(store.FilePath, json);

        var settings = await store.LoadAsync();
        NotNull(settings, "valid settings were ignored");
        Equal(
            Path.TrimEndingDirectorySeparator(Path.GetFullPath(libraryRoot)),
            settings!.LibraryRoot,
            "normalized library root");
        Equal(ReceiverSettings.CurrentVersion, settings.Version, "settings version");
    }

    private static async Task TestAtomicSettingsReplacementAsync()
    {
        using var temporaryDirectory = new TemporaryDirectory();
        var store = StoreIn(temporaryDirectory.Path);
        var original = new ReceiverSettings(Path.Combine(temporaryDirectory.Path, "Original"));
        var replacement = new ReceiverSettings(Path.Combine(temporaryDirectory.Path, "Replacement"));

        await store.SaveAsync(original);
        await store.SaveAsync(replacement);

        var loaded = await store.LoadAsync();
        NotNull(loaded, "replacement settings were not readable");
        Equal(replacement.LibraryRoot, loaded!.LibraryRoot, "replacement library root");
        var settingsDirectory = Path.GetDirectoryName(store.FilePath)!;
        Equal(0, Directory.GetFiles(settingsDirectory, ".settings.json.*.tmp").Length, "temporary settings files");
        using var document = JsonDocument.Parse(await File.ReadAllTextAsync(store.FilePath));
        Equal(ReceiverSettings.CurrentVersion, document.RootElement.GetProperty("version").GetInt32(), "persisted version");
        Equal(replacement.LibraryRoot, document.RootElement.GetProperty("libraryRoot").GetString(), "persisted root");
    }

    private static async Task TestFailedSettingsSavePreservesPriorValueAsync()
    {
        using var temporaryDirectory = new TemporaryDirectory();
        var store = StoreIn(temporaryDirectory.Path);
        var original = new ReceiverSettings(Path.Combine(temporaryDirectory.Path, "Original"));
        var replacement = new ReceiverSettings(Path.Combine(temporaryDirectory.Path, "Replacement"));
        await store.SaveAsync(original);

        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        await ThrowsAsync<OperationCanceledException>(() => store.SaveAsync(replacement, cancellation.Token));

        var loaded = await store.LoadAsync();
        NotNull(loaded, "prior settings disappeared after failed save");
        Equal(original.LibraryRoot, loaded!.LibraryRoot, "prior settings after failed save");
        var settingsDirectory = Path.GetDirectoryName(store.FilePath)!;
        Equal(0, Directory.GetFiles(settingsDirectory, ".settings.json.*.tmp").Length, "failed-save temporary files");
    }

    private static async Task TestPreviewSafePathAsync()
    {
        using var temporaryDirectory = new TemporaryDirectory();
        var libraryRoot = Path.Combine(temporaryDirectory.Path, "Library");
        Directory.CreateDirectory(libraryRoot);
        var outsidePath = Path.Combine(temporaryDirectory.Path, "outside.jpg");
        WriteJpeg(outsidePath);

        var loader = new TransferPreviewLoader();
        var preview = await loader.TryLoadAsync(libraryRoot, "../outside.jpg");
        Equal<BitmapSource?>(null, preview, "escaping preview path");
    }

    private static async Task TestMalformedPreviewAsync()
    {
        using var temporaryDirectory = new TemporaryDirectory();
        var libraryRoot = Path.Combine(temporaryDirectory.Path, "Library");
        var previewDirectory = Path.Combine(libraryRoot, "MB Photos Data", "Thumbnails");
        Directory.CreateDirectory(previewDirectory);
        var malformedPath = Path.Combine(previewDirectory, "malformed.jpg");
        await File.WriteAllBytesAsync(malformedPath, [0x00, 0x01, 0x02, 0x03]);

        var loader = new TransferPreviewLoader();
        var preview = await loader.TryLoadAsync(libraryRoot, "MB Photos Data/Thumbnails/malformed.jpg");
        Equal<BitmapSource?>(null, preview, "malformed JPEG preview");
    }

    private static async Task TestPreviewFileHandleReleaseAsync()
    {
        using var temporaryDirectory = new TemporaryDirectory();
        var libraryRoot = Path.Combine(temporaryDirectory.Path, "Library");
        var previewDirectory = Path.Combine(libraryRoot, "MB Photos Data", "Thumbnails");
        Directory.CreateDirectory(previewDirectory);
        var previewPath = Path.Combine(previewDirectory, "verified.jpg");
        WriteJpeg(previewPath);

        var loader = new TransferPreviewLoader();
        var preview = await loader.TryLoadAsync(libraryRoot, "MB Photos Data/Thumbnails/verified.jpg");
        NotNull(preview, "valid JPEG preview was not decoded");
        True(preview!.IsFrozen, "decoded preview was not frozen");
        True(preview.PixelWidth > 0 && preview.PixelHeight > 0, "decoded preview has no pixels");

        using (new FileStream(previewPath, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
        {
            // Exclusive access proves the decoder no longer owns the source stream.
        }

        File.Delete(previewPath);
        False(File.Exists(previewPath), "preview source could not be removed after decoding");
    }

    private static ReceiverOrchestrationSnapshot Snapshot(
        ReceiverPresentationState state,
        long generation,
        string? libraryRoot,
        Exception? error = null) => new(
            state,
            generation,
            libraryRoot,
            null,
            null,
            null,
            null,
            error,
            null,
            state == ReceiverPresentationState.Paused);

    private static ReceiverSettingsStore StoreIn(string root) => new(
        Path.Combine(root, "Settings", "settings.json"));

    private static void WriteJpeg(string path)
    {
        var pixels = new byte[] { 0x20, 0x80, 0xE0, 0xFF };
        var bitmap = BitmapSource.Create(
            1,
            1,
            96,
            96,
            PixelFormats.Bgra32,
            null,
            pixels,
            stride: 4);
        var encoder = new JpegBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var stream = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None);
        encoder.Save(stream);
    }

    private static async Task<TException> ThrowsAsync<TException>(Func<Task> action)
        where TException : Exception
    {
        try
        {
            await action();
        }
        catch (TException exception)
        {
            return exception;
        }

        throw new InvalidOperationException($"Expected {typeof(TException).Name}.");
    }

    private static void NotNull<T>(T? value, string message)
        where T : class
    {
        if (value is null)
        {
            throw new InvalidOperationException(message);
        }
    }

    private static void Same(object expected, object? actual, string message)
    {
        if (!ReferenceEquals(expected, actual))
        {
            throw new InvalidOperationException($"{message}: references differ");
        }
    }

    private static void True(bool value, string message)
    {
        if (!value)
        {
            throw new InvalidOperationException(message);
        }
    }

    private static void False(bool value, string message) => True(!value, message);

    private static void Equal<T>(T expected, T actual, string message)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
        {
            throw new InvalidOperationException($"{message}: expected <{expected}>, actual <{actual}>");
        }
    }

    private sealed class TemporaryDirectory : IDisposable
    {
        public TemporaryDirectory()
        {
            Path = System.IO.Path.Combine(
                System.IO.Path.GetTempPath(),
                "MBPhotos.Receiver.Wpf.Tests",
                Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(Path);
        }

        public string Path { get; }

        public void Dispose()
        {
            try
            {
                Directory.Delete(Path, recursive: true);
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
        }
    }
}
