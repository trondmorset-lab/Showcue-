using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using ShowCue.Models;

namespace ShowCue;

/// <summary>
/// Bytter fargetema mens programmet kjører. Alle farger er DynamicResource,
/// så det holder å bytte ut fargeordboka. Tittellinja følger tema (mørk/lys).
/// </summary>
public static class ThemeManager
{
    public static AppTheme Current { get; private set; } = AppTheme.Dark;
    public static event Action? Changed;

    public static void Apply(AppTheme theme)
    {
        var app = Application.Current;
        if (app == null) return;
        var dict = new ResourceDictionary { Source = new Uri($"pack://application:,,,/Themes/Colors.{theme}.xaml", UriKind.Absolute) };
        var md = app.Resources.MergedDictionaries;
        if (md.Count > 0) md[0] = dict; else md.Insert(0, dict);
        Current = theme;
        foreach (Window w in app.Windows) ApplyTitleBar(w);
        Changed?.Invoke();
    }

    public static AppTheme Next(AppTheme t) => t switch
    {
        AppTheme.Dark => AppTheme.Light,
        AppTheme.Light => AppTheme.Night,
        _ => AppTheme.Dark,
    };

    /// <summary>Kall i vinduets konstruktør, så tittellinja får riktig farge.</summary>
    public static void Register(Window w)
    {
        w.SourceInitialized += (_, _) => ApplyTitleBar(w);
    }

    public static void ApplyTitleBar(Window w)
    {
        try
        {
            var hwnd = new WindowInteropHelper(w).Handle;
            if (hwnd == IntPtr.Zero) return;
            int dark = Current == AppTheme.Light ? 0 : 1;
            // 20 = DWMWA_USE_IMMERSIVE_DARK_MODE (Windows 10 20H1+), 19 på eldre Windows 10.
            if (DwmSetWindowAttribute(hwnd, 20, ref dark, sizeof(int)) != 0)
                DwmSetWindowAttribute(hwnd, 19, ref dark, sizeof(int));
        }
        catch { /* eldre Windows: ignorer */ }
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
}
