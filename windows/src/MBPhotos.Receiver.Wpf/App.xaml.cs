using System.ComponentModel;
using System.Windows;
using System.Windows.Threading;
using MBPhotos.Receiver.Hosting;
using MBPhotos.Receiver.Transfer;
using Forms = System.Windows.Forms;

namespace MBPhotos.Receiver.Wpf;

public partial class App : Application
{
    private Forms.NotifyIcon? trayIcon;
    private Forms.ContextMenuStrip? trayMenu;
    private Forms.ToolStripMenuItem? stopMenuItem;
    private WindowsKeepAwake? keepAwake;
    private ReceiverActivityDispatcher? activityDispatcher;
    private ApplicationLifetimeCoordinator applicationLifetime = null!;
    private bool closeHintShown;

    internal ReceiverActivityFeed ActivityFeed { get; private set; } = null!;

    internal ReceiverLifecycleController Lifecycle { get; private set; } = null!;

    internal bool IsExiting => applicationLifetime.IsExiting;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        ActivityFeed = new ReceiverActivityFeed();
        Lifecycle = new ReceiverLifecycleController(ActivityFeed);
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
        applicationLifetime = new ApplicationLifetimeCoordinator(
            hideWindow: () => MainWindow?.Hide(),
            disposeLifecycle: () => Lifecycle.DisposeAsync(),
            cleanupApplicationResources: CleanupApplicationResources,
            reportError: exception =>
                System.Diagnostics.Debug.WriteLine($"Receiver shutdown failed: {exception.GetType().Name}"),
            shutdown: Shutdown);
        ActivityFeed.ActivityAvailable += ActivityFeed_ActivityAvailable;
        Lifecycle.StateChanged += Lifecycle_StateChanged;

