using System.IO;
using System.Runtime.CompilerServices;
using System.Text.Json.Serialization;

namespace ShowCue.Models;

public enum ContinueMode { None, AutoContinue, AutoFollow }
public enum VisualStretch { Uniform, UniformToFill, Fill, None }
public enum MidiMessageType { NoteOn, NoteOff, ProgramChange, ControlChange, MscGo }
/// <summary>Fargemerking av cuer i lista (som i QLab).</summary>
public enum CueColor { None, Red, Orange, Yellow, Green, Blue, Purple, Gray }

/// <summary>Cuer med lyd som går gjennom lydpatchen (lyd-cuer og lydsporet i video-cuer).</summary>
public interface IRoutedAudio : System.ComponentModel.INotifyPropertyChanged
{
    int FileChannels { get; set; }
    List<AudioRoute>? Routes { get; set; }
    double VolumeDb { get; set; }
    IReadOnlyList<AudioRoute> EffectiveRoutes(int fileChannels);
}

/// <summary>Grunnklasse for alle cues. Alt som lagres i showfila er vanlige properties;
/// kjøretidsstatus er merket med JsonIgnore.</summary>
// JSON: "type" angir cuetypen (audio, video, …). Se CueJsonConverter – den leser "type" uansett
// hvor i objektet det står, så showfiler fra Mac-versjonen også kan åpnes.
public abstract class Cue : ObservableObject
{
    private string _number = "";
    private string _name = "";
    private string _notes = "";
    private double _preWait;
    private ContinueMode _continueMode;
    private string _hotkey = "";
    private bool _disabled;

    public string Number { get => _number; set => SetCue(ref _number, value?.Trim() ?? ""); }
    public string Name { get => _name; set => SetCue(ref _name, value ?? ""); }
    public string Notes { get => _notes; set => SetCue(ref _notes, value ?? ""); }
    /// <summary>Sekunder fra GO til cuen faktisk starter.</summary>
    public double PreWait { get => _preWait; set => SetCue(ref _preWait, Math.Max(0, value)); }
    public ContinueMode ContinueMode { get => _continueMode; set => SetCue(ref _continueMode, value); }
    /// <summary>Hurtigtast, f.eks. "F1", "Q" eller "1". Tom = ingen.</summary>
    public string Hotkey { get => _hotkey; set { if (SetCue(ref _hotkey, (value ?? "").Trim().ToUpperInvariant())) OnPropertyChanged(nameof(TriggerText)); } }
    /// <summary>Deaktiverte cues hoppes over av GO.</summary>
    public bool Disabled { get => _disabled; set => SetCue(ref _disabled, value); }
    private CueColor _color;
    /// <summary>Fargemerking i lista.</summary>
    public CueColor Color { get => _color; set => SetCue(ref _color, value); }
    private string _midiTrigger = "";
    /// <summary>MIDI-melding som starter cuen, f.eks. "N:60" (note), "CC:20" eller "PC:5". Tom = ingen.</summary>
    public string MidiTrigger { get => _midiTrigger; set { if (SetCue(ref _midiTrigger, value ?? "")) OnPropertyChanged(nameof(TriggerText)); } }

    /// <summary>Hurtigtast og MIDI-trigger samlet, for visning i lista.</summary>
    [JsonIgnore] public string TriggerText => string.Join(" · ",
        new[] { Hotkey, MidiTriggers.Describe(MidiTrigger) }.Where(s => !string.IsNullOrEmpty(s)));

    [JsonIgnore] public abstract string TypeName { get; }
    [JsonIgnore] public abstract string TypeIcon { get; }
    [JsonIgnore] public virtual string Summary => "";
    /// <summary>Varighet i sekunder, 0 = ukjent/uendelig.</summary>
    [JsonIgnore] public virtual double Duration => 0;
    [JsonIgnore] public string DurationText => Duration > 0 ? TimeFormat.Format(Duration) : "";
    [JsonIgnore] public string PreWaitText => PreWait > 0 ? TimeFormat.Format(PreWait) : "";
    [JsonIgnore] public string DisplayName => string.IsNullOrWhiteSpace(Name) ? DefaultName : Name;
    [JsonIgnore] protected virtual string DefaultName => TypeName;

    // ---- Kjøretidsstatus ----
    private int _activeCount;
    private double _progress;
    private bool _isPreWaiting;
    private string? _error;

