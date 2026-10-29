using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using ShowCue.Engine;
using ShowCue.Models;

namespace ShowCue.Views;

public partial class SettingsWindow : Window
{
    private readonly RemoteControl? _remote;
    private readonly Dictionary<string, string> _midiMap = new();
    private readonly Dictionary<string, TextBox> _midiBoxes = new();
    private AppTheme _originalTheme;
    private bool _ok;

    public AppSettings Result { get; }

    public SettingsWindow(AppSettings settings, RemoteControl? remote = null)
    {
        Result = settings;
        _remote = remote;
        InitializeComponent();

        // ---- Lyd ----
        DriverBox.SelectedItem = settings.AudioDriver;

        WasapiBox.ItemsSource = AudioEngine.GetWasapiDevices();
        WasapiBox.SelectedValue = settings.WasapiDeviceId;
        if (WasapiBox.SelectedIndex < 0) WasapiBox.SelectedIndex = 0;
        LatencyBox.Text = settings.LatencyMs.ToString();

        var asio = AudioEngine.GetAsioDrivers();
        AsioBox.ItemsSource = asio;
        AsioBox.SelectedItem = asio.Contains(settings.AsioDriverName) ? settings.AsioDriverName : asio.FirstOrDefault();
        AsioChannelsBox.Text = settings.AsioMaxChannels.ToString();

        RateBox.ItemsSource = new[] { 44100, 48000, 88200, 96000 };
        RateBox.SelectedItem = settings.SampleRate;
        if (RateBox.SelectedIndex < 0) RateBox.SelectedItem = 48000;

        // ---- Video ----
        var screens = new List<KeyValuePair<int, string>> { new(-1, "Vindu (ikke fullskjerm)") };
        screens.AddRange(Monitors.GetAll().Select(m => new KeyValuePair<int, string>(m.Index, m.ToString())));
        ScreenBox.ItemsSource = screens;
        ScreenBox.SelectedValue = settings.VideoScreen;
        if (ScreenBox.SelectedIndex < 0) ScreenBox.SelectedIndex = 0;

        // ---- OSC ----
        OscEnabledBox.IsChecked = settings.OscInEnabled;
        OscPortBox.Text = settings.OscInPort.ToString();
        var ips = OscServer.LocalAddresses();
        OscAddressText.Text = ips.Count == 0
            ? "Fant ingen nettverksadresser."
            : "Send til: " + string.Join("  eller  ", ips) + $"  (port {settings.OscInPort}). Fra samme maskin: 127.0.0.1.";

        FbEnabledBox.IsChecked = settings.OscFeedbackEnabled;
        FbHostBox.Text = settings.OscFeedbackHost;
        FbPortBox.Text = settings.OscFeedbackPort.ToString();
        FbFormatBox.SelectedItem = settings.OscFeedbackFormat;

        // ---- Utseende ----
        _originalTheme = settings.Theme;
        ThemeBox.SelectedItem = settings.Theme;

        // ---- MIDI ----
        var midiIns = new List<string> { "" };
        midiIns.AddRange(MidiInput.GetDevices());
        if (!string.IsNullOrEmpty(settings.MidiInDevice) && !midiIns.Contains(settings.MidiInDevice)) midiIns.Add(settings.MidiInDevice);
        MidiInBox.ItemsSource = midiIns.Select(n => n == "" ? "(av)" : n).ToList();
        MidiInBox.SelectedIndex = Math.Max(0, midiIns.IndexOf(settings.MidiInDevice));

        var channels = new List<KeyValuePair<int, string>> { new(0, "Alle kanaler") };
        channels.AddRange(Enumerable.Range(1, 16).Select(i => new KeyValuePair<int, string>(i, $"Kanal {i}")));
        MidiChannelBox.ItemsSource = channels;
        MidiChannelBox.SelectedValue = settings.MidiInChannel;

        _midiMap["GO"] = settings.MidiGo;
        _midiMap["Stopp alt"] = settings.MidiStopAll;
        _midiMap["Neste"] = settings.MidiNext;
        _midiMap["Forrige"] = settings.MidiPrevious;
        BuildMidiMap();

        MscBox.IsChecked = settings.MscInEnabled;
        MscIdBox.Text = settings.MscInDeviceId.ToString();

        // ---- Sikkerhet ----
        PanicBox.Text = settings.PanicFadeTime.ToString(CultureInfo.CurrentCulture);
        DoubleGoBox.Text = settings.DoubleGoProtectionMs.ToString();

        UpdatePanels();
        ThemeManager.Register(this);
        Closed += (_, _) =>
        {
            _remote?.CancelLearn();
            if (!_ok && ThemeManager.Current != _originalTheme) ThemeManager.Apply(_originalTheme); // Avbryt angrer forhåndsvisning
        };
    }

