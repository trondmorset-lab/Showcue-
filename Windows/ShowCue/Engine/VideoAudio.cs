using System.IO;
using NAudio.Wave;

namespace ShowCue.Engine;

/// <summary>
/// Lydsporet i videofiler («de-embedding»). Windows' Media Foundation dekoder lyden
/// (AAC i MP4/MOV, WMA, PCM osv.) så den kan spilles gjennom lydpatchen i stedet for
/// Windows' standard lydenhet.
/// </summary>
public static class VideoAudio
{
    /// <summary>Åpner lydsporet som flyttall. Returnerer null hvis fila ikke har lyd.</summary>
    public static WaveStream? Open(string path)
    {
        try
        {
            return new MediaFoundationReader(path, new MediaFoundationReader.MediaFoundationReaderSettings
            {
                RequestFloatOutput = true,
                RepositionInRead = true,
            });
        }
        catch
        {
            return null;
        }
    }

    /// <summary>Lengde (s) og antall kanaler i lydsporet. Kanaler = 0 betyr ingen lyd.</summary>
    public static (double Duration, int Channels) Probe(string path)
    {
        using var r = Open(path);
        return r == null ? (0, 0) : (r.TotalTime.TotalSeconds, r.WaveFormat.Channels);
    }

    /// <summary>
    /// Pakker ut lydsporet til en WAV-fil (32-bit flyttall, original samplingsfrekvens og kanaler).
    /// Returnerer stien til fila. Kjører i bakgrunnen.
    /// </summary>
    public static Task<string> ExtractAsync(string videoPath, string? wavPath = null, IProgress<double>? progress = null, CancellationToken ct = default)
    {
        wavPath ??= UniquePath(Path.ChangeExtension(videoPath, null) + " (lyd).wav");
        return Task.Run(() =>
        {
            using var reader = Open(videoPath) ?? throw new InvalidOperationException("Videoen har ikke noe lydspor.");
            var tmp = wavPath + ".part";
            try
            {
                using (var writer = new WaveFileWriter(tmp, reader.WaveFormat))
                {
                    var buf = new byte[reader.WaveFormat.AverageBytesPerSecond / 2 / reader.WaveFormat.BlockAlign * reader.WaveFormat.BlockAlign];
                    long total = Math.Max(1, reader.Length);
                    int n;
                    while ((n = reader.Read(buf, 0, buf.Length)) > 0)
                    {
                        ct.ThrowIfCancellationRequested();
                        writer.Write(buf, 0, n);
                        progress?.Report(Math.Clamp(writer.Length / (double)total, 0, 1));
                    }
                }
                File.Move(tmp, wavPath, overwrite: true);
            }
            catch
            {
                try { File.Delete(tmp); } catch { }
                throw;
            }
            progress?.Report(1);
            return wavPath;
        }, ct);
    }

    private static string UniquePath(string path)
    {
        if (!File.Exists(path)) return path;
        var dir = Path.GetDirectoryName(path) ?? "";
        var name = Path.GetFileNameWithoutExtension(path);
        var ext = Path.GetExtension(path);
        for (int i = 2; ; i++)
        {
            var p = Path.Combine(dir, $"{name} {i}{ext}");
            if (!File.Exists(p)) return p;
        }
    }
}
