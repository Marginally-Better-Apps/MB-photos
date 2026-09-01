using System.ComponentModel;
using System.IO;
using System.Runtime.CompilerServices;
using System.Windows.Media;
using MBPhotos.Receiver.Models;
using MBPhotos.Receiver.Transfer;

namespace MBPhotos.Receiver.Wpf;

internal enum ReceiverShellPage
{
    Receiver,
    Library,
    Settings,
}

/// <summary>
/// UI-only projection of receiver orchestration state. This keeps wording,
/// navigation availability, and transfer progress independent from the WPF
/// controls that render it.
/// </summary>
internal sealed class ReceiverWindowPresentationModel : INotifyPropertyChanged
{
    private ReceiverShellPage page;
    private ReceiverPresentationState state = ReceiverPresentationState.Setup;
    private long generation;
    private string? libraryRoot;
    private ImageSource? pairingQrImage;
    private string? pairingLink;
    private ImageSource? transferPreviewImage;
    private ImageSource? completionPreviewImage;
    private string heading = "Choose where photos are saved";
    private string message = "Pick a folder for your MB Photos library. You only need to do this once.";
    private string statusText = "Set up";
    private string progressText = string.Empty;
    private double progressMaximum = 1;
    private double progressValue;
    private bool isProgressIndeterminate;
    private bool hasCompletionBanner;
    private bool completionHasIssues;
    private string completionHeading = string.Empty;
    private string completionMessage = string.Empty;
    private string errorDetails = string.Empty;
    private string? requestedPreviewPath;
    private long requestedPreviewGeneration;

    public event PropertyChangedEventHandler? PropertyChanged;

    public ReceiverShellPage Page
    {
        get => page;
        private set
        {
            if (Set(ref page, value))
            {
                Raise(nameof(IsReceiverPage));
                Raise(nameof(IsLibraryPage));
                Raise(nameof(IsSettingsPage));
            }
        }
    }

    public ReceiverPresentationState State
    {
        get => state;
        private set
        {
            if (Set(ref state, value))
            {
                Raise(nameof(CanOpenLibrary));
                Raise(nameof(CanChangeLibrary));
                Raise(nameof(CanStop));
                Raise(nameof(CanRetry));
            }
        }
    }

    public long Generation
    {
        get => generation;
        private set => Set(ref generation, value);
    }

    public string? LibraryRoot
    {
        get => libraryRoot;
        private set
        {
            if (Set(ref libraryRoot, value))
            {
                Raise(nameof(HasLibrary));
                Raise(nameof(LibraryDisplayName));
                Raise(nameof(LibraryLocationText));
                Raise(nameof(CanOpenLibrary));
            }
        }
    }

    public string LibraryDisplayName => string.IsNullOrWhiteSpace(LibraryRoot)
        ? "MB Photos library"
        : new DirectoryInfo(LibraryRoot).Name is { Length: > 0 } name
            ? name
            : LibraryRoot;

    public string LibraryLocationText => string.IsNullOrWhiteSpace(LibraryRoot)
        ? "No library selected"
        : LibraryRoot;

    public bool HasLibrary => !string.IsNullOrWhiteSpace(LibraryRoot);

    public ImageSource? PairingQrImage
    {
        get => pairingQrImage;
        private set => Set(ref pairingQrImage, value);
    }

    public string? PairingLink
    {
        get => pairingLink;
        private set
        {
            if (Set(ref pairingLink, value))
            {
                Raise(nameof(CanCopyPairingLink));
            }
        }
    }

    public bool CanCopyPairingLink => !string.IsNullOrWhiteSpace(PairingLink);

    public ImageSource? TransferPreviewImage
    {
        get => transferPreviewImage;
        private set
        {
            if (Set(ref transferPreviewImage, value))
            {
                Raise(nameof(HasTransferPreview));
            }
        }
    }

    public bool HasTransferPreview => TransferPreviewImage is not null;

    public ImageSource? CompletionPreviewImage
    {
        get => completionPreviewImage;
        private set => Set(ref completionPreviewImage, value);
    }

    public string Heading
    {
        get => heading;
        private set => Set(ref heading, value);
    }

    public string Message
    {
        get => message;
        private set => Set(ref message, value);
    }

    public string StatusText
    {
        get => statusText;
        private set => Set(ref statusText, value);
    }

    public string ProgressText
    {
        get => progressText;
        private set => Set(ref progressText, value);
    }

    public double ProgressMaximum
    {
        get => progressMaximum;
        private set => Set(ref progressMaximum, value);
    }

    public double ProgressValue
    {
        get => progressValue;
        private set => Set(ref progressValue, value);
    }

    public bool IsProgressIndeterminate
    {
        get => isProgressIndeterminate;
        private set => Set(ref isProgressIndeterminate, value);
    }

    public bool HasCompletionBanner
    {
        get => hasCompletionBanner;
        private set => Set(ref hasCompletionBanner, value);
    }

    public bool CompletionHasIssues
    {
        get => completionHasIssues;
        private set => Set(ref completionHasIssues, value);
    }

