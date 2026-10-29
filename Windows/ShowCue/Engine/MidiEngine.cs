using System.Text;
using NAudio.Midi;
using ShowCue.Models;

namespace ShowCue.Engine;

/// <summary>Holder MIDI-utganger åpne mellom cues så det ikke blir forsinkelse ved GO.</summary>
public sealed class MidiEngine : IDisposable
{
    private readonly Dictionary<string, MidiOut> _open = new();

    public static List<string> GetDevices()
    {
        var list = new List<string>();
        try
        {
            for (int i = 0; i < MidiOut.NumberOfDevices; i++)
                list.Add(MidiOut.DeviceInfo(i).ProductName);
        }
        catch { }
        return list;
    }

    private MidiOut GetOut(string name)
    {
        var devices = GetDevices();
        if (devices.Count == 0) throw new InvalidOperationException("Ingen MIDI-utganger funnet.");
        if (string.IsNullOrEmpty(name)) name = devices[0];
        if (_open.TryGetValue(name, out var mo)) return mo;
        int index = devices.IndexOf(name);
        if (index < 0) throw new InvalidOperationException($"MIDI-enheten «{name}» finnes ikke.");
        mo = new MidiOut(index);
        _open[name] = mo;
        return mo;
    }

    public void Send(MidiCue c)
    {
        var mo = GetOut(c.Device);
        switch (c.MessageType)
        {
            case MidiMessageType.NoteOn:
                mo.Send(MidiMessage.StartNote(c.Data1, c.Data2, c.Channel).RawData); break;
            case MidiMessageType.NoteOff:
                mo.Send(MidiMessage.StopNote(c.Data1, 0, c.Channel).RawData); break;
            case MidiMessageType.ProgramChange:
                mo.Send(MidiMessage.ChangePatch(c.Data1, c.Channel).RawData); break;
            case MidiMessageType.ControlChange:
                mo.Send(MidiMessage.ChangeControl(c.Data1, c.Data2, c.Channel).RawData); break;
            case MidiMessageType.MscGo:
                mo.SendBuffer(BuildMscGo(c.MscDeviceId, c.MscCommandFormat, c.MscCueNumber)); break;
        }
    }

    /// <summary>MIDI Show Control GO: F0 7F dev 02 fmt 01 [cue] F7</summary>
    public static byte[] BuildMscGo(int deviceId, int commandFormat, string cue)
    {
        var bytes = new List<byte> { 0xF0, 0x7F, (byte)deviceId, 0x02, (byte)commandFormat, 0x01 };
        if (!string.IsNullOrEmpty(cue)) bytes.AddRange(Encoding.ASCII.GetBytes(cue));
        bytes.Add(0xF7);
        return bytes.ToArray();
    }

    public void Dispose()
    {
        foreach (var mo in _open.Values) { try { mo.Dispose(); } catch { } }
        _open.Clear();
    }
}
