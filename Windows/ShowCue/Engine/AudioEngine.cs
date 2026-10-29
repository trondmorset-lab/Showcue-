using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using ShowCue.Models;

namespace ShowCue.Engine;

/// <summary>
/// Én felles flerkanals mikser (<see cref="PatchMixer"/>) som alltid kjører, koblet til WASAPI eller ASIO.
/// Med ASIO åpnes alle kanalene på lydkortet (f.eks. 64 på Dante Virtual Soundcard),
/// og lydpatchen bestemmer hvilke busser som går hvor.
/// </summary>
public sealed class AudioEngine : IDisposable
{
    private IWavePlayer? _output;
    private PatchMixer? _mixer;
    private readonly Dictionary<int, TestToneSource> _testTones = new();
    private IReadOnlyList<PatchBus> _patch = PatchBus.DefaultPatch(2);

    public string Status { get; private set; } = "Lyd ikke startet";
    public bool IsRunning => _output != null && _mixer != null;
    public int SampleRate => _mixer?.WaveFormat.SampleRate ?? 0;
    public int DeviceChannels => _mixer?.DeviceChannels ?? 0;
    /// <summary>Navn på kanalene på lydkortet (ASIO gir navn, f.eks. Dante-kanaler).</summary>
    public IReadOnlyList<string> ChannelNames { get; private set; } = Array.Empty<string>();
    public PatchMixer? Mixer => _mixer;

    public event Action<string>? StatusChanged;
    /// <summary>Lydutgangen er startet på nytt (antall kanaler kan ha endret seg).</summary>
    public event Action? Restarted;

    public void Start(AppSettings s)
    {
        StopOutput();
        _patch = s.Buses;
        try
        {
            CreateOutput(s);
        }
        catch (Exception ex)
        {
            // Fall tilbake til Windows standardenhet så det i det minste kommer lyd.
            var reason = ex.Message;
            StopOutput();
            try
            {
                CreateOutput(new AppSettings { AudioDriver = AudioDriverType.Wasapi, LatencyMs = Math.Max(s.LatencyMs, 60), Buses = s.Buses });
                SetStatus($"Kunne ikke åpne valgt lydenhet ({reason}). Bruker Windows standardenhet.");
            }
            catch (Exception ex2)
            {
                StopOutput();
                SetStatus("Ingen lydutgang: " + ex2.Message);
            }
        }
        Restarted?.Invoke();
    }

    private void CreateOutput(AppSettings s)
    {
        if (s.AudioDriver == AudioDriverType.Asio)
        {
            if (string.IsNullOrEmpty(s.AsioDriverName))
                throw new InvalidOperationException("Ingen ASIO-driver valgt");
            var asio = new AsioOut(s.AsioDriverName);
            try
            {
                int channels = Math.Min(asio.DriverOutputChannelCount, Math.Clamp(s.AsioMaxChannels, 2, 128));
                if (channels < 1) throw new InvalidOperationException("ASIO-driveren har ingen utganger");

                // Dante Virtual Soundcard o.l. har fast samplingsfrekvens satt i Dante Controller.
                var rate = new[] { s.SampleRate, 48000, 44100, 96000, 88200 }.FirstOrDefault(asio.IsSampleRateSupported);
                if (rate == 0) throw new InvalidOperationException("Fant ingen støttet samplingsfrekvens");

                var names = new List<string>();
                for (int i = 0; i < channels; i++)
                {
                    try { names.Add(asio.AsioOutputChannelName(i)); } catch { names.Add($"Ut {i + 1}"); }
                }
                ChannelNames = names;

                _mixer = new PatchMixer(rate, channels, s.Buses);
                asio.Init(new SampleToWaveProvider(_mixer));
                _output = asio;
                SetStatus($"ASIO: {s.AsioDriverName} · {channels} kanaler · {rate / 1000.0:0.#} kHz");
            }
            catch
            {
                asio.Dispose();
                throw;
            }
        }
        else
        {
            using var en = new MMDeviceEnumerator();
            MMDevice dev = string.IsNullOrEmpty(s.WasapiDeviceId)
                ? en.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia)
                : en.GetDevice(s.WasapiDeviceId);

            // Bruk enhetens egne kanaler og samplingsfrekvens (Dante i WDM-modus, flerkanals USB-kort osv.).
            int channels, rate;
            using (var client = dev.AudioClient)
            {
                channels = client.MixFormat.Channels;
                rate = client.MixFormat.SampleRate;
            }
            ChannelNames = Enumerable.Range(1, channels).Select(i => channels == 2 ? (i == 1 ? "Venstre" : "Høyre") : $"Ut {i}").ToList();

            _mixer = new PatchMixer(rate, channels, s.Buses);
            var wasapi = new WasapiOut(dev, AudioClientShareMode.Shared, true, s.LatencyMs);
            wasapi.Init(new SampleToWaveProvider(_mixer));
            _output = wasapi;
            SetStatus($"WASAPI: {dev.FriendlyName} · {channels} kanaler · {rate / 1000.0:0.#} kHz");
        }