    [JsonIgnore] public bool IsRunning => _activeCount > 0;
    [JsonIgnore] public int ActiveCount
    {
        get => _activeCount;
        set { if (Set(ref _activeCount, Math.Max(0, value))) OnPropertyChanged(nameof(IsRunning)); }
    }
    [JsonIgnore] public double Progress { get => _progress; set => Set(ref _progress, value); }
    [JsonIgnore] public bool IsPreWaiting { get => _isPreWaiting; set => Set(ref _isPreWaiting, value); }
    /// <summary>Siste feilmelding (f.eks. fil mangler). Vises i lista.</summary>
    [JsonIgnore] public string? Error { get => _error; set { if (Set(ref _error, value)) OnPropertyChanged(nameof(HasError)); } }
    [JsonIgnore] public bool HasError => !string.IsNullOrEmpty(_error);

    protected bool SetCue<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (!Set(ref field, value, name)) return false;
        OnPropertyChanged(nameof(Summary));
        OnPropertyChanged(nameof(Duration));
        OnPropertyChanged(nameof(DurationText));
        OnPropertyChanged(nameof(PreWaitText));
        OnPropertyChanged(nameof(DisplayName));
        return true;
    }

    protected static string FileLabel(string path) =>
        string.IsNullOrWhiteSpace(path) ? "(ingen fil)" : Path.GetFileName(path);

    public Cue Clone()
    {
        var json = System.Text.Json.JsonSerializer.Serialize<Cue>(this, ShowDocument.JsonOptions);
        return System.Text.Json.JsonSerializer.Deserialize<Cue>(json, ShowDocument.JsonOptions)!;
    }
}

public interface IFileCue
{
    string FilePath { get; set; }
}

// ======================================================================
//  LYD
// ======================================================================
public sealed class AudioCue : Cue, IFileCue, IRoutedAudio
{
    private string _filePath = "";
    private double _volumeDb;
    private double _startTime;
    private double _endTime;
    private bool _loop;
    private double _fadeIn;
    private double _fadeOut;
    private double _fileDuration;
    private int _fileChannels;
    private List<AudioRoute>? _routes;

    public string FilePath { get => _filePath; set => SetCue(ref _filePath, value ?? ""); }
    /// <summary>Antall kanaler i lydfila. Fylles inn automatisk.</summary>
    public int FileChannels { get => _fileChannels; set => SetCue(ref _fileChannels, Math.Max(0, value)); }
    /// <summary>Routing fra filkanal til utgang (buss). null = standard (mono → 1+2, stereo → 1/2, osv.).
    /// Tom liste = alt av. Listen byttes ut i sin helhet ved endring.</summary>
    public List<AudioRoute>? Routes { get => _routes; set => SetCue(ref _routes, value); }

    /// <summary>Gjeldende routing (standard hvis ingen er satt).</summary>
    public IReadOnlyList<AudioRoute> EffectiveRoutes(int fileChannels) => _routes ?? AudioRoute.Default(fileChannels);
    /// <summary>Nivå i dB (0 = uendret, -60 eller lavere = stille).</summary>
    public double VolumeDb { get => _volumeDb; set => SetCue(ref _volumeDb, Math.Clamp(value, -60, 12)); }
    public double StartTime { get => _startTime; set => SetCue(ref _startTime, Math.Max(0, value)); }
    /// <summary>0 = spill til slutten av fila.</summary>
    public double EndTime { get => _endTime; set => SetCue(ref _endTime, Math.Max(0, value)); }
    public bool Loop { get => _loop; set => SetCue(ref _loop, value); }
    public double FadeIn { get => _fadeIn; set => SetCue(ref _fadeIn, Math.Max(0, value)); }
    /// <summary>Brukes ved stopp, og automatisk mot slutten av fila når cuen ikke looper.</summary>
    public double FadeOut { get => _fadeOut; set => SetCue(ref _fadeOut, Math.Max(0, value)); }
    /// <summary>Lengden på lydfila. Fylles inn automatisk.</summary>
    public double FileDuration { get => _fileDuration; set => SetCue(ref _fileDuration, value); }

    public override string TypeName => "Lyd";
    public override string TypeIcon => "♪";
    protected override string DefaultName => Path.GetFileNameWithoutExtension(FilePath) is { Length: > 0 } n ? n : TypeName;
    public override string Summary => FileLabel(FilePath) + (Loop ? "  ⟲" : "") + (VolumeDb != 0 ? $"  {VolumeDb:+0.#;-0.#} dB" : "")
        + (Routes != null ? "  → " + RouteSummary : "");

