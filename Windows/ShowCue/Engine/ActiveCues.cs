using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using ShowCue.Models;

namespace ShowCue.Engine;

/// <summary>En cue som er avfyrt: venter (pre-wait), spiller, eller holder på å fade ut.</summary>
public abstract class ActiveCue : ObservableObject
{
    protected readonly CueEngine Engine;
    private double _elapsed;
    private double _duration;
    private bool _stopping;

    public Cue Cue { get; }
    public double StartAt { get; set; }
    public bool Started { get; private set; }
    public bool Done { get; private set; }
    /// <summary>Stoppet manuelt eller av stopp-/fade-cue (utløser ikke auto-follow).</summary>
    public bool WasStopped { get; protected set; }
    public event Action<ActiveCue>? Completed;

    protected ActiveCue(Cue cue, CueEngine engine) { Cue = cue; Engine = engine; }

    public double Elapsed { get => _elapsed; protected set { if (Set(ref _elapsed, value)) RaiseTime(); } }
    /// <summary>0 = ukjent eller uendelig (loop / står til stopp).</summary>
    public double Duration { get => _duration; protected set { if (Set(ref _duration, value)) RaiseTime(); } }
    public bool IsStopping { get => _stopping; protected set { if (Set(ref _stopping, value)) OnPropertyChanged(nameof(StateText)); } }
    public double Progress => Duration > 0 ? Math.Clamp(Elapsed / Duration, 0, 1) : 0;
    public bool HasDuration => Duration > 0;

    public string ElapsedText => !Started ? "-" + TimeFormat.Format(Math.Max(0, StartAt - Engine.Now)) : TimeFormat.Format(Elapsed);
    public string RemainingText => Started && Duration > 0 ? "-" + TimeFormat.Format(Math.Max(0, Duration - Elapsed)) : (Started ? "∞" : "");
    public string StateText => !Started ? "Pre-wait" : IsStopping ? "Fader ut" : "Spiller";

    private void RaiseTime()
    {
        OnPropertyChanged(nameof(Progress));
        OnPropertyChanged(nameof(HasDuration));
        OnPropertyChanged(nameof(ElapsedText));
        OnPropertyChanged(nameof(RemainingText));
    }

    internal void Begin()
    {
        Started = true;
        OnPropertyChanged(nameof(StateText));
        OnBegin();
    }

    /// <summary>Kalles ca. 60 ganger i sekundet fra UI-tråden.</summary>
    internal virtual void Tick()
    {
        if (!Started) { OnPropertyChanged(nameof(ElapsedText)); return; }
    }

    protected abstract void OnBegin();

    /// <summary>Stopp, eventuelt med fade (sekunder).</summary>
    public virtual void Stop(double fadeSeconds)
    {
        WasStopped = true;
        if (!Started) Complete();
    }

    /// <summary>Utfør en fade-cue mot denne cuen.</summary>
    public virtual void ApplyFade(FadeCue fade) { }

    protected void Complete()
    {
        if (Done) return;
        Done = true;
        OnCompleted();
        Completed?.Invoke(this);
    }

    protected virtual void OnCompleted() { }
}

// ======================================================================
public sealed class AudioActive : ActiveCue
{
    private CuePlayback? _pb;
    private AudioCue AudioCue => (AudioCue)Cue;

    public AudioActive(AudioCue cue, CueEngine engine) : base(cue, engine) { }

    protected override void OnBegin()
    {
        if (!File.Exists(AudioCue.FilePath)) throw new FileNotFoundException("Lydfila finnes ikke: " + AudioCue.FilePath);
        _pb = Engine.Audio.Play(AudioCue);
        var pb = _pb;
        // Fila lukkes først når lydtråden har sluppet den.
        pb.Finished += _ => Application.Current.Dispatcher.BeginInvoke(() => { pb.Dispose(); Complete(); });
        Duration = AudioCue.Loop ? 0 : _pb.PassLength;
        if (AudioCue.FileDuration <= 0 && _pb.PassLength > 0 && AudioCue.EndTime <= 0)
            AudioCue.FileDuration = AudioCue.StartTime + _pb.PassLength;
        if (AudioCue.FileChannels != _pb.FileChannels) AudioCue.FileChannels = _pb.FileChannels;
        // Endringer i routing og nivå høres med en gang (nyttig under lydsjekk).
        AudioCue.PropertyChanged += OnCueChanged;
    }