        _mixer.SourceFinished += src => { if (src is TestToneSource t) lock (_testTones) _testTones.Remove(t.Bus); };
        _output.PlaybackStopped += (_, e) =>
        {
            if (e.Exception != null) SetStatus("Lydutgangen stoppet: " + e.Exception.Message);
        };
        _output.Play();
    }

    private void SetStatus(string s)
    {
        Status = s;
        StatusChanged?.Invoke(s);
    }

    public CuePlayback Play(AudioCue cue)
    {
        if (_mixer == null) throw new InvalidOperationException("Lydutgangen er ikke startet. Sjekk innstillinger.");
        var pb = new CuePlayback(cue, _mixer.WaveFormat.SampleRate);
        _mixer.Add(pb);
        return pb;
    }

    /// <summary>Oppdater patchen mens lyden går.</summary>
    public void ApplyPatch(IReadOnlyList<PatchBus> patch)
    {
        _patch = patch;
        _mixer?.SetPatch(patch);
    }

    public bool IsTestToneOn(int busIndex)
    {
        lock (_testTones) return _testTones.ContainsKey(busIndex);
    }

    public void SetTestTone(int busIndex, bool on)
    {
        if (_mixer == null) return;
        lock (_testTones)
        {
            if (on && !_testTones.ContainsKey(busIndex))
            {
                var t = new TestToneSource(busIndex);
                _testTones[busIndex] = t;
                _mixer.Add(t);
            }
            else if (!on && _testTones.Remove(busIndex, out var t))
            {
                t.Stop();
            }
        }
    }

    public void StopAllTestTones()
    {
        lock (_testTones)
        {
            foreach (var t in _testTones.Values) t.Stop();
            _testTones.Clear();
        }
    }

    public void StopOutput()
    {
        try { _output?.Stop(); } catch { }
        try { _output?.Dispose(); } catch { }
        _output = null;
        _mixer?.Clear();
        _mixer = null;
        lock (_testTones) _testTones.Clear();
        ChannelNames = Array.Empty<string>();
    }

    public void Dispose() => StopOutput();

    public static List<KeyValuePair<string, string>> GetWasapiDevices()
    {
        var list = new List<KeyValuePair<string, string>> { new("", "Windows standardenhet") };
        try
        {
            using var en = new MMDeviceEnumerator();
            foreach (var d in en.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active))
            {
                string extra = "";
                try { using var c = d.AudioClient; extra = $"  ({c.MixFormat.Channels} kanaler)"; } catch { }
                list.Add(new(d.ID, d.FriendlyName + extra));
            }
        }
        catch { }
        return list;
    }

    public static string[] GetAsioDrivers()
    {
        try { return AsioOut.GetDriverNames(); }
        catch { return Array.Empty<string>(); }
    }

    /// <summary>Leser lengde (sekunder) og antall kanaler i en lydfil. (0, 0) ved feil.</summary>
    public static (double Duration, int Channels) Probe(string path)
    {
        try
        {
            using var r = new AudioFileReader(path);
            return (r.TotalTime.TotalSeconds, r.WaveFormat.Channels);
        }
        catch { return (0, 0); }
    }
}
