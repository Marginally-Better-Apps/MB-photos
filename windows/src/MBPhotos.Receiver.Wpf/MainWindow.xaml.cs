using System.Diagnostics;
using System.IO;
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
using Brushes = System.Windows.Media.Brushes;

namespace MBPhotos.Receiver.Wpf;

public partial class MainWindow : Window
{
    private readonly App app;
    private readonly ReceiverLifecycleController lifecycle;
    private readonly ReceiverActivityFeed activityFeed;
    private readonly ReceiverActivityDispatcher activityDispatcher;
    private readonly PortableLibraryService portableLibraryService = new();
    private readonly VariantExportService variantExportService = new();
    private string? destinationPath;
    private PortableLibrarySnapshot? openLibrary;
    private bool isLibraryExportInProgress;
    private long presentedGeneration;

    public MainWindow()
    {
        InitializeComponent();
        app = (App)System.Windows.Application.Current;
        lifecycle = app.Lifecycle;
        activityFeed = app.ActivityFeed;
        activityDispatcher = new ReceiverActivityDispatcher(
            callback =>
            {
                if (Dispatcher.HasShutdownStarted)
                {
                    return false;
                }

                _ = Dispatcher.BeginInvoke(DispatcherPriority.Normal, callback);
                return true;
            },
            ApplyActivity);
        Closing += Window_Closing;
        lifecycle.StateChanged += Lifecycle_StateChanged;
        activityFeed.ActivityAvailable += ActivityFeed_ActivityAvailable;
        ApplyLifecycleState(lifecycle.Snapshot);
    }