    private string RouteSummary
    {
        get
        {
            var buses = Routes!.Select(r => r.Bus).Distinct().OrderBy(b => b).ToList();
            return buses.Count == 0 ? "av" : "ut " + string.Join(",", buses);
        }
    }
    public override double Duration
    {
        get
        {
            if (Loop) return 0;
            var end = EndTime > 0 ? Math.Min(EndTime, FileDuration > 0 ? FileDuration : EndTime) : FileDuration;
            return Math.Max(0, end - StartTime);
        }
    }
}

// ======================================================================
//  VISUELT (video, bilde, PDF)
// ======================================================================
public abstract class VisualCue : Cue, IFileCue
{
    private string _filePath = "";
    private double _fadeIn = 0.5;
    private double _fadeOut = 0.5;
    private bool _replaceOthers = true;
    private VisualStretch _stretch = VisualStretch.Uniform;

    public string FilePath { get => _filePath; set => SetCue(ref _filePath, value ?? ""); }
    public double FadeIn { get => _fadeIn; set => SetCue(ref _fadeIn, Math.Max(0, value)); }
    public double FadeOut { get => _fadeOut; set => SetCue(ref _fadeOut, Math.Max(0, value)); }
    /// <summary>Når cuen starter, fades andre bilder/videoer ut (krysstoning).</summary>
    public bool ReplaceOthers { get => _replaceOthers; set => SetCue(ref _replaceOthers, value); }
    public VisualStretch Stretch { get => _stretch; set => SetCue(ref _stretch, value); }

    protected override string DefaultName => Path.GetFileNameWithoutExtension(FilePath) is { Length: > 0 } n ? n : TypeName;
}

public sealed class VideoCue : VisualCue, IRoutedAudio
{
    private double _volumeDb;
    private bool _loop;
    private double _knownDuration;
    private int _fileChannels = -1;
    private List<AudioRoute>? _routes;

    /// <summary>Nivå på videoens lydspor i dB. Lyden går gjennom lydpatchen akkurat som en lyd-cue.</summary>
    public double VolumeDb { get => _volumeDb; set => SetCue(ref _volumeDb, Math.Clamp(value, -60, 12)); }

    /// <summary>Eldre showfiler (0.1/0.2) lagret nivå i prosent. Leses inn og gjøres om til dB; skrives aldri.</summary>
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public double? Volume
    {
        get => null;
        set { if (value is double v) VolumeDb = v <= 0.1 ? -60 : 20 * Math.Log10(Math.Min(v, 100) / 100.0); }
    }

    /// <summary>Antall kanaler i lydsporet. 0 = ingen lyd, -1 = ikke undersøkt ennå.</summary>
    public int FileChannels { get => _fileChannels; set { if (SetCue(ref _fileChannels, value)) OnPropertyChanged(nameof(HasNoAudio)); } }
    /// <summary>Routing fra lydsporets kanaler til utganger. null = standard.</summary>
    public List<AudioRoute>? Routes { get => _routes; set => SetCue(ref _routes, value); }
    public IReadOnlyList<AudioRoute> EffectiveRoutes(int fileChannels) => _routes ?? AudioRoute.Default(fileChannels);
    [JsonIgnore] public bool HasNoAudio => _fileChannels == 0;
    public bool Loop { get => _loop; set => SetCue(ref _loop, value); }
    /// <summary>Fylles inn første gang videoen åpnes.</summary>
    public double KnownDuration { get => _knownDuration; set => SetCue(ref _knownDuration, value); }

    public override string TypeName => "Video";
    public override string TypeIcon => "▶";
    public override string Summary => FileLabel(FilePath) + (Loop ? "  ⟲" : "")
        + (FileChannels == 0 ? "  (ingen lyd)" : Routes is { Count: 0 } ? "  (lyd av)" : VolumeDb != 0 ? $"  {VolumeDb:+0.#;-0.#} dB" : "");
    public override double Duration => Loop ? 0 : KnownDuration;
}

public abstract class StillCue : VisualCue
{
    private double _holdTime;
    /// <summary>Sekunder bildet står før det fades ut. 0 = til det stoppes.</summary>
    public double HoldTime { get => _holdTime; set => SetCue(ref _holdTime, Math.Max(0, value)); }
    public override double Duration => HoldTime > 0 ? FadeIn + HoldTime + FadeOut : 0;
}

