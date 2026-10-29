using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using ShowCue.Models;

namespace ShowCue;

/// <summary>
/// Routingmatrise for en lyd-cue eller lydsporet i en video-cue: rader = kanaler i lydfila, kolonner = utganger i lydpatchen.
/// Hver rute er et nivå i dB; tom rute = ikke routet.
/// </summary>
public sealed class RoutingMatrix : UserControl
{
    public static readonly DependencyProperty CueProperty = DependencyProperty.Register(
        nameof(Cue), typeof(IRoutedAudio), typeof(RoutingMatrix), new PropertyMetadata(null, (d, e) => ((RoutingMatrix)d).OnCueChanged(e)));

    public static readonly DependencyProperty BusesProperty = DependencyProperty.Register(
        nameof(Buses), typeof(IReadOnlyList<PatchBus>), typeof(RoutingMatrix), new PropertyMetadata(null, (d, _) => ((RoutingMatrix)d).Rebuild()));

    public IRoutedAudio? Cue { get => (IRoutedAudio?)GetValue(CueProperty); set => SetValue(CueProperty, value); }
    public IReadOnlyList<PatchBus>? Buses { get => (IReadOnlyList<PatchBus>?)GetValue(BusesProperty); set => SetValue(BusesProperty, value); }

    private const int MaxRows = 16;
    private readonly Grid _grid = new();
    private bool _updating;

