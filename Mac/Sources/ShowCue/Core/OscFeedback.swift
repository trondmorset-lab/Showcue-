import Foundation

/// Øyeblikksbilde av showet, laget ca. 10 ganger i sekundet.
struct ShowStatus: Equatable {
    var showName: String
    var nextNumber: String
    var nextName: String
    var nextNotes: String
    /// 1-basert, 0 = slutt på lista.
    var playheadPosition: Int
    var cueCount: Int
    var playing: [PlayingCue]
}

struct PlayingCue: Equatable {
    var number: String
    var name: String
    var elapsed: Double
    var remaining: Double
    var hasDuration: Bool
    var preWaiting: Bool
}

/// Verdi som sendes: tekst eller heltall.
enum FeedbackValue: Equatable, CustomStringConvertible {
    case text(String)
    case int(Int)
    var description: String {
        switch self {
        case .text(let s): return s
        case .int(let i): return String(i)
        }
    }
    var osc: OscArg {
        switch self {
        case .text(let s): return .string(s)
        case .int(let i): return .int(Int32(clamping: i))
        }
    }
}

/// Sender status tilbake til Companion (eller annet) over OSC. Bare endrede verdier sendes,
/// pluss alt hvert 5. sekund (i tilfelle Companion er startet på nytt).
///
/// Companion-format:  /custom-variable/sc_next_name/value "Intro"
/// Generisk format:   /showcue/next/name "Intro"   og   /showcue/cue/12/running 1
final class OscFeedback {
    static let fullRefreshSeconds = 5.0

    private let send: (String, [OscArg]) -> Void
    private var last: [String: FeedbackValue] = [:]
    private var lastRunning: Set<String> = []
    private var lastFull = -Double.infinity
    private var forceNext = true

    var format: OscFeedbackFormat = .companion
    var prefix = "sc_"
    private(set) var messagesSent = 0

    init(send: @escaping (String, [OscArg]) -> Void) { self.send = send }

    static func forTarget(host: String, port: Int) -> OscFeedback {
        OscFeedback { addr, args in OscSender.shared.send(host: host, port: port, address: addr, args: args) }
    }

    func requestRefresh() { forceNext = true }

    static func clock(_ seconds: Double) -> String {
        let s = (seconds.isNaN || seconds < 0) ? 0 : Int(seconds.rounded(.down))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", s / 60, sec)
    }

    /// Verdiene som sendes, som (nøkkel, verdi).
    static func values(_ s: ShowStatus) -> [(String, FeedbackValue)] {
        let started = s.playing.filter { !$0.preWaiting }
        let current = started.last
        let timed = started.filter { $0.hasDuration }.min(by: { $0.remaining < $1.remaining })
        var running: [String] = []
        for p in started where !running.contains(p.number) { running.append(p.number) }
        return [
            ("show", .text(s.showName)),
            ("next_number", .text(s.nextNumber)),
            ("next_name", .text(s.nextName)),
            ("next_notes", .text(s.nextNotes)),
            ("playhead", .text(s.playheadPosition == 0 ? "slutt/\(s.cueCount)" : "\(s.playheadPosition)/\(s.cueCount)")),
            ("playing_count", .int(started.count)),
            ("playing", .text(current?.name ?? "")),
            ("playing_number", .text(current?.number ?? "")),
            ("playing_all", .text(started.map(\.name).joined(separator: " · "))),
            ("elapsed", .text(current.map { clock($0.elapsed) } ?? "")),
            ("remaining", .text(timed.map { "-" + clock($0.remaining.rounded(.up)) } ?? (current == nil ? "" : "∞"))),
            ("remaining_name", .text(timed?.name ?? "")),
            ("running", .text(running.joined(separator: ","))),
            ("state", .text(current != nil ? "spiller" : (s.playing.isEmpty ? "klar" : "venter"))),
        ]
    }

    func update(_ s: ShowStatus, now: Double) {
        let full = forceNext || now - lastFull >= OscFeedback.fullRefreshSeconds
        if full { lastFull = now; forceNext = false }

        for (key, value) in OscFeedback.values(s) {
            if !full, last[key] == value { continue }
            last[key] = value
            if format == .companion {
                raw("/custom-variable/\(prefix)\(key)/value", .string(value.description)) // Companion forventer tekst
            } else {
                raw("/showcue/" + key.replacingOccurrences(of: "_", with: "/"), value.osc)
            }
        }

        if format == .generic {
            let running = Set(s.playing.filter { !$0.preWaiting && !$0.number.isEmpty }.map(\.number))
            for n in running.sorted() where full || !lastRunning.contains(n) { raw("/showcue/cue/\(n)/running", .int(1)) }
            for n in lastRunning.sorted() where !running.contains(n) { raw("/showcue/cue/\(n)/running", .int(0)) }
            lastRunning = running
        }
    }

    private func raw(_ address: String, _ arg: OscArg) {
        send(address, [arg])
        messagesSent += 1
    }
}
