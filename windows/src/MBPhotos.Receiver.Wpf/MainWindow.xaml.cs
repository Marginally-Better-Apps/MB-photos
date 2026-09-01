using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using MBPhotos.Receiver.Diagnostics;
using MBPhotos.Receiver.Library;
using MBPhotos.Receiver.Models;
using MBPhotos.Receiver.Transfer;
using Microsoft.Win32;
using Button = System.Windows.Controls.Button;

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
    private CancellationTokenSource? previewLoadCancellation;
    private string? previewRequestIdentity;
    private string? openedLibraryPath;
    private string? alternateLibraryPath;
    private long libraryLoadRevision;
    private long appliedSnapshotRevision = -1;
    private bool isLibraryExportInProgress;

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
        if (!force && string.Equals(openedLibraryPath, rootPath, StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        var revision = Interlocked.Increment(ref libraryLoadRevision);
        openedLibraryPath = rootPath;
        openLibrary = null;
        LibrarySummaryText.Text = "Opening your photos…";
        LibraryAssetList.ItemsSource = null;
        ClearLibrarySelection("Choose a photo or video to see its available versions.");
        try
        {
            var (snapshot, items) = await Task.Run(async () =>
            {
                var loaded = await portableLibraryService.OpenAsync(rootPath).ConfigureAwait(false);
                return (
                    loaded,
                    loaded.Assets.Select(CreateLibraryListItem).ToArray());
            });

            if (revision != Volatile.Read(ref libraryLoadRevision) ||
                presentation.Page != ReceiverShellPage.Library)
            {
                return;
            }

            openLibrary = snapshot;
            LibrarySummaryText.Text = items.Length == 0
                ? "No transferred photos yet"
                : $"{items.Length:N0} {ItemWord(items.Length)} • Updated {snapshot.Catalog.GeneratedAt.LocalDateTime:g}";
            LibraryAssetList.ItemsSource = items;
            LibraryExportStatusText.Text = string.Empty;
            if (items.Length > 0)
            {
                LibraryAssetList.SelectedIndex = 0;
            }
            else
            {
                ClearLibrarySelection("This library does not contain any photos yet.");
            }
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
        LibraryPreviewImage.Source = LoadPreview(item.ThumbnailPath);
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

        var individualOriginals = BuildOriginalChoices(asset);
        IndividualOriginalsComboBox.ItemsSource = individualOriginals;
        IndividualOriginalsComboBox.SelectedIndex = individualOriginals.Count == 0 ? -1 : 0;
        ConfigureExportButtons(asset);
        LibraryExportStatusText.Text = string.Empty;
    }

    private async void ExportVariant_Click(object sender, RoutedEventArgs e)
    {
        if (isLibraryExportInProgress ||
            openLibrary is null ||
            LibraryAssetList.SelectedItem is not LibraryAssetListItem item ||
            sender is not Button button ||
            button.Tag is not string tag ||
            !Enum.TryParse<VariantKind>(tag, out var variant))
        {
            return;
        }

        var file = FindExportableFile(item.Asset, variant);
        if (file is null)
        {
            System.Windows.MessageBox.Show(
                this,
                "That version is not available for this item.",
                "Version unavailable",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
            return;
        }

        await ExportFileAsync(file, VariantLabel(variant));
    }

    private async void ExportIndividualOriginal_Click(object sender, RoutedEventArgs e)
    {
        if (!isLibraryExportInProgress &&
            IndividualOriginalsComboBox.SelectedItem is OriginalExportChoice choice)
        {
            await ExportFileAsync(choice.File, choice.Label);
        }
    }

    private async Task ExportFileAsync(PortableLibraryFile file, string label)
    {
        if (openLibrary is not { } library)
        {
            return;
        }

        var dialog = new OpenFolderDialog
        {
            Title = $"Save {label}",
            Multiselect = false,
        };
        if (dialog.ShowDialog(this) != true)
        {
            return;
        }

        isLibraryExportInProgress = true;
        SetLibraryInteractionEnabled(false);
        SetResourceBrush(LibraryExportStatusText, "TextSecondaryBrush");
        LibraryExportStatusText.Text = $"Saving {label}…";
        try
        {
            var result = await variantExportService.ExportAsync(file, dialog.FolderName);
            SetResourceBrush(LibraryExportStatusText, "SuccessBrush");
            var folderName = new DirectoryInfo(Path.GetDirectoryName(result.ExportedPath) ?? dialog.FolderName).Name;
            LibraryExportStatusText.Text = result.ExistingVerified
                ? $"An identical copy is already in {folderName}."
                : $"Saved to {folderName}.";
        }
        catch (Exception)
        {
            SetResourceBrush(LibraryExportStatusText, "ErrorBrush");
            LibraryExportStatusText.Text = "That version could not be saved. Check the destination folder and try again.";
        }
        finally
        {
            isLibraryExportInProgress = false;
            SetLibraryInteractionEnabled(true);
            if (openLibrary == library && LibraryAssetList.SelectedItem is LibraryAssetListItem selected)
            {
                ConfigureExportButtons(selected.Asset);
            }
        }
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
        var receiver = orchestrator.Snapshot.Receiver;

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
            if (receiver is not null)
            {
                await receiver.Diagnostics.ExportAsync(dialog.FileName);
            }
            else
            {
                await RedactingFileLoggerProvider.ExportExistingAsync(dialog.FileName);
            }
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
            previewLoadCancellation?.Cancel();
            previewLoadCancellation?.Dispose();
            previewLoadCancellation = null;
            return;
        }

        app.HandleWindowClosing(e);
    }

    private static LibraryAssetListItem CreateLibraryListItem(PortableLibraryAsset asset)
    {
        var preferredFile = asset.MasterFile ??
            asset.Files.FirstOrDefault(file => file.Catalog.Roles.Contains(RepresentationRole.RootOriginal)) ??
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
            thumbnailPath);
    }

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

    private static IReadOnlyList<OriginalExportChoice> BuildOriginalChoices(PortableLibraryAsset asset) =>
        asset.Files
            .Where(file =>
                file.Catalog.Availability == Availability.Available &&
                (file.Catalog.Roles.Contains(RepresentationRole.RootOriginal) ||
                 file.Catalog.Roles.Contains(RepresentationRole.AlternateOriginal)) &&
                file.Catalog.ByteCount is not null &&
                file.Catalog.Sha256 is not null &&
                file.IsPresent)
            .Select(file => new OriginalExportChoice(
                file.Catalog.Roles.Contains(RepresentationRole.RootOriginal)
                    ? $"{file.Catalog.OriginalFilename} (main original)"
                    : file.Catalog.OriginalFilename,
                file))
            .ToArray();

    private void ConfigureExportButtons(PortableLibraryAsset asset)
    {
        if (isLibraryExportInProgress)
        {
            SetExportButtonsEnabled(false);
            return;
        }

        ExportCurrentButton.IsEnabled = FindExportableFile(asset, VariantKind.CurrentMaster) is not null;
        ExportOriginalButton.IsEnabled = FindExportableFile(asset, VariantKind.RootOriginal) is not null;
        ExportCurrentMotionButton.IsEnabled = FindExportableFile(asset, VariantKind.CurrentLiveMotion) is not null;
        ExportOriginalMotionButton.IsEnabled = FindExportableFile(asset, VariantKind.OriginalLiveMotion) is not null;
        var hasIndividualOriginal = IndividualOriginalsComboBox.Items.Count > 1 ||
            (IndividualOriginalsComboBox.Items.Count == 1 &&
             FindExportableFile(asset, VariantKind.RootOriginal) is null);
        IndividualOriginalsComboBox.Visibility = hasIndividualOriginal ? Visibility.Visible : Visibility.Collapsed;
        ExportIndividualOriginalButton.Visibility = hasIndividualOriginal ? Visibility.Visible : Visibility.Collapsed;
        IndividualOriginalsComboBox.IsEnabled = hasIndividualOriginal;
        ExportIndividualOriginalButton.IsEnabled = hasIndividualOriginal;
    }

    private void SetExportButtonsEnabled(bool enabled)
    {
        ExportCurrentButton.IsEnabled = enabled;
        ExportOriginalButton.IsEnabled = enabled;
        ExportCurrentMotionButton.IsEnabled = enabled;
        ExportOriginalMotionButton.IsEnabled = enabled;
        IndividualOriginalsComboBox.IsEnabled = enabled;
        ExportIndividualOriginalButton.IsEnabled = enabled;
    }

    private void SetLibraryInteractionEnabled(bool enabled)
    {
        LibraryAssetList.IsEnabled = enabled;
        ReloadLibraryButton.IsEnabled = enabled;
        CloseLibraryButton.IsEnabled = enabled;
        OpenMasterFolderButton.IsEnabled = enabled;
        OpenAnotherLibraryMenuItem.IsEnabled = enabled && presentation.CanOpenLibrary;
        SetExportButtonsEnabled(enabled);
    }

    private void ClearLibrarySelection(string message)
    {
        LibraryPreviewImage.Source = null;
        LibraryFilenameText.Text = "No item selected";
        LibraryDateText.Text = string.Empty;
        LibraryFlagsText.Text = string.Empty;
        LibraryArchiveText.Text = message;
        LibraryExportStatusText.Text = message;
        SetResourceBrush(LibraryExportStatusText, "TextSecondaryBrush");
        IndividualOriginalsComboBox.ItemsSource = null;
        IndividualOriginalsComboBox.Visibility = Visibility.Collapsed;
        ExportIndividualOriginalButton.Visibility = Visibility.Collapsed;
        SetExportButtonsEnabled(false);
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
        LibraryAssetList.ItemsSource = null;
        LibraryPreviewImage.Source = null;
        ClearLibrarySelection("Your library will reload the next time you open it.");
    }
}

internal sealed record LibraryAssetListItem(
    PortableLibraryAsset Asset,
    string Filename,
    string DateText,
    string StatusText,
    string? ThumbnailPath);

internal sealed record OriginalExportChoice(string Label, PortableLibraryFile File);