    public RoutingMatrix()
    {
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 6, 0, 0) };
        buttons.Children.Add(MakeButton("Standard", "Mono → 1+2, stereo → 1/2 osv.", () => SetRoutes(null)));
        buttons.Children.Add(MakeButton("Alt av", "Fjern all routing", () => SetRoutes(new List<AudioRoute>())));
        buttons.Children.Add(MakeButton("Sum til mono", "Alle kanaler til utgang 1 og 2 (−6 dB hver)", () =>
        {
            int ch = Math.Max(1, Cue?.FileChannels ?? 1);
            SetRoutes(Enumerable.Range(1, ch).SelectMany(c => new[] { new AudioRoute(c, 1, ch > 1 ? -6 : 0), new AudioRoute(c, 2, ch > 1 ? -6 : 0) }).ToList());
        }));

        var root = new StackPanel();
        root.Children.Add(new ScrollViewer
        {
            Content = _grid,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
        });
        root.Children.Add(buttons);
        Content = root;
        // Tegn på nytt ved temabytte (rutene får farger fra temaet).
        Loaded += (_, _) => ThemeManager.Changed += Rebuild;
        Unloaded += (_, _) => ThemeManager.Changed -= Rebuild;
    }

    private Button MakeButton(string text, string tip, Action onClick)
    {
        var b = new Button { Content = text, ToolTip = tip, Margin = new Thickness(0, 0, 6, 0), Padding = new Thickness(8, 3, 8, 3), FontSize = 11.5 };
        b.Click += (_, _) => onClick();
        return b;
    }

    private void OnCueChanged(DependencyPropertyChangedEventArgs e)
    {
        if (e.OldValue is IRoutedAudio old) old.PropertyChanged -= Cue_PropertyChanged;
        if (e.NewValue is IRoutedAudio cue) cue.PropertyChanged += Cue_PropertyChanged;
        Rebuild();
    }

    private void Cue_PropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (_updating) return;
        if (e.PropertyName is nameof(AudioCue.Routes) or nameof(AudioCue.FileChannels)) Rebuild();
    }

    private void Rebuild()
    {
        // Husk hvilken rute som har fokus, så Tab/klikk mellom ruter fungerer etter ny tegning.
        var focusedKey = _grid.Children.OfType<TextBox>().FirstOrDefault(t => t.IsKeyboardFocusWithin)?.Tag;
        _grid.Children.Clear();
        _grid.RowDefinitions.Clear();
        _grid.ColumnDefinitions.Clear();
        var cue = Cue;
        var buses = Buses;
        if (cue == null || buses == null) return;

        int rows = Math.Clamp(cue.FileChannels > 0 ? cue.FileChannels : 2, 1, MaxRows);
        var routes = cue.EffectiveRoutes(rows);

        _grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        for (int b = 0; b < buses.Count; b++) _grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(40) });
        for (int r = 0; r <= rows; r++) _grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var muted = (System.Windows.Media.Brush)FindResource("Muted");
        for (int b = 0; b < buses.Count; b++)
        {
            var h = new TextBlock
            {
                Text = (b + 1).ToString(),
                ToolTip = $"Utgang {b + 1}: {buses[b].Name}",
                HorizontalAlignment = HorizontalAlignment.Center,
                Foreground = muted,
                FontSize = 11,
                Margin = new Thickness(0, 0, 0, 3),
            };
            Grid.SetColumn(h, b + 1);
            _grid.Children.Add(h);
        }

        for (int r = 0; r < rows; r++)
        {
            var label = new TextBlock
            {
                Text = rows == 2 ? (r == 0 ? "Venstre" : "Høyre") : rows == 1 ? "Mono" : $"Kanal {r + 1}",
                Foreground = muted,
                FontSize = 11.5,
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(0, 0, 8, 0),
            };
            Grid.SetRow(label, r + 1);
            _grid.Children.Add(label);

            for (int b = 0; b < buses.Count; b++)
            {
                int src = r + 1, bus = b + 1;
                var route = routes.FirstOrDefault(x => x.Source == src && x.Bus == bus);
                var tb = new TextBox
                {
                    Text = route == null ? "" : FormatDb(route.GainDb),
                    Margin = new Thickness(1),
                    Padding = new Thickness(2, 3, 2, 3),
                    FontSize = 12,
                    TextAlignment = TextAlignment.Center,
                    ToolTip = $"Kanal {src} → {buses[b].Name}",
                    Tag = (src, bus),
                };
                if (focusedKey is (int fs, int fb) && fs == src && fb == bus)
                    Dispatcher.BeginInvoke(() => { tb.Focus(); tb.SelectAll(); }, System.Windows.Threading.DispatcherPriority.Input);
                if (route != null) tb.Background = (System.Windows.Media.Brush)FindResource("RunningRow");
                tb.LostKeyboardFocus += (_, _) => Commit(src, bus, tb.Text);
                tb.KeyDown += (_, e) => { if (e.Key == Key.Enter) Commit(src, bus, tb.Text); };
                tb.MouseDoubleClick += (_, e) =>
                {
                    Commit(src, bus, string.IsNullOrWhiteSpace(tb.Text) ? "0" : "");
                    e.Handled = true;
                };
                Grid.SetRow(tb, r + 1);
                Grid.SetColumn(tb, b + 1);
                _grid.Children.Add(tb);
            }
        }
    }

    private static string FormatDb(double db) => db.ToString("0.#", CultureInfo.CurrentCulture);

    private void Commit(int src, int bus, string text)
    {
        var cue = Cue;
        if (cue == null) return;
        int rows = Math.Clamp(cue.FileChannels > 0 ? cue.FileChannels : 2, 1, MaxRows);
        var list = cue.EffectiveRoutes(rows).Select(r => new AudioRoute(r.Source, r.Bus, r.GainDb)).ToList();
        var existing = list.FirstOrDefault(r => r.Source == src && r.Bus == bus);

        text = text.Trim();
        if (text.Length == 0 || text is "-" or "-inf" or "av")
        {
            if (existing == null) return;
            list.Remove(existing);
        }
        else
        {
            if (!double.TryParse(text.Replace('.', ','), NumberStyles.Float, new CultureInfo("nb-NO"), out var db)) { Rebuild(); return; }
            db = Math.Clamp(db, -60, 12);
            if (existing != null && Math.Abs(existing.GainDb - db) < 0.001) return;
            if (existing != null) existing.GainDb = db;
            else list.Add(new AudioRoute(src, bus, db));
        }
        SetRoutes(list.OrderBy(r => r.Source).ThenBy(r => r.Bus).ToList());
    }

    private void SetRoutes(List<AudioRoute>? routes)
    {
        if (Cue == null) return;
        _updating = true;
        try { Cue.Routes = routes; }
        finally { _updating = false; }
        // Tegn på nytt etter at fokus er flyttet, så Tab mellom ruter fortsatt virker.
        Dispatcher.BeginInvoke(Rebuild, System.Windows.Threading.DispatcherPriority.Background);
    }
}
