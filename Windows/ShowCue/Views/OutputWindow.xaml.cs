using System.ComponentModel;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using ShowCue.Engine;

namespace ShowCue.Views;

/// <summary>Vinduet som vises på projektor/skjerm. Hver visuell cue legger et lag i <see cref="Layers"/>.</summary>
public partial class OutputWindow : Window
{
    private Monitors.MonitorInfo? _monitor;

    /// <summary>Tastetrykk sendes videre til hovedvinduet så GO/hurtigtaster virker selv om utgangen har fokus.</summary>
    public event KeyEventHandler? ForwardKey;
    public bool AllowClose { get; set; }

    public System.Windows.Controls.Grid LayerHost => Layers;

    public OutputWindow()
    {
        InitializeComponent();
        PreviewKeyDown += (s, e) => ForwardKey?.Invoke(s, e);
        SourceInitialized += (_, _) => ApplyMonitor();
    }

    /// <summary>screenIndex = -1 gir et vanlig vindu (nyttig når man bare har én skjerm).</summary>
    public void Configure(int screenIndex)
    {
        var all = Monitors.GetAll();
        _monitor = screenIndex >= 0 && screenIndex < all.Count ? all[screenIndex] : null;

        if (_monitor == null)
        {
            WindowStyle = WindowStyle.SingleBorderWindow;
            ResizeMode = ResizeMode.CanResize;
            Topmost = false;
            Cursor = null;
            if (Width < 200) { Width = 960; Height = 540; }
        }
        else
        {
            WindowStyle = WindowStyle.None;
            ResizeMode = ResizeMode.NoResize;
            Topmost = true;
            Cursor = Cursors.None;
        }
        ApplyMonitor();
    }

    private void ApplyMonitor()
    {
        if (_monitor == null) return;
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd != IntPtr.Zero) Monitors.PlaceWindow(hwnd, _monitor);
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        // Lukking skjuler bare vinduet; det gjenbrukes til neste visuelle cue.
        if (!AllowClose) { e.Cancel = true; Hide(); }
        base.OnClosing(e);
    }
}
