using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.ComponentModel;
using System.IO;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media;
using Microsoft.Win32;
using ShowCue.Engine;
using ShowCue.Models;
using ShowCue.Views;

namespace ShowCue;

public partial class MainWindow : Window, INotifyPropertyChanged, IShowControl
{
    // ---------- Filtyper ----------
    private static readonly string[] AudioExt = { ".wav", ".mp3", ".aif", ".aiff", ".flac", ".m4a", ".aac", ".wma" };
    private static readonly string[] VideoExt = { ".mp4", ".mov", ".m4v", ".wmv", ".avi", ".mkv" };
    private static readonly string[] ImageExt = { ".png", ".jpg", ".jpeg", ".bmp", ".gif", ".tif", ".tiff" };
    private const string AudioFilter = "Lydfiler|*.wav;*.mp3;*.aif;*.aiff;*.flac;*.m4a;*.aac;*.wma|Alle filer|*.*";
    private const string VideoFilter = "Videofiler|*.mp4;*.mov;*.m4v;*.wmv;*.avi;*.mkv|Alle filer|*.*";
    private const string ImageFilter = "Bilder|*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tif;*.tiff|Alle filer|*.*";
    private const string PdfFilter = "PDF|*.pdf";
    private const string ShowFilter = "ShowCue-show|*.showcue|Alle filer|*.*";

    private AppSettings _settings;
    private ShowDocument _show = new();
    private string? _showPath;
    private string _savedJson = "";
    private Cue? _selected;
    private string _statusText = "";
    private DateTime _lastGo = DateTime.MinValue;
    private DateTime _lastPanic = DateTime.MinValue;
    private double _meterL, _meterR;
    private string _lastClock = "";
    private PatchWindow? _patchWindow;
    private OscFeedback? _feedback;
    private int _feedbackTick;

