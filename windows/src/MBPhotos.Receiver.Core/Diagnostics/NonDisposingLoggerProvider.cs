using Microsoft.Extensions.Logging;

namespace MBPhotos.Receiver.Diagnostics;

/// <summary>
/// Lets a short-lived ASP.NET host use diagnostics owned by the desktop process
/// without disposing them when that host stops.
/// </summary>
internal sealed class NonDisposingLoggerProvider : ILoggerProvider
{
    private readonly ILoggerProvider provider;

    public NonDisposingLoggerProvider(ILoggerProvider provider)
    {
        this.provider = provider ?? throw new ArgumentNullException(nameof(provider));
    }

    public ILogger CreateLogger(string categoryName) => provider.CreateLogger(categoryName);

    public void Dispose()
    {
    }
}