        CreateTrayIcon();
        var window = new MainWindow();
        MainWindow = window;
        window.Show();
    }

    internal void HandleWindowClosing(CancelEventArgs e)
    {
        if (!applicationLifetime.HandleCloseRequested())
        {
            return;
        }

        e.Cancel = true;
        if (!closeHintShown)
        {
            closeHintShown = true;
            var active = Lifecycle.Snapshot.State is ReceiverLifecycleState.Starting or ReceiverLifecycleState.Running;
            ShowNotification(
                active ? "Receiver is still running" : "Receiver is in the notification area",
                active
                    ? "The transfer continues in the notification area. Use Stop or Exit there when you are finished."
                    : "Double-click the tray icon to show the receiver, or choose Exit to close it.",
                Forms.ToolTipIcon.Info);
        }
    }

    internal void ShowMainWindow()
    {
        if (MainWindow is null)
        {
            return;
        }

        MainWindow.Show();
        if (MainWindow.WindowState == WindowState.Minimized)
        {
            MainWindow.WindowState = WindowState.Normal;
        }
        MainWindow.Activate();
    }

    internal async Task ExitAsync()
    {
        if (applicationLifetime.IsExiting)
        {
            await applicationLifetime.ExitAsync();
            return;
        }

        if (trayIcon is not null)
        {
            trayIcon.Text = "MB Photos Receiver — Exiting";
        }
        if (trayMenu is not null)
        {
            trayMenu.Enabled = false;
        }

        await applicationLifetime.ExitAsync();
    }

    private void CleanupApplicationResources()
    {
        if (trayIcon is not null)
        {
            trayIcon.Visible = false;
        }
        ActivityFeed.ActivityAvailable -= ActivityFeed_ActivityAvailable;
        Lifecycle.StateChanged -= Lifecycle_StateChanged;
        activityDispatcher?.Dispose();
        activityDispatcher = null;
        ActivityFeed.Dispose();
        keepAwake?.Dispose();
        keepAwake = null;
        trayIcon?.Dispose();
        trayMenu?.Dispose();
        trayMenu = null;
        trayIcon = null;
    }

    private void CreateTrayIcon()
    {
        trayMenu = new Forms.ContextMenuStrip();
        var showItem = new Forms.ToolStripMenuItem("Show receiver");
        stopMenuItem = new Forms.ToolStripMenuItem("Stop receiver") { Enabled = false };
        var exitItem = new Forms.ToolStripMenuItem("Exit");
        showItem.Click += (_, _) => Dispatcher.BeginInvoke(new Action(ShowMainWindow));
        stopMenuItem.Click += StopMenuItem_Click;
        exitItem.Click += ExitMenuItem_Click;
        trayMenu.Items.Add(showItem);
        trayMenu.Items.Add(stopMenuItem);
        trayMenu.Items.Add(new Forms.ToolStripSeparator());
        trayMenu.Items.Add(exitItem);

        trayIcon = new Forms.NotifyIcon
        {
            ContextMenuStrip = trayMenu,
            Icon = System.Drawing.SystemIcons.Application,
            Text = "MB Photos Receiver",
            Visible = true,
        };
        trayIcon.DoubleClick += (_, _) => Dispatcher.BeginInvoke(new Action(ShowMainWindow));
    }

    private async void StopMenuItem_Click(object? sender, EventArgs e)
    {
        try
        {
            await Lifecycle.StopAsync();
            ShowNotification("Receiver stopped", "The active receiver session was paused safely.", Forms.ToolTipIcon.Info);
        }
        catch (Exception exception)
        {
            ShowNotification("Could not stop receiver", exception.Message, Forms.ToolTipIcon.Error);
        }
    }

    private async void ExitMenuItem_Click(object? sender, EventArgs e) => await ExitAsync();

    private void Lifecycle_StateChanged(object? sender, ReceiverLifecycleSnapshot state)
    {
        _ = Dispatcher.BeginInvoke(new Action(() =>
        {
            if (stopMenuItem is not null)
            {
                stopMenuItem.Enabled = state.State is ReceiverLifecycleState.Starting or ReceiverLifecycleState.Running;
                stopMenuItem.Text = state.State == ReceiverLifecycleState.Starting ? "Cancel startup" : "Stop receiver";
            }
            if (trayIcon is not null)
            {
                trayIcon.Text = state.State switch
                {
                    ReceiverLifecycleState.Starting => "MB Photos Receiver — Starting",
                    ReceiverLifecycleState.Running => "MB Photos Receiver — Running",
                    ReceiverLifecycleState.Stopping => "MB Photos Receiver — Stopping",
                    ReceiverLifecycleState.Faulted => "MB Photos Receiver — Error",
                    _ => "MB Photos Receiver — Stopped",
                };
            }

            if (state.State is ReceiverLifecycleState.Stopped or ReceiverLifecycleState.Faulted)
            {
                keepAwake?.Dispose();
                keepAwake = null;
            }

            if (state.State == ReceiverLifecycleState.Faulted && state.Error is not null && MainWindow?.IsVisible != true)
            {
                ShowMainWindow();
                ShowNotification("Receiver error", state.Error.Message, Forms.ToolTipIcon.Error);
            }
        }));
    }

    private void ActivityFeed_ActivityAvailable(object? sender, ReceiverActivityEnvelope envelope)
        => activityDispatcher?.Post(envelope);

    private void ApplyActivity(ReceiverActivityEnvelope envelope)
    {
        var snapshot = Lifecycle.Snapshot;
        if (snapshot.State != ReceiverLifecycleState.Running || envelope.Generation != snapshot.Generation)
        {
            return;
        }

        var activity = envelope.Activity;
        if (activity.ErrorMessage is not null ||
            activity.State is "completed" or "completedWithFailures" or "abandoned")
        {
            ShowMainWindow();
        }

        if (activity.ErrorMessage is not null)
        {
            ShowNotification("Transfer error", activity.ErrorMessage, Forms.ToolTipIcon.Error);
        }

        if (activity.State is "completed" or "completedWithFailures" or "abandoned")
        {
            keepAwake?.Dispose();
            keepAwake = null;

            if (activity.State == "completed")
            {
                ShowNotification("Export complete", $"Verified {activity.TotalFiles:N0} files.", Forms.ToolTipIcon.Info);
            }
            else if (activity.State == "completedWithFailures")
            {
                ShowNotification("Export completed with failures", "Open the receiver to review the completion report.", Forms.ToolTipIcon.Warning);
            }
            else
            {
                ShowNotification("Export stopped", "The iPhone abandoned the current export.", Forms.ToolTipIcon.Info);
            }
            return;
        }

        keepAwake ??= new WindowsKeepAwake();
    }

    private void ShowNotification(string title, string message, Forms.ToolTipIcon icon)
    {
        if (trayIcon is null || !trayIcon.Visible)
        {
            return;
        }

        trayIcon.BalloonTipTitle = title;
        trayIcon.BalloonTipText = message;
        trayIcon.BalloonTipIcon = icon;
        trayIcon.ShowBalloonTip(5000);
    }
}