    public string CompletionHeading
    {
        get => completionHeading;
        private set => Set(ref completionHeading, value);
    }

    public string CompletionMessage
    {
        get => completionMessage;
        private set => Set(ref completionMessage, value);
    }

    public string ErrorDetails
    {
        get => errorDetails;
        private set => Set(ref errorDetails, value);
    }

    public bool IsReceiverPage => Page == ReceiverShellPage.Receiver;

    public bool IsLibraryPage => Page == ReceiverShellPage.Library;

    public bool IsSettingsPage => Page == ReceiverShellPage.Settings;

    public bool CanOpenLibrary => HasLibrary && State is not (
        ReceiverPresentationState.Starting or
        ReceiverPresentationState.Transferring or
        ReceiverPresentationState.Finalizing);

    public bool CanChangeLibrary => State is not (
        ReceiverPresentationState.Starting or
        ReceiverPresentationState.Transferring or
        ReceiverPresentationState.Finalizing or
        ReceiverPresentationState.Library);

    public bool CanStop => State is
        ReceiverPresentationState.Starting or
        ReceiverPresentationState.Ready or
        ReceiverPresentationState.Connected or
        ReceiverPresentationState.Transferring or
        ReceiverPresentationState.Finalizing;

    public bool CanRetry => State is ReceiverPresentationState.Error or ReceiverPresentationState.Paused;

    public void Apply(ReceiverOrchestrationSnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);

        var previousRoot = LibraryRoot;
        var previousGeneration = Generation;
        Generation = snapshot.Generation;
        LibraryRoot = snapshot.LibraryRoot;
        PairingQrImage = snapshot.PairingQrBitmap;
        PairingLink = snapshot.PairingPayload;
        State = snapshot.State;

        var rootChanged = !string.Equals(previousRoot, LibraryRoot, StringComparison.OrdinalIgnoreCase);
        var generationChanged = previousGeneration != 0 &&
            snapshot.Generation != 0 &&
            previousGeneration != snapshot.Generation;
        if (rootChanged)
        {
            ClearPreview();
        }
        else if (generationChanged)
        {
            // A generation change invalidates pending decoder work, but an
            // already accepted frozen bitmap is still a verified thumbnail from
            // this same library. Keep it visible until a newer safe preview wins.
            requestedPreviewGeneration = 0;
            requestedPreviewPath = null;
        }

        if (snapshot.State == ReceiverPresentationState.Library)
        {
            Page = ReceiverShellPage.Library;
        }
        else if (Page == ReceiverShellPage.Library)
        {
            Page = ReceiverShellPage.Receiver;
        }

