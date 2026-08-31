using System.Text;

namespace MBPhotos.Receiver.Storage;

internal static class AtomicFile
{
    public static Task WriteTextAsync(string path, string contents, CancellationToken cancellationToken = default) =>
        WriteAsync(path, async (stream, token) =>
        {
            var bytes = new UTF8Encoding(false).GetBytes(contents);
            await stream.WriteAsync(bytes, token);
        }, cancellationToken);

    public static async Task WriteAsync(
        string path,
        Func<Stream, CancellationToken, Task> write,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(write);
        var directory = Path.GetDirectoryName(path)
            ?? throw new InvalidOperationException("The output path has no parent directory.");
        Directory.CreateDirectory(directory);
        var temporaryPath = path + ".tmp-" + Guid.NewGuid().ToString("N");
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
                await write(stream, cancellationToken);
                await stream.FlushAsync(cancellationToken);
                stream.Flush(true);
            }

            File.Move(temporaryPath, path, true);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }
}
