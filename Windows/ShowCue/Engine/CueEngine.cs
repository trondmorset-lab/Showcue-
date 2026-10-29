using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Windows.Controls;
using System.Windows.Threading;
using ShowCue.Models;
using ShowCue.Views;

namespace ShowCue.Engine;

/// <summary>
/// Kjører cues: pre-wait, auto-continue, auto-follow, stopp og panikk.
/// All logikk her kjører på UI-tråden; bare selve lydmiksingen går på lydtråden.
/// </summary>
public sealed class CueEngine : IDisposable
{
    private readonly Stopwatch _clock = Stopwatch.StartNew();
    private readonly DispatcherTimer _timer;
    private readonly Func<IList<Cue>> _cueList;
    private OutputWindow? _output;

    public AudioEngine Audio { get; } = new();
    public MidiEngine Midi { get; } = new();
    public AppSettings Settings { get; private set; }
    public ObservableCollection<ActiveCue> Active { get; } = new();
    public double Now => _clock.Elapsed.TotalSeconds;

    /// <summary>Utgangsvinduet ble opprettet (brukes til forhåndsvisning og tastevideresending).</summary>
    public event Action<OutputWindow>? OutputCreated;
    public event Action? Ticked;
    public event Action<string>? Log;

    public OutputWindow? Output => _output;

    public CueEngine(AppSettings settings, Func<IList<Cue>> cueList)
    {
        Settings = settings;
        _cueList = cueList;
        _timer = new DispatcherTimer(DispatcherPriority.Render) { Interval = TimeSpan.FromMilliseconds(16) };
        _timer.Tick += (_, _) => Tick();
        _timer.Start();
    }

    /// <summary>Ta i bruk nye innstillinger. Lyden startes bare på nytt (og alt stoppes) hvis lydoppsettet er endret.</summary>
    public void ApplySettings(AppSettings s, bool restartAudio = true)
    {
        Settings = s;
        if (restartAudio)
        {
            StopAll(0);
            Audio.Start(s);
        }
        if (_output != null)
        {
            _output.Configure(s.VideoScreen);
            if (s.VideoScreen >= 0 && !_output.IsVisible) _output.Show();
        }
        else if (s.VideoScreen >= 0)
        {
            EnsureOutput();
        }
    }

    // ------------------------------------------------------------------
    public void Fire(Cue cue)
    {
        var a = Create(cue);
        a.StartAt = Now + cue.PreWait;
        a.Completed += OnCompleted;
        cue.Error = null;
        cue.ActiveCount++;
        Active.Add(a);
        if (cue.PreWait > 0) cue.IsPreWaiting = true;
        else StartActive(a);
    }

    private ActiveCue Create(Cue cue) => cue switch
    {
        AudioCue c => new AudioActive(c, this),
        VideoCue c => new VideoActive(c, this),
        StillCue c => new StillActive(c, this),
        FadeCue c => new FadeActive(c, this),
        StopCue c => new StopActive(c, this),
        _ => new InstantActive(cue, this),
    };

    private void StartActive(ActiveCue a)
    {
        a.Cue.IsPreWaiting = Active.Any(x => x.Cue == a.Cue && x != a && !x.Started);
        try
        {
            a.Begin();
        }
        catch (Exception ex)
        {
            a.Cue.Error = ex.Message;
            Log?.Invoke($"Cue {a.Cue.Number}: {ex.Message}");
            if (!a.Done) a.Stop(0);
            if (!a.Done) ForceRemove(a);
        }
        if (a.Cue.ContinueMode == ContinueMode.AutoContinue) FireNextAfter(a.Cue);
    }

    private void OnCompleted(ActiveCue a)
    {
        Active.Remove(a);
        a.Cue.ActiveCount--;
        if (!a.Cue.IsRunning) { a.Cue.Progress = 0; a.Cue.IsPreWaiting = false; }
        if (a.Started && !a.WasStopped && a.Cue.ContinueMode == ContinueMode.AutoFollow)
            FireNextAfter(a.Cue);
    }

    private void ForceRemove(ActiveCue a)
    {
        a.Completed -= OnCompleted;
        if (Active.Remove(a)) a.Cue.ActiveCount--;
    }

    private void FireNextAfter(Cue cue)
    {
        var list = _cueList();
        var idx = list.IndexOf(cue);
        if (idx < 0) return;
        for (int i = idx + 1; i < list.Count; i++)
        {
            if (list[i].Disabled) continue;
            Fire(list[i]);
            return;
        }
    }

    /// <summary>Finn neste cue for GO etter at <paramref name="cue"/> er avfyrt (hopper over kjeder).</summary>
    public static int NextPlayheadIndex(IList<Cue> list, int firedIndex)
    {
        int i = firedIndex;
        // Hopp over cues som blir trigget automatisk av forrige cue.
        while (i < list.Count && list[i].ContinueMode != ContinueMode.None)
        {
            i++;
            while (i < list.Count && list[i].Disabled) i++;
        }
        i++;
        while (i < list.Count && list[i].Disabled) i++;
        return Math.Min(i, list.Count);
    }

    public IEnumerable<ActiveCue> FindActive(string number)
    {
        if (string.IsNullOrWhiteSpace(number)) return Enumerable.Empty<ActiveCue>();
        return Active.Where(a => a.Started && !a.Done && string.Equals(a.Cue.Number, number.Trim(), StringComparison.OrdinalIgnoreCase)).ToList();
    }

    public void Stop(Cue cue, double fade)
    {
        foreach (var a in Active.Where(a => a.Cue == cue).ToList()) a.Stop(fade);
    }

    public void StopAll(double fade)
    {
        foreach (var a in Active.ToList()) a.Stop(fade);
    }

    // ------------------------------------------------------------------
    public Grid EnsureOutput()
    {
        if (_output == null)
        {
            _output = new OutputWindow();
            _output.Configure(Settings.VideoScreen);
            OutputCreated?.Invoke(_output);
        }
        if (!_output.IsVisible) _output.Show();
        return _output.LayerHost;
    }

    public void ToggleOutput()
    {
        if (_output != null && _output.IsVisible) _output.Hide();
        else EnsureOutput();
    }

    private void Tick()
    {
        var now = Now;
        foreach (var a in Active.ToList())
        {
            if (a.Done) continue;
            if (!a.Started && now >= a.StartAt) StartActive(a);
            if (a.Done) continue;
            a.Tick();
            a.Cue.Progress = a.Progress;
        }
        Ticked?.Invoke();
    }

    public void Dispose()
    {
        _timer.Stop();
        StopAll(0);
        Audio.Dispose();
        Midi.Dispose();
        if (_output != null) { _output.AllowClose = true; _output.Close(); }
    }
}
