using System.IO;
using System.Text.Json;

namespace ShowCue.Models;

public enum AudioDriverType { Wasapi, Asio }
public enum AppTheme { Dark, Light, Night }
public enum OscFeedbackFormat { Companion, Generic }

/// <summary>En logisk utgang i lydpatchen.</summary>
public sealed class PatchBus
{
    public string Name { get; set; } = "";
    public double GainDb { get; set; }
    /// <summary>Kanaler på lydkortet (fra 1) bussen sendes til.</summary>
    public List<int> Channels { get; set; } = new();

    public PatchBus Copy() => new() { Name = Name, GainDb = GainDb, Channels = new(Channels) };

    public static List<PatchBus> DefaultPatch(int count)
    {
        var list = new List<PatchBus>();
        for (int i = 1; i <= count; i++)
            list.Add(new PatchBus { Name = i switch { 1 => "Main L", 2 => "Main R", _ => $"Utgang {i}" }, Channels = { i } });
        return list;
    }
}

/// <summary>Maskininnstillinger (lagres i %AppData%\ShowCue, ikke i showfila).</summary>
public sealed class AppSettings
{
    public AudioDriverType AudioDriver { get; set; } = AudioDriverType.Wasapi;
    /// <summary>WASAPI-enhetens ID. Tom = Windows standardenhet.</summary>
    public string WasapiDeviceId { get; set; } = "";
    public string AsioDriverName { get; set; } = "";
    /// <summary>Maks antall ASIO-kanaler som åpnes (Dante Virtual Soundcard har opptil 64).</summary>
    public int AsioMaxChannels { get; set; } = 64;
    /// <summary>Ønsket samplingsfrekvens. For WASAPI brukes enhetens egen frekvens.</summary>
    public int SampleRate { get; set; } = 48000;

    /// <summary>Lydpatch: logiske utganger (busser) som lyd-cues routes til, og hvilke kanaler på lydkortet de går til.</summary>
    public List<PatchBus> Buses { get; set; } = PatchBus.DefaultPatch(8);

    // ---- OSC inn ----
    public bool OscInEnabled { get; set; } = true;
    public int OscInPort { get; set; } = 53000;

    // ---- OSC-status ut (til Companion o.l.) ----
    public bool OscFeedbackEnabled { get; set; }
    public string OscFeedbackHost { get; set; } = "127.0.0.1";
    /// <summary>Companion lytter på OSC-port 12321 som standard.</summary>
    public int OscFeedbackPort { get; set; } = 12321;
    public OscFeedbackFormat OscFeedbackFormat { get; set; } = OscFeedbackFormat.Companion;

    // ---- Utseende ----
    public AppTheme Theme { get; set; } = AppTheme.Dark;

    // ---- MIDI inn ----
    /// <summary>Navn på MIDI-inngang. Tom = av.</summary>
    public string MidiInDevice { get; set; } = "";
    /// <summary>0 = alle kanaler, ellers 1–16.</summary>
    public int MidiInChannel { get; set; }
    public string MidiGo { get; set; } = "";
    public string MidiStopAll { get; set; } = "";
    public string MidiNext { get; set; } = "";
    public string MidiPrevious { get; set; } = "";
    /// <summary>Ta imot MIDI Show Control (GO/STOP med cuenummer).</summary>
    public bool MscInEnabled { get; set; } = true;
    /// <summary>MSC device ID vi svarer på (127 = alle).</summary>
    public int MscInDeviceId { get; set; } = 127;
    public int LatencyMs { get; set; } = 60;

    /// <summary>-1 = eget vindu (for testing på én skjerm), ellers skjermindeks.</summary>
    public int VideoScreen { get; set; } = -1;

    public double PanicFadeTime { get; set; } = 1.0;
    /// <summary>Hindrer dobbel-GO ved prell på tasten.</summary>
    public int DoubleGoProtectionMs { get; set; } = 300;

    public string LastShowPath { get; set; } = "";

    private static string FilePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ShowCue", "settings.json");

    public static AppSettings Load()
    {
        try
        {
            if (File.Exists(FilePath))
                return Normalize(JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath), ShowDocument.JsonOptions) ?? new());
        }
        catch { /* ødelagt fil → standardverdier */ }
        return new AppSettings();
    }

    private static AppSettings Normalize(AppSettings s)
    {
        // En tom eller manglende patch (f.eks. fra eldre versjon) gir standardpatch.
        if (s.Buses == null || s.Buses.Count == 0) s.Buses = PatchBus.DefaultPatch(8);
        return s;
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this, ShowDocument.JsonOptions));
        }
        catch { }
    }

    public AppSettings Copy() =>
        JsonSerializer.Deserialize<AppSettings>(JsonSerializer.Serialize(this, ShowDocument.JsonOptions), ShowDocument.JsonOptions)!;
}
