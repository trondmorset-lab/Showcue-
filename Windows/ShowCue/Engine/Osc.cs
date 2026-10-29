using System.Globalization;
using System.IO;
using System.Net.Sockets;
using System.Text;

namespace ShowCue.Engine;

/// <summary>Minimal OSC 1.0-sender over UDP (int32, float32, string, true/false).</summary>
public static class Osc
{
    private static readonly UdpClient Udp = new();

    public static void Send(string host, int port, string address, string arguments)
        => Send(host, port, address, ParseArguments(arguments));

    public static void Send(string host, int port, string address, IList<object> args)
    {
        var packet = Encode(address, args);
        lock (Udp) Udp.Send(packet, packet.Length, host, port);
    }

    public static List<object> ParseArguments(string text)
    {
        var result = new List<object>();
        foreach (var (token, quoted) in Tokenize(text))
        {
            if (quoted) { result.Add(token); continue; }
            if (int.TryParse(token, NumberStyles.Integer, CultureInfo.InvariantCulture, out var i)) result.Add(i);
            else if (float.TryParse(token.Replace(',', '.'), NumberStyles.Float, CultureInfo.InvariantCulture, out var f)) result.Add(f);
            else if (token.Equals("true", StringComparison.OrdinalIgnoreCase)) result.Add(true);
            else if (token.Equals("false", StringComparison.OrdinalIgnoreCase)) result.Add(false);
            else result.Add(token);
        }
        return result;
    }

    private static IEnumerable<(string, bool)> Tokenize(string text)
    {
        var sb = new StringBuilder();
        bool inQuotes = false, wasQuoted = false;
        foreach (var ch in text ?? "")
        {
            if (ch == '"') { inQuotes = !inQuotes; wasQuoted = true; continue; }
            if (char.IsWhiteSpace(ch) && !inQuotes)
            {
                if (sb.Length > 0 || wasQuoted) yield return (sb.ToString(), wasQuoted);
                sb.Clear(); wasQuoted = false;
                continue;
            }
            sb.Append(ch);
        }
        if (sb.Length > 0 || wasQuoted) yield return (sb.ToString(), wasQuoted);
    }

    public static byte[] Encode(string address, IList<object> args)
    {
        if (string.IsNullOrEmpty(address) || address[0] != '/')
            throw new ArgumentException("OSC-adresse må starte med /");
        using var ms = new MemoryStream();
        WriteString(ms, address);
        var tags = new StringBuilder(",");
        foreach (var a in args)
            tags.Append(a switch { int => 'i', float => 'f', bool b => b ? 'T' : 'F', _ => 's' });
        WriteString(ms, tags.ToString());
        foreach (var a in args)
        {
            switch (a)
            {
                case int i: WriteBigEndian(ms, BitConverter.GetBytes(i)); break;
                case float f: WriteBigEndian(ms, BitConverter.GetBytes(f)); break;
                case bool: break; // T/F har ingen data
                default: WriteString(ms, a.ToString() ?? ""); break;
            }
        }
        return ms.ToArray();
    }

    // ==================================================================
    //  Dekoding (OSC inn)
    // ==================================================================

    /// <summary>Pakker ut én UDP-pakke til meldinger (støtter #bundle, også nøstet).</summary>
    public static List<OscMessage> Decode(byte[] data, int length)
    {
        var result = new List<OscMessage>();
        DecodeInto(data, 0, length, result, 0);
        return result;
    }

    private static void DecodeInto(byte[] d, int start, int length, List<OscMessage> result, int depth)
    {
        if (length < 4 || depth > 8) return;
        int end = start + length;
        if (d[start] == (byte)'#')
        {
            int p = start;
            if (ReadString(d, ref p, end) != "#bundle") return;
            p += 8; // tidsstempel – vi utfører alt med en gang
            while (p + 4 <= end)
            {
                int size = ReadInt(d, ref p);
                if (size <= 0 || p + size > end) break;
                DecodeInto(d, p, size, result, depth + 1);
                p += size;
            }
            return;
        }
        if (d[start] != (byte)'/') return;

        int pos = start;
        var address = ReadString(d, ref pos, end);
        var args = new List<object>();
        if (pos < end && d[pos] == (byte)',')
        {
            var tags = ReadString(d, ref pos, end);
            foreach (var t in tags.Skip(1))
            {
                int before = args.Count;
                switch (t)
                {
                    case 'i': args.Add(ReadInt(d, ref pos)); break;
                    case 'f': args.Add(BitConverter.Int32BitsToSingle(ReadInt(d, ref pos))); break;
                    case 'h': args.Add(((long)ReadInt(d, ref pos) << 32) | (uint)ReadInt(d, ref pos)); break;
                    case 'd': args.Add(BitConverter.Int64BitsToDouble(((long)ReadInt(d, ref pos) << 32) | (uint)ReadInt(d, ref pos))); break;
                    case 's': case 'S': args.Add(ReadString(d, ref pos, end)); break;
                    case 'b': { int n = ReadInt(d, ref pos); pos += (n + 3) & ~3; args.Add(Array.Empty<byte>()); break; }
                    case 'T': args.Add(true); break;
                    case 'F': args.Add(false); break;
                    case 'N': case 'I': break;
                    case 't': pos += 8; break;
                    case 'c': args.Add((char)ReadInt(d, ref pos)); break;
                    case 'r': case 'm': pos += 4; break;
                    default: pos = end; break; // ukjent type: stopp parsing av argumenter
                }
                if (pos > end) { if (args.Count > before) args.RemoveAt(args.Count - 1); break; }
            }
        }
        result.Add(new OscMessage(address, args));
    }

