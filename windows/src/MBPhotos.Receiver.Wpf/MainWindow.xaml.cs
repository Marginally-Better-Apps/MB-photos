using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Threading;
using MBPhotos.Receiver.Transfer;
using Microsoft.Win32;

namespace MBPhotos.Receiver.Wpf;

public partial class MainWindow : Window
{
    private readonly App app;
    private readonly ReceiverLifecycleController lifecycle;
    private readonly ReceiverActivityFeed activityFeed;
    private readonly ReceiverActivityDispatcher activityDispatcher;
    private string? destinationPath;
    private long presentedGeneration;

    public MainWindow()
    {
        InitializeComponent();
        app = (App)Application.Current;
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
            Title = "Choose an MB Photos backup folder",
            Multiselect = false,
        };
        if (dialog.ShowDialog(this) == true)
        {
            DestinationTextBox.Text = dialog.FolderName;
        }
    }

    private async void Start_Click(object sender, RoutedEventArgs e)
    {
        var selected = DestinationTextBox.Text.Trim();
        if (string.IsNullOrEmpty(selected))
        {
            MessageBox.Show(this, "Choose a backup folder first.", "Backup folder required", MessageBoxButton.OK, MessageBoxImage.Information);
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
            MessageBox.Show(this, exception.Message, "Could not open backup folder", MessageBoxButton.OK, MessageBoxImage.Error);
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
            MessageBox.Show(this, "Start the receiver before exporting its diagnostics.", "No diagnostics", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }

        var dialog = new SaveFileDialog
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
                MessageBox.Show(this, exception.Message, "Could not export diagnostics", MessageBoxButton.OK, MessageBoxImage.Error);
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
                ? $"Verified {activity.TotalFiles:N0} files. A JSON report and portable metadata manifests were written to the backup."
                : "The export finished with declared failures. Review the JSON report for the files the iPhone could not provide.";
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

    private void ShowError(string message)
    {
        ErrorText.Text = message;
        ShowPanel(ErrorPanel);
    }

    private void ShowPanel(FrameworkElement panel)
    {
        foreach (var item in new[] { SelectPanel, OperationPanel, PairPanel, TransferPanel, CompletePanel, ErrorPanel })
        {
            item.Visibility = ReferenceEquals(item, panel) ? Visibility.Visible : Visibility.Collapsed;
        }
    }

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
