using System.ComponentModel;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Threading;
using MBPhotos.Receiver.Diagnostics;
using MBPhotos.Receiver.Hosting;
using MBPhotos.Receiver.Transfer;
using Microsoft.Extensions.Logging;
using Forms = System.Windows.Forms;

namespace MBPhotos.Receiver.Wpf;

public partial class App : System.Windows.Application
{
    private readonly RedactingFileLoggerProvider diagnostics = new();
    private readonly ILogger logger;
    private Forms.NotifyIcon? trayIcon;
    private Forms.ContextMenuStrip? trayMenu;
    private Forms.ToolStripMenuItem? stopMenuItem;
    private Icon? trayAppIcon;
    private WindowsKeepAwake? keepAwake;
    private ReceiverActivityDispatcher? activityDispatcher;
    private ApplicationLifetimeCoordinator applicationLifetime = null!;
    private SystemThemeService themeService = null!;
    private bool closeHintShown;
    private long appliedTrayStateRevision = -1;
    private long terminalNotificationGeneration = long.MinValue;
    private readonly HashSet<Guid> notifiedTerminalJobs = [];
    private int lastLoggedPresentationState = -1;

    public App()
    {
        logger = diagnostics.CreateLogger("MBPhotos.Receiver.Wpf.App");
        DispatcherUnhandledException += App_DispatcherUnhandledException;
        AppDomain.CurrentDomain.UnhandledException += CurrentDomain_UnhandledException;
        TaskScheduler.UnobservedTaskException += TaskScheduler_UnobservedTaskException;
    }

    internal ReceiverActivityFeed ActivityFeed { get; private set; } = null!;

    internal RedactingFileLoggerProvider Diagnostics => diagnostics;

    internal ReceiverLifecycleController Lifecycle { get; private set; } = null!;

    internal ReceiverOrchestrator ReceiverOrchestrator { get; private set; } = null!;

    internal ReceiverSettingsStore SettingsStore { get; private set; } = null!;

    internal bool IsExiting => applicationLifetime.IsExiting;