    private void OnCueChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (_pb == null || Done) return;
        if (e.PropertyName == nameof(AudioCue.Routes)) _pb.SetRouting(AudioCue.EffectiveRoutes(_pb.FileChannels));
        else if (e.PropertyName == nameof(AudioCue.VolumeDb) && !IsStopping) _pb.AdjustLevel(AudioCue.VolumeDb);
    }

    internal override void Tick()
    {
        base.Tick();
        if (_pb != null) Elapsed = AudioCue.Loop ? _pb.Elapsed : _pb.PassPosition;
    }

    public override void Stop(double fadeSeconds)
    {
        base.Stop(fadeSeconds);
        if (_pb == null) return;
        IsStopping = true;
        _pb.Stop(fadeSeconds);
        // Uten fade: fjern fra lista med en gang, selv om lydutgangen skulle ha hengt seg.
        if (fadeSeconds <= 0) Complete();
    }

    public override void ApplyFade(FadeCue fade)
    {
        if (_pb == null) return;
        if (fade.FadeAudio)
        {
            if (fade.StopWhenDone) { WasStopped = true; IsStopping = true; }
            _pb.FadeTo(fade.TargetDb, fade.FadeTime, fade.StopWhenDone);
        }
        else if (fade.StopWhenDone)
        {
            Stop(0);
        }
    }

    protected override void OnCompleted()
    {
        AudioCue.PropertyChanged -= OnCueChanged;
        if (_pb == null) return;
        var pb = _pb;
        // Sørg for at fila lukkes selv om lydutgangen er stoppet/byttet (da kommer aldri Finished).
        Engine.Audio.Mixer?.Remove(pb);
        _ = Task.Delay(500).ContinueWith(_ => pb.Dispose());
    }

}

// ======================================================================
/// <summary>Felles logikk for video, bilde og PDF: lag i utgangsvinduet, opacity-fade.</summary>
public abstract class VisualActive : ActiveCue
{
    protected FrameworkElement? Element;
    protected double StartedAt;
    private double? _finishAt;
    protected VisualCue VCue => (VisualCue)Cue;

    protected VisualActive(VisualCue cue, CueEngine engine) : base(cue, engine) { }

    protected abstract FrameworkElement CreateElement();

    protected override void OnBegin()
    {
        if (!File.Exists(VCue.FilePath)) throw new FileNotFoundException("Fila finnes ikke: " + VCue.FilePath);
        var host = Engine.EnsureOutput();

        if (VCue.ReplaceOthers)
        {
            // Krysstoning: de andre fades ut på samme tid som denne fades inn.
            foreach (var other in Engine.Active.OfType<VisualActive>().Where(v => v != this && v.Started && !v.Done && !v.IsStopping).ToList())
                other.Stop(VCue.FadeIn > 0 ? VCue.FadeIn : other.VCue.FadeOut);
        }

        Element = CreateElement();
        Element.Opacity = 0;
        host.Children.Add(Element);
        StartedAt = Engine.Now;
        AnimateOpacity(1, VCue.FadeIn);
    }

    protected static Stretch ToStretch(VisualStretch s) => s switch
    {
        VisualStretch.UniformToFill => Stretch.UniformToFill,
        VisualStretch.Fill => Stretch.Fill,
        VisualStretch.None => Stretch.None,
        _ => Stretch.Uniform,
    };

    protected void AnimateOpacity(double to, double seconds)
    {
        if (Element == null) return;
        if (seconds <= 0)
        {
            Element.BeginAnimation(UIElement.OpacityProperty, null);
            Element.Opacity = to;
            return;
        }
        var anim = new DoubleAnimation(to, TimeSpan.FromSeconds(seconds)) { FillBehavior = FillBehavior.HoldEnd };
        Element.BeginAnimation(UIElement.OpacityProperty, anim, HandoffBehavior.SnapshotAndReplace);
    }

    internal override void Tick()
    {
        base.Tick();
        if (_finishAt is double t && Engine.Now >= t) Finish();
    }

    public override void Stop(double fadeSeconds)
    {
        base.Stop(fadeSeconds);
        if (!Started || Done) return;
        IsStopping = true;
        AnimateOpacity(0, fadeSeconds);
        OnStopping(fadeSeconds);
        if (fadeSeconds <= 0) Finish();
        else _finishAt = Engine.Now + fadeSeconds;
    }

    protected virtual void OnStopping(double fadeSeconds) { }

    public override void ApplyFade(FadeCue fade)
    {
        if (Element == null || Done) return;
        if (fade.FadeVisual) AnimateOpacity(fade.TargetOpacity / 100.0, fade.FadeTime);
        if (fade.StopWhenDone)
        {
            WasStopped = true;
            IsStopping = true;
            _finishAt = Engine.Now + fade.FadeTime;
        }
    }

    protected void Finish()
    {
        if (Done) return;
        _finishAt = null;
        OnRemove();
        if (Element != null)
        {
            Element.BeginAnimation(UIElement.OpacityProperty, null);
            if (Element.Parent is Panel p) p.Children.Remove(Element);
        }
        Complete();
    }

    protected virtual void OnRemove() { }
}

// ======================================================================
public sealed class StillActive : VisualActive
{
    private Image? _image;
    private StillCue SCue => (StillCue)Cue;

