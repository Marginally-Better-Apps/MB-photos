using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using MBPhotos.Receiver.Library;
using MBPhotos.Receiver.Models;
using MBPhotos.Receiver.Transfer;
using Microsoft.Win32;
using Button = System.Windows.Controls.Button;
using RadioButton = System.Windows.Controls.RadioButton;

namespace MBPhotos.Receiver.Wpf;

public partial class MainWindow : Window
{
    private readonly App app;
    private readonly ReceiverOrchestrator orchestrator;
    private readonly ReceiverWindowPresentationModel presentation = new();
    private readonly TransferPreviewLoader transferPreviewLoader = new();
    private readonly PortableLibraryService portableLibraryService = new();
    private readonly VariantExportService variantExportService = new();

    private PortableLibrarySnapshot? openLibrary;
    private IReadOnlyList<LibraryAssetListItem> libraryItems = Array.Empty<LibraryAssetListItem>();
    private CancellationTokenSource? previewLoadCancellation;
    private CancellationTokenSource? libraryPreviewLoadCancellation;
    private PortableLibraryFile? selectedLibraryPreviewFile;
    private string selectedLibraryPreviewLabel = string.Empty;
    private string? previewRequestIdentity;
    private string? openedLibraryPath;
    private string? alternateLibraryPath;
    private long libraryLoadRevision;
    private long libraryPreviewRevision;
    private long appliedSnapshotRevision = -1;
    private bool isLibraryExportInProgress;
    private bool isClipboardCopyInProgress;
    private bool isConfiguringLibraryVersions;
    private bool isLibraryVideoPreviewActive;
    private LibraryTimeFilter libraryTimeFilter = LibraryTimeFilter.All;

    public MainWindow()
    {
        InitializeComponent();
        var workArea = SystemParameters.WorkArea;
        var availableWidth = Math.Max(320, workArea.Width - 24);
        var availableHeight = Math.Max(320, workArea.Height - 24);
        MinWidth = Math.Min(MinWidth, availableWidth);
        MinHeight = Math.Min(MinHeight, availableHeight);
        Width = Math.Max(MinWidth, Math.Min(Width, availableWidth));
        Height = Math.Max(MinHeight, Math.Min(Height, availableHeight));
        app = (App)System.Windows.Application.Current;
        orchestrator = app.ReceiverOrchestrator;
        DataContext = presentation;
        AppVersionText.Text = ProductVersionText();

        Closing += Window_Closing;
        IsVisibleChanged += Window_IsVisibleChanged;
        orchestrator.StateChanged += Orchestrator_StateChanged;
        ApplySnapshot(orchestrator.Snapshot);
    }