        ApplyStateCopy(snapshot);
        ApplyActivity(snapshot.Activity);
        ApplyLastTransfer(snapshot.LastTransfer);
    }

    public void Navigate(ReceiverShellPage destination)
    {
        if (destination == ReceiverShellPage.Library && !CanOpenLibrary)
        {
            return;
        }

        Page = destination;
    }

    public void BeginPreviewRequest(long requestGeneration, string relativePath)
    {
        requestedPreviewGeneration = requestGeneration;
        requestedPreviewPath = relativePath;
    }

    public bool TrySetPreview(long requestGeneration, string relativePath, ImageSource image, bool completion)
    {
        ArgumentNullException.ThrowIfNull(image);
        if (requestGeneration != Generation ||
            requestGeneration != requestedPreviewGeneration ||
            !string.Equals(relativePath, requestedPreviewPath, StringComparison.Ordinal))
        {
            return false;
        }

        TransferPreviewImage = image;
        if (completion)
        {
            CompletionPreviewImage = image;
        }
        return true;
    }

    public void PromoteTransferPreviewToCompletion()
    {
        if (TransferPreviewImage is not null)
        {
            CompletionPreviewImage = TransferPreviewImage;
        }
    }

    private void ApplyStateCopy(ReceiverOrchestrationSnapshot snapshot)
    {
        switch (snapshot.State)
        {
            case ReceiverPresentationState.Setup:
                Heading = "Choose where photos are saved";
                Message = "Pick a folder for your MB Photos library. You only need to do this once.";
                StatusText = "Set up";
                break;
            case ReceiverPresentationState.Starting:
                Heading = "Getting ready";
                Message = "Starting a secure connection for your iPhone…";
                StatusText = "Starting";
                break;
            case ReceiverPresentationState.Ready:
                Heading = "Scan with MB Photos on your iPhone";
                Message = $"Photos will be saved to {LibraryDisplayName}.";
                StatusText = "Ready";
                break;
            case ReceiverPresentationState.Connected:
                Heading = "iPhone connected";
                Message = "Start a transfer from your iPhone when you’re ready.";
                StatusText = "Connected";
                break;
            case ReceiverPresentationState.Transferring:
                Heading = "Receiving photos";
                Message = "Keep MB Photos open on your iPhone until the transfer finishes.";
                StatusText = "Receiving";
                break;
            case ReceiverPresentationState.Finalizing:
                Heading = "Finishing up";
                Message = "Verifying your photos and updating the library…";
                StatusText = "Finalizing";
                break;
            case ReceiverPresentationState.Paused:
                Heading = "Receiving is paused";
                Message = "Start receiving when you want to connect your iPhone again.";
                StatusText = "Paused";
                break;
            case ReceiverPresentationState.Error:
                Heading = HasLibrary ? "Receiver needs attention" : "Library unavailable";
                Message = FriendlyError(snapshot.Error);
                ErrorDetails = snapshot.Error?.ToString() ?? "No additional details are available.";
                StatusText = "Needs attention";
                break;
            case ReceiverPresentationState.Library:
                StatusText = "Library";
                break;
            default:
                throw new ArgumentOutOfRangeException(nameof(snapshot), snapshot.State, "Unknown presentation state.");
        }
    }

    private void ApplyActivity(ReceiverActivity? activity)
    {
        if (activity is null)
        {
            if (State is ReceiverPresentationState.Transferring or ReceiverPresentationState.Finalizing)
            {
                IsProgressIndeterminate = true;
                ProgressMaximum = 1;
                ProgressValue = 0;
                ProgressText = State == ReceiverPresentationState.Finalizing
                    ? "Saving your library…"
                    : "Waiting for the first photo…";
            }
            return;
        }

        var total = Math.Max(0, activity.TotalFiles);
        var completed = Math.Clamp(activity.CompletedFiles, 0, Math.Max(total, activity.CompletedFiles));
        ProgressMaximum = Math.Max(1, total);
        ProgressValue = Math.Min(completed, ProgressMaximum);
        IsProgressIndeterminate = activity.State is "planning" or "finalizing" || total == 0;
        ProgressText = activity.State switch
        {
            "planning" => "Checking what needs to be saved…",
            "finalizing" => completed > 0 && total > 0
                ? $"Finishing {completed:N0} of {total:N0} files…"
                : "Saving your library…",
            _ when total > 0 => $"{completed:N0} of {total:N0} files",
            _ => "Receiving photos…",
        };

        if (!string.IsNullOrWhiteSpace(activity.ErrorMessage))
        {
            Message = "One item needs attention. The transfer will continue when possible.";
            ErrorDetails = activity.ErrorMessage;
        }
    }

    private void ApplyLastTransfer(LastTransferPresentation? lastTransfer)
    {
        if (lastTransfer is null)
        {
            HasCompletionBanner = false;
            CompletionHasIssues = false;
            CompletionHeading = string.Empty;
            CompletionMessage = string.Empty;
            return;
        }

        HasCompletionBanner = true;
        CompletionHasIssues = lastTransfer.State is not "completed";
        PromoteTransferPreviewToCompletion();

        var counts = lastTransfer.Counts;
        var savedItems = counts?.AssetsPromoted ?? 0;
        var failedFiles = counts?.FilesFailed ?? 0;
        switch (lastTransfer.State)
        {
            case "completed":
                CompletionHeading = "Transfer complete";
                CompletionMessage = savedItems > 0
                    ? $"{savedItems:N0} {ItemWord(savedItems)} saved to {LibraryDisplayName}."
                    : "Your photos are safely up to date.";
                break;
            case "completedWithFailures":
                CompletionHeading = "Transfer finished with issues";
                CompletionMessage = savedItems > 0
                    ? $"{savedItems:N0} {ItemWord(savedItems)} saved. {Math.Max(1, failedFiles):N0} need attention."
                    : "Some items could not be saved. You can try them again from your iPhone.";
                break;
            case "abandoned":
                CompletionHeading = "Transfer stopped";
                CompletionMessage = savedItems > 0
                    ? $"{savedItems:N0} {ItemWord(savedItems)} were saved before the transfer stopped."
                    : "No new items were saved.";
                break;
            default:
                CompletionHeading = "Transfer finished";
                CompletionMessage = savedItems > 0
                    ? $"{savedItems:N0} {ItemWord(savedItems)} saved."
                    : "Your library is ready.";
                break;
        }
    }

    private void ClearPreview()
    {
        requestedPreviewGeneration = 0;
        requestedPreviewPath = null;
        TransferPreviewImage = null;
        CompletionPreviewImage = null;
    }

    private static string FriendlyError(Exception? error)
    {
        if (error is null)
        {
            return "Try again, or choose a different library folder.";
        }

        return error switch
        {
            DirectoryNotFoundException => "The saved library folder is not available. Reconnect the drive or choose another folder.",
            UnauthorizedAccessException => "MB Photos cannot access this folder. Choose a folder you can write to.",
            IOException => "The library could not be opened. Check that the drive is connected, then try again.",
            _ => "The receiver could not start. Try again, or choose a different library folder.",
        };
    }

    private static string ItemWord(int count) => count == 1 ? "item" : "items";

    private bool Set<T>(ref T field, T value, [CallerMemberName] string? propertyName = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value))
        {
            return false;
        }

        field = value;
        Raise(propertyName);
        return true;
    }

    private void Raise([CallerMemberName] string? propertyName = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
}