    public StillActive(StillCue cue, CueEngine engine) : base(cue, engine) { }

    protected override FrameworkElement CreateElement()
    {
        _image = new Image { Stretch = ToStretch(SCue.Stretch), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        RenderOptions.SetBitmapScalingMode(_image, BitmapScalingMode.HighQuality);

        if (SCue is ImageCue ic)
        {
            _image.Source = MediaCache.GetImage(ic.FilePath);
        }
        else if (SCue is PdfCue pc)
        {
            var task = MediaCache.GetPdfPage(pc.FilePath, pc.Page);
            if (task.IsCompletedSuccessfully) _image.Source = task.Result;
            else _ = LoadPdfAsync(task);
        }
        Duration = SCue.Duration;
        return _image;
    }

    private async Task LoadPdfAsync(Task<System.Windows.Media.Imaging.BitmapSource> task)
    {
        try
        {
            var bmp = await task;
            if (_image != null && !Done) _image.Source = bmp;
        }
        catch (Exception ex)
        {
            Cue.Error = "PDF: " + ex.Message;
            Stop(0);
        }
    }

    internal override void Tick()
    {
        base.Tick();
        if (!Started || Done) return;
        Elapsed = Engine.Now - StartedAt;
        if (SCue.HoldTime > 0 && !IsStopping && Elapsed >= SCue.FadeIn + SCue.HoldTime)
        {
            Stop(SCue.FadeOut);
            WasStopped = false; // naturlig slutt → auto-follow skal fortsatt virke
        }
    }
}

// ======================================================================
public sealed class VideoActive : VisualActive
{
    private MediaElement? _media;
    private CuePlayback? _audio;
    private bool _audioStarted;
    private double _lastResync;
    private VideoCue VidCue => (VideoCue)Cue;

    /// <summary>Største avvik mellom bilde og lyd før bildet justeres (sekunder).</summary>
    private const double MaxDrift = 0.12;

    public VideoActive(VideoCue cue, CueEngine engine) : base(cue, engine) { }

    protected override FrameworkElement CreateElement()
    {
        // Lyden spilles av ShowCue sin egen lydmotor (gjennom lydpatchen), så MediaElement er alltid dempet.
        _media = new MediaElement
        {
            LoadedBehavior = MediaState.Manual,
            UnloadedBehavior = MediaState.Manual,
            Stretch = ToStretch(VidCue.Stretch),
            IsMuted = true,
            Volume = 0,
            ScrubbingEnabled = false,
        };
        PrepareAudio();

        _media.MediaOpened += (_, _) =>
        {
            if (_media.NaturalDuration.HasTimeSpan)
            {
                var d = _media.NaturalDuration.TimeSpan.TotalSeconds;
                VidCue.KnownDuration = d;
                Duration = VidCue.Loop ? 0 : d;
            }
            StartAudio(); // bilde og lyd starter samtidig
        };
        _media.MediaEnded += (_, _) =>
        {
            if (VidCue.Loop && !IsStopping)
            {
                _media.Position = TimeSpan.Zero;
                _media.Play();
                _audio?.RequestRewind();
            }
            else Finish();
        };
        _media.MediaFailed += (_, e) =>
        {
            Cue.Error = "Video: " + e.ErrorException?.Message;
            Finish();
        };
        _media.Source = new Uri(VidCue.FilePath);
        _media.Play();
        VidCue.PropertyChanged += OnCueChanged;
        return _media;
    }

    private void PrepareAudio()
    {
        if (VidCue.Routes is { Count: 0 }) return; // lyd slått av for denne cuen
        var mixer = Engine.Audio.Mixer;
        if (mixer == null) return;
        var reader = VideoAudio.Open(VidCue.FilePath);
        if (reader == null)
        {
            if (VidCue.FileChannels != 0) VidCue.FileChannels = 0;
            return;
        }
        if (VidCue.FileChannels != reader.WaveFormat.Channels) VidCue.FileChannels = reader.WaveFormat.Channels;
        // Fade ut håndteres av VideoActive (samme tid for bilde og lyd), derfor FadeOut = 0 her.
        var o = new CuePlayback.Options(VidCue.VolumeDb, 0, 0, VidCue.Loop, VidCue.FadeIn, 0);
        _audio = new CuePlayback(VidCue, reader, VidCue, o, mixer.WaveFormat.SampleRate);
        var pb = _audio;
        pb.Finished += _ => Application.Current.Dispatcher.BeginInvoke(pb.Dispose);
    }

    private void StartAudio()
    {
        if (_audio == null || _audioStarted || Done) return;
        _audioStarted = true;
        Engine.Audio.Mixer?.Add(_audio);
        _lastResync = Engine.Now;
    }