    private void BuildMidiMap()
    {
        int row = 0;
        foreach (var key in _midiMap.Keys.ToList())
        {
            var label = new TextBlock { Text = key, VerticalAlignment = VerticalAlignment.Center };
            label.SetResourceReference(TextBlock.ForegroundProperty, "Muted");
            var box = new TextBox { IsReadOnly = true, Margin = new Thickness(0, 3, 0, 3), Text = Describe(_midiMap[key]) };
            var learn = new Button { Content = "Lær", Margin = new Thickness(6, 3, 0, 3) };
            var clear = new Button { Content = "✕", Margin = new Thickness(4, 3, 0, 3), ToolTip = "Fjern" };
            string k = key;
            learn.Click += (_, _) => Learn(k);
            clear.Click += (_, _) => { _remote?.CancelLearn(); _midiMap[k] = ""; box.Text = Describe(""); };
            _midiBoxes[key] = box;
            foreach (var (el, col) in new (UIElement, int)[] { (label, 0), (box, 1), (learn, 2), (clear, 3) })
            {
                Grid.SetRow(el, row);
                Grid.SetColumn(el, col);
                MidiMapGrid.Children.Add(el);
            }
            row++;
        }
    }

    private static string Describe(string t) => string.IsNullOrEmpty(t) ? "(ingen)" : MidiTriggers.Describe(t);

    private void Learn(string key)
    {
        if (_remote == null || !_remote.MidiOpen)
        {
            MessageBox.Show(this, "Ingen MIDI-inngang er aktiv ennå. Velg inngang, trykk OK, og åpne innstillingene igjen for å bruke «Lær».",
                "MIDI", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        var box = _midiBoxes[key];
        box.Text = "Venter på MIDI …";
        _remote.BeginLearn(t =>
        {
            _midiMap[key] = t;
            box.Text = Describe(t);
        });
    }

    private void Driver_Changed(object sender, SelectionChangedEventArgs e) => UpdatePanels();

    /// <summary>Forhåndsvis tema med en gang.</summary>
    private void Theme_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (ThemeBox.SelectedItem is AppTheme t && t != ThemeManager.Current) ThemeManager.Apply(t);
    }

    private void UpdatePanels()
    {
        if (WasapiPanel == null) return;
        var asio = DriverBox.SelectedItem is AudioDriverType.Asio;
        WasapiPanel.Visibility = asio ? Visibility.Collapsed : Visibility.Visible;
        AsioPanel.Visibility = asio ? Visibility.Visible : Visibility.Collapsed;
    }

    private static bool TryDouble(string text, out double v) =>
        double.TryParse(text.Replace('.', ','), NumberStyles.Float, new CultureInfo("nb-NO"), out v);

    private void Ok_Click(object sender, RoutedEventArgs e)
    {
        Result.AudioDriver = DriverBox.SelectedItem is AudioDriverType d ? d : AudioDriverType.Wasapi;
        Result.WasapiDeviceId = WasapiBox.SelectedValue as string ?? "";
        Result.AsioDriverName = AsioBox.SelectedItem as string ?? "";
        if (int.TryParse(AsioChannelsBox.Text, out var ac)) Result.AsioMaxChannels = Math.Clamp(ac, 2, 128);
        Result.SampleRate = RateBox.SelectedItem is int r ? r : 48000;
        Result.VideoScreen = ScreenBox.SelectedValue is int s ? s : -1;
        if (int.TryParse(LatencyBox.Text, out var lat)) Result.LatencyMs = Math.Clamp(lat, 10, 500);

        Result.OscInEnabled = OscEnabledBox.IsChecked == true;
        if (int.TryParse(OscPortBox.Text, out var port) && port is > 0 and < 65536) Result.OscInPort = port;

        Result.OscFeedbackEnabled = FbEnabledBox.IsChecked == true;
        Result.OscFeedbackHost = string.IsNullOrWhiteSpace(FbHostBox.Text) ? "127.0.0.1" : FbHostBox.Text.Trim();
        if (int.TryParse(FbPortBox.Text, out var fp) && fp is > 0 and < 65536) Result.OscFeedbackPort = fp;
        Result.OscFeedbackFormat = FbFormatBox.SelectedItem is OscFeedbackFormat ff ? ff : OscFeedbackFormat.Companion;
        Result.Theme = ThemeBox.SelectedItem is AppTheme th ? th : AppTheme.Dark;

        var midiName = MidiInBox.SelectedItem as string ?? "";
        Result.MidiInDevice = midiName == "(av)" ? "" : midiName;
        Result.MidiInChannel = MidiChannelBox.SelectedValue is int ch ? ch : 0;
        Result.MidiGo = _midiMap["GO"];
        Result.MidiStopAll = _midiMap["Stopp alt"];
        Result.MidiNext = _midiMap["Neste"];
        Result.MidiPrevious = _midiMap["Forrige"];
        Result.MscInEnabled = MscBox.IsChecked == true;
        if (int.TryParse(MscIdBox.Text, out var msc)) Result.MscInDeviceId = Math.Clamp(msc, 0, 127);

        if (TryDouble(PanicBox.Text, out var p)) Result.PanicFadeTime = Math.Clamp(p, 0, 30);
        if (int.TryParse(DoubleGoBox.Text, out var dg)) Result.DoubleGoProtectionMs = Math.Clamp(dg, 0, 2000);

        if (Result.AudioDriver == AudioDriverType.Asio && string.IsNullOrEmpty(Result.AsioDriverName))
        {
            MessageBox.Show(this, "Fant ingen ASIO-drivere på denne maskinen. Installer lydkortets ASIO-driver (eller Dante Virtual Soundcard i ASIO-modus), eller velg WASAPI.",
                "Innstillinger", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }
        _ok = true;
        DialogResult = true;
    }
}
