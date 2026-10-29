using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using ShowCue.Models;
using Cue = ShowCue.Models.Cue;

namespace ShowCue.Engine;

/// <summary>
/// Én avspilling av en lyd-cue. Kjører på lydtråden inne i <see cref="PatchMixer"/>.
/// Håndterer start/slutt-punkt, loop, fade inn/ut, fades fra fade-cues og routing
/// fra filkanaler til busser. Nivå rampes i dB-domenet så fades høres naturlige ut.
/// </summary>
public sealed class CuePlayback : IBusSource, IDisposable
{
    public const double SilenceDb = -80;

    private readonly struct Send
    {
        public readonly int Bus;
        public readonly float Gain;
        public Send(int bus, float gain) { Bus = bus; Gain = gain; }
    }

    private readonly WaveStream _reader;
    private readonly ISampleProvider _source;
    private volatile bool _rewindRequested;
    private readonly int _srcCh;
    private readonly int _rate;
    private readonly double _startTime;
    private readonly long _framesPerPass;     // long.MaxValue = til fila er slutt
    private readonly bool _loop;
    private readonly long _autoFadeOutFrames;
    private float[] _tmp = Array.Empty<float>();
    private volatile Send[][] _routing;

    private readonly object _lock = new();
    private double _currentDb;
    private double _targetDb;
    private double _dbStepPerFrame;
    private long _rampFramesLeft;
    private bool _stopAfterRamp;
    private bool _autoFadeStarted;

    private long _passFrames;
    private long _totalFrames;
    private volatile bool _finished;
    private int _finishedRaised;
    private int _disposed;

    public Cue Cue { get; }
    /// <summary>Kalles fra lydtråden når avspillingen er ferdig.</summary>
    public event Action<CuePlayback>? Finished;

    public int FileChannels => _srcCh;
    public bool IsFinished => _finished;
    public double Elapsed => Interlocked.Read(ref _totalFrames) / (double)_rate;
    public double PassPosition => Interlocked.Read(ref _passFrames) / (double)_rate;
    /// <summary>Lengde på én gjennomspilling i sekunder (0 = ukjent).</summary>
    public double PassLength => _framesPerPass == long.MaxValue ? 0 : _framesPerPass / (double)_rate;
    public double CurrentDb { get { lock (_lock) return _currentDb; } }
    public bool IsRamping { get { lock (_lock) return _rampFramesLeft > 0 || _stopAfterRamp; } }

    /// <summary>Innstillinger for én avspilling.</summary>
    public sealed record Options(double VolumeDb, double StartTime, double EndTime, bool Loop, double FadeIn, double FadeOut);

    /// <summary>Spill en lydfil (lyd-cue).</summary>
    public CuePlayback(AudioCue cue, int sampleRate)
        : this(cue, new AudioFileReader(cue.FilePath), cue,
               new Options(cue.VolumeDb, cue.StartTime, cue.EndTime, cue.Loop, cue.FadeIn, cue.FadeOut), sampleRate) { }

    /// <summary>Spill en vilkårlig lydstrøm, f.eks. lydsporet i en video (dekodet med Media Foundation).</summary>
    public CuePlayback(Cue owner, WaveStream reader, IRoutedAudio routing, Options o, int sampleRate)
    {
        Cue = owner;
        _rate = sampleRate;

        _reader = reader;
        ISampleProvider samples = reader as ISampleProvider ?? reader.ToSampleProvider();
        _srcCh = reader.WaveFormat.Channels;
        var total = reader.TotalTime.TotalSeconds;
        _startTime = Math.Min(o.StartTime, Math.Max(0, total - 0.01));
        if (_startTime > 0) _reader.CurrentTime = TimeSpan.FromSeconds(_startTime);

        var end = o.EndTime > 0 ? Math.Min(o.EndTime, total > 0 ? total : o.EndTime) : total;
        _framesPerPass = end > _startTime ? (long)((end - _startTime) * _rate) : long.MaxValue;
        _loop = o.Loop && _framesPerPass != long.MaxValue;
        _autoFadeOutFrames = !_loop && o.FadeOut > 0 ? (long)(o.FadeOut * _rate) : 0;

        _source = samples.WaveFormat.SampleRate == sampleRate
            ? samples
            : new WdlResamplingSampleProvider(samples, sampleRate);

        _routing = BuildRouting(routing.EffectiveRoutes(_srcCh), _srcCh);

        var levelDb = o.VolumeDb <= -60 ? SilenceDb : o.VolumeDb;
        if (o.FadeIn > 0)
        {
            _currentDb = SilenceDb;
            BeginRamp(levelDb, o.FadeIn, false);
        }
        else
        {
            _currentDb = _targetDb = levelDb;
        }
    }

    private static Send[][] BuildRouting(IReadOnlyList<AudioRoute> routes, int srcCh)
    {
        var r = new Send[srcCh][];
        for (int s = 0; s < srcCh; s++)
            r[s] = routes.Where(x => x.Source == s + 1 && x.Bus >= 1)
                         .Select(x => new Send(x.Bus - 1, PatchMixer.DbToGain(x.GainDb)))
                         .Where(x => x.Gain > 0)
                         .ToArray();
        return r;
    }