    private void OnCueChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (_audio == null || Done) return;
        if (e.PropertyName == nameof(VideoCue.Routes)) _audio.SetRouting(VidCue.EffectiveRoutes(_audio.FileChannels));
        else if (e.PropertyName == nameof(VideoCue.VolumeDb) && !IsStopping) _audio.AdjustLevel(VidCue.VolumeDb);
    }

    internal override void Tick()
    {
        base.Tick();
        if (_media == null || Done) return;
        Elapsed = _media.Position.TotalSeconds;

        // Lyden er «master». Lydkortet (f.eks. Dante-klokka) og PC-klokka går aldri helt likt,
        // så bildet justeres hvis det glir mer enn MaxDrift fra lyden.
        if (_audio != null && _audioStarted && !IsStopping && Engine.Now - _lastResync > 2)
        {
            var audioPos = _audio.PassPosition;
            if (audioPos > 0.5 && Math.Abs(audioPos - Elapsed) > MaxDrift && (Duration == 0 || audioPos < Duration - 1))
            {
                _media.Position = TimeSpan.FromSeconds(audioPos);
                _lastResync = Engine.Now;
            }
        }

        // Automatisk fade ut mot slutten av videoen.
        if (!VidCue.Loop && !IsStopping && VidCue.FadeOut > 0 && Duration > 0 && Duration - Elapsed <= VidCue.FadeOut)
        {
            Stop(Math.Max(0.05, Duration - Elapsed));
            WasStopped = false;
        }
    }

    protected override void OnStopping(double fadeSeconds) => _audio?.Stop(fadeSeconds);

    public override void ApplyFade(FadeCue fade)
    {
        base.ApplyFade(fade);
        if (fade.FadeAudio) _audio?.FadeTo(fade.TargetDb, fade.FadeTime, false);
    }

    protected override void OnRemove()
    {
        VidCue.PropertyChanged -= OnCueChanged;
        if (_audio != null)
        {
            var pb = _audio;
            pb.Stop(0);
            Engine.Audio.Mixer?.Remove(pb);
            if (!_audioStarted) pb.Dispose();
            else _ = Task.Delay(500).ContinueWith(_ => pb.Dispose());
        }
        if (_media == null) return;
        _media.Stop();
        _media.Close();
        _media.Source = null;
    }
}

// ======================================================================
/// <summary>Fade-cue: starter fades på målene og varer i fade-tiden.</summary>
public sealed class FadeActive : ActiveCue
{
    private double _begin;
    private FadeCue F => (FadeCue)Cue;
    public FadeActive(FadeCue cue, CueEngine engine) : base(cue, engine) { }

    protected override void OnBegin()
    {
        _begin = Engine.Now;
        Duration = F.FadeTime;
        var targets = Engine.FindActive(F.Target).ToList();
        if (targets.Count == 0) Cue.Error = string.IsNullOrEmpty(F.Target) ? "Mangler mål-cue" : $"Cue {F.Target} kjører ikke";
        foreach (var t in targets) t.ApplyFade(F);
        if (F.FadeTime <= 0) Complete();
    }

    internal override void Tick()
    {
        base.Tick();
        if (!Started || Done) return;
        Elapsed = Engine.Now - _begin;
        if (Elapsed >= F.FadeTime) Complete();
    }

    public override void Stop(double fadeSeconds) { base.Stop(fadeSeconds); Complete(); }
}

// ======================================================================
public sealed class StopActive : ActiveCue
{
    private double _begin;
    private StopCue S => (StopCue)Cue;
    public StopActive(StopCue cue, CueEngine engine) : base(cue, engine) { }

    protected override void OnBegin()
    {
        _begin = Engine.Now;
        Duration = S.FadeTime;
        var targets = string.IsNullOrEmpty(S.Target)
            ? Engine.Active.Where(a => a != this && a is not StopActive).ToList()
            : Engine.FindActive(S.Target).ToList();
        foreach (var t in targets) t.Stop(S.FadeTime);
        if (S.FadeTime <= 0) Complete();
    }

    internal override void Tick()
    {
        base.Tick();
        if (!Started || Done) return;
        Elapsed = Engine.Now - _begin;
        if (Elapsed >= S.FadeTime) Complete();
    }

    public override void Stop(double fadeSeconds) { base.Stop(fadeSeconds); Complete(); }
}

// ======================================================================
/// <summary>OSC og MIDI: sendes umiddelbart og er ferdige med en gang.</summary>
public sealed class InstantActive : ActiveCue
{
    public InstantActive(Cue cue, CueEngine engine) : base(cue, engine) { }

    protected override void OnBegin()
    {
        try
        {
            switch (Cue)
            {
                case OscCue o: Osc.Send(o.Host, o.Port, o.Address, o.Arguments); break;
                case MidiCue m: Engine.Midi.Send(m); break;
            }
        }
        finally
        {
            Complete();
        }
    }
}
