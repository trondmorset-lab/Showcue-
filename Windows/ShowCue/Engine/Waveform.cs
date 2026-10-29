using System.Collections.Concurrent;
using System.IO;
using NAudio.Wave;
using ShowCue.Models;
using Cue = ShowCue.Models.Cue;

namespace ShowCue.Engine;

/// <summary>Bølgeform for en lydfil eller lydsporet i en video: min/maks per bit, samlet over alle kanaler.</summary>
public sealed class WaveformData
{
    public required float[] Min { get; init; }
    public required float[] Max { get; init; }
    /// <summary>Lengde i sekunder.</summary>
    public double Duration { get; init; }
    public int Channels { get; init; }
    public int Buckets => Min.Length;

    /// <summary>Antall biter bølgeformen deles i (nok til å zoome godt inn på vanlige låter).</summary>
    public const int DefaultBuckets = 6000;

    /// <summary>Leser hele kilden og regner ut min/maks per bit.</summary>
    public static WaveformData Compute(ISampleProvider src, long totalFrames, int buckets = DefaultBuckets, CancellationToken ct = default)
    {
        int ch = src.WaveFormat.Channels;
        int rate = src.WaveFormat.SampleRate;
        buckets = (int)Math.Max(1, Math.Min(buckets, Math.Max(1, totalFrames)));
        double framesPerBucket = Math.Max(1.0, totalFrames / (double)buckets);
        var min = new float[buckets];
        var max = new float[buckets];
        var buf = new float[8192 * ch];
        long frame = 0;
        int n;
        while ((n = src.Read(buf, 0, buf.Length)) > 0)
        {
            ct.ThrowIfCancellationRequested();
            int frames = n / ch;
            for (int f = 0; f < frames; f++, frame++)
            {
                int b = (int)Math.Min(buckets - 1, frame / framesPerBucket);
                int i = f * ch;
                for (int c = 0; c < ch; c++)
                {
                    float v = buf[i + c];
                    if (v < min[b]) min[b] = v;
                    if (v > max[b]) max[b] = v;
                }
            }
        }
        return new WaveformData { Min = min, Max = max, Duration = frame / (double)rate, Channels = ch };
    }
}

/// <summary>Regner ut bølgeformer i bakgrunnen og husker dem (per fil).</summary>
public static class WaveformCache
{
    private static readonly ConcurrentDictionary<string, Task<WaveformData?>> Cache = new(StringComparer.OrdinalIgnoreCase);

    public static Task<WaveformData?> Get(string path, bool isVideo)
    {
        if (string.IsNullOrEmpty(path) || !File.Exists(path)) return Task.FromResult<WaveformData?>(null);
        var key = path + "|" + File.GetLastWriteTimeUtc(path).Ticks;
        return Cache.GetOrAdd(key, _ => Task.Run(() => Load(path, isVideo)));
    }

    private static WaveformData? Load(string path, bool isVideo)
    {
        try
        {
            if (isVideo)
            {
                using var r = VideoAudio.Open(path);
                if (r == null) return null;
                long frames = r.Length / Math.Max(1, r.WaveFormat.BlockAlign);
                return WaveformData.Compute(r.ToSampleProvider(), frames);
            }
            using var a = new AudioFileReader(path);
            long total = a.Length / Math.Max(1, a.WaveFormat.BlockAlign);
            return WaveformData.Compute(a, total);
        }
        catch
        {
            return null;
        }
    }
}

/// <summary>Forhåndslytting: spiller lyden i en cue fra et valgfritt punkt, gjennom lydpatchen, uten å påvirke showet.</summary>
public sealed class AudioPreview
{
    private readonly Func<PatchMixer?> _mixer;
    private CuePlayback? _pb;
    private double _from;

    public AudioPreview(Func<PatchMixer?> mixer) { _mixer = mixer; }

    public Cue? Cue { get; private set; }
    public bool IsPlaying => _pb is { IsFinished: false };
    /// <summary>Posisjon i fila (sekunder) mens det spilles, ellers null.</summary>
    public double? Position => IsPlaying ? _from + _pb!.PassPosition : null;
    public event Action? Changed;

    /// <summary>Spill fra <paramref name="from"/> til <paramref name="to"/> (0 = cuens sluttpunkt / filslutt).</summary>
    public bool Play(Cue cue, double from, double to = 0)
    {
        Stop();
        var mixer = _mixer();
        if (mixer == null || cue is not IRoutedAudio routed || cue is not IFileCue fc || !File.Exists(fc.FilePath)) return false;
        WaveStream? reader;
        try { reader = cue is VideoCue ? VideoAudio.Open(fc.FilePath) : new AudioFileReader(fc.FilePath); }
        catch { reader = null; }
        if (reader == null) return false;

        from = Math.Max(0, from);
        if (to > 0 && to <= from + 0.05) to = 0;   // startet etter sluttpunktet: spill til filslutt
        var o = new CuePlayback.Options(routed.VolumeDb, from, to, false, 0.01, 0.02);
        var pb = new CuePlayback(cue, reader, routed, o, mixer.WaveFormat.SampleRate);
        pb.Finished += p => System.Windows.Application.Current?.Dispatcher.BeginInvoke(() =>
        {
            p.Dispose();
            if (_pb == p) { _pb = null; Changed?.Invoke(); }
        });
        _pb = pb;
        _from = from;
        Cue = cue;
        mixer.Add(pb);
        Changed?.Invoke();
        return true;
    }

    public void Stop()
    {
        var pb = _pb;
        _pb = null;
        if (pb != null)
        {
            pb.Stop(0.02);
            Changed?.Invoke();
        }
    }
}