    /// <summary>Bytt routing mens det spiller (f.eks. under lydsjekk).</summary>
    public void SetRouting(IReadOnlyList<AudioRoute> routes) => _routing = BuildRouting(routes, _srcCh);

    /// <summary>Fade til absolutt nivå (dB) over gitt tid.</summary>
    public void FadeTo(double targetDb, double seconds, bool stopWhenDone)
    {
        lock (_lock) BeginRamp(targetDb <= -60 ? SilenceDb : targetDb, seconds, stopWhenDone);
    }

    /// <summary>Juster nivå (kort rampe) – bare hvis ingen fade pågår.</summary>
    public void AdjustLevel(double db)
    {
        lock (_lock)
        {
            if (_rampFramesLeft > 0 || _stopAfterRamp || _autoFadeStarted) return;
            BeginRamp(db <= -60 ? SilenceDb : db, 0.05, false);
        }
    }

    public void Stop(double fadeSeconds)
    {
        if (fadeSeconds <= 0) { _finished = true; return; }
        FadeTo(SilenceDb, fadeSeconds, true);
    }

    private void BeginRamp(double targetDb, double seconds, bool stopWhenDone)
    {
        _targetDb = targetDb;
        _stopAfterRamp = stopWhenDone;
        var frames = (long)(seconds * _rate);
        if (frames <= 0)
        {
            _currentDb = targetDb;
            _rampFramesLeft = 0;
            if (stopWhenDone) _finished = true;
            return;
        }
        _rampFramesLeft = frames;
        _dbStepPerFrame = (targetDb - _currentDb) / frames;
    }

    /// <summary>Hopp tilbake til start (trådsikkert; utføres på lydtråden). Brukes når en video looper.</summary>
    public void RequestRewind() => _rewindRequested = true;

    public bool Render(float[] bus, int frames, int busCount)
    {
        if (_finished) { RaiseFinished(); return false; }
        if (_rewindRequested) { _rewindRequested = false; Rewind(); }

        if (_tmp.Length < frames * _srcCh) _tmp = new float[frames * _srcCh];
        var routing = _routing;
        int written = 0;

        while (written < frames && !_finished)
        {
            long passLeft = _framesPerPass - _passFrames;
            if (passLeft <= 0)
            {
                if (_loop) { Rewind(); continue; }
                break;
            }
            int toRead = (int)Math.Min(frames - written, passLeft);
            int got = _source.Read(_tmp, 0, toRead * _srcCh) / _srcCh;
            if (got == 0)
            {
                if (_loop && _passFrames > 0) { Rewind(); continue; }
                break;
            }
            int keep = MixInto(bus, written, got, busCount, routing);
            written += keep;
            _passFrames += keep;
            Interlocked.Add(ref _totalFrames, keep);
            if (keep < got) break; // stoppet midt i blokka etter fade
        }

        if (written < frames) _finished = true;
        if (_finished) RaiseFinished();
        return !_finished;
    }

    /// <summary>Gain-konvolutt + routing til busser. Returnerer antall rammer som ble brukt.</summary>
    private int MixInto(float[] bus, int frameOffset, int frames, int busCount, Send[][] routing)
    {
        lock (_lock)
        {
            for (int f = 0; f < frames; f++)
            {
                // Automatisk fade ut mot slutten av fila.
                if (_autoFadeOutFrames > 0 && !_autoFadeStarted &&
                    _framesPerPass - (_passFrames + f) <= _autoFadeOutFrames)
                {
                    _autoFadeStarted = true;
                    BeginRamp(SilenceDb, (_framesPerPass - (_passFrames + f)) / (double)_rate, false);
                }

                if (_rampFramesLeft > 0)
                {
                    _currentDb += _dbStepPerFrame;
                    if (--_rampFramesLeft == 0)
                    {
                        _currentDb = _targetDb;
                        if (_stopAfterRamp)
                        {
                            _finished = true;
                            return f;
                        }
                    }
                }

                float g = _currentDb <= SilenceDb + 0.01 ? 0f : (float)Math.Pow(10, _currentDb / 20.0);
                if (g == 0f) continue;
                int src = f * _srcCh;
                int dst = (frameOffset + f) * busCount;
                for (int c = 0; c < _srcCh; c++)
                {
                    float v = _tmp[src + c] * g;
                    foreach (var s in routing[c])
                        if (s.Bus < busCount) bus[dst + s.Bus] += v * s.Gain;
                }
            }
            return frames;
        }
    }

    private void Rewind()
    {
        _reader.CurrentTime = TimeSpan.FromSeconds(_startTime);
        _passFrames = 0;
    }

    private void RaiseFinished()
    {
        if (Interlocked.Exchange(ref _finishedRaised, 1) == 0) Finished?.Invoke(this);
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) == 0) _reader.Dispose();
    }
}
