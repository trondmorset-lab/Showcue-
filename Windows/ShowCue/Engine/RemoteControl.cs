using System.Globalization;
using System.Windows.Threading;
using ShowCue.Models;

namespace ShowCue.Engine;

/// <summary>Det fjernstyringen kan be hovedvinduet om å gjøre. Alle kall skjer på UI-tråden.</summary>
public interface IShowControl
{
    void Go();
    void StopAll();
    void Panic();
    void HardStop();
    void MovePlayhead(int delta);
    bool SelectCue(string number);
    bool StartCue(string number);
    bool StopCue(string number);
    bool GoCue(string number);
    bool FireHotkey(string key);
    /// <summary>Starter cuer som har denne MIDI-triggeren. Returnerer antall.</summary>
    int FireMidiTrigger(string trigger);
    void RemoteLog(string text);
    /// <summary>Send all status på nytt (Companion ba om det).</summary>
    void RefreshFeedback();
}

/// <summary>
/// Tar imot OSC og MIDI og oversetter til kommandoer.
///
/// OSC (port 53000 som standard, samme som QLab):
///   /go                         GO (neste cue)
///   /stop  /panic  /hardstop    stopp alt (med fade / Esc-oppførsel / umiddelbart)
///   /next  /previous            flytt GO-markøren
///   /playhead/{nr}  /select/{nr}  sett markøren til cue
///   /cue/{nr}/start             start cue (markøren flyttes ikke)
///   /cue/{nr}/stop              stopp cue (med cuens fade ut)
///   /cue/{nr}/go                sett markøren og kjør GO
///   /hotkey/{tast}              som å trykke hurtigtasten (f.eks. /hotkey/F1)
///   /refresh                    send all status tilbake på nytt
///   Cuenummer kan også sendes som argument: /cue/start "12"
/// </summary>
public sealed class RemoteControl : IDisposable
{
    private readonly IShowControl _show;
    private readonly Dispatcher _ui;
    private readonly OscServer _osc = new();
    private readonly MidiInput _midi = new();
    private AppSettings _settings;
    private Action<string>? _learn;

    public string OscStatus { get; private set; } = "OSC inn: av";
    public string MidiStatus { get; private set; } = "MIDI inn: av";
    public event Action? StatusChanged;

    public RemoteControl(IShowControl show, Dispatcher ui, AppSettings settings)
    {
        _show = show;
        _ui = ui;
        _settings = settings;
        _osc.MessageReceived += (m, from) => _ui.BeginInvoke(() => HandleOsc(m, from.Address.ToString()));
        _midi.Trigger += (t, ch) => _ui.BeginInvoke(() => HandleMidi(t, ch));
        _midi.Msc += m => _ui.BeginInvoke(() => HandleMsc(m));
    }

    public void Apply(AppSettings s)
    {
        _settings = s;
        _osc.Stop();
        if (s.OscInEnabled)
        {
            try
            {
                _osc.Start(s.OscInPort);
                var ips = OscServer.LocalAddresses();
                OscStatus = $"OSC inn: port {s.OscInPort}" + (ips.Count > 0 ? "  (" + string.Join(", ", ips) + ")" : "");
            }
            catch (Exception ex)
            {
                OscStatus = $"OSC inn: kunne ikke åpne port {s.OscInPort} – {ex.Message}";
            }
        }
        else OscStatus = "OSC inn: av";

        try
        {
            _midi.Open(s.MidiInDevice, s.MidiInChannel);
            MidiStatus = _midi.IsOpen ? $"MIDI inn: {s.MidiInDevice}" + (s.MidiInChannel == 0 ? " (alle kanaler)" : $" (kanal {s.MidiInChannel})") : "MIDI inn: av";
        }
        catch (Exception ex)
        {
            MidiStatus = "MIDI inn: " + ex.Message;
        }
        StatusChanged?.Invoke();
    }

    /// <summary>Neste MIDI-melding sendes til <paramref name="callback"/> i stedet for å utføres.</summary>
    public void BeginLearn(Action<string> callback) => _learn = callback;
    public void CancelLearn() => _learn = null;
    public bool IsLearning => _learn != null;
    public bool MidiOpen => _midi.IsOpen;

    // ------------------------------------------------------------------
    private void HandleMidi(string trigger, int channel)
    {
        if (_learn is { } learn)
        {
            _learn = null;
            learn(trigger);
            return;
        }
        var s = _settings;
        string what;
        if (trigger == s.MidiGo) { _show.Go(); what = "GO"; }
        else if (trigger == s.MidiStopAll) { _show.Panic(); what = "stopp alt"; }
        else if (trigger == s.MidiNext) { _show.MovePlayhead(1); what = "neste"; }
        else if (trigger == s.MidiPrevious) { _show.MovePlayhead(-1); what = "forrige"; }
        else
        {
            int n = _show.FireMidiTrigger(trigger);
            if (n == 0) { _show.RemoteLog($"MIDI: {MidiTriggers.Describe(trigger)} (kanal {channel}) – ingen cue koblet til"); return; }
            what = n == 1 ? "1 cue" : $"{n} cues";
        }
        _show.RemoteLog($"MIDI: {MidiTriggers.Describe(trigger)} → {what}");
    }

