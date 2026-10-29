using NAudio.Wave;
using ShowCue.Models;

namespace ShowCue.Engine;

/// <summary>En lydkilde som mikser seg selv inn i bussene.</summary>
public interface IBusSource
{
    /// <summary>
    /// Legg til <paramref name="frames"/> rammer i <paramref name="bus"/> (interleaved, <paramref name="busCount"/> busser).
    /// Returner false når kilden er ferdig og skal fjernes.
    /// </summary>
    bool Render(float[] bus, int frames, int busCount);
}

/// <summary>
/// Hjertet i lydmotoren:
///   cue → (routingmatrise) → busser → (patch) → kanaler på lydkortet.
/// Kjører på lydtråden. Patch kan endres mens det spilles.
/// </summary>
public sealed class PatchMixer : ISampleProvider
{
    private sealed class PatchState
    {
        public required float[] Gains;      // per buss, lineær
        public required int[][] Channels;   // per buss, 0-baserte kanaler på lydkortet
        public int BusCount => Gains.Length;
    }

    private readonly List<IBusSource> _sources = new();
    private readonly object _lock = new();
    private IBusSource[] _snapshot = Array.Empty<IBusSource>();
    private bool _dirty;
    private volatile PatchState _patch;
    private float[] _bus = Array.Empty<float>();
    private volatile float[] _busLevels = Array.Empty<float>();
    private volatile float[] _channelLevels;
    private readonly float _decay;

    public WaveFormat WaveFormat { get; }
    public int DeviceChannels { get; }

    /// <summary>Kalles fra lydtråden når en kilde er ferdig.</summary>
    public event Action<IBusSource>? SourceFinished;

    public PatchMixer(int sampleRate, int deviceChannels, IReadOnlyList<PatchBus> patch)
    {
        DeviceChannels = Math.Max(1, deviceChannels);
        WaveFormat = WaveFormat.CreateIeeeFloatWaveFormat(sampleRate, DeviceChannels);
        _channelLevels = new float[DeviceChannels];
        _patch = Build(patch);
        // Nivåmålere faller ca. 20 dB i sekundet, uavhengig av bufferstørrelse (beregnes per blokk).
        _decay = (float)Math.Pow(10, -20.0 / 20.0 / sampleRate);
    }

    public int BusCount => _patch.BusCount;

    public void SetPatch(IReadOnlyList<PatchBus> patch) => _patch = Build(patch);

    private PatchState Build(IReadOnlyList<PatchBus> patch)
    {
        var gains = new float[patch.Count];
        var chans = new int[patch.Count][];
        for (int b = 0; b < patch.Count; b++)
        {
            gains[b] = DbToGain(patch[b].GainDb);
            chans[b] = patch[b].Channels.Where(c => c >= 1 && c <= DeviceChannels).Select(c => c - 1).Distinct().ToArray();
        }
        return new PatchState { Gains = gains, Channels = chans };
    }

    public static float DbToGain(double db) => db <= -60 ? 0f : (float)Math.Pow(10, db / 20.0);

    public void Add(IBusSource s)
    {
        lock (_lock) { _sources.Add(s); _dirty = true; }
    }

    public void Remove(IBusSource s)
    {
        lock (_lock) { if (_sources.Remove(s)) _dirty = true; }
    }

    public void Clear()
    {
        lock (_lock) { _sources.Clear(); _dirty = true; }
    }

    /// <summary>Toppnivå per buss (0..1+, faller langsomt). Trygt å lese fra UI-tråden.</summary>
    public float[] BusLevels => _busLevels;
    /// <summary>Toppnivå per kanal på lydkortet.</summary>
    public float[] ChannelLevels => _channelLevels;

    public int Read(float[] buffer, int offset, int count)
    {
        var patch = _patch;
        int D = DeviceChannels, B = patch.BusCount;
        int frames = count / D;

        if (_bus.Length < frames * B) _bus = new float[frames * B];
        Array.Clear(_bus, 0, frames * B);
        Array.Clear(buffer, offset, frames * D);

        if (_dirty)
        {
            lock (_lock) { _snapshot = _sources.ToArray(); _dirty = false; }
        }
        foreach (var s in _snapshot)
        {
            bool alive;
            try { alive = s.Render(_bus, frames, B); }
            catch { alive = false; } // én ødelagt fil skal aldri stoppe resten av lyden
            if (!alive)
            {
                Remove(s);
                SourceFinished?.Invoke(s);
            }
        }

        // Buss → kanaler, med målere.
        float blockDecay = (float)Math.Pow(_decay, frames);
        var busLevels = _busLevels.Length == B ? _busLevels : new float[B];
        for (int b = 0; b < B; b++)
        {
            float g = patch.Gains[b];
            var chans = patch.Channels[b];
            float peak = 0;
            for (int f = 0; f < frames; f++)
            {
                float v = _bus[f * B + b] * g;
                float a = Math.Abs(v);
                if (a > peak) peak = a;
                if (chans.Length == 0) continue;
                int o = offset + f * D;
                foreach (var c in chans) buffer[o + c] += v;
            }
            busLevels[b] = Math.Max(peak, busLevels[b] * blockDecay);
        }
        _busLevels = busLevels;

        var chLevels = _channelLevels;
        for (int c = 0; c < D; c++)
        {
            float peak = 0;
            for (int f = 0; f < frames; f++)
            {
                float a = Math.Abs(buffer[offset + f * D + c]);
                if (a > peak) peak = a;
            }
            chLevels[c] = Math.Max(peak, chLevels[c] * blockDecay);
        }
        return frames * D;
    }
}

/// <summary>Rosa støy på −18 dBFS til én buss, for linjesjekk av patchen.</summary>
public sealed class TestToneSource : IBusSource
{
    private readonly Random _rng = new();
    private double _b0, _b1, _b2, _b3, _b4, _b5, _b6;
    private volatile bool _stop;
    /// <summary>Skalerer filteret til ca. −18 dBFS RMS (målt i testene).</summary>
    public const double PinkScale = 0.075;
    public int Bus { get; }

    public TestToneSource(int busIndex) { Bus = busIndex; }

    public void Stop() => _stop = true;

    public bool Render(float[] bus, int frames, int busCount)
    {
        if (_stop) return false;
        if (Bus >= busCount) return true;
        for (int f = 0; f < frames; f++)
        {
            // Paul Kellett sin rosa støy-filter
            double w = _rng.NextDouble() * 2 - 1;
            _b0 = 0.99886 * _b0 + w * 0.0555179;
            _b1 = 0.99332 * _b1 + w * 0.0750759;
            _b2 = 0.96900 * _b2 + w * 0.1538520;
            _b3 = 0.86650 * _b3 + w * 0.3104856;
            _b4 = 0.55000 * _b4 + w * 0.5329522;
            _b5 = -0.7616 * _b5 - w * 0.0168980;
            double pink = _b0 + _b1 + _b2 + _b3 + _b4 + _b5 + _b6 + w * 0.5362;
            _b6 = w * 0.115926;
            bus[f * busCount + Bus] += (float)(pink * PinkScale);
        }
        return true;
    }
}
