using System.Windows.Media.Imaging;
using MBPhotos.Receiver.Hosting;
using MBPhotos.Receiver.Models;
using MBPhotos.Receiver.Transfer;

namespace MBPhotos.Receiver.Wpf;

internal enum ReceiverPresentationState
{
    Setup,
    Starting,
    Ready,
    Connected,
    Transferring,
    Finalizing,
    Paused,
    Error,
    Library,
}

internal sealed record LastTransferPresentation(
    string State,
    CompletionCounts? Counts,
    string? ThumbnailRelativePath);

internal sealed record ReceiverOrchestrationSnapshot(
    ReceiverPresentationState State,
    long Generation,
    string? LibraryRoot,
    BitmapImage? PairingQrBitmap,
    string? PairingPayload,
    ReceiverActivity? Activity,
    LastTransferPresentation? LastTransfer,
    Exception? Error,
    ReceiverServer? Receiver,
    bool IsManualPause = false,
    long Revision = 0)
{
    public static ReceiverOrchestrationSnapshot Initial { get; } = new(
        ReceiverPresentationState.Starting,
        0,
        null,
        null,
        null,
        null,
        null,
        null,
        null);
}