    private void HandleMsc(MscCommand m)
    {
        if (!_settings.MscInEnabled) return;
        if (_settings.MscInDeviceId != 127 && m.DeviceId != 127 && m.DeviceId != _settings.MscInDeviceId) return;
        bool ok = true;
        switch (m.Command)
        {
            case MscCommand.Go:
                if (string.IsNullOrEmpty(m.CueNumber)) _show.Go();
                else ok = _show.GoCue(m.CueNumber);
                break;
            case MscCommand.Stop:
                if (string.IsNullOrEmpty(m.CueNumber)) _show.StopAll();
                else ok = _show.StopCue(m.CueNumber);
                break;
            case MscCommand.AllOff:
            case MscCommand.Reset:
                _show.StopAll();
                break;
            default:
                return;
        }
        _show.RemoteLog($"MSC: kommando {m.Command:X2} {m.CueNumber}" + (ok ? "" : " – fant ikke cuen"));
    }

    /// <summary>Utfører én OSC-melding. Public for testing.</summary>
    public void HandleOsc(OscMessage m, string from)
    {
        bool ok = Execute(m);
        _show.RemoteLog($"OSC fra {from}: {m}" + (ok ? "" : "  – ukjent kommando eller cue"));
    }

    private bool Execute(OscMessage m)
    {
        var parts = m.Address.Trim('/').Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0) return false;
        // Noen sendere sender /go med argument 0 ved knapp-slipp. Ignorer «av»-meldinger.
        if (m.Args.Count == 1 && IsOff(m.Args[0])) return true;
        string? argNumber = m.Args.Count > 0 && !IsOff(m.Args[0]) && m.Args[0] is not bool ? ArgText(m.Args[0]) : null;

        // Tillat prefiks /showcue/... (nyttig når flere programmer deler port via ruter).
        if (parts[0].Equals("showcue", StringComparison.OrdinalIgnoreCase)) parts = parts[1..];
        if (parts.Length == 0) return false;
        var cmd = parts[0].ToLowerInvariant();

        switch (cmd)
        {
            case "go" when parts.Length == 1:
                // Knapper (TouchOSC o.l.) sender ofte /go 1 ved trykk – bare tekst-argument tolkes som cuenummer.
                if (m.Args.Count > 0 && m.Args[0] is string cueArg) return _show.GoCue(cueArg);
                _show.Go(); return true;
            case "go" when parts.Length == 2:
                return _show.GoCue(parts[1]);
            case "stop" when parts.Length == 1: _show.StopAll(); return true;
            case "panic" when parts.Length == 1: _show.Panic(); return true;
            case "hardstop" when parts.Length == 1: _show.HardStop(); return true;
            case "refresh" or "status" when parts.Length == 1: _show.RefreshFeedback(); return true;
            case "next" when parts.Length == 1: _show.MovePlayhead(1); return true;
            case "previous" or "prev" when parts.Length == 1: _show.MovePlayhead(-1); return true;
            case "playhead" or "select":
                if (parts.Length == 2 && parts[1] is "next") { _show.MovePlayhead(1); return true; }
                if (parts.Length == 2 && parts[1] is "previous" or "prev") { _show.MovePlayhead(-1); return true; }
                var n = parts.Length >= 2 ? parts[1] : argNumber;
                return n != null && _show.SelectCue(n);
            case "hotkey":
                var k = parts.Length >= 2 ? parts[1] : argNumber;
                return k != null && _show.FireHotkey(k.ToUpperInvariant());
            case "cue":
                // /cue/{nr}/{handling}  eller  /cue/{handling} med nummer som argument
                string? number; string action;
                if (parts.Length >= 3) { number = parts[1]; action = parts[2]; }
                else if (parts.Length == 2 && argNumber != null) { number = argNumber; action = parts[1]; }
                else return false;
                return action.ToLowerInvariant() switch
                {
                    "start" => _show.StartCue(number),
                    "stop" => _show.StopCue(number),
                    "go" => _show.GoCue(number),
                    "select" or "playhead" => _show.SelectCue(number),
                    _ => false
                };
        }
        return false;
    }

    private static bool IsOff(object a) => a switch
    {
        int i => i == 0,
        float f => f == 0,
        bool b => !b,
        _ => false
    };

    private static string ArgText(object a) => a switch
    {
        float f => f.ToString("0.###", CultureInfo.InvariantCulture),
        double d => d.ToString("0.###", CultureInfo.InvariantCulture),
        _ => a.ToString() ?? ""
    };

    public void Dispose()
    {
        _osc.Dispose();
        _midi.Dispose();
    }
}
