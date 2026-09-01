using System.IO;
using System.Windows;
using System.Windows.Media.Imaging;

namespace MBPhotos.Receiver.Wpf;

/// <summary>
/// Loads a file-backed thumbnail only while its recycled list item is visible.
/// Decoding happens off the dispatcher and uses OnLoad so the source file is
/// never held open by WPF.
/// </summary>
public sealed class LazyThumbnailImage : System.Windows.Controls.Image
{
    public static readonly DependencyProperty FilePathProperty = DependencyProperty.Register(
        nameof(FilePath),
        typeof(string),
        typeof(LazyThumbnailImage),
        new FrameworkPropertyMetadata(null, OnThumbnailPropertyChanged));

    public static readonly DependencyProperty DecodePixelWidthProperty = DependencyProperty.Register(
        nameof(DecodePixelWidth),
        typeof(int),
        typeof(LazyThumbnailImage),
        new FrameworkPropertyMetadata(240, OnThumbnailPropertyChanged, CoerceDecodePixelWidth));

    private CancellationTokenSource? loadCancellation;
    private long requestRevision;

    public LazyThumbnailImage()
    {
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    public string? FilePath
    {
        get => (string?)GetValue(FilePathProperty);
        set => SetValue(FilePathProperty, value);
    }

    public int DecodePixelWidth
    {
        get => (int)GetValue(DecodePixelWidthProperty);
        set => SetValue(DecodePixelWidthProperty, value);
    }

    private static object CoerceDecodePixelWidth(DependencyObject element, object value) =>
        Math.Clamp((int)value, 32, 2048);

    private static void OnThumbnailPropertyChanged(
        DependencyObject element,
        DependencyPropertyChangedEventArgs args) =>
        ((LazyThumbnailImage)element).BeginLoad();

    private void OnLoaded(object sender, RoutedEventArgs args) => BeginLoad();

    private void OnUnloaded(object sender, RoutedEventArgs args)
    {
        CancelLoad();
        Source = null;
    }

    private void BeginLoad()
    {
        CancelLoad();
        Source = null;

        var path = FilePath;
        if (!IsLoaded || string.IsNullOrWhiteSpace(path))
        {
            return;
        }

        var revision = Interlocked.Increment(ref requestRevision);
        var cancellation = new CancellationTokenSource();
        loadCancellation = cancellation;
        _ = LoadAndApplyAsync(path, DecodePixelWidth, revision, cancellation.Token);
    }

    private async Task LoadAndApplyAsync(
        string path,
        int decodePixelWidth,
        long revision,
        CancellationToken cancellationToken)
    {
        try
        {
            var bitmap = await ThumbnailBitmapCache.LoadAsync(
                path,
                decodePixelWidth,
                cancellationToken);
            if (!cancellationToken.IsCancellationRequested &&
                IsLoaded &&
                revision == Volatile.Read(ref requestRevision) &&
                string.Equals(path, FilePath, StringComparison.OrdinalIgnoreCase))
            {
                Source = bitmap;
            }
        }
        catch (OperationCanceledException)
        {
        }
    }

    private void CancelLoad()
    {
        Interlocked.Increment(ref requestRevision);
        var cancellation = loadCancellation;
        loadCancellation = null;
        if (cancellation is null)
        {
            return;
        }

        cancellation.Cancel();
        cancellation.Dispose();
    }
}

internal static class ThumbnailBitmapCache
{
    private const int Capacity = 128;
    private const int MaxConcurrentDecodes = 2;

    private static readonly object Sync = new();
    private static readonly Dictionary<ThumbnailCacheKey, LinkedListNode<ThumbnailCacheEntry>> Entries = [];
    private static readonly LinkedList<ThumbnailCacheEntry> Recency = [];
    private static readonly SemaphoreSlim DecodeSlots = new(MaxConcurrentDecodes, MaxConcurrentDecodes);

    public static Task<BitmapSource?> LoadAsync(
        string path,
        int decodePixelWidth,
        CancellationToken cancellationToken) =>
        Task.Run(() => Load(path, decodePixelWidth, cancellationToken), cancellationToken);

    private static BitmapSource? Load(
        string path,
        int decodePixelWidth,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        FileInfo file;
        ThumbnailCacheKey key;
        try
        {
            file = new FileInfo(Path.GetFullPath(path));
            if (!file.Exists)
            {
                return null;
            }

            key = new ThumbnailCacheKey(
                file.FullName.ToUpperInvariant(),
                file.LastWriteTimeUtc.Ticks,
                file.Length,
                decodePixelWidth);
        }
        catch (Exception exception) when (IsExpectedFileException(exception))
        {
            return null;
        }

        lock (Sync)
        {
            if (Entries.TryGetValue(key, out var cached))
            {
                Recency.Remove(cached);
                Recency.AddFirst(cached);
                return cached.Value.Bitmap;
            }
        }

        DecodeSlots.Wait(cancellationToken);
        try
        {
            // Another visible item may have populated the same entry while this
            // request was waiting for a decode slot.
            lock (Sync)
            {
                if (Entries.TryGetValue(key, out var cached))
                {
                    Recency.Remove(cached);
                    Recency.AddFirst(cached);
                    return cached.Value.Bitmap;
                }
            }

            cancellationToken.ThrowIfCancellationRequested();
            var bitmap = Decode(file.FullName, decodePixelWidth);
            if (bitmap is null)
            {
                return null;
            }

            lock (Sync)
            {
                if (Entries.TryGetValue(key, out var cached))
                {
                    Recency.Remove(cached);
                    Recency.AddFirst(cached);
                    return cached.Value.Bitmap;
                }

                var entry = new ThumbnailCacheEntry(key, bitmap);
                var node = Recency.AddFirst(entry);
                Entries[key] = node;
                while (Entries.Count > Capacity && Recency.Last is { } oldest)
                {
                    Recency.RemoveLast();
                    Entries.Remove(oldest.Value.Key);
                }
            }

            return bitmap;
        }
        finally
        {
            DecodeSlots.Release();
        }
    }

    private static BitmapSource? Decode(string path, int decodePixelWidth)
    {
        try
        {
            using var stream = new FileStream(
                path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete,
                bufferSize: 64 * 1024,
                FileOptions.SequentialScan);
            var bitmap = new BitmapImage();
            bitmap.BeginInit();
            bitmap.CacheOption = BitmapCacheOption.OnLoad;
            bitmap.DecodePixelWidth = decodePixelWidth;
            bitmap.StreamSource = stream;
            bitmap.EndInit();
            bitmap.Freeze();
            return bitmap;
        }
        catch (Exception exception) when (IsExpectedFileException(exception))
        {
            return null;
        }
    }

    private static bool IsExpectedFileException(Exception exception) => exception is
        IOException or
        UnauthorizedAccessException or
        NotSupportedException or
        InvalidOperationException or
        FormatException or
        ArgumentException;

    private sealed record ThumbnailCacheEntry(ThumbnailCacheKey Key, BitmapSource Bitmap);

    private readonly record struct ThumbnailCacheKey(
        string Path,
        long LastWriteTicks,
        long Length,
        int DecodePixelWidth);
}
