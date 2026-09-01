using System.IO;
using System.Windows.Media.Imaging;
using MBPhotos.Receiver.Models;
using MBPhotos.Receiver.Storage;

namespace MBPhotos.Receiver.Wpf;

internal sealed class TransferPreviewLoader
{
    private readonly WindowsPathPolicy pathPolicy = new();

    public Task<BitmapSource?> TryLoadAsync(
        string libraryRoot,
        string relativePath,
        CancellationToken cancellationToken = default) => Task.Run(() =>
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!IsJpeg(relativePath))
            {
                return null;
            }

            string fullPath;
            try
            {
                fullPath = pathPolicy.ResolveUnderRoot(libraryRoot, relativePath);
                pathPolicy.EnsureNoReparsePoints(libraryRoot, fullPath);
            }
            catch (Exception exception) when (exception is
                ArgumentException or
                IOException or
                UnauthorizedAccessException or
                ReceiverApiException)
            {
                return null;
            }

            if (!File.Exists(fullPath))
            {
                return null;
            }

            try
            {
                using var stream = new FileStream(
                    fullPath,
                    FileMode.Open,
                    FileAccess.Read,
                    FileShare.ReadWrite | FileShare.Delete,
                    bufferSize: 64 * 1024,
                    FileOptions.SequentialScan);
                var bitmap = new BitmapImage();
                bitmap.BeginInit();
                bitmap.CacheOption = BitmapCacheOption.OnLoad;
                bitmap.CreateOptions = BitmapCreateOptions.IgnoreColorProfile;
                bitmap.DecodePixelWidth = 960;
                bitmap.StreamSource = stream;
                bitmap.EndInit();
                bitmap.Freeze();
                return (BitmapSource?)bitmap;
            }
            catch (Exception exception) when (exception is
                IOException or
                UnauthorizedAccessException or
                NotSupportedException or
                InvalidOperationException or
                FormatException)
            {
                return null;
            }
        }, cancellationToken);

    private static bool IsJpeg(string path)
    {
        var extension = Path.GetExtension(path);
        return extension.Equals(".jpg", StringComparison.OrdinalIgnoreCase) ||
               extension.Equals(".jpeg", StringComparison.OrdinalIgnoreCase);
    }
}