    private static int ReadInt(byte[] d, ref int p)
    {
        if (p + 4 > d.Length) { p += 4; return 0; }
        int v = (d[p] << 24) | (d[p + 1] << 16) | (d[p + 2] << 8) | d[p + 3];
        p += 4;
        return v;
    }

    private static string ReadString(byte[] d, ref int p, int end)
    {
        int s = p;
        while (p < end && d[p] != 0) p++;
        var str = Encoding.UTF8.GetString(d, s, p - s);
        p = s + ((p - s) / 4 + 1) * 4; // hopp over null og padding
        return str;
    }

    private static void WriteString(Stream s, string str)
    {
        var bytes = Encoding.UTF8.GetBytes(str);
        s.Write(bytes);
        int pad = 4 - bytes.Length % 4; // alltid minst én null-byte
        for (int i = 0; i < pad; i++) s.WriteByte(0);
    }

    private static void WriteBigEndian(Stream s, byte[] b)
    {
        if (BitConverter.IsLittleEndian) Array.Reverse(b);
        s.Write(b);
    }
}

public sealed record OscMessage(string Address, IReadOnlyList<object> Args)
{
    public override string ToString() => Args.Count == 0 ? Address : Address + " " + string.Join(" ", Args.Select(a => a is float f ? f.ToString("0.###", CultureInfo.InvariantCulture) : a.ToString()));
}

/// <summary>Lytter etter OSC på UDP. Meldinger leveres på en bakgrunnstråd.</summary>
public sealed class OscServer : IDisposable
{
    private UdpClient? _udp;
    private CancellationTokenSource? _cts;

    public int Port { get; private set; }
    public bool IsRunning => _udp != null;
    public event Action<OscMessage, System.Net.IPEndPoint>? MessageReceived;

    public void Start(int port)
    {
        Stop();
        Port = port;
        _udp = new UdpClient(new System.Net.IPEndPoint(System.Net.IPAddress.Any, port));
        _cts = new CancellationTokenSource();
        _ = Loop(_udp, _cts.Token);
    }

    private async Task Loop(UdpClient udp, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            UdpReceiveResult r;
            try { r = await udp.ReceiveAsync(ct); }
            catch (OperationCanceledException) { return; }
            catch (ObjectDisposedException) { return; }
            catch (SocketException) { continue; } // f.eks. ICMP «port unreachable» fra tidligere sending
            try
            {
                foreach (var m in Osc.Decode(r.Buffer, r.Buffer.Length)) MessageReceived?.Invoke(m, r.RemoteEndPoint);
            }
            catch { /* ugyldig pakke */ }
        }
    }

    public void Stop()
    {
        _cts?.Cancel();
        try { _udp?.Dispose(); } catch { }
        _udp = null;
        _cts = null;
    }

    public void Dispose() => Stop();

    /// <summary>Maskinens IPv4-adresser, for å vise hva Companion/lysbord skal sende til.</summary>
    public static List<string> LocalAddresses()
    {
        try
        {
            return System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces()
                .Where(n => n.OperationalStatus == System.Net.NetworkInformation.OperationalStatus.Up)
                .SelectMany(n => n.GetIPProperties().UnicastAddresses)
                .Where(a => a.Address.AddressFamily == AddressFamily.InterNetwork && !System.Net.IPAddress.IsLoopback(a.Address))
                .Select(a => a.Address.ToString()).Distinct().ToList();
        }
        catch { return new(); }
    }
}