public sealed class ImageCue : StillCue
{
    public override string TypeName => "Bilde";
    public override string TypeIcon => "▣";
    public override string Summary => FileLabel(FilePath);
}

public sealed class PdfCue : StillCue
{
    private int _page = 1;
    /// <summary>Sidenummer, starter på 1.</summary>
    public int Page { get => _page; set => SetCue(ref _page, Math.Max(1, value)); }

    public override string TypeName => "PDF";
    public override string TypeIcon => "▤";
    public override string Summary => $"{FileLabel(FilePath)}  s. {Page}";
    protected override string DefaultName => base.DefaultName + $" s.{Page}";
}

// ======================================================================
//  KONTROLL
// ======================================================================
public sealed class FadeCue : Cue
{
    private string _target = "";
    private double _fadeTime = 3;
    private bool _fadeAudio = true;
    private double _targetDb = -60;
    private bool _fadeVisual = true;
    private double _targetOpacity;
    private bool _stopWhenDone = true;

    /// <summary>Cue-nummeret som skal fades.</summary>
    public string Target { get => _target; set => SetCue(ref _target, value?.Trim() ?? ""); }
    public double FadeTime { get => _fadeTime; set => SetCue(ref _fadeTime, Math.Max(0, value)); }
    public bool FadeAudio { get => _fadeAudio; set => SetCue(ref _fadeAudio, value); }
    public double TargetDb { get => _targetDb; set => SetCue(ref _targetDb, Math.Clamp(value, -60, 12)); }
    public bool FadeVisual { get => _fadeVisual; set => SetCue(ref _fadeVisual, value); }
    /// <summary>Synlighet 0–100 %.</summary>
    public double TargetOpacity { get => _targetOpacity; set => SetCue(ref _targetOpacity, Math.Clamp(value, 0, 100)); }
    public bool StopWhenDone { get => _stopWhenDone; set => SetCue(ref _stopWhenDone, value); }

    public override string TypeName => "Fade";
    public override string TypeIcon => "◢";
    protected override string DefaultName => string.IsNullOrEmpty(Target) ? "Fade" : $"Fade cue {Target}";
    public override string Summary
    {
        get
        {
            var t = string.IsNullOrEmpty(Target) ? "(mål mangler)" : "→ " + Target;
            var lvl = FadeAudio ? (TargetDb <= -60 ? "  −∞ dB" : $"  {TargetDb:0.#} dB") : "";
            return t + lvl + (StopWhenDone ? "  + stopp" : "");
        }
    }
    public override double Duration => FadeTime;
}

public sealed class StopCue : Cue
{
    private string _target = "";
    private double _fadeTime;

    /// <summary>Cue-nummeret som skal stoppes. Tomt = stopp alt.</summary>
    public string Target { get => _target; set => SetCue(ref _target, value?.Trim() ?? ""); }
    public double FadeTime { get => _fadeTime; set => SetCue(ref _fadeTime, Math.Max(0, value)); }

    public override string TypeName => "Stopp";
    public override string TypeIcon => "■";
    protected override string DefaultName => string.IsNullOrEmpty(Target) ? "Stopp alt" : $"Stopp cue {Target}";
    public override string Summary => (string.IsNullOrEmpty(Target) ? "Alle cues" : "→ " + Target) + (FadeTime > 0 ? $"  fade {FadeTime:0.#}s" : "");
    public override double Duration => FadeTime;
}

public sealed class OscCue : Cue
{
    private string _host = "127.0.0.1";
    private int _port = 53000;
    private string _address = "/";
    private string _arguments = "";

    public string Host { get => _host; set => SetCue(ref _host, value?.Trim() ?? ""); }
    public int Port { get => _port; set => SetCue(ref _port, Math.Clamp(value, 1, 65535)); }
    public string Address { get => _address; set => SetCue(ref _address, value?.Trim() ?? "/"); }
    /// <summary>Mellomromsseparert: 1 = int, 0.5 = float, tekst eller "tekst med mellomrom" = string.</summary>
    public string Arguments { get => _arguments; set => SetCue(ref _arguments, value ?? ""); }

    public override string TypeName => "OSC";
    public override string TypeIcon => "⇢";
    protected override string DefaultName => "OSC " + Address;
    public override string Summary => $"{Host}:{Port}  {Address} {Arguments}".TrimEnd();
}

