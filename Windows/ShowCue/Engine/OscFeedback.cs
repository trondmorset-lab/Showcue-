using ShowCue.Models;

namespace ShowCue.Engine;

/// <summary>Øyeblikksbilde av showet, laget av hovedvinduet ca. 10 ganger i sekundet.</summary>
public sealed record ShowStatus(
    string ShowName,
    string NextNumber,
    string NextName,
    string NextNotes,
    int PlayheadPosition,       // 1-basert, 0 = slutt på lista
    int CueCount,
    IReadOnlyList<PlayingCue> Playing);

public sealed record PlayingCue(string Number, string Name, double Elapsed, double Remaining, bool HasDuration, bool PreWaiting);

/// <summary>
/// Sender status tilbake til Companion (eller annet) over OSC, slik at knapper kan vise
/// neste cue, hva som spiller og tid igjen. Bare endrede verdier sendes, pluss en full
/// oppfriskning hvert 5. sekund (i tilfelle Companion er startet på nytt).
///
/// Companion-format:  /custom-variable/sc_next_name/value "Intro"
/// Generisk format:   /showcue/next/name "Intro"   og   /showcue/cue/12/running 1
/// </summary>
public sealed class OscFeedback
{
    public const double FullRefreshSeconds = 5;

    private readonly Action<string, IList<object>> _send;
    private readonly Dictionary<string, object> _last = new();
    private HashSet<string> _lastRunning = new(StringComparer.OrdinalIgnoreCase);
    private double _lastFull = double.NegativeInfinity;
    private bool _forceNext = true;

    public OscFeedbackFormat Format { get; set; } = OscFeedbackFormat.Companion;
    public string Prefix { get; set; } = "sc_";
    public int MessagesSent { get; private set; }

    /// <summary><paramref name="send"/> får adresse og argumenter. Standard er UDP til innstilt mottaker.</summary>
    public OscFeedback(Action<string, IList<object>> send) { _send = send; }

    public static OscFeedback ForTarget(string host, int port) =>
        new((addr, args) => { try { Osc.Send(host, port, addr, args); } catch { /* mottaker nede: prøv igjen senere */ } });

    /// <summary>Send alt på nytt ved neste oppdatering (f.eks. når Companion ber om det).</summary>
    public void RequestRefresh() => _forceNext = true;

    /// <summary>Verdiene som sendes, som (nøkkel, verdi). Nøklene brukes både som variabelnavn og adresse.</summary>
    public static List<(string Key, object Value)> Values(ShowStatus s)
    {
        var current = s.Playing.Where(p => !p.PreWaiting).LastOrDefault();
        var timed = s.Playing.Where(p => !p.PreWaiting && p.HasDuration).OrderBy(p => p.Remaining).FirstOrDefault();
        return new()
        {
            ("show", s.ShowName),
            ("next_number", s.NextNumber),
            ("next_name", s.NextName),
            ("next_notes", s.NextNotes),
            ("playhead", s.PlayheadPosition == 0 ? $"slutt/{s.CueCount}" : $"{s.PlayheadPosition}/{s.CueCount}"),
            ("playing_count", s.Playing.Count(p => !p.PreWaiting)),
            ("playing", current == null ? "" : current.Name),
            ("playing_number", current == null ? "" : current.Number),
            ("playing_all", string.Join(" · ", s.Playing.Where(p => !p.PreWaiting).Select(p => p.Name))),
            ("elapsed", current == null ? "" : Clock(current.Elapsed)),
            // «Tid igjen» for den cuen som slutter først (det man trenger å vite på en knapp).
            ("remaining", timed == null ? (current == null ? "" : "∞") : "-" + Clock(Math.Ceiling(timed.Remaining))),
            ("remaining_name", timed?.Name ?? ""),
            ("running", string.Join(",", s.Playing.Where(p => !p.PreWaiting).Select(p => p.Number).Distinct())),
            ("state", current != null ? "spiller" : s.Playing.Count > 0 ? "venter" : "klar"),
        };
    }

    /// <summary>Hele sekunder, m:ss (eller t:mm:ss).</summary>
    public static string Clock(double seconds)
    {
        if (double.IsNaN(seconds) || seconds < 0) seconds = 0;
        var t = TimeSpan.FromSeconds(Math.Floor(seconds));
        return t.TotalHours >= 1 ? $"{(int)t.TotalHours}:{t.Minutes:00}:{t.Seconds:00}" : $"{(int)t.TotalMinutes}:{t.Seconds:00}";
    }

    public void Update(ShowStatus s, double now)
    {
        bool full = _forceNext || now - _lastFull >= FullRefreshSeconds;
        if (full) { _lastFull = now; _forceNext = false; }

        foreach (var (key, value) in Values(s))
        {
            if (!full && _last.TryGetValue(key, out var old) && Equals(old, value)) continue;
            _last[key] = value;
            Send(key, value);
        }

        // Per-cue status (generisk format): /showcue/cue/{nr}/running 1|0
        if (Format == OscFeedbackFormat.Generic)
        {
            var running = new HashSet<string>(s.Playing.Where(p => !p.PreWaiting && p.Number != "").Select(p => p.Number), StringComparer.OrdinalIgnoreCase);
            foreach (var n in running.Where(n => full || !_lastRunning.Contains(n))) Raw($"/showcue/cue/{n}/running", 1);
            foreach (var n in _lastRunning.Where(n => !running.Contains(n))) Raw($"/showcue/cue/{n}/running", 0);
            _lastRunning = running;
        }
    }

    private void Send(string key, object value)
    {
        if (Format == OscFeedbackFormat.Companion)
            Raw($"/custom-variable/{Prefix}{key}/value", value.ToString() ?? ""); // Companion forventer tekst
        else
            Raw("/showcue/" + key.Replace('_', '/'), value);
    }

    private void Raw(string address, object value)
    {
        _send(address, new List<object> { value });
        MessagesSent++;
    }
}
