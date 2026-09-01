using System.ComponentModel;
using System.IO;
using System.Security;
using System.Windows;
using Microsoft.Win32;
using WpfApplication = System.Windows.Application;

namespace MBPhotos.Receiver.Wpf;

/// <summary>
/// Keeps application resources and tracked native title bars synchronized with the
/// user's Windows light, dark, and high-contrast preferences.
/// </summary>
public sealed class SystemThemeService : IDisposable
{
    private const string PersonalizeRegistryKey =
        @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";
    private const string AppsUseLightThemeRegistryValue = "AppsUseLightTheme";

    private readonly WpfApplication application;
    private readonly Func<AppTheme> detectTheme;
    private readonly HashSet<Window> trackedWindows = [];
    private bool started;
    private bool disposed;
    private ResourceDictionary? appliedThemeDictionary;

    public SystemThemeService(WpfApplication application, Func<AppTheme>? detector = null)
    {
        this.application = application ?? throw new ArgumentNullException(nameof(application));
        detectTheme = detector ?? DetectSystemTheme;
        CurrentTheme = AppTheme.Light;
    }

    public event EventHandler<AppTheme>? ThemeChanged;

    public AppTheme CurrentTheme { get; private set; }

    public void Start()
    {
        ThrowIfDisposed();
        application.Dispatcher.VerifyAccess();
        if (started)
        {
            return;
        }

        started = true;
        SystemParameters.StaticPropertyChanged += SystemParameters_StaticPropertyChanged;
        SystemEvents.UserPreferenceChanged += SystemEvents_UserPreferenceChanged;
        ApplyDetectedTheme(force: true);
    }

    public void Refresh()
    {
        ThrowIfDisposed();
        if (!application.Dispatcher.CheckAccess())
        {
            _ = application.Dispatcher.BeginInvoke(new Action(Refresh));
            return;
        }

        ApplyDetectedTheme(force: false);
    }

    public void TrackWindow(Window window)
    {
        ArgumentNullException.ThrowIfNull(window);
        ThrowIfDisposed();
        application.Dispatcher.VerifyAccess();

        if (!trackedWindows.Add(window))
        {
            return;
        }

        window.SourceInitialized += Window_SourceInitialized;
        window.Closed += Window_Closed;
        WindowThemeHelper.Apply(window, CurrentTheme);
    }

    public void UntrackWindow(Window window)
    {
        ArgumentNullException.ThrowIfNull(window);
        application.Dispatcher.VerifyAccess();

        if (!trackedWindows.Remove(window))
        {
            return;
        }

        window.SourceInitialized -= Window_SourceInitialized;
        window.Closed -= Window_Closed;
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }

        disposed = true;
        if (started)
        {
            SystemParameters.StaticPropertyChanged -= SystemParameters_StaticPropertyChanged;
            SystemEvents.UserPreferenceChanged -= SystemEvents_UserPreferenceChanged;
            started = false;
        }

        foreach (var window in trackedWindows.ToArray())
        {
            window.SourceInitialized -= Window_SourceInitialized;
            window.Closed -= Window_Closed;
        }
        trackedWindows.Clear();
    }

    private static AppTheme DetectSystemTheme()
    {
        if (SystemParameters.HighContrast)
        {
            return AppTheme.HighContrast;
        }

        try
        {
            var registryValue = Registry.GetValue(
                PersonalizeRegistryKey,
                AppsUseLightThemeRegistryValue,
                defaultValue: 1);
            return registryValue is int value && value == 0
                ? AppTheme.Dark
                : AppTheme.Light;
        }
        catch (Exception exception) when (exception is
            IOException or
            UnauthorizedAccessException or
            SecurityException)
        {
            return AppTheme.Light;
        }
    }

    private void ApplyDetectedTheme(bool force)
    {
        var theme = detectTheme();
        if (!Enum.IsDefined(theme))
        {
            theme = AppTheme.Light;
        }

        if (!force && theme == CurrentTheme && appliedThemeDictionary is not null)
        {
            return;
        }

        var newDictionary = LoadThemeDictionary(theme);
        var dictionaries = application.Resources.MergedDictionaries;
        foreach (var oldDictionary in dictionaries.Where(IsThemeDictionary).ToArray())
        {
            dictionaries.Remove(oldDictionary);
        }
        dictionaries.Add(newDictionary);
        appliedThemeDictionary = newDictionary;

        var changed = theme != CurrentTheme;
        CurrentTheme = theme;
        foreach (var window in trackedWindows)
        {
            WindowThemeHelper.Apply(window, theme);
        }

        if (changed || force)
        {
            ThemeChanged?.Invoke(this, theme);
        }
    }

    private static ResourceDictionary LoadThemeDictionary(AppTheme theme)
    {
        var fileName = theme switch
        {
            AppTheme.Dark => "Dark.xaml",
            AppTheme.HighContrast => "HighContrast.xaml",
            _ => "Light.xaml",
        };
        var assemblyName = typeof(SystemThemeService).Assembly.GetName().Name;
        return new ResourceDictionary
        {
            Source = new Uri($"/{assemblyName};component/Themes/{fileName}", UriKind.Relative),
        };
    }

    private static bool IsThemeDictionary(ResourceDictionary dictionary)
    {
        var source = dictionary.Source?.OriginalString.Replace('\\', '/');
        return source is not null &&
            (source.EndsWith("Themes/Light.xaml", StringComparison.OrdinalIgnoreCase) ||
             source.EndsWith("Themes/Dark.xaml", StringComparison.OrdinalIgnoreCase) ||
             source.EndsWith("Themes/HighContrast.xaml", StringComparison.OrdinalIgnoreCase));
    }

    private void SystemParameters_StaticPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(SystemParameters.HighContrast))
        {
            QueueRefresh();
        }
    }

    private void SystemEvents_UserPreferenceChanged(object sender, UserPreferenceChangedEventArgs e)
    {
        if (e.Category is UserPreferenceCategory.Color or
            UserPreferenceCategory.General or
            UserPreferenceCategory.VisualStyle or
            UserPreferenceCategory.Accessibility)
        {
            QueueRefresh();
        }
    }

    private void QueueRefresh()
    {
        if (disposed || application.Dispatcher.HasShutdownStarted)
        {
            return;
        }

        _ = application.Dispatcher.BeginInvoke(new Action(() =>
        {
            if (!disposed)
            {
                Refresh();
            }
        }));
    }

    private void Window_SourceInitialized(object? sender, EventArgs e)
    {
        if (sender is Window window)
        {
            WindowThemeHelper.Apply(window, CurrentTheme);
        }
    }

    private void Window_Closed(object? sender, EventArgs e)
    {
        if (sender is Window window)
        {
            UntrackWindow(window);
        }
    }

    private void ThrowIfDisposed()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
    }
}