    private void Browse_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFolderDialog
        {
            Title = "Choose an MB Photos portable library root",
            Multiselect = false,
        };
        if (dialog.ShowDialog(this) == true)
        {
            DestinationTextBox.Text = dialog.FolderName;
        }
    }

    private async void OpenLibrary_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFolderDialog
        {
            Title = "Choose the MB Photos library root (not Master)",
            Multiselect = false,
        };
        if (dialog.ShowDialog(this) != true)
        {
            return;
        }

        await OpenLibraryAsync(dialog.FolderName);
    }

    private async Task OpenLibraryAsync(string rootPath)
    {
        ShowOperation(
            "Opening portable library",
            "Reading the atomic catalog generation and checking its root-relative paths…",
            canCancel: false);
        try
        {
            var (snapshot, items) = await Task.Run(async () =>
            {
                var loaded = await portableLibraryService.OpenAsync(rootPath).ConfigureAwait(false);
                return (
                    loaded,
                    loaded.Assets.Select(CreateLibraryListItem).ToArray());
            });

            openLibrary = snapshot;
            LibraryRootText.Text = snapshot.RootPath;
            LibrarySummaryText.Text =
                $"{snapshot.Assets.Count:N0} assets • catalog {snapshot.Catalog.GeneratedAt.LocalDateTime:g} • generation {snapshot.Catalog.GenerationId:D}";
            LibraryAssetList.ItemsSource = items;
            LibraryExportStatusText.Text = string.Empty;
            ShowPanel(LibraryPanel);
            if (items.Length > 0)
            {
                LibraryAssetList.SelectedIndex = 0;
            }
            else
            {
                ClearLibrarySelection("This catalog does not contain any assets.");
            }
        }
        catch (Exception exception)
        {
            ShowError(exception.Message, "Library could not be opened");
        }
    }

    private async void ReloadLibrary_Click(object sender, RoutedEventArgs e)
    {
        if (!isLibraryExportInProgress && openLibrary is { } library)
        {
            await OpenLibraryAsync(library.RootPath);
        }
    }

    private void CloseLibrary_Click(object sender, RoutedEventArgs e)
    {
        if (isLibraryExportInProgress)
        {
            return;
        }
        openLibrary = null;
        LibraryAssetList.ItemsSource = null;
        LibraryPreviewImage.Source = null;
        ShowPanel(SelectPanel);
    }

    private void LibraryAssetList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (isLibraryExportInProgress)
        {
            return;
        }
        if (LibraryAssetList.SelectedItem is not LibraryAssetListItem item)
        {
            ClearLibrarySelection("Choose an asset to inspect its available representations.");
            return;
        }

        var asset = item.Asset;
        LibraryPreviewImage.Source = LoadPreview(item.ThumbnailPath);
        LibraryFilenameText.Text = item.Filename;
        LibraryDateText.Text = item.DateText;
        var flags = new List<string> { asset.Catalog.MediaType == "video" ? "Video" : "Photo" };
        if (asset.IsEdited)
        {
            flags.Add("Edited current rendition");
        }
        if (asset.IsLivePhoto)
        {
            flags.Add("Live Photo");
        }
        LibraryFlagsText.Text = string.Join(" • ", flags);

        var available = Enum.GetValues<VariantKind>()
            .Where(variant => FindExportableFile(asset, variant) is not null)
            .Select(VariantLabel)
            .ToList();
        var individualOriginals = BuildOriginalChoices(asset);
        IndividualOriginalsComboBox.ItemsSource = individualOriginals;
        IndividualOriginalsComboBox.SelectedIndex = individualOriginals.Count == 0 ? -1 : 0;
        if (individualOriginals.Count > 1)
        {
            available.Add($"{individualOriginals.Count} individual originals");
        }
        LibraryArchiveText.Foreground = asset.ArchiveState == ArchiveState.Complete
            ? Brushes.DarkGreen
            : Brushes.DarkOrange;
        LibraryArchiveText.Text = asset.ArchiveState == ArchiveState.Complete
            ? $"Archive complete at last sync. Exports are hash-verified. Cataloged: {FormatAvailable(available)}."
            : $"Archive incomplete at last sync; unavailable variants are disabled. Cataloged: {FormatAvailable(available)}.";
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
                "That representation is unavailable, missing, or not fully cataloged.",
                "Variant unavailable",
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
            Title = $"Export {label} to…",
            Multiselect = false,
        };
        if (dialog.ShowDialog(this) != true)
        {
            return;
        }

        isLibraryExportInProgress = true;
        SetLibraryInteractionEnabled(false);
        LibraryExportStatusText.Foreground = Brushes.DarkSlateGray;
        LibraryExportStatusText.Text = $"Verifying and exporting {label}…";
        try
        {
            var result = await variantExportService.ExportAsync(file, dialog.FolderName);
            LibraryExportStatusText.Foreground = Brushes.DarkGreen;
            LibraryExportStatusText.Text = result.ExistingVerified
                ? $"An exact verified copy already exists at {result.ExportedPath}"
                : $"Exported an exact verified copy to {result.ExportedPath}";
        }
        catch (Exception exception)
        {
            LibraryExportStatusText.Foreground = Brushes.Firebrick;
            LibraryExportStatusText.Text = exception.Message;
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
        if (isLibraryExportInProgress || openLibrary is not { } library)
        {
            return;
        }

        var path = Path.Combine(library.RootPath, library.Library.MasterRelativePath);
        try
        {
            await Task.Run(() => Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }));
        }
        catch (Exception exception)
        {
            System.Windows.MessageBox.Show(this, exception.Message, "Could not open Master", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private async void Start_Click(object sender, RoutedEventArgs e)
    {
        var selected = DestinationTextBox.Text.Trim();
        if (string.IsNullOrEmpty(selected))
        {
            System.Windows.MessageBox.Show(this, "Choose a portable library root first.", "Library root required", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }

        ShowOperation(
            "Starting receiver",
            "Checking the destination, opening its ledger, and preparing a secure local connection…",
            canCancel: true);
        try
        {
            var result = await lifecycle.StartAsync(selected, InitializeCheckBox.IsChecked == true);
            var current = lifecycle.Snapshot;
            if (current.State != ReceiverLifecycleState.Running || current.Generation != result.Generation)
            {
                return;
            }

            presentedGeneration = result.Generation;
            destinationPath = result.Receiver.Destination.RootPath;
            QrImage.Source = result.PairingQrBitmap;
            PairingCodeText.Text = result.Receiver.QrPayload;
            PairingSubtitle.Text = $"Listening at {result.Receiver.Address}:{result.Receiver.Port}. {FormatBytes(result.Receiver.Destination.Info.FreeBytes)} free. The code expires in five minutes and works once.";
            ShowPanel(PairPanel);
        }
        catch (OperationCanceledException)
        {
            if (lifecycle.Snapshot.State == ReceiverLifecycleState.Stopped)
            {
                ShowPanel(SelectPanel);
            }
        }
        catch (Exception exception)
        {
            ShowError(exception.Message);
        }
    }

    private async void Stop_Click(object sender, RoutedEventArgs e)
    {
        var state = lifecycle.Snapshot.State;
        ShowOperation(
            state == ReceiverLifecycleState.Starting ? "Canceling startup" : "Stopping receiver",
            "Finishing the current durable operation and pausing the receiver safely…",
            canCancel: false);
        try
        {
            await lifecycle.StopAsync();
            presentedGeneration = 0;
            QrImage.Source = null;
            PairingCodeText.Text = string.Empty;
            ShowPanel(SelectPanel);
        }
        catch (Exception exception)
        {
            ShowError(exception.Message);
        }
    }

    private async void OpenFolder_Click(object sender, RoutedEventArgs e)
    {
        if (destinationPath is null)
        {
            return;
        }

        var path = destinationPath;
        try
        {
            await Task.Run(() => Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }));
        }
        catch (Exception exception)
        {
            System.Windows.MessageBox.Show(this, exception.Message, "Could not open backup folder", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private async void Restart_Click(object sender, RoutedEventArgs e)
    {
        ShowOperation(
            "Preparing another export",
            "Closing the current secure receiver session…",
            canCancel: false);
        try
        {
            await lifecycle.StopAsync();
            presentedGeneration = 0;
            QrImage.Source = null;
            PairingCodeText.Text = string.Empty;
            ShowPanel(SelectPanel);
        }
        catch (Exception exception)
        {
            ShowError(exception.Message);
        }
    }

    private void Back_Click(object sender, RoutedEventArgs e) => ShowPanel(SelectPanel);

    private async void ExportDiagnostics_Click(object sender, RoutedEventArgs e)
    {
        var snapshot = lifecycle.Snapshot;
        var receiver = snapshot.Receiver;
        if (receiver is null || snapshot.State != ReceiverLifecycleState.Running)
        {
            System.Windows.MessageBox.Show(this, "Start the receiver before exporting its diagnostics.", "No diagnostics", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }

        var dialog = new Microsoft.Win32.SaveFileDialog
        {
            Title = "Export redacted diagnostics",
            FileName = $"mbphotos-receiver-{DateTime.Now:yyyyMMdd-HHmmss}.log",
            Filter = "Log files (*.log)|*.log|All files (*.*)|*.*",
        };
        if (dialog.ShowDialog(this) == true)
        {
            try
            {
                await Task.Run(() => receiver.Diagnostics.ExportAsync(dialog.FileName));
            }
            catch (Exception exception)
            {
                System.Windows.MessageBox.Show(this, exception.Message, "Could not export diagnostics", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }
    }

    private void Window_Closing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        if (app.IsExiting)
        {
            lifecycle.StateChanged -= Lifecycle_StateChanged;
            activityFeed.ActivityAvailable -= ActivityFeed_ActivityAvailable;
            activityDispatcher.Dispose();
            return;
        }

        app.HandleWindowClosing(e);
    }

    private void Lifecycle_StateChanged(object? sender, ReceiverLifecycleSnapshot state)
    {
        if (Dispatcher.HasShutdownStarted)
        {
            return;
        }

        _ = Dispatcher.BeginInvoke(
            DispatcherPriority.Background,
            new Action(() => ApplyLifecycleState(state)));
    }

    private void ActivityFeed_ActivityAvailable(object? sender, ReceiverActivityEnvelope envelope)
    {
        activityDispatcher.Post(envelope);
    }

    private void ApplyLifecycleState(ReceiverLifecycleSnapshot state)
    {
        StartButton.IsEnabled = state.State is ReceiverLifecycleState.Stopped or ReceiverLifecycleState.Faulted;
        BrowseButton.IsEnabled = StartButton.IsEnabled;
        OpenLibraryButton.IsEnabled = StartButton.IsEnabled;
        DestinationTextBox.IsEnabled = StartButton.IsEnabled;
        InitializeCheckBox.IsEnabled = StartButton.IsEnabled;

        switch (state.State)
        {
            case ReceiverLifecycleState.Starting:
                ShowOperation(
                    "Starting receiver",
                    "Checking the destination, opening its ledger, and preparing a secure local connection…",
                    canCancel: true);
                break;
            case ReceiverLifecycleState.Stopping:
                ShowOperation(
                    "Stopping receiver",
                    "Finishing the current durable operation and pausing the receiver safely…",
                    canCancel: false);
                break;
            case ReceiverLifecycleState.Faulted when state.Error is not null:
                ShowError(state.Error.Message);
                break;
            case ReceiverLifecycleState.Stopped:
                ShowPanel(SelectPanel);
                break;
        }
    }

    private void ApplyActivity(ReceiverActivityEnvelope envelope)
    {
        var current = lifecycle.Snapshot;
        if (current.State != ReceiverLifecycleState.Running ||
            envelope.Generation != current.Generation ||
            (presentedGeneration != 0 && envelope.Generation != presentedGeneration))
        {
            return;
        }

        presentedGeneration = envelope.Generation;
        var activity = envelope.Activity;
        if (activity.State is "completed" or "completedWithFailures")
        {
            CompleteSubtitle.Text = activity.State == "completed"
                ? $"Verified {activity.TotalFiles:N0} files, promoted current Master media, and committed a new portable catalog generation."
                : "The sync finished with declared failures. Existing Master files were preserved where a required current resource was unavailable.";
            ShowPanel(CompletePanel);
            return;
        }

        if (activity.State == "abandoned")
        {
            TransferHeading.Text = "Export stopped";
            TransferSubtitle.Text = "The iPhone ended this export. Stop the receiver and start again to create a new pairing code.";
            TransferProgress.IsIndeterminate = false;
            TransferProgress.Value = 0;
            TransferErrorText.Text = string.Empty;
            ShowPanel(TransferPanel);
            return;
        }

        TransferHeading.Text = activity.State switch
        {
            "planning" => "Planning export",
            "finalizing" => "Finalizing export",
            _ => "Receiving photos",
        };
        TransferProgress.IsIndeterminate = activity.State is "planning" or "finalizing" || activity.TotalFiles <= 0;
        TransferProgress.Maximum = Math.Max(1, activity.TotalFiles);
        TransferProgress.Value = Math.Min(activity.CompletedFiles, (int)TransferProgress.Maximum);
        TransferCountText.Text = activity.State switch
        {
            "planning" => $"Checking {activity.TotalFiles:N0} files against the existing backup",
            "finalizing" => $"Verified {activity.CompletedFiles:N0} of {activity.TotalFiles:N0} files; writing portable metadata",
            _ => $"{activity.CompletedFiles:N0} of {activity.TotalFiles:N0} files verified",
        };
        TransferBytesText.Text = $"{FormatBytes(activity.TransferredBytes)} received in this job";
        CurrentFileText.Text = activity.CurrentRelativePath is null
            ? activity.State == "finalizing" ? "Writing reports and metadata…" : "Waiting for the iPhone…"
            : "Current file: " + Path.GetFileName(activity.CurrentRelativePath);
        FreeSpaceText.Text = $"{FormatBytes(activity.FreeBytes)} free at destination";
        TransferErrorText.Text = activity.ErrorMessage is null ? string.Empty : "Transfer error: " + activity.ErrorMessage;
        TransferSubtitle.Text = $"Saving to {destinationPath}";
        ShowPanel(TransferPanel);
    }

    private void ShowOperation(string heading, string subtitle, bool canCancel)
    {
        OperationHeading.Text = heading;
        OperationSubtitle.Text = subtitle;
        CancelOperationButton.IsEnabled = canCancel;
        CancelOperationButton.Content = canCancel ? "Cancel" : "Please wait…";
        ShowPanel(OperationPanel);
    }

    private void ShowError(string message, string heading = "Receiver could not start")
    {
        ErrorHeading.Text = heading;
        ErrorText.Text = message;
        ShowPanel(ErrorPanel);
    }

    private void ShowPanel(FrameworkElement panel)
    {
        foreach (var item in new FrameworkElement[] { SelectPanel, OperationPanel, PairPanel, TransferPanel, CompletePanel, LibraryPanel, ErrorPanel })
        {
            item.Visibility = ReferenceEquals(item, panel) ? Visibility.Visible : Visibility.Collapsed;
        }
    }

    private static LibraryAssetListItem CreateLibraryListItem(PortableLibraryAsset asset)
    {
        var preferredFile = asset.MasterFile ??
            asset.Files.FirstOrDefault(file => file.Catalog.Roles.Contains(RepresentationRole.RootOriginal)) ??
            asset.Files.FirstOrDefault();
        var filename = preferredFile?.Catalog.OriginalFilename ?? asset.AssetId.ToString("D");
        var dateText = asset.Catalog.CreationDate?.LocalDateTime.ToString("g") ?? "Capture date unavailable";
        var statuses = new List<string>();
        if (asset.IsEdited)
        {
            statuses.Add("Edited");
        }
        if (asset.IsLivePhoto)
        {
            statuses.Add("Live Photo");
        }
        statuses.Add(asset.ArchiveState == ArchiveState.Complete ? "Archive complete" : "Archive incomplete");
        var thumbnail = asset.Files.FirstOrDefault(file =>
            file.Catalog.Provenance == Provenance.GeneratedThumbnail &&
            file.Catalog.Availability == Availability.Available &&
            file.IsPresent);
        return new LibraryAssetListItem(
            asset,
            filename,
            dateText,
            string.Join(" • ", statuses),
            thumbnail?.AbsolutePath);
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
                    ? $"{file.Catalog.OriginalFilename} (primary)"
                    : $"{file.Catalog.OriginalFilename} (alternate)",
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
        var hasIndividualOriginal = IndividualOriginalsComboBox.Items.Count > 0;
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
        SetExportButtonsEnabled(enabled);
    }

    private void ClearLibrarySelection(string message)
    {
        LibraryPreviewImage.Source = null;
        LibraryFilenameText.Text = "No asset selected";
        LibraryDateText.Text = string.Empty;
        LibraryFlagsText.Text = string.Empty;
        LibraryArchiveText.Foreground = Brushes.DarkSlateGray;
        LibraryArchiveText.Text = message;
        LibraryExportStatusText.Text = string.Empty;
        IndividualOriginalsComboBox.ItemsSource = null;
        SetExportButtonsEnabled(false);
    }

    private static BitmapImage? LoadPreview(string? path)
    {
        if (path is null || !File.Exists(path))
        {
            return null;
        }
        try
        {
            var bitmap = new BitmapImage();
            bitmap.BeginInit();
            bitmap.CacheOption = BitmapCacheOption.OnLoad;
            bitmap.DecodePixelWidth = 640;
            bitmap.UriSource = new Uri(path, UriKind.Absolute);
            bitmap.EndInit();
            bitmap.Freeze();
            return bitmap;
        }
        catch
        {
            return null;
        }
    }

    private static string VariantLabel(VariantKind variant) => variant switch
    {
        VariantKind.CurrentMaster => "current Master",
        VariantKind.RootOriginal => "untouched original",
        VariantKind.CurrentLiveMotion => "current Live Photo MOV",
        VariantKind.OriginalLiveMotion => "original Live Photo MOV",
        _ => variant.ToString(),
    };

    private static string FormatAvailable(IReadOnlyCollection<string> available) =>
        available.Count == 0 ? "none" : string.Join(", ", available);

    private static string FormatBytes(long bytes)
    {
        string[] units = { "B", "KB", "MB", "GB", "TB" };
        var value = (double)bytes;
        var index = 0;
        while (value >= 1024 && index < units.Length - 1)
        {
            value /= 1024;
            index++;
        }

        return $"{value:0.##} {units[index]}";
    }
}

internal sealed record LibraryAssetListItem(
    PortableLibraryAsset Asset,
    string Filename,
    string DateText,
    string StatusText,
    string? ThumbnailPath);

internal sealed record OriginalExportChoice(string Label, PortableLibraryFile File);