public sealed class MidiCue : Cue
{
    private string _device = "";
    private MidiMessageType _messageType = MidiMessageType.NoteOn;
    private int _channel = 1;
    private int _data1 = 60;
    private int _data2 = 127;
    private int _mscDeviceId = 127;
    private int _mscCommandFormat = 1;
    private string _mscCueNumber = "1";

    public string Device { get => _device; set => SetCue(ref _device, value ?? ""); }
    public MidiMessageType MessageType { get => _messageType; set => SetCue(ref _messageType, value); }
    public int Channel { get => _channel; set => SetCue(ref _channel, Math.Clamp(value, 1, 16)); }
    /// <summary>Note / program / controller.</summary>
    public int Data1 { get => _data1; set => SetCue(ref _data1, Math.Clamp(value, 0, 127)); }
    /// <summary>Velocity / verdi.</summary>
    public int Data2 { get => _data2; set => SetCue(ref _data2, Math.Clamp(value, 0, 127)); }
    /// <summary>MSC device ID (127 = alle).</summary>
    public int MscDeviceId { get => _mscDeviceId; set => SetCue(ref _mscDeviceId, Math.Clamp(value, 0, 127)); }
    /// <summary>MSC command format (1 = lys, 0x10 = lyd …).</summary>
    public int MscCommandFormat { get => _mscCommandFormat; set => SetCue(ref _mscCommandFormat, Math.Clamp(value, 0, 127)); }
    public string MscCueNumber { get => _mscCueNumber; set => SetCue(ref _mscCueNumber, value?.Trim() ?? ""); }

    public override string TypeName => "MIDI";
    public override string TypeIcon => "♫";
    public override string Summary => MessageType switch
    {
        MidiMessageType.NoteOn => $"Note on  ch{Channel}  {Data1} / {Data2}",
        MidiMessageType.NoteOff => $"Note off  ch{Channel}  {Data1}",
        MidiMessageType.ProgramChange => $"Program  ch{Channel}  {Data1}",
        MidiMessageType.ControlChange => $"CC  ch{Channel}  {Data1} = {Data2}",
        MidiMessageType.MscGo => $"MSC GO  cue {MscCueNumber}",
        _ => ""
    } + (string.IsNullOrEmpty(Device) ? "" : $"  [{Device}]");
}

/// <summary>Ett krysspunkt i en lyd-cues routingmatrise.</summary>
public sealed class AudioRoute
{
    /// <summary>Kanal i lydfila, fra 1.</summary>
    public int Source { get; set; }
    /// <summary>Utgang/buss i lydpatchen, fra 1.</summary>
    public int Bus { get; set; }
    public double GainDb { get; set; }

    public AudioRoute() { }
    public AudioRoute(int source, int bus, double gainDb = 0) { Source = source; Bus = bus; GainDb = gainDb; }

    /// <summary>Mono → utgang 1 og 2. Ellers kanal n → utgang n.</summary>
    public static List<AudioRoute> Default(int fileChannels)
    {
        if (fileChannels <= 1) return new() { new(1, 1), new(1, 2) };
        return Enumerable.Range(1, fileChannels).Select(c => new AudioRoute(c, c)).ToList();
    }
}

/// <summary>MIDI-triggere lagres som tekst: "N:60", "CC:20", "PC:5".</summary>
public static class MidiTriggers
{
    public static string Describe(string trigger)
    {
        if (string.IsNullOrEmpty(trigger)) return "";
        var p = trigger.Split(':');
        if (p.Length != 2) return trigger;
        return p[0] switch
        {
            "N" => $"Note {p[1]}",
            "CC" => $"CC {p[1]}",
            "PC" => $"Prog {p[1]}",
            _ => trigger
        };
    }
}

public static class TimeFormat
{
    public static string Format(double seconds)
    {
        if (double.IsNaN(seconds) || double.IsInfinity(seconds)) return "";
        var neg = seconds < 0;
        seconds = Math.Abs(seconds);
        var ts = TimeSpan.FromSeconds(seconds);
        var s = ts.TotalHours >= 1
            ? $"{(int)ts.TotalHours}:{ts.Minutes:00}:{ts.Seconds:00}"
            : $"{ts.Minutes:00}:{ts.Seconds:00}.{ts.Milliseconds / 100}";
        return neg ? "-" + s : s;
    }
}
