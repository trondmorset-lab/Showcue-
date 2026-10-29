using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Threading;
using ShowCue.Engine;
using ShowCue.Models;

namespace ShowCue.Views;

/// <summary>
/// Lydpatch: rader = utganger (busser) som cuene sender til, kolonner = kanaler på lydkortet.
/// Kryss av for å sende en utgang til en kanal. Endringer høres med en gang.
/// Med Dante Virtual Soundcard (ASIO) vises Dante-kanalnavnene som verktøytips.
/// </summary>
public sealed class PatchWindow : Window
{
    private const double RowH = 30;
    private const double ColW = 28;

    private readonly AudioEngine _audio;
    private readonly List<PatchBus> _buses;
    private readonly Action _changed;
    private readonly DispatcherTimer _timer;
    private readonly TextBlock _status = new() { TextWrapping = TextWrapping.Wrap };
    private readonly Grid _left = new();
    private readonly Grid _right = new();
    private readonly List<Border> _busMeters = new();
    private readonly List<Border> _chanMeters = new();
    private readonly List<ToggleButton> _testButtons = new();

    public PatchWindow(AudioEngine audio, List<PatchBus> buses, Action changed)
    {
        _audio = audio;
        _buses = buses;
        _changed = changed;

        Title = "Lydpatch — ShowCue";
        Width = 1000;
        Height = 620;
        MinWidth = 640;
        MinHeight = 320;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        SetResourceReference(BackgroundProperty, "Panel");
        SetResourceReference(ForegroundProperty, "Text");
        ThemeManager.Register(this);
        FontFamily = (FontFamily)Application.Current.FindResource("UiFont");
        ShowInTaskbar = false;

        var toolbar = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 10, 0, 10) };
        toolbar.Children.Add(Btn("+ Utgang", "Legg til en ny utgang", () =>
        {
            int n = _buses.Count + 1;
            var b = new PatchBus { Name = $"Utgang {n}" };
            if (n <= Math.Max(_audio.DeviceChannels, 1)) b.Channels.Add(n);
            _buses.Add(b);
            Changed(rebuild: true);
        }));
        toolbar.Children.Add(Btn("− Fjern siste", "Fjern den nederste utgangen", () =>
        {
            if (_buses.Count <= 1) return;
            _audio.SetTestTone(_buses.Count - 1, false);
            _buses.RemoveAt(_buses.Count - 1);
            Changed(rebuild: true);
        }));
        toolbar.Children.Add(Btn("1:1", "Utgang 1 → kanal 1, utgang 2 → kanal 2 osv.", () =>
        {
            for (int i = 0; i < _buses.Count; i++) _buses[i].Channels = i < _audio.DeviceChannels ? new List<int> { i + 1 } : new List<int>();
            Changed(rebuild: true);
        }));
        toolbar.Children.Add(Btn("Nullstill krysspunkter", "Fjern alle krysspunkter", () =>
        {
            foreach (var b in _buses) b.Channels = new List<int>();
            Changed(rebuild: true);
        }));
        toolbar.Children.Add(Btn("Stopp testtoner", "Slå av all rosa støy", () =>
        {
            _audio.StopAllTestTones();
            foreach (var t in _testButtons) t.IsChecked = false;
        }));

        var hint = new TextBlock
        {
            Text = "Lyd-cuer sender til utganger (rader). Kryss av for hvilke kanaler på lydkortet hver utgang skal ut på. " +
                   "«Test» spiller rosa støy (−18 dBFS) på utgangen – fin for linjesjekk mot Dante/PA. Patchen lagres på denne maskinen, ikke i showfila.",
            FontSize = 11.5,
            TextWrapping = TextWrapping.Wrap,
        };

        // Venstre del (navn, nivå, test, måler) står fast; kanalene til høyre kan rulles sidelengs.
        var rightScroll = new ScrollViewer
        {
            Content = _right,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
        };
        var table = new Grid();
        table.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        table.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        table.Children.Add(_left);
        Grid.SetColumn(rightScroll, 1);
        table.Children.Add(rightScroll);
        var outer = new ScrollViewer { Content = table, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };

        var root = new DockPanel { Margin = new Thickness(16, 12, 16, 12) };
        var top = new StackPanel();
        top.Children.Add(_status);
        top.Children.Add(hint);
        top.Children.Add(toolbar);
        DockPanel.SetDock(top, Dock.Top);
        root.Children.Add(top);
        root.Children.Add(outer);
        Content = root;

        _timer = new DispatcherTimer(DispatcherPriority.Render) { Interval = TimeSpan.FromMilliseconds(40) };
        _timer.Tick += (_, _) => UpdateMeters();
        hint.SetResourceReference(TextBlock.ForegroundProperty, "Faint");
        _audio.Restarted += OnRestarted;
        ThemeManager.Changed += OnRestarted; // tegn på nytt med nye farger
        Loaded += (_, _) => { Rebuild(); _timer.Start(); };
        Closed += (_, _) =>
        {
            _timer.Stop();
            _audio.Restarted -= OnRestarted;
            ThemeManager.Changed -= OnRestarted;
            _audio.StopAllTestTones();
        };
    }

    private void OnRestarted() => Dispatcher.BeginInvoke(Rebuild);

    private Brush Res(string key) => (Brush)Application.Current.FindResource(key);

    private Button Btn(string text, string tip, Action onClick)
    {
        var b = new Button { Content = text, ToolTip = tip, Margin = new Thickness(0, 0, 6, 0) };
        b.Click += (_, _) => onClick();
        return b;
    }

    private void Changed(bool rebuild)
    {
        _changed();
        if (rebuild) Rebuild();
    }

    // ------------------------------------------------------------------
    private void Rebuild()
    {
        int D = _audio.DeviceChannels;
        _status.Text = _audio.IsRunning
            ? $"{_audio.Status}"
            : "Lydutgangen er ikke startet. Velg lydkort under Innstillinger.";
        _status.Foreground = _audio.IsRunning ? Res("Text") : Res("Danger");
        _status.Margin = new Thickness(0, 0, 0, 6);

        _left.Children.Clear(); _left.RowDefinitions.Clear(); _left.ColumnDefinitions.Clear();
        _right.Children.Clear(); _right.RowDefinitions.Clear(); _right.ColumnDefinitions.Clear();
        _busMeters.Clear(); _chanMeters.Clear(); _testButtons.Clear();

        foreach (var w in new[] { 34.0, 170, 64, 56, 80 }) _left.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(w) });
        for (int c = 0; c < D; c++) _right.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(ColW) });

        int rows = 1 + _buses.Count + 1; // overskrift, busser, kanalmålere
        for (int r = 0; r < rows; r++)
        {
            _left.RowDefinitions.Add(new RowDefinition { Height = new GridLength(r == 0 ? 44 : RowH) });
            _right.RowDefinitions.Add(new RowDefinition { Height = new GridLength(r == 0 ? 44 : RowH) });
        }

        // --- Overskrifter ---
        string[] heads = { "#", "UTGANG", "NIVÅ dB", "TEST", "NIVÅ" };
        for (int i = 0; i < heads.Length; i++) Place(_left, Header(heads[i]), 0, i);
        var names = _audio.ChannelNames;
        for (int c = 0; c < D; c++)
        {
            var h = Header((c + 1).ToString());
            h.HorizontalAlignment = HorizontalAlignment.Center;
            h.ToolTip = c < names.Count ? $"Kanal {c + 1}: {names[c]}" : $"Kanal {c + 1}";
            Place(_right, h, 0, c);
        }

        // --- Én rad per buss ---
        for (int b = 0; b < _buses.Count; b++)
        {
            var bus = _buses[b];
            int row = b + 1, busIndex = b;

            Place(_left, new TextBlock { Text = (b + 1).ToString(), Foreground = Res("Muted"), VerticalAlignment = VerticalAlignment.Center }, row, 0);

            var name = new TextBox { Text = bus.Name, Margin = new Thickness(0, 2, 6, 2), Padding = new Thickness(5, 2, 5, 2) };
            name.LostKeyboardFocus += (_, _) => { if (bus.Name != name.Text) { bus.Name = name.Text; Changed(false); } };
            Place(_left, name, row, 1);

            var gain = new TextBox { Text = bus.GainDb.ToString("0.#", CultureInfo.CurrentCulture), Margin = new Thickness(0, 2, 6, 2), Padding = new Thickness(5, 2, 5, 2), TextAlignment = TextAlignment.Right };
            gain.LostKeyboardFocus += (_, _) =>
            {
                if (double.TryParse(gain.Text.Replace('.', ','), NumberStyles.Float, new CultureInfo("nb-NO"), out var db))
                {
                    bus.GainDb = Math.Clamp(db, -60, 12);
                    Changed(false);
                }
                gain.Text = bus.GainDb.ToString("0.#", CultureInfo.CurrentCulture);
            };
            Place(_left, gain, row, 2);

            var test = new ToggleButton
            {
                Content = "Test",
                IsChecked = _audio.IsTestToneOn(busIndex),
                Margin = new Thickness(0, 3, 6, 3),
                Focusable = false,
                ToolTip = "Rosa støy på denne utgangen",
            };
            test.Checked += (_, _) => _audio.SetTestTone(busIndex, true);
            test.Unchecked += (_, _) => _audio.SetTestTone(busIndex, false);
            StyleToggle(test);
            _testButtons.Add(test);
            Place(_left, test, row, 3);

            var meter = MakeHorizontalMeter(out var fill);
            _busMeters.Add(fill);
            Place(_left, meter, row, 4);

            for (int c = 0; c < D; c++)
            {
                int ch = c + 1;
                var cb = new CheckBox
                {
                    IsChecked = bus.Channels.Contains(ch),
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center,
                    Margin = new Thickness(0),
                    Focusable = false,
                    ToolTip = $"{bus.Name} → kanal {ch}" + (c < names.Count ? $" ({names[c]})" : ""),
                };
                cb.Checked += (_, _) => { if (!bus.Channels.Contains(ch)) { bus.Channels = bus.Channels.Append(ch).OrderBy(x => x).ToList(); Changed(false); } };
                cb.Unchecked += (_, _) => { bus.Channels = bus.Channels.Where(x => x != ch).ToList(); Changed(false); };
                var cell = new Border
                {
                    Background = (row % 2 == 0) ? Res("Panel2") : Brushes.Transparent,
                    BorderBrush = Res("Line"),
                    BorderThickness = new Thickness(0, 0, (c + 1) % 8 == 0 ? 1 : 0, 0),
                    Child = cb,
                };
                Place(_right, cell, row, c);
            }
        }

        // --- Kanalmålere nederst ---
        int last = rows - 1;
        var chanLabel = new TextBlock { Text = "Kanalnivå på lydkortet", Foreground = Res("Muted"), FontSize = 11.5, VerticalAlignment = VerticalAlignment.Center };
        Place(_left, chanLabel, last, 1);
        Grid.SetColumnSpan(chanLabel, 4);
        for (int c = 0; c < D; c++)
        {
            var m = MakeVerticalMeter(out var fill);
            _chanMeters.Add(fill);
            Place(_right, m, last, c);
        }
    }

    private void StyleToggle(ToggleButton t)
    {
        t.Background = Res("Panel3");
        t.Foreground = Res("Text");
        t.BorderBrush = Res("Line");
        t.Template = (ControlTemplate)System.Windows.Markup.XamlReader.Parse(
            "<ControlTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml' TargetType='ToggleButton'>" +
            "<Border x:Name='b' Background='{TemplateBinding Background}' BorderBrush='{TemplateBinding BorderBrush}' BorderThickness='1' CornerRadius='4'>" +
            "<ContentPresenter HorizontalAlignment='Center' VerticalAlignment='Center' /></Border>" +
            "<ControlTemplate.Triggers><Trigger Property='IsChecked' Value='True'>" +
            "<Setter TargetName='b' Property='Background' Value='#E3A33A' /><Setter Property='Foreground' Value='#1A1200' /></Trigger></ControlTemplate.Triggers>" +
            "</ControlTemplate>");
    }

    private static TextBlock Header(string text) => new()
    {
        Text = text,
        FontSize = 11,
        FontWeight = FontWeights.SemiBold,
        Foreground = (Brush)Application.Current.FindResource("Muted"),
        VerticalAlignment = VerticalAlignment.Bottom,
        Margin = new Thickness(0, 0, 0, 6),
    };

    private static void Place(Grid g, UIElement e, int row, int col)
    {
        Grid.SetRow(e, row);
        Grid.SetColumn(e, col);
        g.Children.Add(e);
    }

    private Border MakeHorizontalMeter(out Border fill)
    {
        fill = new Border { Background = Res("Running"), HorizontalAlignment = HorizontalAlignment.Left, Width = 0, CornerRadius = new CornerRadius(2) };
        return new Border { Background = Res("Panel3"), Height = 8, CornerRadius = new CornerRadius(2), Margin = new Thickness(0, 0, 6, 0), Child = fill };
    }

    private Border MakeVerticalMeter(out Border fill)
    {
        fill = new Border { Background = Res("Running"), VerticalAlignment = VerticalAlignment.Bottom, Height = 0, CornerRadius = new CornerRadius(1) };
        return new Border { Background = Res("Panel3"), Width = 8, Margin = new Thickness(0, 3, 0, 3), CornerRadius = new CornerRadius(1), Child = fill };
    }

    private void UpdateMeters()
    {
        var mixer = _audio.Mixer;
        if (mixer == null) return;
        var bl = mixer.BusLevels;
        for (int i = 0; i < _busMeters.Count; i++)
        {
            double f = i < bl.Length ? MeterMath.ToFraction(bl[i]) : 0;
            _busMeters[i].Width = f * 68;
            _busMeters[i].Background = Res(bl.Length > i && bl[i] >= 0.99f ? "Danger" : "Running");
        }
        var cl = mixer.ChannelLevels;
        for (int i = 0; i < _chanMeters.Count; i++)
        {
            double f = i < cl.Length ? MeterMath.ToFraction(cl[i]) : 0;
            _chanMeters[i].Height = f * (RowH - 6);
            _chanMeters[i].Background = Res(cl.Length > i && cl[i] >= 0.99f ? "Danger" : "Running");
        }
    }
}