    public event PropertyChangedEventHandler? PropertyChanged;
    private void Raise([CallerMemberName] string? n = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n));

    public CueEngine Engine { get; }
    public RemoteControl Remote { get; }
    /// <summary>Lydpatchens utganger (ny liste ved hver endring, så routingmatrisen tegnes på nytt).</summary>
    public IReadOnlyList<PatchBus> Buses => _settings.Buses.ToList();
    public string RemoteStatus => Remote.OscStatus + "   ·   " + Remote.MidiStatus
        + (_settings.OscFeedbackEnabled ? $"   ·   Status ut: {_settings.OscFeedbackHost}:{_settings.OscFeedbackPort}" : "");
    /// <summary>Ikon for temaknappen: viser hvilket tema man bytter til.</summary>
    public string ThemeGlyph => ThemeManager.Current switch { AppTheme.Dark => "☀", AppTheme.Light => "☾", _ => "◐" };
    private string _learnText = "";
    /// <summary>Vises i inspector mens vi venter på en MIDI-melding.</summary>
    public string LearnText { get => _learnText; set { _learnText = value; Raise(); } }
    public List<string> MidiDevices { get; private set; } = MidiEngine.GetDevices();
    public ListCollectionView HotkeyCues { get; private set; } = null!;

    public ObservableCollection<Cue> Cues => _show.Cues;

    public Cue? SelectedCue
    {
        get => _selected;
        set
        {
            if (_selected == value) return;
            if (_selected != null) _selected.PropertyChanged -= Selected_PropertyChanged;
            _selected = value;
            if (_selected != null) _selected.PropertyChanged += Selected_PropertyChanged;
            Raise();
            Raise(nameof(HasSelection));
            Raise(nameof(NoSelection));
            Raise(nameof(NextCueTitle));
            if (_selected != null) CueGrid.ScrollIntoView(_selected);
        }
    }

    public bool HasSelection => _selected != null;
    public bool NoSelection => _selected == null;
    public bool IsEmpty => Cues.Count == 0;
    public bool NothingActive => Engine.Active.Count == 0;
    public bool NoHotkeys => HotkeyCues.Count == 0;
    public string NextCueTitle => _selected?.DisplayName ?? (Cues.Count > 0 ? "— slutt på lista —" : "");
    public string ActiveCountText => Engine.Active.Count == 0 ? "" : $"{Engine.Active.Count} aktive";
    public string StatusText { get => _statusText; set { _statusText = value; Raise(); } }
    public string WindowTitle =>
        $"{(_showPath != null ? Path.GetFileNameWithoutExtension(_showPath) : "Uten navn")}{(IsDirty ? " •" : "")} — ShowCue {AppVersion}";

    /// <summary>Programversjonen (fra VERSION-fila ved bygging), f.eks. «0.5.0».</summary>
    public static string AppVersion
    {
        get
        {
            var v = typeof(MainWindow).Assembly.GetName().Version;
            return v == null ? "" : $"{v.Major}.{v.Minor}.{Math.Max(0, v.Build)}";
        }
    }

    private bool IsDirty => _show.ToJson() != _savedJson;

    public MainWindow()
    {
        _settings = AppSettings.Load();
        ThemeManager.Apply(_settings.Theme);
        ThemeManager.Register(this);
        ThemeManager.Changed += () => Raise(nameof(ThemeGlyph));
        Engine = new CueEngine(_settings, () => Cues);
        WaveformEditor.Engine = Engine;
        Remote = new RemoteControl(this, Dispatcher, _settings);
        Remote.StatusChanged += () => Raise(nameof(RemoteStatus));

        InitializeComponent();
        SetShow(new ShowDocument(), null);
        DataContext = this;

        Engine.Audio.StatusChanged += s => Dispatcher.BeginInvoke(() => StatusText = s);
        Engine.Log += s => StatusText = s;
        Engine.Ticked += OnTick;
        Engine.OutputCreated += OnOutputCreated;
        Engine.Active.CollectionChanged += (_, _) => { Raise(nameof(NothingActive)); Raise(nameof(ActiveCountText)); };

        PreviewKeyDown += (_, e) => HandleKey(e);
        Closing += OnClosing;
        Loaded += (_, _) =>
        {
            Engine.ApplySettings(_settings);
            Remote.Apply(_settings);
            ApplyFeedbackSettings();
            if (!string.IsNullOrEmpty(_settings.LastShowPath) && File.Exists(_settings.LastShowPath))
                TryOpen(_settings.LastShowPath);
            Activate();
            CueGrid.Focus();
        };
    }

    // ==================================================================
    //  Show-håndtering
    // ==================================================================
    private void SetShow(ShowDocument doc, string? path)
    {
        Engine.StopAll(0);
        if (_show != null) _show.Cues.CollectionChanged -= Cues_CollectionChanged;
        foreach (var c in _show!.Cues) c.PropertyChanged -= Cue_PropertyChanged;

        _show = doc;
        _showPath = path;
        _show.Cues.CollectionChanged += Cues_CollectionChanged;
        foreach (var c in _show.Cues) c.PropertyChanged += Cue_PropertyChanged;

        HotkeyCues = new ListCollectionView(_show.Cues)
        {
            Filter = o => o is Cue c && !string.IsNullOrEmpty(c.Hotkey),
            IsLiveFiltering = true,
        };
        HotkeyCues.LiveFilteringProperties.Add(nameof(Cue.Hotkey));
        ((INotifyCollectionChanged)HotkeyCues).CollectionChanged += (_, _) => Raise(nameof(NoHotkeys));

        // Fyll inn manglende lengder og forhåndslast bilder/PDF.
        foreach (var a in _show.Cues.OfType<AudioCue>().Where(a => (a.FileDuration <= 0 || a.FileChannels <= 0) && File.Exists(a.FilePath)))
            (a.FileDuration, a.FileChannels) = AudioEngine.Probe(a.FilePath);
        MediaCache.Clear();
        MediaCache.Preload(_show.Cues);
        foreach (var v in _show.Cues.OfType<VideoCue>().Where(v => v.FileChannels < 0)) ProbeVideoAudio(v);

        _savedJson = _show.ToJson();
        Raise(nameof(Cues));
        Raise(nameof(HotkeyCues));
        Raise(nameof(NoHotkeys));
        Raise(nameof(IsEmpty));
        SelectedCue = _show.Cues.FirstOrDefault(c => !c.Disabled);
        RaiseTitle();

        var missing = _show.Cues.OfType<IFileCue>().Count(f => !string.IsNullOrEmpty(f.FilePath) && !File.Exists(f.FilePath));
        if (missing > 0)
        {
            foreach (var c in _show.Cues.Where(c => c is IFileCue f && !string.IsNullOrEmpty(f.FilePath) && !File.Exists(f.FilePath)))
                c.Error = "Fila finnes ikke: " + ((IFileCue)c).FilePath;
            StatusText = $"Advarsel: {missing} mediefil(er) mangler. De er merket med ! i lista.";
        }
    }

    private void Cues_CollectionChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        if (e.NewItems != null) foreach (Cue c in e.NewItems) c.PropertyChanged += Cue_PropertyChanged;
        if (e.OldItems != null) foreach (Cue c in e.OldItems) c.PropertyChanged -= Cue_PropertyChanged;
        Raise(nameof(IsEmpty));
        Raise(nameof(NextCueTitle));
        RaiseTitle();
    }

    private void Cue_PropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (sender is not Cue c) return;
        // Kjøretidsstatus endrer ikke showet.
        if (e.PropertyName is nameof(Cue.Progress) or nameof(Cue.ActiveCount) or nameof(Cue.IsRunning)
            or nameof(Cue.IsPreWaiting) or nameof(Cue.Error) or nameof(Cue.HasError)) return;

        if (e.PropertyName == nameof(IFileCue.FilePath))
        {
            if (c is AudioCue a) (a.FileDuration, a.FileChannels) = File.Exists(a.FilePath) ? AudioEngine.Probe(a.FilePath) : (0, 0);
            if (c is VideoCue v) { v.KnownDuration = 0; v.FileChannels = -1; ProbeVideoAudio(v); }
            c.Error = c is IFileCue f && !string.IsNullOrEmpty(f.FilePath) && !File.Exists(f.FilePath) ? "Fila finnes ikke" : null;
            if (c is StillCue) MediaCache.Preload(new[] { c });
        }
        if (e.PropertyName == nameof(PdfCue.Page)) MediaCache.Preload(new[] { c });
        if (e.PropertyName == nameof(Cue.Summary)) RaiseTitle();
    }

    private void Selected_PropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(Cue.DisplayName)) Raise(nameof(NextCueTitle));
    }

    private void RaiseTitle() => Raise(nameof(WindowTitle));

    private bool ConfirmDiscard()
    {
        if (!IsDirty) return true;
        var r = MessageBox.Show(this, "Vil du lagre endringene i showet?", "ShowCue", MessageBoxButton.YesNoCancel, MessageBoxImage.Question);
        if (r == MessageBoxResult.Cancel) return false;
        if (r == MessageBoxResult.Yes) return Save(false);
        return true;
    }

    private bool Save(bool saveAs)
    {
        CommitFocusedTextBox();
        var path = _showPath;
        if (saveAs || path == null)
        {
            var dlg = new SaveFileDialog { Filter = ShowFilter, DefaultExt = ".showcue", FileName = path != null ? Path.GetFileName(path) : "Show.showcue" };
            if (dlg.ShowDialog(this) != true) return false;
            path = dlg.FileName;
        }
        try
        {
            _show.Title = Path.GetFileNameWithoutExtension(path);
            _show.Save(path);
            _showPath = path;
            _savedJson = _show.ToJson();
            _settings.LastShowPath = path;
            _settings.Save();
            StatusText = "Lagret " + path;
            RaiseTitle();
            return true;
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, "Kunne ikke lagre: " + ex.Message, "ShowCue", MessageBoxButton.OK, MessageBoxImage.Error);
            return false;
        }
    }

    private void TryOpen(string path)
    {
        try
        {
            SetShow(ShowDocument.Load(path), path);
            _settings.LastShowPath = path;
            _settings.Save();
            if (string.IsNullOrEmpty(StatusText) || !StatusText.StartsWith("Advarsel")) StatusText = "Åpnet " + path;
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, "Kunne ikke åpne showet: " + ex.Message, "ShowCue", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void OnClosing(object? sender, CancelEventArgs e)
    {
        CommitFocusedTextBox();
        if (Engine.Active.Count > 0 &&
            MessageBox.Show(this, "Cues spiller fortsatt. Vil du avslutte?", "ShowCue", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes)
        {
            e.Cancel = true;
            return;
        }
        if (!ConfirmDiscard()) { e.Cancel = true; return; }
        _settings.Save();
        _patchWindow?.Close();
        Remote.Dispose();
        Engine.Dispose();
    }

    // ==================================================================
    //  GO / stopp
    // ==================================================================
    private void Go()
    {
        if ((DateTime.Now - _lastGo).TotalMilliseconds < _settings.DoubleGoProtectionMs) return;
        _lastGo = DateTime.Now;

        var cue = SelectedCue;
        if (cue == null) return;
        int idx = Cues.IndexOf(cue);
        if (cue.Disabled)
        {
            // Hopp til neste aktive cue og kjør den.
            var next = Cues.Skip(idx + 1).FirstOrDefault(c => !c.Disabled);
            if (next == null) return;
            cue = next;
            idx = Cues.IndexOf(cue);
        }
        Engine.Fire(cue);
        int nextIdx = CueEngine.NextPlayheadIndex(Cues, idx);
        SelectedCue = nextIdx < Cues.Count ? Cues[nextIdx] : null;
    }

    private void Panic()
    {
        var hard = (DateTime.Now - _lastPanic).TotalSeconds < 1.0;
        _lastPanic = DateTime.Now;
        Engine.StopAll(hard ? 0 : _settings.PanicFadeTime);
        StatusText = hard ? "Alt stoppet umiddelbart." : $"Stopper alt (fade {_settings.PanicFadeTime:0.#} s). Trykk Esc igjen for umiddelbar stopp.";
    }

    private static double FadeOutOf(Cue c) => c switch
    {
        AudioCue a => a.FadeOut,
        VisualCue v => v.FadeOut,
        _ => 0
    };

    private void ToggleHotCue(Cue cue)
    {
        if (cue.IsRunning && cue is AudioCue or VisualCue) Engine.Stop(cue, FadeOutOf(cue));
        else Engine.Fire(cue);
    }

    // ==================================================================
    //  Tastatur
    // ==================================================================
    private void HandleKey(KeyEventArgs e)
    {
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        var mods = Keyboard.Modifiers;
        var focused = Keyboard.FocusedElement;

        if (key == Key.Escape)
        {
            if (Remote.IsLearning) { Remote.CancelLearn(); LearnText = ""; }
            Panic();
            if (focused is TextBox) CueGrid.Focus();
            e.Handled = true;
            return;
        }
        if (focused == HotkeyBox) return; // tastefangeren håndterer selv

        bool typing = focused is TextBox { IsReadOnly: false };
        bool inCombo = focused is ComboBox or ComboBoxItem;

        if (mods == ModifierKeys.Control)
        {
            switch (key)
            {
                case Key.S: Save(false); e.Handled = true; return;
                case Key.O: Open_Click(this, new RoutedEventArgs()); e.Handled = true; return;
                case Key.N: New_Click(this, new RoutedEventArgs()); e.Handled = true; return;
            }
            if (!typing)
            {
                switch (key)
                {
                    case Key.D: Duplicate_Click(this, new RoutedEventArgs()); e.Handled = true; return;
                    case Key.Up: MoveSelected(-1); e.Handled = true; return;
                    case Key.Down: MoveSelected(1); e.Handled = true; return;
                    case >= Key.D1 and <= Key.D8:
                        AddCue(new[] { "audio", "video", "image", "pdf", "fade", "stop", "osc", "midi" }[key - Key.D1]);
                        e.Handled = true; return;
                }
            }
        }

        if (typing)
        {
            if (key == Key.Enter && focused is TextBox { AcceptsReturn: false })
            {
                CommitFocusedTextBox();
                CueGrid.Focus();
                e.Handled = true;
                return;
            }
            // F-tast-hurtigtaster virker også mens man skriver.
            if (key is >= Key.F1 and <= Key.F24 && mods == ModifierKeys.None && FireHotkey(key)) e.Handled = true;
            return;
        }

        if (mods != ModifierKeys.None) return;

        switch (key)
        {
            case Key.Space:
                Go();
                e.Handled = true;
                return;
            case Key.Up when !inCombo:
                MovePlayhead(-1); e.Handled = true; return;
            case Key.Down when !inCombo:
                MovePlayhead(1); e.Handled = true; return;
            case Key.Home when !inCombo:
                SelectedCue = Cues.FirstOrDefault(); e.Handled = true; return;
            case Key.Delete:
                Delete_Click(this, new RoutedEventArgs()); e.Handled = true; return;
        }

        if (FireHotkey(key)) e.Handled = true;
    }

    private bool FireHotkey(Key key)
    {
        var name = KeyName(key);
        if (name == null) return false;
        var cue = Cues.FirstOrDefault(c => c.Hotkey == name && !c.Disabled);
        if (cue == null) return false;
        ToggleHotCue(cue);
        return true;
    }

    // ==================================================================
    //  Fjernstyring (OSC / MIDI)
    // ==================================================================
    private Cue? FindCue(string number) =>
        Cues.FirstOrDefault(c => string.Equals(c.Number, number.Trim(), StringComparison.OrdinalIgnoreCase));

    void IShowControl.Go() => Go();
    void IShowControl.StopAll() => Engine.StopAll(_settings.PanicFadeTime);
    void IShowControl.Panic() => Panic();
    void IShowControl.HardStop() => Engine.StopAll(0);
    void IShowControl.MovePlayhead(int delta) => MovePlayhead(delta);

    bool IShowControl.SelectCue(string number)
    {
        var c = FindCue(number);
        if (c == null) return false;
        SelectedCue = c;
        return true;
    }

    bool IShowControl.StartCue(string number)
    {
        var c = FindCue(number);
        if (c == null) return false;
        Engine.Fire(c);
        return true;
    }

    bool IShowControl.StopCue(string number)
    {
        var c = FindCue(number);
        if (c == null) return false;
        Engine.Stop(c, FadeOutOf(c));
        return true;
    }

    bool IShowControl.GoCue(string number)
    {
        var c = FindCue(number);
        if (c == null) return false;
        SelectedCue = c;
        _lastGo = DateTime.MinValue; // eksplisitt cue: ingen dobbel-GO-sperre
        Go();
        return true;
    }

    bool IShowControl.FireHotkey(string key)
    {
        var cue = Cues.FirstOrDefault(c => c.Hotkey == key && !c.Disabled);
        if (cue == null) return false;
        ToggleHotCue(cue);
        return true;
    }

    int IShowControl.FireMidiTrigger(string trigger)
    {
        var cues = Cues.Where(c => c.MidiTrigger == trigger && !c.Disabled).ToList();
        foreach (var c in cues) ToggleHotCue(c);
        return cues.Count;
    }

    void IShowControl.RemoteLog(string text) => StatusText = text;

    private static string? KeyName(Key k)
    {
        if (k is >= Key.A and <= Key.Z) return k.ToString();
        if (k is >= Key.D0 and <= Key.D9) return ((int)(k - Key.D0)).ToString();
        if (k is >= Key.NumPad0 and <= Key.NumPad9) return "NUM" + (int)(k - Key.NumPad0);
        if (k is >= Key.F1 and <= Key.F24) return k.ToString();
        return null;
    }

    private void HotkeyBox_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (SelectedCue == null) return;
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (key is Key.Escape) return; // panikk håndteres av vinduet
        if (key is Key.Back or Key.Delete) { SelectedCue.Hotkey = ""; e.Handled = true; return; }
        if (key is Key.Tab or Key.Enter) { CueGrid.Focus(); e.Handled = true; return; }
        var name = KeyName(key);
        if (name != null)
        {
            var other = Cues.FirstOrDefault(c => c != SelectedCue && c.Hotkey == name);
            if (other != null) { other.Hotkey = ""; StatusText = $"Hurtigtast {name} flyttet fra cue {other.Number}."; }
            SelectedCue.Hotkey = name;
            CueGrid.Focus();
        }
        e.Handled = true;
    }

    private void MovePlayhead(int delta)
    {
        if (Cues.Count == 0) return;
        int idx = SelectedCue != null ? Cues.IndexOf(SelectedCue) : (delta > 0 ? -1 : Cues.Count);
        idx = Math.Clamp(idx + delta, 0, Cues.Count - 1);
        SelectedCue = Cues[idx];
    }

    private void CommitFocusedTextBox()
    {
        if (Keyboard.FocusedElement is TextBox tb)
            tb.GetBindingExpression(TextBox.TextProperty)?.UpdateSource();
    }

    // ==================================================================
    //  Legge til / redigere cues
    // ==================================================================
    private string NextNumber()
    {
        double max = 0;
        foreach (var c in Cues)
            if (double.TryParse(c.Number, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var n))
                max = Math.Max(max, n);
        return ((int)Math.Floor(max) + 1).ToString();
    }

    private int InsertIndex()
    {
        var selected = CueGrid.SelectedItems.Cast<Cue>().ToList();
        if (selected.Count == 0) return Cues.Count;
        return selected.Max(c => Cues.IndexOf(c)) + 1;
    }

    private void InsertCues(IList<Cue> newCues, int at)
    {
        foreach (var c in newCues)
        {
            if (string.IsNullOrEmpty(c.Number)) c.Number = NextNumber();
            Cues.Insert(Math.Min(at++, Cues.Count), c);
        }
        if (newCues.Count > 0)
        {
            CueGrid.SelectedItems.Clear();
            SelectedCue = newCues[newCues.Count - 1];
        }
    }

    private void AddCue(string type)
    {
        CommitFocusedTextBox();
        var at = InsertIndex();
        var target = SelectedCue;
        var list = new List<Cue>();
        switch (type)
        {
            case "audio": list.AddRange(PickFiles(AudioFilter, true).Select(CreateCueForFile).OfType<Cue>()); if (list.Count == 0) return; break;
            case "video": list.AddRange(PickFiles(VideoFilter, true).Select(CreateCueForFile).OfType<Cue>()); if (list.Count == 0) return; break;
            case "image": list.AddRange(PickFiles(ImageFilter, true).Select(CreateCueForFile).OfType<Cue>()); if (list.Count == 0) return; break;
            case "pdf": list.AddRange(PickFiles(PdfFilter, true).Select(CreateCueForFile).OfType<Cue>()); if (list.Count == 0) return; break;
            case "fade": list.Add(new FadeCue { Target = target is AudioCue or VisualCue ? target.Number : "" }); break;
            case "stop": list.Add(new StopCue()); break;
            case "osc": list.Add(new OscCue()); break;
            case "midi": list.Add(new MidiCue { Device = MidiDevices.FirstOrDefault() ?? "" }); break;
        }
        InsertCues(list, at);
    }

    private IEnumerable<string> PickFiles(string filter, bool multi)
    {
        var dlg = new OpenFileDialog { Filter = filter, Multiselect = multi };
        return dlg.ShowDialog(this) == true ? dlg.FileNames : Array.Empty<string>();
    }

    private Cue? CreateCueForFile(string path)
    {
        var ext = Path.GetExtension(path).ToLowerInvariant();
        if (AudioExt.Contains(ext))
        {
            var (dur, ch) = AudioEngine.Probe(path);
            return new AudioCue { FilePath = path, FileDuration = dur, FileChannels = ch };
        }
        if (VideoExt.Contains(ext))
        {
            var v = new VideoCue { FilePath = path };
            ProbeVideoAudio(v);
            return v;
        }
        if (ImageExt.Contains(ext)) return new ImageCue { FilePath = path };
        if (ext == ".pdf") return new PdfCue { FilePath = path };
        return null;
    }

    private void AddCue_Click(object sender, RoutedEventArgs e) => AddCue((string)((FrameworkElement)sender).Tag);

    private void Duplicate_Click(object sender, RoutedEventArgs e)
    {
        CommitFocusedTextBox();
        var selected = CueGrid.SelectedItems.Cast<Cue>().OrderBy(c => Cues.IndexOf(c)).ToList();
        if (selected.Count == 0) return;
        var at = InsertIndex();
        var copies = selected.Select(c => { var k = c.Clone(); k.Number = ""; k.Hotkey = ""; return k; }).ToList();
        InsertCues(copies, at);
    }

    private void Delete_Click(object sender, RoutedEventArgs e)
    {
        var selected = CueGrid.SelectedItems.Cast<Cue>().ToList();
        if (selected.Count == 0) return;
        var text = selected.Count == 1 ? $"Slette cue {selected[0].Number} «{selected[0].DisplayName}»?" : $"Slette {selected.Count} cues?";
        if (MessageBox.Show(this, text, "ShowCue", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
        int idx = selected.Min(c => Cues.IndexOf(c));
        foreach (var c in selected)
        {
            Engine.Stop(c, 0);
            Cues.Remove(c);
        }
        SelectedCue = Cues.Count == 0 ? null : Cues[Math.Min(idx, Cues.Count - 1)];
    }

    private void MoveSelected(int delta)
    {
        if (SelectedCue == null) return;
        var c = SelectedCue;
        int i = Cues.IndexOf(c), j = i + delta;
        if (j < 0 || j >= Cues.Count) return;
        Cues.Move(i, j);
        SelectedCue = null;
        SelectedCue = c;
    }

    private void MoveUp_Click(object sender, RoutedEventArgs e) => MoveSelected(-1);
    private void MoveDown_Click(object sender, RoutedEventArgs e) => MoveSelected(1);

    private void Renumber_Click(object sender, RoutedEventArgs e)
    {
        if (MessageBox.Show(this, "Gi alle cues nye nummer 1, 2, 3 …?\nFade- og stopp-cues oppdateres automatisk.", "ShowCue",
                MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
        var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        for (int i = 0; i < Cues.Count; i++)
        {
            var n = (i + 1).ToString();
            if (!string.IsNullOrEmpty(Cues[i].Number)) map.TryAdd(Cues[i].Number, n);
            Cues[i].Number = n;
        }
        foreach (var f in Cues.OfType<FadeCue>()) if (map.TryGetValue(f.Target, out var t)) f.Target = t;
        foreach (var s in Cues.OfType<StopCue>()) if (map.TryGetValue(s.Target, out var t)) s.Target = t;
    }

    private void PdfNextPage_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedCue is not PdfCue pc) return;
        var copy = (PdfCue)pc.Clone();
        copy.Number = "";
        copy.Hotkey = "";
        copy.Page = pc.Page + 1;
        if (!string.IsNullOrEmpty(pc.Name)) copy.Name = "";
        InsertCues(new List<Cue> { copy }, Cues.IndexOf(pc) + 1);
    }

    private void BrowseFile_Click(object sender, RoutedEventArgs e)
    {
        if (((FrameworkElement)sender).DataContext is not IFileCue fc) return;
        var filter = fc switch
        {
            AudioCue => AudioFilter,
            VideoCue => VideoFilter,
            ImageCue => ImageFilter,
            PdfCue => PdfFilter,
            _ => "Alle filer|*.*"
        };
        var file = PickFiles(filter, false).FirstOrDefault();
        if (file != null) fc.FilePath = file;
    }

    // ---------- Dra og slipp ----------
    private void CueGrid_DragOver(object sender, DragEventArgs e)
    {
        e.Effects = e.Data.GetDataPresent(DataFormats.FileDrop) ? DragDropEffects.Copy : DragDropEffects.None;
        e.Handled = true;
    }

    private void CueGrid_Drop(object sender, DragEventArgs e)
    {
        if (e.Data.GetData(DataFormats.FileDrop) is not string[] files) return;
        var cues = files.OrderBy(f => f, StringComparer.CurrentCultureIgnoreCase).Select(CreateCueForFile).OfType<Cue>().ToList();
        if (cues.Count == 0) { StatusText = "Ingen støttede filer i det du slapp."; return; }

        // Sett inn under raden det ble sluppet på, ellers nederst.
        int at = Cues.Count;
        var row = FindParent<DataGridRow>(e.OriginalSource as DependencyObject);
        if (row?.Item is Cue c) at = Cues.IndexOf(c) + 1;
        InsertCues(cues, at);
        StatusText = $"La til {cues.Count} cue(s).";
    }

    private static T? FindParent<T>(DependencyObject? d) where T : DependencyObject
    {
        while (d != null && d is not T) d = d is Visual or System.Windows.Media.Media3D.Visual3D ? VisualTreeHelper.GetParent(d) : LogicalTreeHelper.GetParent(d);
        return d as T;
    }

    private void CueGrid_DoubleClick(object sender, MouseButtonEventArgs e)
    {
        // Dobbeltklikk på en rad kjører den (som test) uten å flytte markøren.
        if (FindParent<DataGridRow>(e.OriginalSource as DependencyObject)?.Item is Cue c) Engine.Fire(c);
    }

    // ==================================================================
    //  Knapper
    // ==================================================================
    private void Go_Click(object sender, RoutedEventArgs e) => Go();
    private void Panic_Click(object sender, RoutedEventArgs e) => Panic();
    private void TestCue_Click(object sender, RoutedEventArgs e) { CommitFocusedTextBox(); if (SelectedCue != null) Engine.Fire(SelectedCue); }
    private void StopSelected_Click(object sender, RoutedEventArgs e) { if (SelectedCue != null) Engine.Stop(SelectedCue, FadeOutOf(SelectedCue)); }

    private void StopActive_Click(object sender, RoutedEventArgs e)
    {
        if (((FrameworkElement)sender).DataContext is ActiveCue a) a.Stop(FadeOutOf(a.Cue));
    }

    private void HotButton_Click(object sender, RoutedEventArgs e)
    {
        if (((FrameworkElement)sender).DataContext is Cue c) ToggleHotCue(c);
    }

    private void New_Click(object sender, RoutedEventArgs e)
    {
        if (!ConfirmDiscard()) return;
        SetShow(new ShowDocument(), null);
        StatusText = "Nytt show.";
    }

    private void Open_Click(object sender, RoutedEventArgs e)
    {
        if (!ConfirmDiscard()) return;
        var dlg = new OpenFileDialog { Filter = ShowFilter };
        if (dlg.ShowDialog(this) == true) TryOpen(dlg.FileName);
    }

    private void Save_Click(object sender, RoutedEventArgs e) => Save(false);
    private void SaveAs_Click(object sender, RoutedEventArgs e) => Save(true);
    private void ToggleOutput_Click(object sender, RoutedEventArgs e) => Engine.ToggleOutput();

    private static string AudioKey(AppSettings s) =>
        $"{s.AudioDriver}|{s.WasapiDeviceId}|{s.AsioDriverName}|{s.AsioMaxChannels}|{s.SampleRate}|{s.LatencyMs}";

    private void Settings_Click(object sender, RoutedEventArgs e)
    {
        var win = new SettingsWindow(_settings.Copy(), Remote) { Owner = this };
        if (win.ShowDialog() != true) return;
        win.Result.LastShowPath = _settings.LastShowPath;
        win.Result.Buses = _settings.Buses; // patchen redigeres i eget vindu

        // Bare endringer i lydoppsettet krever omstart av lyden (som stopper alt som spiller).
        bool restartAudio = AudioKey(win.Result) != AudioKey(_settings);
        if (restartAudio && Engine.Active.Count > 0 &&
            MessageBox.Show(this, "Nytt lydoppsett stopper alt som spiller. Fortsette?", "ShowCue",
                MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes)
        {
            win.Result.AudioDriver = _settings.AudioDriver; win.Result.WasapiDeviceId = _settings.WasapiDeviceId;
            win.Result.AsioDriverName = _settings.AsioDriverName; win.Result.AsioMaxChannels = _settings.AsioMaxChannels;
            win.Result.SampleRate = _settings.SampleRate; win.Result.LatencyMs = _settings.LatencyMs;
            restartAudio = false;
        }
        _settings = win.Result;
        _settings.Save();
        Engine.ApplySettings(_settings, restartAudio);
        Remote.Apply(_settings);
        ApplyFeedbackSettings();
        if (ThemeManager.Current != _settings.Theme) ThemeManager.Apply(_settings.Theme);
        MidiDevices = MidiEngine.GetDevices();
        Raise(nameof(MidiDevices));
    }

    private void ThemeToggle_Click(object sender, RoutedEventArgs e)
    {
        _settings.Theme = ThemeManager.Next(ThemeManager.Current);
        ThemeManager.Apply(_settings.Theme);
        _settings.Save();
    }

    private void CueColor_Click(object sender, RoutedEventArgs e)
    {
        if (((FrameworkElement)sender).Tag is not CueColor color) return;
        var targets = CueGrid.SelectedItems.Cast<Cue>().ToList();
        if (targets.Count == 0 && SelectedCue != null) targets.Add(SelectedCue);
        foreach (var c in targets) c.Color = color;
    }

    // ---------- Videolyd ----------
    /// <summary>Finn ut (i bakgrunnen) om videoen har lyd og hvor mange kanaler.</summary>
    private void ProbeVideoAudio(VideoCue v)
    {
        var path = v.FilePath;
        if (!File.Exists(path)) return;
        Task.Run(() => VideoAudio.Probe(path)).ContinueWith(t =>
        {
            if (t.IsCompletedSuccessfully && v.FilePath == path)
            {
                v.FileChannels = t.Result.Channels;
                if (v.KnownDuration <= 0 && t.Result.Duration > 0) v.KnownDuration = t.Result.Duration;
            }
        }, TaskScheduler.FromCurrentSynchronizationContext());
    }

    private async void ExtractVideoAudio_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedCue is not VideoCue v || !File.Exists(v.FilePath)) return;
        var btn = (Button)sender;
        btn.IsEnabled = false;
        try
        {
            var progress = new Progress<double>(p => StatusText = $"Pakker ut lyd fra {Path.GetFileName(v.FilePath)} … {p:P0}");
            var wav = await VideoAudio.ExtractAsync(v.FilePath, null, progress);
            var (dur, ch) = AudioEngine.Probe(wav);
            var audio = new AudioCue
            {
                FilePath = wav,
                FileDuration = dur,
                FileChannels = ch,
                Name = v.DisplayName + " (lyd)",
                VolumeDb = v.VolumeDb,
                FadeIn = v.FadeIn,
                FadeOut = v.FadeOut,
                Loop = v.Loop,
                // Var videolyden slått av, får lyd-cuen standard routing.
                Routes = v.Routes is { Count: > 0 } ? v.Routes.Select(r => new AudioRoute(r.Source, r.Bus, r.GainDb)).ToList() : null,
                Color = v.Color,
            };
            // Videoen starter lyd-cuen samtidig, og blir selv stum.
            audio.ContinueMode = v.ContinueMode;
            v.ContinueMode = ContinueMode.AutoContinue;
            v.Routes = new List<AudioRoute>();
            InsertCues(new List<Cue> { audio }, Cues.IndexOf(v) + 1);
            SelectedCue = v;
            StatusText = $"Lyden er lagret som {Path.GetFileName(wav)} og lagt inn som cue {audio.Number} (starter samtidig med videoen).";
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, "Kunne ikke pakke ut lyden: " + ex.Message, "ShowCue", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        finally
        {
            btn.IsEnabled = true;
        }
    }

    // ---------- OSC-status ut ----------
    private void ApplyFeedbackSettings()
    {
        _feedback = _settings.OscFeedbackEnabled
            ? OscFeedback.ForTarget(_settings.OscFeedbackHost, _settings.OscFeedbackPort)
            : null;
        if (_feedback != null) _feedback.Format = _settings.OscFeedbackFormat;
        Raise(nameof(RemoteStatus));
    }

    private ShowStatus BuildStatus()
    {
        var next = SelectedCue;
        var playing = Engine.Active
            .Where(a => !a.Done)
            .Select(a => new PlayingCue(a.Cue.Number, a.Cue.DisplayName, a.Started ? a.Elapsed : 0,
                a.Duration > 0 ? Math.Max(0, a.Duration - a.Elapsed) : 0, a.Duration > 0, !a.Started))
            .ToList();
        return new ShowStatus(
            _showPath != null ? Path.GetFileNameWithoutExtension(_showPath) : "Uten navn",
            next?.Number ?? "", next?.DisplayName ?? "", next?.Notes ?? "",
            next != null ? Cues.IndexOf(next) + 1 : 0, Cues.Count, playing);
    }

    void IShowControl.RefreshFeedback() => _feedback?.RequestRefresh();

    private void Patch_Click(object sender, RoutedEventArgs e)
    {
        if (_patchWindow != null) { _patchWindow.Activate(); return; }
        _patchWindow = new PatchWindow(Engine.Audio, _settings.Buses, OnPatchChanged) { Owner = this };
        _patchWindow.Closed += (_, _) =>
        {
            _patchWindow = null;
            _settings.Save();
            Activate();
        };
        _patchWindow.Show();
    }

    private void OnPatchChanged()
    {
        Engine.Audio.ApplyPatch(_settings.Buses);
        Raise(nameof(Buses));
    }

    // ---------- MIDI-trigger per cue ----------
    private void MidiLearn_Click(object sender, RoutedEventArgs e)
    {
        if (SelectedCue == null) return;
        if (!Remote.MidiOpen)
        {
            MessageBox.Show(this, "Velg en MIDI-inngang under Innstillinger → MIDI inn først.", "ShowCue", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        var cue = SelectedCue;
        LearnText = "Venter på MIDI … trykk en tast/knapp på kontrolleren";
        Remote.BeginLearn(t =>
        {
            LearnText = "";
            var other = Cues.FirstOrDefault(c => c != cue && c.MidiTrigger == t);
            cue.MidiTrigger = t;
            StatusText = $"Cue {cue.Number} startes nå av {MidiTriggers.Describe(t)}" + (other != null ? $" (cue {other.Number} har samme trigger)" : "");
        });
    }

    private void MidiClear_Click(object sender, RoutedEventArgs e)
    {
        Remote.CancelLearn();
        LearnText = "";
        if (SelectedCue != null) SelectedCue.MidiTrigger = "";
    }

    // ==================================================================
    //  Utgang, måler og klokke
    // ==================================================================
    private void OnOutputCreated(OutputWindow w)
    {
        w.ForwardKey += (_, e) => HandleKey(e);
        PreviewRect.Fill = new VisualBrush(w.LayerHost) { Stretch = Stretch.Uniform };
        // Utgangsvinduet skal ikke stjele fokus fra operatøren.
        Dispatcher.BeginInvoke(() => { Activate(); }, System.Windows.Threading.DispatcherPriority.ApplicationIdle);
    }

    private void OnTick()
    {
        var levels = Engine.Audio.Mixer?.BusLevels ?? Array.Empty<float>();
        float l = levels.Length > 0 ? levels[0] : 0, r = levels.Length > 1 ? levels[1] : l;
        _meterL = Math.Max(MeterMath.ToFraction(l), _meterL - 0.025);
        _meterR = Math.Max(MeterMath.ToFraction(r), _meterR - 0.025);
        MeterLScale.ScaleY = _meterL;
        MeterRScale.ScaleY = _meterR;

        // Status til Companion ca. 10 ganger i sekundet (bare endringer sendes).
        if (_feedback != null && ++_feedbackTick % 6 == 0)
        {
            try { _feedback.Update(BuildStatus(), Engine.Now); }
            catch { /* nettverksfeil skal aldri påvirke showet */ }
        }

        var clock = DateTime.Now.ToString("HH:mm:ss");
        if (clock != _lastClock)
        {
            _lastClock = clock;
            ClockText.Text = clock;
            RaiseTitle();
        }
    }
}