    private async void ChooseLibraryRoot_Click(object sender, RoutedEventArgs e)
    {
        if (!presentation.CanChangeLibrary)
        {
            return;
        }

        var dialog = new OpenFolderDialog
        {
            Title = "Choose where MB Photos should save your photos",
            Multiselect = false,
        };
        if (dialog.ShowDialog(this) != true)
        {
            return;
        }

        var allowInitialize = false;
        try
        {
            if (!IsInitializedLibrary(dialog.FolderName) && IsEmptyFolder(dialog.FolderName))
            {
                var confirmation = System.Windows.MessageBox.Show(
                    this,
                    "Set up this empty folder as your MB Photos library?\n\nMB Photos will add the folders it needs here.",
                    "Set up photo library",
                    MessageBoxButton.OKCancel,
                    MessageBoxImage.Question,
                    MessageBoxResult.OK);
                if (confirmation != MessageBoxResult.OK)
                {
                    return;
                }
                allowInitialize = true;
            }
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            System.Windows.MessageBox.Show(
                this,
                "That folder could not be checked. Make sure the drive is connected and you can open it, then try again.",
                "Folder unavailable",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
            return;
        }

        presentation.Navigate(ReceiverShellPage.Receiver);
        await RunOrchestrationActionAsync(
            () => orchestrator.ChangeLibraryAsync(dialog.FolderName, allowInitialize),
            "The library could not be opened.");
    }

    private async void StartReceiving_Click(object sender, RoutedEventArgs e) =>
        await RunOrchestrationActionAsync(
            () => orchestrator.StartOrResumeAsync(),
            "Receiving could not start.");

    private async void StopReceiving_Click(object sender, RoutedEventArgs e) =>
        await RunOrchestrationActionAsync(
            () => orchestrator.StopAsync(manualPause: true),
            "Receiving could not be paused.");

    private async void Retry_Click(object sender, RoutedEventArgs e) =>
        await RunOrchestrationActionAsync(
            () => orchestrator.RetryAsync(),
            "The receiver could not restart.");

    private async void NavigateReceiver_Click(object sender, RoutedEventArgs e)
    {
        if (orchestrator.Snapshot.State == ReceiverPresentationState.Library)
        {
            await ExitLibraryAsync(ReceiverShellPage.Receiver);
            return;
        }

        presentation.Navigate(ReceiverShellPage.Receiver);
    }

    private async void NavigateLibrary_Click(object sender, RoutedEventArgs e)
    {
        if (!presentation.CanOpenLibrary)
        {
            return;
        }

        await RunOrchestrationActionAsync(
            () => orchestrator.EnterLibraryAsync(),
            "The library could not be opened.");
    }

    private async void NavigateSettings_Click(object sender, RoutedEventArgs e)
    {
        if (orchestrator.Snapshot.State == ReceiverPresentationState.Library)
        {
            await ExitLibraryAsync(ReceiverShellPage.Settings);
            return;
        }

        presentation.Navigate(ReceiverShellPage.Settings);
    }

    private void OverflowButton_Click(object sender, RoutedEventArgs e)
    {
        CopyPairingLinkMenuItem.IsEnabled = presentation.CanCopyPairingLink;
        OpenAnotherLibraryMenuItem.IsEnabled = presentation.CanOpenLibrary && !isLibraryExportInProgress;
        OverflowMenu.PlacementTarget = OverflowButton;
        OverflowMenu.IsOpen = true;
    }

    private void CopyPairingLink_Click(object sender, RoutedEventArgs e)
    {
        if (presentation.PairingLink is not { Length: > 0 } pairingLink)
        {
            return;
        }

        try
        {
            System.Windows.Clipboard.SetText(pairingLink);
        }
        catch (Exception exception) when (exception is System.Runtime.InteropServices.ExternalException)
        {
            System.Windows.MessageBox.Show(
                this,
                "The pairing link could not be copied. Try again in a moment.",
                "Clipboard unavailable",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
        }
    }

    private async void OpenAnotherLibrary_Click(object sender, RoutedEventArgs e)
    {
        if (!presentation.CanOpenLibrary || isLibraryExportInProgress)
        {
            return;
        }

        var dialog = new OpenFolderDialog
        {
            Title = "Open another MB Photos library",
            Multiselect = false,
        };
        if (dialog.ShowDialog(this) != true)
        {
            return;
        }

        var selectedRoot = dialog.FolderName;
        alternateLibraryPath = selectedRoot;

        if (orchestrator.Snapshot.State != ReceiverPresentationState.Library)
        {
            await RunOrchestrationActionAsync(
                () => orchestrator.EnterLibraryAsync(),
                "The library could not be opened.");
            if (orchestrator.Snapshot.State != ReceiverPresentationState.Library)
            {
                alternateLibraryPath = null;
                return;
            }
        }

        await OpenLibraryAsync(selectedRoot, force: true);
    }

    private async void OpenPhotosFolder_Click(object sender, RoutedEventArgs e)
    {
        var root = openLibrary?.RootPath ?? openedLibraryPath ?? presentation.LibraryRoot;
        if (root is { Length: > 0 })
        {
            await OpenFolderInExplorerAsync(Path.Combine(root, "Master"), "The photos folder could not be opened.");
        }
    }

    private async Task ExitLibraryAsync(ReceiverShellPage destination)
    {
        if (isLibraryExportInProgress)
        {
            return;
        }

        ResetLibraryView();
        await RunOrchestrationActionAsync(
            () => orchestrator.ExitLibraryAsync(),
            "The receiver could not restart.");
        if (orchestrator.Snapshot.State != ReceiverPresentationState.Library)
        {
            presentation.Navigate(destination);
        }
    }

    private async Task RunOrchestrationActionAsync(Func<Task> action, string fallbackMessage)
    {
        try
        {
            await action();
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception)
        {
            System.Windows.MessageBox.Show(
                this,
                fallbackMessage,
                "MB Photos",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
        }
    }

    private void Orchestrator_StateChanged(object? sender, ReceiverOrchestrationSnapshot snapshot)
    {
        if (Dispatcher.HasShutdownStarted)
        {
            return;
        }

        _ = Dispatcher.BeginInvoke(
            DispatcherPriority.Background,
            new Action(() => ApplySnapshot(snapshot)));
    }

    private void ApplySnapshot(ReceiverOrchestrationSnapshot snapshot)
    {
        if (snapshot.Revision < appliedSnapshotRevision)
        {
            return;
        }
        appliedSnapshotRevision = snapshot.Revision;

        presentation.Apply(snapshot);
        ExportDiagnosticsButton.IsEnabled = true;
        CopyPairingLinkMenuItem.IsEnabled = presentation.CanCopyPairingLink;
        OpenAnotherLibraryMenuItem.IsEnabled = presentation.CanOpenLibrary && !isLibraryExportInProgress;

        if (snapshot.State == ReceiverPresentationState.Library &&
            (alternateLibraryPath ?? snapshot.LibraryRoot) is { Length: > 0 } root &&
            !string.Equals(openedLibraryPath, root, StringComparison.OrdinalIgnoreCase))
        {
            _ = OpenLibraryAsync(root);
        }

        var thumbnailPath = snapshot.Activity?.LatestThumbnailRelativePath ??
            snapshot.LastTransfer?.ThumbnailRelativePath;
        if (snapshot.LibraryRoot is { Length: > 0 } libraryRoot &&
            thumbnailPath is { Length: > 0 })
        {
            var completion = snapshot.LastTransfer?.ThumbnailRelativePath is { } completionPath &&
                string.Equals(completionPath, thumbnailPath, StringComparison.Ordinal);
            RequestTransferPreview(snapshot.Generation, libraryRoot, thumbnailPath, completion);
        }
    }

    private void RequestTransferPreview(
        long generation,
        string libraryRoot,
        string relativePath,
        bool completion)
    {
        var identity = $"{generation}\0{libraryRoot}\0{relativePath}";
        if (string.Equals(previewRequestIdentity, identity, StringComparison.Ordinal))
        {
            if (completion)
            {
                presentation.PromoteTransferPreviewToCompletion();
            }
            return;
        }

        previewRequestIdentity = identity;
        presentation.BeginPreviewRequest(generation, relativePath);
        previewLoadCancellation?.Cancel();
        previewLoadCancellation?.Dispose();
        previewLoadCancellation = new CancellationTokenSource();
        _ = LoadTransferPreviewAsync(
            generation,
            libraryRoot,
            relativePath,
            completion,
            previewLoadCancellation.Token);
    }

    private async Task LoadTransferPreviewAsync(
        long generation,
        string libraryRoot,
        string relativePath,
        bool completion,
        CancellationToken cancellationToken)
    {
        try
        {
            var image = await transferPreviewLoader.TryLoadAsync(
                libraryRoot,
                relativePath,
                cancellationToken);
            if (image is not null && !cancellationToken.IsCancellationRequested)
            {
                presentation.TrySetPreview(generation, relativePath, image, completion);
            }
        }
        catch (OperationCanceledException)
        {
        }
        catch
        {
            // A malformed or temporarily unavailable preview never interrupts a transfer.
            // The preceding verified image or the neutral placeholder remains visible.
        }
    }

    private async Task OpenLibraryAsync(string rootPath, bool force = false)
    {
        var isDifferentLibrary = !string.Equals(openedLibraryPath, rootPath, StringComparison.OrdinalIgnoreCase);
        if (!force && !isDifferentLibrary)
        {
            return;
        }

        var revision = Interlocked.Increment(ref libraryLoadRevision);
        if (isDifferentLibrary)
        {
            libraryTimeFilter = LibraryTimeFilter.All;
        }
        openedLibraryPath = rootPath;
        openLibrary = null;
        libraryItems = Array.Empty<LibraryAssetListItem>();
        LibrarySummaryText.Text = "Opening your photos…";
        LibraryAssetList.ItemsSource = null;
        ConfigureLibraryTimeFilters(DateTimeOffset.Now);
        ClearLibrarySelection("Choose a photo or video to see its available versions.");
        try
        {
            var (snapshot, items) = await Task.Run(async () =>
            {
                var loaded = await portableLibraryService.OpenAsync(rootPath).ConfigureAwait(false);
                return (
                    loaded,
                    SortLibraryItems(loaded.Assets.Select(CreateLibraryListItem)));
            });

            if (revision != Volatile.Read(ref libraryLoadRevision) ||
                presentation.Page != ReceiverShellPage.Library)
            {
                return;
            }

            openLibrary = snapshot;
            libraryItems = items;
            LibraryExportStatusText.Text = string.Empty;
            ConfigureLibraryTimeFilters(DateTimeOffset.Now);
            ApplyLibraryTimeFilter(DateTimeOffset.Now);
        }
        catch (FileNotFoundException)
        {
            if (IsCurrentLibraryLoad(revision))
            {
                LibrarySummaryText.Text = "No transferred photos yet";
                ClearLibrarySelection("Your photos will appear here after the first transfer.");
            }
        }
        catch (DirectoryNotFoundException)
        {
            if (IsCurrentLibraryLoad(revision))
            {
                LibrarySummaryText.Text = "This library is not available";
                ClearLibrarySelection("Reconnect its drive, then choose Refresh.");
            }
        }
        catch (Exception)
        {
            if (IsCurrentLibraryLoad(revision))
            {
                LibrarySummaryText.Text = "This library could not be opened";
                ClearLibrarySelection("Try Refresh, or open another MB Photos library.");
            }
        }
    }

    private bool IsCurrentLibraryLoad(long revision) =>
        revision == Volatile.Read(ref libraryLoadRevision) &&
        presentation.Page == ReceiverShellPage.Library;

    private async void ReloadLibrary_Click(object sender, RoutedEventArgs e)
    {
        if (!isLibraryExportInProgress && openedLibraryPath is { Length: > 0 } path)
        {
            await OpenLibraryAsync(path, force: true);
        }
    }

    private async void CloseLibrary_Click(object sender, RoutedEventArgs e)
    {
        if (!isLibraryExportInProgress)
        {
            await ExitLibraryAsync(ReceiverShellPage.Receiver);
        }
    }

    private void LibraryTimeFilter_Click(object sender, RoutedEventArgs e)
    {
        if (isLibraryExportInProgress ||
            sender is not RadioButton button ||
            button.Tag is not string tag ||
            !Enum.TryParse<LibraryTimeFilter>(tag, out var filter))
        {
            return;
        }

        libraryTimeFilter = filter;
        ApplyLibraryTimeFilter(DateTimeOffset.Now);
    }

    private void LibraryAssetList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (isLibraryExportInProgress)
        {
            return;
        }
        if (LibraryAssetList.SelectedItem is not LibraryAssetListItem item)
        {
            ClearLibrarySelection("Choose a photo or video to see its available versions.");
            return;
        }

        var asset = item.Asset;
        LibraryFilenameText.Text = item.Filename;
        LibraryDateText.Text = item.DateText;
        var flags = new List<string> { asset.Catalog.MediaType == "video" ? "Video" : "Photo" };
        if (asset.IsEdited)
        {
            flags.Add("Edited");
        }
        if (asset.IsLivePhoto)
        {
            flags.Add("Live Photo");
        }
        LibraryFlagsText.Text = string.Join(" • ", flags);

        var additionalOriginals = BuildAdditionalOriginalChoices(asset);
        isConfiguringLibraryVersions = true;
        IndividualOriginalsComboBox.ItemsSource = additionalOriginals;
        IndividualOriginalsComboBox.SelectedIndex = -1;
        AdditionalOriginalsPanel.Visibility = additionalOriginals.Count > 0
            ? Visibility.Visible
            : Visibility.Collapsed;
        isConfiguringLibraryVersions = false;
        ConfigureVariantButtons(asset);
        SelectPreferredLibraryPreview(asset, item.ThumbnailPath);
        LibraryExportStatusText.Text = string.Empty;
    }

    private void LibraryThumbnail_ContextMenuOpening(object sender, ContextMenuEventArgs e)
    {
        if (isLibraryExportInProgress ||
            isClipboardCopyInProgress ||
            sender is not FrameworkElement { DataContext: LibraryAssetListItem item } ||
            FindCopyableImageFile(item.Asset) is null)
        {
            e.Handled = true;
            return;
        }

        LibraryAssetList.SelectedItem = item;
    }

    private async void CopyFullQualityImage_Click(object sender, RoutedEventArgs e)
    {
        if (isLibraryExportInProgress ||
            LibraryAssetList.SelectedItem is not LibraryAssetListItem item ||
            FindCopyableImageFile(item.Asset) is not { } file)
        {
            return;
        }

        await CopyImageFileToClipboardAsync(file);
    }

    private async void CopyLibraryPreview_Click(object sender, RoutedEventArgs e)
    {
        if (!isLibraryExportInProgress &&
            selectedLibraryPreviewFile is { } file &&
            IsCopyableStillImage(file))
        {
            await CopyImageFileToClipboardAsync(file);
        }
    }

    private async Task CopyImageFileToClipboardAsync(PortableLibraryFile file)
    {
        if (isClipboardCopyInProgress ||
            !IsCopyableStillImage(file) ||
            file.AbsolutePath is not { } path ||
            !File.Exists(path))
        {
            return;
        }

        isClipboardCopyInProgress = true;
        CopyLibraryPreviewButton.IsEnabled = false;
        SetResourceBrush(LibraryExportStatusText, "TextSecondaryBrush");
        LibraryExportStatusText.Text = "Preparing a full-resolution image…";
        try
        {
            var image = await Task.Run(() => CreatePlatformClipboardImage(path));
            if (image is null)
            {
                SetResourceBrush(LibraryExportStatusText, "ErrorBrush");
                LibraryExportStatusText.Text = "This image could not be prepared for the clipboard. Use Save to keep the original file.";
                return;
            }

            var clipboardData = new System.Windows.DataObject();
            clipboardData.SetData(System.Windows.DataFormats.Bitmap, image.Bitmap);
            clipboardData.SetData("PNG", new MemoryStream(image.PngBytes, writable: false));
            System.Windows.Clipboard.SetDataObject(clipboardData, true);
            SetResourceBrush(LibraryExportStatusText, "SuccessBrush");
            LibraryExportStatusText.Text = "Full-resolution image copied in a widely supported format.";
        }
        catch (Exception exception) when (exception is System.Runtime.InteropServices.ExternalException)
        {
            System.Windows.MessageBox.Show(
                this,
                "The full-quality image could not be copied. Try again in a moment.",
                "Clipboard unavailable",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
        }
        finally
        {
            isClipboardCopyInProgress = false;
            CopyLibraryPreviewButton.IsEnabled = !isLibraryExportInProgress;
        }
    }

    internal static PlatformClipboardImage? CreatePlatformClipboardImage(string path)
    {
        try
        {
            using var input = new FileStream(
                path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete,
                128 * 1024,
                FileOptions.SequentialScan);
            var bitmap = new BitmapImage();
            bitmap.BeginInit();
            bitmap.CacheOption = BitmapCacheOption.OnLoad;
            bitmap.CreateOptions = BitmapCreateOptions.PreservePixelFormat;
            bitmap.StreamSource = input;
            bitmap.EndInit();
            bitmap.Freeze();

            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using var output = new MemoryStream();
            encoder.Save(output);
            return new PlatformClipboardImage(bitmap, output.ToArray());
        }
        catch (Exception exception) when (exception is
            IOException or
            UnauthorizedAccessException or
            NotSupportedException or
            InvalidOperationException or
            OutOfMemoryException or
            System.Runtime.InteropServices.ExternalException or
            FormatException or
            ArgumentException)
        {
            return null;
        }
    }

    private void PreviewVariant_Click(object sender, RoutedEventArgs e)
    {
        if (isLibraryExportInProgress ||
            LibraryAssetList.SelectedItem is not LibraryAssetListItem item ||
            sender is not RadioButton button ||
            button.Tag is not string tag ||
            !Enum.TryParse<VariantKind>(tag, out var variant))
        {
            return;
        }

        var file = FindExportableFile(item.Asset, variant);
        if (file is null)
        {
            button.IsEnabled = false;
            return;
        }

        isConfiguringLibraryVersions = true;
        IndividualOriginalsComboBox.SelectedIndex = -1;
        isConfiguringLibraryVersions = false;
        SelectLibraryPreview(file, VariantLabel(variant), variant, item.ThumbnailPath);
    }

    private void IndividualOriginalsComboBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (isConfiguringLibraryVersions ||
            isLibraryExportInProgress ||
            LibraryAssetList.SelectedItem is not LibraryAssetListItem item ||
            IndividualOriginalsComboBox.SelectedItem is not LibraryVariantChoice choice)
        {
            return;
        }

        SetCheckedVariant(null);
        SelectLibraryPreview(choice.File, choice.Label, null, item.ThumbnailPath);
    }

    private async void SaveLibraryPreview_Click(object sender, RoutedEventArgs e)
    {
        if (!isLibraryExportInProgress && selectedLibraryPreviewFile is { } file)
        {
            await ExportFileAsync(file, selectedLibraryPreviewLabel);
        }
    }

    private async Task ExportFileAsync(PortableLibraryFile file, string label)
    {
        if (openLibrary is not { } library)
        {
            return;
        }

        var suggestedFilename = SuggestedLibraryExportFilename(file);
        var extension = Path.GetExtension(suggestedFilename);
        var dialog = new Microsoft.Win32.SaveFileDialog
        {
            Title = $"Save {label} as",
            FileName = suggestedFilename,
            Filter = string.IsNullOrEmpty(extension)
                ? "All files (*.*)|*.*"
                : $"{extension.TrimStart('.').ToUpperInvariant()} files (*{extension})|*{extension}|All files (*.*)|*.*",
            DefaultExt = extension,
            AddExtension = !string.IsNullOrEmpty(extension),
            OverwritePrompt = true,
            CheckPathExists = true,
            RestoreDirectory = true,
        };
        if (dialog.ShowDialog(this) != true)
        {
            return;
        }

        var resumeVideoPreview = isLibraryVideoPreviewActive &&
            selectedLibraryPreviewFile?.FileId == file.FileId &&
            file.AbsolutePath is not null;
        isLibraryExportInProgress = true;
        SetLibraryInteractionEnabled(false);
        SetResourceBrush(LibraryExportStatusText, "TextSecondaryBrush");
        LibraryExportStatusText.Text = $"Saving {label}…";
        try
        {
            if (resumeVideoPreview)
            {
                // MediaElement can retain an open handle to the selected MOV.
                // Close it before exact-copy verification and let WPF release
                // the native media resources before opening the file again.
                StopLibraryVideoPreview();
                await System.Windows.Threading.Dispatcher.Yield(DispatcherPriority.Background);
            }

            var result = await variantExportService.ExportToPathAsync(file, dialog.FileName);
            SetResourceBrush(LibraryExportStatusText, "SuccessBrush");
            var folderName = new DirectoryInfo(Path.GetDirectoryName(result.ExportedPath)!).Name;
            LibraryExportStatusText.Text = result.ExistingVerified
                ? $"An identical copy is already in {folderName}."
                : $"Saved to {folderName}.";

            var successMessage = result.ExistingVerified
                ? $"An identical copy already exists here:\n\n{result.ExportedPath}"
                : $"Saved a copy here:\n\n{result.ExportedPath}";
            System.Windows.MessageBox.Show(
                this,
                successMessage,
                "Version saved",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
        }
        catch (Exception exception)
        {
            var failureMessage = LibraryExportFailureMessage(exception);
            SetResourceBrush(LibraryExportStatusText, "ErrorBrush");
            LibraryExportStatusText.Text = failureMessage;
            System.Windows.MessageBox.Show(
                this,
                failureMessage,
                "Version could not be saved",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
        }
        finally
        {
            isLibraryExportInProgress = false;
            SetLibraryInteractionEnabled(true);
            if (openLibrary == library && LibraryAssetList.SelectedItem is LibraryAssetListItem selected)
            {
                ConfigureVariantButtons(selected.Asset);
            }
            if (resumeVideoPreview &&
                selectedLibraryPreviewFile?.FileId == file.FileId &&
                file.AbsolutePath is { } videoPath)
            {
                StartLibraryVideoPreview(videoPath);
            }
        }
    }

    internal static string LibraryExportFailureMessage(Exception exception) => exception switch
    {
        InvalidDataException =>
            "The selected library file has changed or is incomplete. Reload the library and try again.",
        InvalidOperationException when exception.Message.Contains("outside", StringComparison.OrdinalIgnoreCase) ||
                                       exception.Message.Contains("inside", StringComparison.OrdinalIgnoreCase) =>
            "Choose a folder outside the MB Photos library, then try again.",
        UnauthorizedAccessException =>
            "Windows denied access to that folder. Choose another folder or check its permissions.",
        IOException =>
            "The file could not be copied. Close any app using the file, then try another folder.",
        _ =>
            "That version could not be saved. Choose another folder and try again.",
    };

    private string SuggestedLibraryExportFilename(PortableLibraryFile file)
    {
        var displayFilename = LibraryAssetList.SelectedItem is LibraryAssetListItem item &&
                              item.Asset.AssetId == file.AssetId
            ? item.Filename
            : file.Catalog.OriginalFilename;
        return SuggestedLibraryExportFilename(displayFilename, file.Catalog.OriginalFilename, file.FileId);
    }

    internal static string SuggestedLibraryExportFilename(
        string displayFilename,
        string representationFilename,
        Guid fileId)
    {
        var displayLeaf = Path.GetFileName(displayFilename);
        var representationLeaf = Path.GetFileName(representationFilename);
        var stem = Path.GetFileNameWithoutExtension(displayLeaf);
        if (string.IsNullOrWhiteSpace(stem))
        {
            stem = Path.GetFileNameWithoutExtension(representationLeaf);
        }
        if (string.IsNullOrWhiteSpace(stem))
        {
            stem = fileId.ToString("D");
        }

        return stem + Path.GetExtension(representationLeaf);
    }

    private async void OpenMasterFolder_Click(object sender, RoutedEventArgs e)
    {
        if (!isLibraryExportInProgress && openLibrary is { } library)
        {
            await OpenFolderInExplorerAsync(
                Path.Combine(library.RootPath, library.Library.MasterRelativePath),
                "The photos folder could not be opened.");
        }
    }

    private async Task OpenFolderInExplorerAsync(string path, string fallbackMessage)
    {
        try
        {
            await Task.Run(() => Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }));
        }
        catch (Exception)
        {
            System.Windows.MessageBox.Show(
                this,
                fallbackMessage,
                "MB Photos",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
        }
    }

    private async void ExportDiagnostics_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.SaveFileDialog
        {
            Title = "Export redacted diagnostics",
            FileName = $"mbphotos-receiver-{DateTime.Now:yyyyMMdd-HHmmss}.log",
            Filter = "Log files (*.log)|*.log|All files (*.*)|*.*",
        };
        if (dialog.ShowDialog(this) != true)
        {
            return;
        }

        try
        {
            await app.Diagnostics.ExportAsync(dialog.FileName);
        }
        catch (Exception)
        {
            System.Windows.MessageBox.Show(
                this,
                "The diagnostics file could not be created. Choose another location and try again.",
                "Diagnostics could not be exported",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
        }
    }

    private void Window_Closing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        if (app.IsExiting)
        {
            orchestrator.StateChanged -= Orchestrator_StateChanged;
            CancelLibraryImagePreview();
            StopLibraryVideoPreview();
            previewLoadCancellation?.Cancel();
            previewLoadCancellation?.Dispose();
            previewLoadCancellation = null;
            return;
        }

        app.HandleWindowClosing(e);
    }

    private void Window_IsVisibleChanged(object sender, DependencyPropertyChangedEventArgs e)
    {
        if (!isLibraryVideoPreviewActive)
        {
            return;
        }

        if (IsVisible)
        {
            LibraryPreviewVideo.Play();
        }
        else
        {
            LibraryPreviewVideo.Pause();
        }
    }

    private static LibraryAssetListItem CreateLibraryListItem(PortableLibraryAsset asset)
    {
        var preferredFile = asset.Files.FirstOrDefault(file =>
                file.Catalog.Roles.Contains(RepresentationRole.RootOriginal)) ??
            asset.MasterFile ??
            asset.Files.FirstOrDefault();
        var filename = preferredFile?.Catalog.OriginalFilename ?? asset.AssetId.ToString("D");
        var dateText = asset.Catalog.CreationDate?.LocalDateTime.ToString("g") ?? "Date unavailable";
        var statuses = new List<string>();
        if (asset.IsEdited)
        {
            statuses.Add("Edited");
        }
        if (asset.IsLivePhoto)
        {
            statuses.Add("Live Photo");
        }
        if (statuses.Count == 0)
        {
            statuses.Add(asset.Catalog.MediaType == "video" ? "Video" : "Photo");
        }

        var thumbnail = asset.Files.FirstOrDefault(file =>
            file.Catalog.Provenance == Provenance.GeneratedThumbnail &&
            file.Catalog.Availability == Availability.Available &&
            file.IsPresent);
        var thumbnailPath = thumbnail?.AbsolutePath;
        return new LibraryAssetListItem(
            asset,
            filename,
            dateText,
            string.Join(" • ", statuses),
            thumbnailPath,
            asset.Catalog.CreationDate);
    }

    internal static LibraryAssetListItem[] SortLibraryItems(IEnumerable<LibraryAssetListItem> items)
    {
        ArgumentNullException.ThrowIfNull(items);
        return items
            .OrderByDescending(item => item.CaptureDate?.UtcDateTime.Ticks ?? long.MinValue)
            .ThenBy(item => item.Filename, StringComparer.CurrentCultureIgnoreCase)
            .ThenBy(item => item.Asset.AssetId)
            .ToArray();
    }

    internal static bool LibraryTimeFilterIncludes(
        DateTimeOffset? captureDate,
        LibraryTimeFilter filter,
        DateTimeOffset now)
    {
        if (filter == LibraryTimeFilter.All)
        {
            return true;
        }
        if (captureDate is null)
        {
            return false;
        }

        var captured = captureDate.Value.ToLocalTime().DateTime;
        var today = now.ToLocalTime().Date;
        var startOfWeek = today.AddDays(-(((int)today.DayOfWeek + 6) % 7));
        return filter switch
        {
            LibraryTimeFilter.Today => captured.Date == today,
            LibraryTimeFilter.ThisWeek => captured >= startOfWeek && captured < startOfWeek.AddDays(7),
            LibraryTimeFilter.ThisMonth => captured.Year == today.Year && captured.Month == today.Month,
            LibraryTimeFilter.ThisYear => captured.Year == today.Year,
            LibraryTimeFilter.Earlier => captured < new DateTime(today.Year, 1, 1),
            _ => throw new ArgumentOutOfRangeException(nameof(filter)),
        };
    }

    private void ConfigureLibraryTimeFilters(DateTimeOffset now)
    {
        var filters = LibraryTimeFilterButtons();
        foreach (var (filter, button) in filters)
        {
            button.Visibility = filter == LibraryTimeFilter.All ||
                                libraryItems.Any(item =>
                                    LibraryTimeFilterIncludes(item.CaptureDate, filter, now))
                ? Visibility.Visible
                : Visibility.Collapsed;
        }

        if (libraryTimeFilter != LibraryTimeFilter.All &&
            filters.First(pair => pair.Filter == libraryTimeFilter).Button.Visibility != Visibility.Visible)
        {
            libraryTimeFilter = LibraryTimeFilter.All;
        }

        foreach (var (filter, button) in filters)
        {
            button.IsChecked = filter == libraryTimeFilter;
        }
        LibraryTimeFilterPanel.Visibility = filters.Count(pair => pair.Button.Visibility == Visibility.Visible) > 1
            ? Visibility.Visible
            : Visibility.Collapsed;
    }

    private void ApplyLibraryTimeFilter(DateTimeOffset now)
    {
        var visibleItems = libraryItems
            .Where(item => LibraryTimeFilterIncludes(item.CaptureDate, libraryTimeFilter, now))
            .ToArray();
        LibraryAssetList.ItemsSource = visibleItems;
        UpdateLibrarySummary(visibleItems.Length);

        if (visibleItems.Length > 0)
        {
            LibraryAssetList.SelectedIndex = 0;
        }
        else
        {
            ClearLibrarySelection(libraryItems.Count == 0
                ? "This library does not contain any photos yet."
                : LibraryTimeFilterEmptyMessage(libraryTimeFilter));
        }
    }

    private void UpdateLibrarySummary(int visibleCount)
    {
        if (openLibrary is not { } library)
        {
            return;
        }
        if (libraryItems.Count == 0)
        {
            LibrarySummaryText.Text = "No transferred photos yet";
            return;
        }

        var updated = library.Catalog.GeneratedAt.LocalDateTime.ToString("g");
        LibrarySummaryText.Text = libraryTimeFilter == LibraryTimeFilter.All
            ? $"{libraryItems.Count:N0} {ItemWord(libraryItems.Count)} • Newest first • Updated {updated}"
            : $"{visibleCount:N0} of {libraryItems.Count:N0} {ItemWord(libraryItems.Count)} • " +
              $"{LibraryTimeFilterLabel(libraryTimeFilter)} • Newest first • Updated {updated}";
    }

    private (LibraryTimeFilter Filter, RadioButton Button)[] LibraryTimeFilterButtons() =>
    [
        (LibraryTimeFilter.All, AllDatesFilterButton),
        (LibraryTimeFilter.Today, TodayFilterButton),
        (LibraryTimeFilter.ThisWeek, ThisWeekFilterButton),
        (LibraryTimeFilter.ThisMonth, ThisMonthFilterButton),
        (LibraryTimeFilter.ThisYear, ThisYearFilterButton),
        (LibraryTimeFilter.Earlier, EarlierFilterButton),
    ];

    private static string LibraryTimeFilterLabel(LibraryTimeFilter filter) => filter switch
    {
        LibraryTimeFilter.All => "All dates",
        LibraryTimeFilter.Today => "Today",
        LibraryTimeFilter.ThisWeek => "This week",
        LibraryTimeFilter.ThisMonth => "This month",
        LibraryTimeFilter.ThisYear => "This year",
        LibraryTimeFilter.Earlier => "Earlier",
        _ => throw new ArgumentOutOfRangeException(nameof(filter)),
    };

    private static string LibraryTimeFilterEmptyMessage(LibraryTimeFilter filter) => filter switch
    {
        LibraryTimeFilter.Today => "No photos were taken today.",
        LibraryTimeFilter.ThisWeek => "No photos were taken this week.",
        LibraryTimeFilter.ThisMonth => "No photos were taken this month.",
        LibraryTimeFilter.ThisYear => "No photos were taken this year.",
        LibraryTimeFilter.Earlier => "There are no photos from before this year.",
        _ => "This library does not contain any photos yet.",
    };

    private static PortableLibraryFile? FindExportableFile(PortableLibraryAsset asset, VariantKind variant)
    {
        if (variant == VariantKind.CurrentMaster)
        {
            var master = asset.MasterFile;
            return master is not null &&
                   master.Catalog.Availability == Availability.Available &&
                   master.Catalog.ByteCount is not null &&
                   master.Catalog.Sha256 is not null &&
                   master.IsPresent
                ? master
                : null;
        }

        var role = variant switch
        {
            VariantKind.RootOriginal => RepresentationRole.RootOriginal,
            VariantKind.CurrentLiveMotion => RepresentationRole.CurrentLiveMotion,
            VariantKind.OriginalLiveMotion => RepresentationRole.OriginalLiveMotion,
            _ => throw new ArgumentOutOfRangeException(nameof(variant)),
        };
        return asset.Files.FirstOrDefault(file =>
            file.Catalog.Availability == Availability.Available &&
            file.Catalog.Roles.Contains(role) &&
            file.Catalog.ByteCount is not null &&
            file.Catalog.Sha256 is not null &&
            file.IsPresent);
    }

    internal static PortableLibraryFile? FindCopyableImageFile(PortableLibraryAsset asset)
    {
        ArgumentNullException.ThrowIfNull(asset);
        if (asset.Catalog.MediaType != "photo" && !asset.IsLivePhoto)
        {
            return null;
        }

        var relationships = asset.Catalog.LivePhotoRelationships;
        var candidates = new[]
        {
            FindExportableFile(asset, VariantKind.CurrentMaster),
            FindFile(relationships?.CurrentStillFileId),
            FindExportableFile(asset, VariantKind.RootOriginal),
            FindFile(relationships?.OriginalStillFileId),
        };
        return candidates
                   .OfType<PortableLibraryFile>()
                   .DistinctBy(file => file.FileId)
                   .FirstOrDefault(IsCopyableStillImage) ??
               asset.Files.FirstOrDefault(IsCopyableStillImage);

        PortableLibraryFile? FindFile(Guid? fileId) => fileId is { } id
            ? asset.Files.FirstOrDefault(file => file.FileId == id)
            : null;
    }

    internal static bool IsCopyableStillImage(PortableLibraryFile file)
    {
        ArgumentNullException.ThrowIfNull(file);
        var isStillImage =
            file.Catalog.ContentType?.StartsWith("image/", StringComparison.OrdinalIgnoreCase) == true ||
            file.Catalog.PhotoKitResourceType is
                "photo" or "alternatePhoto" or "fullSizePhoto" or "adjustmentBasePhoto";
        return isStillImage &&
               file.Catalog.Provenance == Provenance.ExactPhotoKitResource &&
               file.Catalog.Availability == Availability.Available &&
               file.Catalog.ByteCount is not null &&
               file.Catalog.Sha256 is not null &&
               file.IsPresent;
    }

    private static IReadOnlyList<LibraryVariantChoice> BuildAdditionalOriginalChoices(PortableLibraryAsset asset)
    {
        var primaryFileIds = new[]
            {
                VariantKind.CurrentMaster,
                VariantKind.RootOriginal,
                VariantKind.CurrentLiveMotion,
                VariantKind.OriginalLiveMotion,
            }
            .Select(variant => FindExportableFile(asset, variant)?.FileId)
            .OfType<Guid>()
            .ToHashSet();
        return asset.Files
            .Where(file =>
                !primaryFileIds.Contains(file.FileId) &&
                file.Catalog.Availability == Availability.Available &&
                (file.Catalog.Roles.Contains(RepresentationRole.RootOriginal) ||
                 file.Catalog.Roles.Contains(RepresentationRole.AlternateOriginal)) &&
                file.Catalog.ByteCount is not null &&
                file.Catalog.Sha256 is not null &&
                file.IsPresent)
            .GroupBy(file => file.FileId)
            .Select(group => group.First())
            .OrderBy(file => file.Catalog.OriginalFilename, StringComparer.CurrentCultureIgnoreCase)
            .Select(file => new LibraryVariantChoice(
                $"Original — {file.Catalog.OriginalFilename}",
                file))
            .ToArray();
    }

    private void ConfigureVariantButtons(PortableLibraryAsset asset)
    {
        var candidates = new[]
        {
            (VariantKind.CurrentMaster, FindExportableFile(asset, VariantKind.CurrentMaster)),
            (VariantKind.RootOriginal, FindExportableFile(asset, VariantKind.RootOriginal)),
            (VariantKind.CurrentLiveMotion, FindExportableFile(asset, VariantKind.CurrentLiveMotion)),
            (VariantKind.OriginalLiveMotion, FindExportableFile(asset, VariantKind.OriginalLiveMotion)),
        };
        var distinctKinds = DistinctVariantKinds(candidates
            .Where(candidate => candidate.Item2 is not null)
            .Select(candidate => (candidate.Item1, candidate.Item2!.FileId)));
        var visibleKinds = distinctKinds.ToHashSet();

        CurrentVersionButton.IsEnabled = visibleKinds.Contains(VariantKind.CurrentMaster);
        OriginalVersionButton.IsEnabled = visibleKinds.Contains(VariantKind.RootOriginal);
        CurrentMotionVersionButton.IsEnabled = visibleKinds.Contains(VariantKind.CurrentLiveMotion);
        OriginalMotionVersionButton.IsEnabled = visibleKinds.Contains(VariantKind.OriginalLiveMotion);
        var additionalCount = IndividualOriginalsComboBox.Items.Count;
        VersionSelectionPanel.Visibility = ShouldShowVariantSelection(distinctKinds.Count, additionalCount)
            ? Visibility.Visible
            : Visibility.Collapsed;
        AdditionalOriginalsPanel.Visibility =
            VersionSelectionPanel.Visibility == Visibility.Visible && additionalCount > 0
                ? Visibility.Visible
                : Visibility.Collapsed;
        SetVariantInteractionEnabled(!isLibraryExportInProgress);
    }

    internal static IReadOnlyList<VariantKind> DistinctVariantKinds(
        IEnumerable<(VariantKind Variant, Guid FileId)> candidates)
    {
        ArgumentNullException.ThrowIfNull(candidates);
        var seenFiles = new HashSet<Guid>();
        var result = new List<VariantKind>(4);
        foreach (var (variant, fileId) in candidates)
        {
            if (seenFiles.Add(fileId))
            {
                result.Add(variant);
            }
        }
        return result;
    }

    internal static bool ShouldShowVariantSelection(int distinctVariantCount, int additionalOriginalCount)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(distinctVariantCount);
        ArgumentOutOfRangeException.ThrowIfNegative(additionalOriginalCount);
        return distinctVariantCount + additionalOriginalCount > 1;
    }

    private void SetVariantInteractionEnabled(bool enabled)
    {
        foreach (var button in VariantButtons())
        {
            button.IsHitTestVisible = enabled;
            button.Focusable = enabled;
        }
        IndividualOriginalsComboBox.IsHitTestVisible = enabled;
        IndividualOriginalsComboBox.Focusable = enabled;
        SaveLibraryPreviewButton.IsHitTestVisible = enabled;
        SaveLibraryPreviewButton.Focusable = enabled;
        CopyLibraryPreviewButton.IsHitTestVisible = enabled;
        CopyLibraryPreviewButton.Focusable = enabled;
        SaveLibraryPreviewButton.Content = enabled ? "Save" : "Saving…";
    }

    private RadioButton[] VariantButtons() =>
    [
        CurrentVersionButton,
        OriginalVersionButton,
        CurrentMotionVersionButton,
        OriginalMotionVersionButton,
    ];

    private void SelectPreferredLibraryPreview(PortableLibraryAsset asset, string? thumbnailPath)
    {
        foreach (var variant in new[]
                 {
                     VariantKind.CurrentMaster,
                     VariantKind.RootOriginal,
                     VariantKind.CurrentLiveMotion,
                     VariantKind.OriginalLiveMotion,
                 })
        {
            if (FindExportableFile(asset, variant) is { } file)
            {
                SelectLibraryPreview(file, VariantLabel(variant), variant, thumbnailPath);
                return;
            }
        }

        if (IndividualOriginalsComboBox.Items.Count > 0 &&
            IndividualOriginalsComboBox.Items[0] is LibraryVariantChoice choice)
        {
            isConfiguringLibraryVersions = true;
            IndividualOriginalsComboBox.SelectedIndex = 0;
            isConfiguringLibraryVersions = false;
            SetCheckedVariant(null);
            SelectLibraryPreview(choice.File, choice.Label, null, thumbnailPath);
            return;
        }

        selectedLibraryPreviewFile = null;
        selectedLibraryPreviewLabel = string.Empty;
        LibraryPreviewImage.Source = LoadPreview(thumbnailPath);
        SaveLibraryPreviewButton.Visibility = Visibility.Collapsed;
        CopyLibraryPreviewButton.Visibility = Visibility.Collapsed;
        ShowLibraryPreviewMessage("No saved version is available.");
        SetCheckedVariant(null);
    }

    private void SelectLibraryPreview(
        PortableLibraryFile file,
        string label,
        VariantKind? variant,
        string? thumbnailPath)
    {
        CancelLibraryImagePreview();
        StopLibraryVideoPreview();

        selectedLibraryPreviewFile = file;
        selectedLibraryPreviewLabel = label;
        SaveLibraryPreviewButton.Visibility = Visibility.Visible;
        CopyLibraryPreviewButton.Visibility = IsCopyableStillImage(file)
            ? Visibility.Visible
            : Visibility.Collapsed;
        SaveLibraryPreviewButton.Content = "Save";
        SaveLibraryPreviewButton.ToolTip = $"Save {label}";
        SetCheckedVariant(variant);

        var thumbnail = LoadPreview(thumbnailPath);
        LibraryPreviewImage.Source = thumbnail;
        ShowLibraryPreviewMessage(null);
        if (file.AbsolutePath is not { } path)
        {
            ShowLibraryPreviewMessage("This version is no longer available to preview.");
            return;
        }

        if (IsVideoPreview(file, path))
        {
            StartLibraryVideoPreview(path);
            return;
        }

        var cancellation = new CancellationTokenSource();
        libraryPreviewLoadCancellation = cancellation;
        var revision = Interlocked.Increment(ref libraryPreviewRevision);
        if (thumbnail is null)
        {
            ShowLibraryPreviewMessage("Loading preview…");
        }
        _ = LoadLibraryImagePreviewAsync(file.FileId, path, revision, cancellation);
    }

    private async Task LoadLibraryImagePreviewAsync(
        Guid fileId,
        string path,
        long revision,
        CancellationTokenSource cancellation)
    {
        try
        {
            var image = await ThumbnailBitmapCache.LoadAsync(path, 1200, cancellation.Token);
            if (cancellation.IsCancellationRequested ||
                revision != Volatile.Read(ref libraryPreviewRevision) ||
                selectedLibraryPreviewFile?.FileId != fileId)
            {
                return;
            }

            if (image is not null)
            {
                LibraryPreviewImage.Source = image;
                ShowLibraryPreviewMessage(null);
            }
            else
            {
                ShowLibraryPreviewMessage("Full preview unavailable — showing the library thumbnail.");
            }
        }
        catch (OperationCanceledException)
        {
        }
        finally
        {
            if (ReferenceEquals(libraryPreviewLoadCancellation, cancellation))
            {
                libraryPreviewLoadCancellation = null;
                cancellation.Dispose();
            }
        }
    }

    private void StartLibraryVideoPreview(string path)
    {
        try
        {
            isLibraryVideoPreviewActive = true;
            LibraryPreviewVideo.Source = new Uri(Path.GetFullPath(path), UriKind.Absolute);
            LibraryPreviewVideo.Position = TimeSpan.Zero;
            LibraryPreviewVideo.Visibility = Visibility.Visible;
            ShowLibraryPreviewMessage("Loading video preview…");
            if (IsVisible)
            {
                LibraryPreviewVideo.Play();
            }
        }
        catch (Exception exception) when (exception is UriFormatException or IOException or UnauthorizedAccessException)
        {
            StopLibraryVideoPreview();
            ShowLibraryPreviewMessage("Video preview unavailable. You can still save this version.");
        }
    }

    private void LibraryPreviewVideo_MediaOpened(object sender, RoutedEventArgs e)
    {
        if (isLibraryVideoPreviewActive)
        {
            ShowLibraryPreviewMessage(null);
        }
    }

    private void LibraryPreviewVideo_MediaEnded(object sender, RoutedEventArgs e)
    {
        if (isLibraryVideoPreviewActive && IsVisible)
        {
            LibraryPreviewVideo.Position = TimeSpan.Zero;
            LibraryPreviewVideo.Play();
        }
    }

    private void LibraryPreviewVideo_MediaFailed(object sender, ExceptionRoutedEventArgs e)
    {
        if (!isLibraryVideoPreviewActive)
        {
            return;
        }

        StopLibraryVideoPreview();
        ShowLibraryPreviewMessage("Video preview unavailable. You can still save this version.");
    }

    private void SetCheckedVariant(VariantKind? selected)
    {
        foreach (var button in VariantButtons())
        {
            button.IsChecked = selected is not null &&
                button.Tag is string tag &&
                Enum.TryParse<VariantKind>(tag, out var variant) &&
                variant == selected;
        }
    }

    private void ShowLibraryPreviewMessage(string? message)
    {
        LibraryPreviewMessageText.Text = message ?? string.Empty;
        LibraryPreviewMessageBorder.Visibility = string.IsNullOrWhiteSpace(message)
            ? Visibility.Collapsed
            : Visibility.Visible;
    }

    private void CancelLibraryImagePreview()
    {
        Interlocked.Increment(ref libraryPreviewRevision);
        var cancellation = libraryPreviewLoadCancellation;
        libraryPreviewLoadCancellation = null;
        if (cancellation is null)
        {
            return;
        }

        cancellation.Cancel();
        cancellation.Dispose();
    }

    private void StopLibraryVideoPreview()
    {
        isLibraryVideoPreviewActive = false;
        LibraryPreviewVideo.Close();
        LibraryPreviewVideo.Source = null;
        LibraryPreviewVideo.Visibility = Visibility.Collapsed;
    }

    private static bool IsVideoPreview(PortableLibraryFile file, string path)
    {
        if (file.Catalog.ContentType?.StartsWith("video/", StringComparison.OrdinalIgnoreCase) == true ||
            file.Catalog.PhotoKitResourceType?.Contains("video", StringComparison.OrdinalIgnoreCase) == true ||
            file.Catalog.Roles.Any(static role =>
                role is RepresentationRole.CurrentLiveMotion or RepresentationRole.OriginalLiveMotion))
        {
            return true;
        }

        return Path.GetExtension(path).ToLowerInvariant() is
            ".mov" or ".mp4" or ".m4v" or ".avi" or ".wmv" or ".mpeg" or ".mpg";
    }

    private void SetLibraryInteractionEnabled(bool enabled)
    {
        LibraryAssetList.IsEnabled = enabled;
        foreach (var (_, button) in LibraryTimeFilterButtons())
        {
            button.IsHitTestVisible = enabled;
            button.Focusable = enabled;
        }
        ReloadLibraryButton.IsEnabled = enabled;
        OpenLibraryFolderButton.IsEnabled = enabled;
        CloseLibraryButton.IsEnabled = enabled;
        OpenMasterFolderButton.IsEnabled = enabled;
        OpenAnotherLibraryMenuItem.IsEnabled = enabled && presentation.CanOpenLibrary;
        SetVariantInteractionEnabled(enabled);
    }

    private void ClearLibrarySelection(string message)
    {
        CancelLibraryImagePreview();
        StopLibraryVideoPreview();
        selectedLibraryPreviewFile = null;
        selectedLibraryPreviewLabel = string.Empty;
        LibraryPreviewImage.Source = null;
        SaveLibraryPreviewButton.Visibility = Visibility.Collapsed;
        CopyLibraryPreviewButton.Visibility = Visibility.Collapsed;
        ShowLibraryPreviewMessage(null);
        LibraryFilenameText.Text = "No item selected";
        LibraryDateText.Text = string.Empty;
        LibraryFlagsText.Text = string.Empty;
        LibraryArchiveText.Text = message;
        LibraryExportStatusText.Text = message;
        SetResourceBrush(LibraryExportStatusText, "TextSecondaryBrush");
        IndividualOriginalsComboBox.ItemsSource = null;
        VersionSelectionPanel.Visibility = Visibility.Collapsed;
        AdditionalOriginalsPanel.Visibility = Visibility.Collapsed;
        foreach (var button in VariantButtons())
        {
            button.IsChecked = false;
            button.IsEnabled = false;
        }
    }

    private static BitmapImage? LoadPreview(string? path, int decodePixelWidth = 800)
    {
        if (path is null || !File.Exists(path))
        {
            return null;
        }

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
        catch (Exception exception) when (exception is
            IOException or
            UnauthorizedAccessException or
            NotSupportedException or
            InvalidOperationException or
            FormatException)
        {
            return null;
        }
    }

    private static string VariantLabel(VariantKind variant) => variant switch
    {
        VariantKind.CurrentMaster => "Current Version",
        VariantKind.RootOriginal => "Original",
        VariantKind.CurrentLiveMotion => "Live Photo Video",
        VariantKind.OriginalLiveMotion => "Original Live Photo Video",
        _ => variant.ToString(),
    };

    private static bool IsInitializedLibrary(string rootPath) =>
        File.Exists(Path.Combine(rootPath, "MB Photos Data", ".mbphotos", "destination.json"));

    private static bool IsEmptyFolder(string rootPath) =>
        Directory.Exists(rootPath) && !Directory.EnumerateFileSystemEntries(rootPath).Any();

    private static string ItemWord(int count) => count == 1 ? "item" : "items";

    private static string ProductVersionText()
    {
        var assembly = typeof(MainWindow).Assembly;
        var informational = assembly
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?
            .InformationalVersion;
        var version = informational?.Split('+')[0] ?? assembly.GetName().Version?.ToString(3) ?? "1.0";
        return $"Version {version}";
    }

    private static void SetResourceBrush(TextBlock textBlock, string resourceKey) =>
        textBlock.SetResourceReference(TextBlock.ForegroundProperty, resourceKey);

    private void ResetLibraryView()
    {
        Interlocked.Increment(ref libraryLoadRevision);
        alternateLibraryPath = null;
        openedLibraryPath = null;
        openLibrary = null;
        libraryItems = Array.Empty<LibraryAssetListItem>();
        libraryTimeFilter = LibraryTimeFilter.All;
        LibraryAssetList.ItemsSource = null;
        ConfigureLibraryTimeFilters(DateTimeOffset.Now);
        LibraryPreviewImage.Source = null;
        ClearLibrarySelection("Your library will reload the next time you open it.");
    }
}

internal sealed record LibraryAssetListItem(
    PortableLibraryAsset Asset,
    string Filename,
    string DateText,
    string StatusText,
    string? ThumbnailPath,
    DateTimeOffset? CaptureDate);

internal sealed record LibraryVariantChoice(string Label, PortableLibraryFile File);

internal sealed record PlatformClipboardImage(BitmapSource Bitmap, byte[] PngBytes);

internal enum LibraryTimeFilter
{
    All,
    Today,
    ThisWeek,
    ThisMonth,
    ThisYear,
    Earlier,
}