    protected override void OnStartup(StartupEventArgs e)
    {
        try
        {
            base.OnStartup(e);
            logger.LogInformation(
                "Desktop receiver starting version={Version} framework={Framework} os={OperatingSystem} processId={ProcessId}",
                typeof(App).Assembly.GetName().Version,
                RuntimeInformation.FrameworkDescription,
                RuntimeInformation.OSDescription,
                Environment.ProcessId);

            ActivityFeed = new ReceiverActivityFeed();
            Lifecycle = new ReceiverLifecycleController(ActivityFeed, diagnostics);
            SettingsStore = new ReceiverSettingsStore();
            ReceiverOrchestrator = new ReceiverOrchestrator(Lifecycle, ActivityFeed, SettingsStore);
            themeService = new SystemThemeService(this);
            themeService.Start();
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
                disposeLifecycle: () => ReceiverOrchestrator.DisposeAsync(),
                cleanupApplicationResources: CleanupApplicationResources,
                reportError: exception => logger.LogError(exception, "Receiver shutdown stage failed"),
                shutdown: Shutdown);
            ActivityFeed.ActivityAvailable += ActivityFeed_ActivityAvailable;
            ReceiverOrchestrator.StateChanged += ReceiverOrchestrator_StateChanged;

            CreateTrayIcon();
            var window = new MainWindow();
            window.Icon = AppIconFactory.CreateWindowIcon();
            MainWindow = window;
            themeService.TrackWindow(window);
            window.Show();
            _ = InitializeReceiverAsync();
        }
        catch (Exception exception)
        {
            LogFatalAndFlush("Desktop receiver startup failed", exception);
            throw;
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        try
        {
            logger.LogInformation("Desktop receiver exited normally exitCode={ExitCode}", e.ApplicationExitCode);
            diagnostics.Dispose();
        }
        finally
        {
            DispatcherUnhandledException -= App_DispatcherUnhandledException;
            AppDomain.CurrentDomain.UnhandledException -= CurrentDomain_UnhandledException;
            TaskScheduler.UnobservedTaskException -= TaskScheduler_UnobservedTaskException;
            base.OnExit(e);
        }
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
            var active = ReceiverOrchestrator.Snapshot.State is
                ReceiverPresentationState.Starting or
                ReceiverPresentationState.Ready or
                ReceiverPresentationState.Connected or
                ReceiverPresentationState.Transferring or
                ReceiverPresentationState.Finalizing;
            ShowNotification(
                active ? "MB Photos is still receiving" : "MB Photos is still open",
                active
                    ? "You can reopen it from the notification area."
                    : "Double-click the MB Photos icon to reopen the app.",
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
        ReceiverOrchestrator.StateChanged -= ReceiverOrchestrator_StateChanged;
        activityDispatcher?.Dispose();
        activityDispatcher = null;
        ActivityFeed.Dispose();
        if (MainWindow is { } window)
        {
            themeService.UntrackWindow(window);
        }
        themeService.Dispose();
        keepAwake?.Dispose();
        keepAwake = null;
        trayIcon?.Dispose();
        trayAppIcon?.Dispose();
        trayAppIcon = null;
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

        trayAppIcon = AppIconFactory.CreateTrayIcon();

        trayIcon = new Forms.NotifyIcon
        {
            ContextMenuStrip = trayMenu,
            Icon = trayAppIcon,
            Text = "MB Photos Receiver",
            Visible = true,
        };
        trayIcon.DoubleClick += (_, _) => Dispatcher.BeginInvoke(new Action(ShowMainWindow));
    }

    private async void StopMenuItem_Click(object? sender, EventArgs e)
    {
        try
        {
            var state = ReceiverOrchestrator.Snapshot.State;
            if (state is ReceiverPresentationState.Paused or ReceiverPresentationState.Error)
            {
                await ReceiverOrchestrator.StartOrResumeAsync();
                if (ReceiverOrchestrator.Snapshot.State == ReceiverPresentationState.Error)
                {
                    throw ReceiverOrchestrator.Snapshot.Error ?? new InvalidOperationException("Receiving could not start.");
                }
                ShowNotification("Ready to receive", "Open MB Photos to scan the new code.", Forms.ToolTipIcon.Info);
            }
            else if (state == ReceiverPresentationState.Setup)
            {
                ShowMainWindow();
            }
            else
            {
                await ReceiverOrchestrator.StopAsync(manualPause: true);
                ShowNotification("Receiving paused", "Start again from MB Photos or the notification area.", Forms.ToolTipIcon.Info);
            }
        }
        catch (Exception exception)
        {
            logger.LogError(exception, "Notification-area receiver action failed");
            ShowNotification("Receiver action failed", "Open MB Photos and try again.", Forms.ToolTipIcon.Error);
        }
    }

    private async void ExitMenuItem_Click(object? sender, EventArgs e) => await ExitAsync();

    private void ReceiverOrchestrator_StateChanged(object? sender, ReceiverOrchestrationSnapshot state)
    {
        var previousState = Interlocked.Exchange(ref lastLoggedPresentationState, (int)state.State);
        if (previousState != (int)state.State)
        {
            logger.LogInformation(
                "Receiver presentation changed state={State} generation={Generation} revision={Revision}",
                state.State,
                state.Generation,
                state.Revision);
        }
        if (state.Error is not null)
        {
            logger.LogError(
                state.Error,
                "Receiver presentation reported an error state={State} generation={Generation}",
                state.State,
                state.Generation);
        }

        _ = Dispatcher.BeginInvoke(new Action(() =>
        {
            if (state.Revision < appliedTrayStateRevision)
            {
                return;
            }
            appliedTrayStateRevision = state.Revision;

            if (stopMenuItem is not null)
            {
                stopMenuItem.Enabled = state.State != ReceiverPresentationState.Library;
                stopMenuItem.Text = state.State switch
                {
                    ReceiverPresentationState.Setup => "Show setup",
                    ReceiverPresentationState.Paused or ReceiverPresentationState.Error => "Start receiving",
                    ReceiverPresentationState.Library => "Library open",
                    _ => "Pause receiving",
                };
            }
            if (trayIcon is not null)
            {
                trayIcon.Text = state.State switch
                {
                    ReceiverPresentationState.Starting => "MB Photos — Starting",
                    ReceiverPresentationState.Ready => "MB Photos — Ready to scan",
                    ReceiverPresentationState.Connected => "MB Photos — iPhone connected",
                    ReceiverPresentationState.Transferring => "MB Photos — Receiving",
                    ReceiverPresentationState.Finalizing => "MB Photos — Finishing transfer",
                    ReceiverPresentationState.Paused => "MB Photos — Paused",
                    ReceiverPresentationState.Error => "MB Photos — Needs attention",
                    ReceiverPresentationState.Library => "MB Photos — Library",
                    _ => "MB Photos",
                };
            }

            if (state.State is not (
                ReceiverPresentationState.Transferring or
                ReceiverPresentationState.Finalizing))
            {
                keepAwake?.Dispose();
                keepAwake = null;
            }

            if (state.State == ReceiverPresentationState.Error && state.Error is not null && MainWindow?.IsVisible != true)
            {
                ShowMainWindow();
                ShowNotification("Receiver needs attention", "Open MB Photos to retry or choose another folder.", Forms.ToolTipIcon.Error);
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
        var terminal = activity.State is "completed" or "completedWithFailures" or "abandoned";
        if (terminalNotificationGeneration != envelope.Generation)
        {
            terminalNotificationGeneration = envelope.Generation;
            notifiedTerminalJobs.Clear();
        }
        var firstTerminalNotification = !terminal || notifiedTerminalJobs.Add(activity.JobId);

        if (activity.ErrorMessage is not null || (terminal && firstTerminalNotification))
        {
            ShowMainWindow();
        }

        if (activity.ErrorMessage is not null)
        {
            logger.LogWarning(
                "Transfer activity reported an error jobId={JobId} state={State} generation={Generation}",
                activity.JobId,
                activity.State,
                envelope.Generation);
            ShowNotification("Transfer needs attention", "Open MB Photos to see what you can do next.", Forms.ToolTipIcon.Error);
        }

        if (terminal)
        {
            keepAwake?.Dispose();
            keepAwake = null;

            if (!firstTerminalNotification)
            {
                return;
            }

            logger.LogInformation(
                "Transfer reached terminal state jobId={JobId} state={State} generation={Generation}",
                activity.JobId,
                activity.State,
                envelope.Generation);

            if (activity.State == "completed")
            {
                var itemCount = activity.CompletionCounts?.AssetsPromoted;
                ShowNotification(
                    "Transfer complete",
                    itemCount is { } count ? $"Saved {count:N0} item{(count == 1 ? string.Empty : "s")}." : "Your photos are ready.",
                    Forms.ToolTipIcon.Info);
            }
            else if (activity.State == "completedWithFailures")
            {
                ShowNotification("Transfer finished with issues", "Some items could not be saved. Open MB Photos for details.", Forms.ToolTipIcon.Warning);
            }
            else
            {
                ShowNotification("Transfer stopped", "Start another transfer from your iPhone whenever you’re ready.", Forms.ToolTipIcon.Info);
            }
            return;
        }

        if (activity.State == "rejected")
        {
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

    private async Task InitializeReceiverAsync()
    {
        try
        {
            await ReceiverOrchestrator.InitializeAsync();
        }
        catch (Exception exception)
        {
            logger.LogError(exception, "Automatic receiver startup failed");
            ShowMainWindow();
            ShowNotification("Receiver could not start", "Open MB Photos to retry or choose another folder.", Forms.ToolTipIcon.Error);
        }
    }

    private void App_DispatcherUnhandledException(
        object sender,
        DispatcherUnhandledExceptionEventArgs e) =>
        LogFatalAndFlush("Unhandled WPF dispatcher exception", e.Exception);

    private void CurrentDomain_UnhandledException(object sender, UnhandledExceptionEventArgs e)
    {
        var exception = e.ExceptionObject as Exception;
        LogFatalAndFlush(
            e.IsTerminating
                ? "Unhandled process exception; runtime is terminating"
                : "Unhandled process exception",
            exception);
    }

    private void TaskScheduler_UnobservedTaskException(object? sender, UnobservedTaskExceptionEventArgs e)
    {
        logger.LogError(e.Exception, "Unobserved background task exception");
        FlushDiagnosticsBestEffort();
        e.SetObserved();
    }

    private void LogFatalAndFlush(string message, Exception? exception)
    {
        logger.LogCritical(exception, "{FatalMessage}", message);
        FlushDiagnosticsBestEffort();
    }

    private void FlushDiagnosticsBestEffort()
    {
        try
        {
            _ = diagnostics.FlushAsync().Wait(TimeSpan.FromSeconds(3));
        }
        catch
        {
            // Fatal error reporting cannot safely throw another exception.
        }
    }
}
