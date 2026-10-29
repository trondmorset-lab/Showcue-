import Foundation

/// Det fjernstyringen kan be showet om. Kalles alltid på hovedtråden.
protocol ShowControl: AnyObject {
    func go()
    func stopAll()
    func panic()
    func hardStop()
    func movePlayhead(_ delta: Int)
    @discardableResult func selectCue(_ number: String) -> Bool
    @discardableResult func startCue(_ number: String) -> Bool
    @discardableResult func stopCue(_ number: String) -> Bool
    @discardableResult func goCue(_ number: String) -> Bool
    @discardableResult func fireHotkey(_ key: String) -> Bool
    /// Starter (eller stopper) cuer med denne MIDI-triggeren. Returnerer antall.
    func fireMidiTrigger(_ trigger: String) -> Int
    func remoteLog(_ text: String)
    func refreshFeedback()
}

/// Oversetter OSC, MIDI og MSC til kommandoer. Samme kommandoer som Windows-versjonen:
///
///   /go  /go/{nr}  /stop  /panic  /hardstop  /next  /previous  /refresh
///   /playhead/{nr}  /select/{nr}  /cue/{nr}/start|stop|go|select  /hotkey/{tast}
///   Cuenummer kan også sendes som argument: /cue/start "12". Prefikset /showcue/ er tillatt.
final class RemoteRouter {
    weak var show: ShowControl?
    var settings: AppSettings
    private var learn: ((String) -> Void)?

    init(settings: AppSettings) { self.settings = settings }

    var isLearning: Bool { learn != nil }
    func beginLearn(_ callback: @escaping (String) -> Void) { learn = callback }
    func cancelLearn() { learn = nil }

    // MARK: OSC

    func handleOsc(_ m: OscMessage, from: String) {
        let ok = execute(m)
        show?.remoteLog("OSC fra \(from): \(m)" + (ok ? "" : "  – ukjent kommando eller cue"))
    }

    @discardableResult
    func execute(_ m: OscMessage) -> Bool {
        guard let show else { return false }
        var parts = m.address.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return false }
        // Knapper sender ofte 0 når de slippes – ignorer.
        if m.args.count == 1 && m.args[0].isOff { return true }
        let argNumber: String? = {
            guard let a = m.args.first, !a.isOff else { return nil }
            if case .bool = a { return nil }
            return a.text
        }()
        if parts[0].lowercased() == "showcue" { parts.removeFirst() }
        guard !parts.isEmpty else { return false }
        let cmd = parts[0].lowercased()

        switch (cmd, parts.count) {
        case ("go", 1):
            // /go 1 fra en knapp = GO; bare tekst-argument tolkes som cuenummer.
            if let a = m.args.first, case .string(let s) = a { return show.goCue(s) }
            show.go(); return true
        case ("go", 2): return show.goCue(parts[1])
        case ("stop", 1): show.stopAll(); return true
        case ("panic", 1): show.panic(); return true
        case ("hardstop", 1): show.hardStop(); return true
        case ("next", 1): show.movePlayhead(1); return true
        case ("previous", 1), ("prev", 1): show.movePlayhead(-1); return true
        case ("refresh", 1), ("status", 1): show.refreshFeedback(); return true
        case ("playhead", _), ("select", _):
            if parts.count == 2 && parts[1] == "next" { show.movePlayhead(1); return true }
            if parts.count == 2 && (parts[1] == "previous" || parts[1] == "prev") { show.movePlayhead(-1); return true }
            guard let n = parts.count >= 2 ? parts[1] : argNumber else { return false }
            return show.selectCue(n)
        case ("hotkey", _):
            guard let k = parts.count >= 2 ? parts[1] : argNumber else { return false }
            return show.fireHotkey(k.uppercased())
        case ("cue", _):
            let number: String, action: String
            if parts.count >= 3 { number = parts[1]; action = parts[2] }
            else if parts.count == 2, let n = argNumber { number = n; action = parts[1] }
            else { return false }
            switch action.lowercased() {
            case "start": return show.startCue(number)
            case "stop": return show.stopCue(number)
            case "go": return show.goCue(number)
            case "select", "playhead": return show.selectCue(number)
            default: return false
            }
        default:
            return false
        }
    }

    // MARK: MIDI

    func handleMidiTrigger(_ trigger: String, channel: Int) {
        if let l = learn {
            learn = nil
            l(trigger)
            return
        }
        guard let show else { return }
        let what: String
        if trigger == settings.midiGo { show.go(); what = "GO" }
        else if trigger == settings.midiStopAll { show.panic(); what = "stopp alt" }
        else if trigger == settings.midiNext { show.movePlayhead(1); what = "neste" }
        else if trigger == settings.midiPrevious { show.movePlayhead(-1); what = "forrige" }
        else {
            let n = show.fireMidiTrigger(trigger)
            if n == 0 {
                show.remoteLog("MIDI: \(MidiTriggers.describe(trigger)) (kanal \(channel)) – ingen cue koblet til")
                return
            }
            what = n == 1 ? "1 cue" : "\(n) cues"
        }
        show.remoteLog("MIDI: \(MidiTriggers.describe(trigger)) → \(what)")
    }

    func handleMsc(_ m: MscCommand) {
        guard settings.mscInEnabled, let show else { return }
        if settings.mscInDeviceId != 127 && m.deviceId != 127 && m.deviceId != settings.mscInDeviceId { return }
        var ok = true
        switch m.command {
        case MscCommand.go:
            if m.cueNumber.isEmpty { show.go() } else { ok = show.goCue(m.cueNumber) }
        case MscCommand.stop:
            if m.cueNumber.isEmpty { show.stopAll() } else { ok = show.stopCue(m.cueNumber) }
        case MscCommand.allOff, MscCommand.reset:
            show.stopAll()
        default:
            return
        }
        show.remoteLog("MSC: kommando \(String(format: "%02X", m.command)) \(m.cueNumber)" + (ok ? "" : " – fant ikke cuen"))
    }
}
