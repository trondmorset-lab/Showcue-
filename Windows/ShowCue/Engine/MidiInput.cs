using NAudio.Midi;

namespace ShowCue.Engine;

/// <summary>
/// Leser én MIDI-inngang og gjør meldinger om til triggere ("N:60", "CC:20", "PC:5")
/// og MSC-kommandoer. Hendelser leveres på MIDI-tråden.
/// </summary>
public sealed class MidiInput : IDisposable
{
    private MidiIn? _in;
    private readonly int[] _lastCc = new int[16 * 128];

    public string DeviceName { get; private set; } = "";
    /// <summary>0 = alle kanaler, ellers 1–16.</summary>
    public int Channel { get; set; }
    public bool IsOpen => _in != null;

    public event Action<string, int>? Trigger;           // trigger, kanal
    public event Action<MscCommand>? Msc;

    public static List<string> GetDevices()
    {
        var list = new List<string>();
        try
        {
            for (int i = 0; i < MidiIn.NumberOfDevices; i++) list.Add(MidiIn.DeviceInfo(i).ProductName);
        }
        catch { }
        return list;
    }

    public void Open(string deviceName, int channel)
    {
        Close();
        Channel = channel;
        if (string.IsNullOrEmpty(deviceName)) return;
        int idx = GetDevices().IndexOf(deviceName);
        if (idx < 0) throw new InvalidOperationException($"MIDI-inngangen «{deviceName}» finnes ikke.");
        var mi = new MidiIn(idx);
        mi.MessageReceived += OnMessage;
        mi.SysexMessageReceived += OnSysex;
        mi.CreateSysexBuffers(1024, 8);
        mi.Start();
        _in = mi;
        DeviceName = deviceName;
        Array.Clear(_lastCc);
    }

    private void OnMessage(object? sender, MidiInMessageEventArgs e)
    {
        var ev = e.MidiEvent;
        if (ev == null) return;
        if (Channel != 0 && ev.Channel != Channel) return;
        string? trig = ev switch
        {
            NoteOnEvent n when n.Velocity > 0 => $"N:{n.NoteNumber}",
            ControlChangeEvent cc => CcTrigger(cc),
            PatchChangeEvent pc => $"PC:{pc.Patch}",
            _ => null
        };
        if (trig != null) Trigger?.Invoke(trig, ev.Channel);
    }

    /// <summary>CC trigger bare når verdien går fra under 64 til 64 eller mer (knapp trykket ned).</summary>
    private string? CcTrigger(ControlChangeEvent cc)
    {
        int key = (cc.Channel - 1) * 128 + (int)cc.Controller;
        int last = _lastCc[key];
        _lastCc[key] = cc.ControllerValue;
        return cc.ControllerValue >= 64 && last < 64 ? $"CC:{(int)cc.Controller}" : null;
    }

    private void OnSysex(object? sender, MidiInSysexMessageEventArgs e)
    {
        var m = MscCommand.Parse(e.SysexBytes);
        if (m != null) Msc?.Invoke(m);
    }

    public void Close()
    {
        var mi = _in;
        _in = null;
        DeviceName = "";
        if (mi == null) return;
        // Viktig: fjern sysex-handleren før Dispose, ellers kan midiInReset gå i løkke (kjent NAudio-feil).
        mi.MessageReceived -= OnMessage;
        mi.SysexMessageReceived -= OnSysex;
        try { mi.Stop(); } catch { }
        try { mi.Dispose(); } catch { }
    }

    public void Dispose() => Close();
}

/// <summary>En MIDI Show Control-melding: F0 7F &lt;dev&gt; 02 &lt;format&gt; &lt;kommando&gt; [cue 00 liste 00 sti] F7</summary>
public sealed record MscCommand(int DeviceId, int CommandFormat, int Command, string CueNumber)
{
    public const int Go = 0x01, Stop = 0x02, Resume = 0x03, AllOff = 0x08, Reset = 0x0A;

    public static MscCommand? Parse(byte[]? b)
    {
        if (b == null) return null;
        // Noen drivere leverer uten F0 først.
        int i = b.Length > 0 && b[0] == 0xF0 ? 1 : 0;
        if (b.Length < i + 5 || b[i] != 0x7F || b[i + 2] != 0x02) return null;
        int dev = b[i + 1], fmt = b[i + 3], cmd = b[i + 4];
        var sb = new System.Text.StringBuilder();
        for (int p = i + 5; p < b.Length && b[p] != 0x00 && b[p] != 0xF7; p++) sb.Append((char)b[p]);
        return new MscCommand(dev, fmt, cmd, sb.ToString());
    }
}
