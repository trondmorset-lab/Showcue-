import Foundation
import Combine

// MARK: - Enums (tekstverdiene er de samme som i Windows-versjonen, så showfilene kan deles)

enum CueType: String, Codable, CaseIterable {
    case audio, video, image, pdf, fade, stop, osc, midi
}

enum ContinueMode: String, Codable, CaseIterable {
    case none = "None", autoContinue = "AutoContinue", autoFollow = "AutoFollow"

    var label: String {
        switch self {
        case .none: return "Ingen"
        case .autoContinue: return "Auto-continue (start neste samtidig)"
        case .autoFollow: return "Auto-follow (start neste når ferdig)"
        }
    }
    var glyph: String {
        switch self {
        case .none: return ""
        case .autoContinue: return "↓"
        case .autoFollow: return "↧"
        }
    }
}

enum VisualStretch: String, Codable, CaseIterable {
    case uniform = "Uniform", uniformToFill = "UniformToFill", fill = "Fill", none = "None"

    var label: String {
        switch self {
        case .uniform: return "Tilpass (behold format)"
        case .uniformToFill: return "Fyll (beskjær)"
        case .fill: return "Strekk"
        case .none: return "Originalstørrelse"
        }
    }
}

enum MidiMessageType: String, Codable, CaseIterable {
    case noteOn = "NoteOn", noteOff = "NoteOff", programChange = "ProgramChange", controlChange = "ControlChange", mscGo = "MscGo"

    var label: String {
        switch self {
        case .noteOn: return "Note on"
        case .noteOff: return "Note off"
        case .programChange: return "Program change"
        case .controlChange: return "Control change (CC)"
        case .mscGo: return "MSC GO (MIDI Show Control)"
        }
    }
}

enum CueColor: String, Codable, CaseIterable {
    case none = "None", red = "Red", orange = "Orange", yellow = "Yellow", green = "Green", blue = "Blue", purple = "Purple", gray = "Gray"

    var label: String {
        switch self {
        case .none: return "Ingen"
        case .red: return "Rød"
        case .orange: return "Oransje"
        case .yellow: return "Gul"
        case .green: return "Grønn"
        case .blue: return "Blå"
        case .purple: return "Lilla"
        case .gray: return "Grå"
        }
    }
}

// MARK: - Routing

/// Ett krysspunkt i routingmatrisen: kanal i fila → utgang (buss) i lydpatchen. Begge fra 1.
struct AudioRoute: Codable, Hashable {
    var source: Int
    var bus: Int
    var gainDb: Double

    init(_ source: Int, _ bus: Int, _ gainDb: Double = 0) {
        self.source = source; self.bus = bus; self.gainDb = gainDb
    }

    enum CodingKeys: String, CodingKey { case source = "Source", bus = "Bus", gainDb = "GainDb" }

    /// Mono → utgang 1 og 2, ellers kanal n → utgang n.
    static func defaults(fileChannels: Int) -> [AudioRoute] {
        if fileChannels <= 1 { return [AudioRoute(1, 1), AudioRoute(1, 2)] }
        return (1...fileChannels).map { AudioRoute($0, $0) }
    }
}

// MARK: - Cue

/// Én cue. Alle typer deler klasse (enklere for SwiftUI og JSON); `type` bestemmer hvilke felt som brukes.
final class Cue: ObservableObject, Identifiable, Codable {
    let id = UUID()
    let type: CueType

    // Felles
    @Published var number = ""
    @Published var name = ""
    @Published var notes = ""
    @Published var preWait: Double = 0
    @Published var continueMode: ContinueMode = .none
    @Published var hotkey = "" { didSet { let u = hotkey.uppercased(); if u != hotkey { hotkey = u } } }
    @Published var disabled = false
    @Published var color: CueColor = .none
    /// "N:60", "CC:20", "PC:5" eller tom.
    @Published var midiTrigger = ""

    // Filer (lyd, video, bilde, PDF)
    @Published var filePath = ""

    // Lyd og videolyd
    @Published var volumeDb: Double = 0
    @Published var startTime: Double = 0
    @Published var endTime: Double = 0
    @Published var loop = false
    @Published var fadeIn: Double = 0
    @Published var fadeOut: Double = 0
    @Published var fileDuration: Double = 0
    /// Kanaler i lydfila / lydsporet. For video: 0 = ingen lyd, -1 = ikke undersøkt.
    @Published var fileChannels = 0
    /// nil = standard routing, tom = alt av.
    @Published var routes: [AudioRoute]? = nil

    // Visuelt
    @Published var replaceOthers = true
    @Published var stretch: VisualStretch = .uniform
    @Published var knownDuration: Double = 0
    @Published var holdTime: Double = 0
    @Published var page = 1

    // Fade / stopp
    @Published var target = ""
    @Published var fadeTime: Double = 0
    @Published var fadeAudio = true
    @Published var targetDb: Double = -60
    @Published var fadeVisual = true
    @Published var targetOpacity: Double = 0
    @Published var stopWhenDone = true

    // OSC
    @Published var host = "127.0.0.1"
    @Published var port = 53000
    @Published var address = "/"
    @Published var arguments = ""

    // MIDI
    @Published var device = ""
    @Published var messageType: MidiMessageType = .noteOn
    @Published var channel = 1
    @Published var data1 = 60
    @Published var data2 = 127
    @Published var mscDeviceId = 127
    @Published var mscCommandFormat = 1
    @Published var mscCueNumber = "1"

    // Kjøretid (lagres ikke)
    @Published var activeCount = 0
    @Published var progress: Double = 0
    @Published var isPreWaiting = false
    @Published var error: String? = nil
    var isRunning: Bool { activeCount > 0 }

    init(type: CueType) {
        self.type = type
        switch type {
        case .video:
            fadeIn = 0.5; fadeOut = 0.5; fileChannels = -1
        case .image, .pdf:
            fadeIn = 0.5; fadeOut = 0.5
        case .fade:
            fadeTime = 3
        default: break
        }
    }

    // MARK: Egenskaper

    var isFileCue: Bool { [.audio, .video, .image, .pdf].contains(type) }
    var isVisual: Bool { [.video, .image, .pdf].contains(type) }
    var isStill: Bool { type == .image || type == .pdf }
    var hasRouting: Bool { type == .audio || type == .video }
    var hasNoAudio: Bool { type == .video && fileChannels == 0 }

    var typeName: String {
        switch type {
        case .audio: return "Lyd"
        case .video: return "Video"
        case .image: return "Bilde"
        case .pdf: return "PDF"
        case .fade: return "Fade"
        case .stop: return "Stopp"
        case .osc: return "OSC"
        case .midi: return "MIDI"
        }
    }

    var typeIcon: String {
        switch type {
        case .audio: return "♪"
        case .video: return "▶"
        case .image: return "▣"
        case .pdf: return "▤"
        case .fade: return "◢"
        case .stop: return "■"
        case .osc: return "⇢"
        case .midi: return "♫"
        }
    }

    var fileName: String { Cue.lastPathComponent(filePath) }
    private var fileStem: String {
        let n = fileName
        if let dot = n.lastIndex(of: "."), dot > n.startIndex { return String(n[..<dot]) }
        return n
    }
    private var fileLabel: String { filePath.isEmpty ? "(ingen fil)" : fileName }

    /// Fungerer både for Mac-stier og Windows-stier (fra show laget på Windows).
    static func lastPathComponent(_ path: String) -> String {
        let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        return parts.last.map(String.init) ?? path
    }

    var displayName: String {
        if !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        switch type {
        case .audio, .video, .image: return fileStem.isEmpty ? typeName : fileStem
        case .pdf: return (fileStem.isEmpty ? typeName : fileStem) + " s.\(page)"
        case .fade: return target.isEmpty ? "Fade" : "Fade cue \(target)"
        case .stop: return target.isEmpty ? "Stopp alt" : "Stopp cue \(target)"
        case .osc: return "OSC " + address
        case .midi: return "MIDI"
        }
    }

    var summary: String {
        switch type {
        case .audio:
            var s = fileLabel
            if loop { s += "  ⟲" }
            if volumeDb != 0 { s += "  " + Cue.signedDb(volumeDb) + " dB" }
            if let r = routes { s += "  → " + Cue.routeSummary(r) }
            return s
        case .video:
            var s = fileLabel
            if loop { s += "  ⟲" }
            if fileChannels == 0 { s += "  (ingen lyd)" }
            else if let r = routes, r.isEmpty { s += "  (lyd av)" }
            else if volumeDb != 0 { s += "  " + Cue.signedDb(volumeDb) + " dB" }
            return s
        case .image:
            return fileLabel
        case .pdf:
            return "\(fileLabel)  s. \(page)"
        case .fade:
            var s = target.isEmpty ? "(mål mangler)" : "→ " + target
            if fadeAudio { s += targetDb <= -60 ? "  −∞ dB" : "  " + Cue.fmt(targetDb) + " dB" }
            if stopWhenDone { s += "  + stopp" }
            return s
        case .stop:
            return (target.isEmpty ? "Alle cues" : "→ " + target) + (fadeTime > 0 ? "  fade \(Cue.fmt(fadeTime))s" : "")
        case .osc:
            return "\(host):\(port)  \(address) \(arguments)".trimmingCharacters(in: .whitespaces)
        case .midi:
            let s: String
            switch messageType {
            case .noteOn: s = "Note on  ch\(channel)  \(data1) / \(data2)"
            case .noteOff: s = "Note off  ch\(channel)  \(data1)"
            case .programChange: s = "Program  ch\(channel)  \(data1)"
            case .controlChange: s = "CC  ch\(channel)  \(data1) = \(data2)"
            case .mscGo: s = "MSC GO  cue \(mscCueNumber)"
            }
            return s + (device.isEmpty ? "" : "  [\(device)]")
        }
    }

    /// Lengden på hele fila (lyd eller video), 0 = ukjent.
    var mediaLength: Double { type == .video ? knownDuration : fileDuration }

    /// Sluttpunktet i en video (0 = ukjent).
    var videoEnd: Double {
        endTime > 0 ? (knownDuration > 0 ? min(endTime, knownDuration) : endTime) : knownDuration
    }

    /// Varighet i sekunder, 0 = ukjent/uendelig.
    var duration: Double {
        switch type {
        case .audio:
            if loop { return 0 }
            let end = endTime > 0 ? min(endTime, fileDuration > 0 ? fileDuration : endTime) : fileDuration
            return max(0, end - startTime)
        case .video:
            let end = videoEnd
            return loop || end <= 0 ? 0 : max(0, end - startTime)
        case .image, .pdf: return holdTime > 0 ? fadeIn + holdTime + fadeOut : 0
        case .fade, .stop: return fadeTime
        default: return 0
        }
    }

    var durationText: String { duration > 0 ? TimeFormat.format(duration) : "" }
    var preWaitText: String { preWait > 0 ? TimeFormat.format(preWait) : "" }
    var triggerText: String {
        [hotkey, MidiTriggers.describe(midiTrigger)].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    func effectiveRoutes(fileChannels ch: Int) -> [AudioRoute] { routes ?? AudioRoute.defaults(fileChannels: ch) }

    static func routeSummary(_ r: [AudioRoute]) -> String {
        let buses = Array(Set(r.map { $0.bus })).sorted()
        return buses.isEmpty ? "av" : "ut " + buses.map(String.init).joined(separator: ",")
    }

    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "nb_NO")
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 1
        return f
    }()
    static func fmt(_ v: Double) -> String { numberFormatter.string(from: NSNumber(value: v)) ?? "\(v)" }
    static func signedDb(_ v: Double) -> String { (v > 0 ? "+" : "") + fmt(v) }

    func clone() -> Cue {
        let data = try! JSONEncoder().encode(self)
        return try! JSONDecoder().decode(Cue.self, from: data)
    }

    // MARK: Codable – samme feltnavn som Windows-versjonen (PascalCase)

    enum K: String, CodingKey {
        case type, Number, Name, Notes, PreWait, ContinueMode, Hotkey, Disabled, Color, MidiTrigger
        case FilePath, VolumeDb, Volume, StartTime, EndTime, Loop, FadeIn, FadeOut, FileDuration, FileChannels, Routes
        case ReplaceOthers, Stretch, KnownDuration, HoldTime, Page
        case Target, FadeTime, FadeAudio, TargetDb, FadeVisual, TargetOpacity, StopWhenDone
        case Host, Port, Address, Arguments
        case Device, MessageType, Channel, Data1, Data2, MscDeviceId, MscCommandFormat, MscCueNumber
    }

    convenience init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let t = (try? c.decode(CueType.self, forKey: .type)) ?? .stop
        self.init(type: t)
        func v<T: Decodable>(_ k: K, _ def: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? def }

        number = v(.Number, ""); name = v(.Name, ""); notes = v(.Notes, "")
        preWait = v(.PreWait, 0.0); continueMode = v(.ContinueMode, ContinueMode.none)
        hotkey = v(.Hotkey, ""); disabled = v(.Disabled, false); color = v(.Color, CueColor.none)
        midiTrigger = v(.MidiTrigger, "")
        filePath = v(.FilePath, "")
        volumeDb = v(.VolumeDb, 0.0)
        if t == .video, (try? c.decodeIfPresent(Double.self, forKey: .VolumeDb)) == nil,
           let pct = (try? c.decodeIfPresent(Double.self, forKey: .Volume)) ?? nil {
            // Eldre Windows-show lagret videovolum i prosent.
            volumeDb = pct <= 0.1 ? -60 : 20 * log10(min(pct, 100) / 100)
        }
        startTime = v(.StartTime, 0.0); endTime = v(.EndTime, 0.0); loop = v(.Loop, false)
        fadeIn = v(.FadeIn, fadeIn); fadeOut = v(.FadeOut, fadeOut)
        fileDuration = v(.FileDuration, 0.0); fileChannels = v(.FileChannels, fileChannels)
        routes = (try? c.decodeIfPresent([AudioRoute].self, forKey: .Routes)) ?? nil
        replaceOthers = v(.ReplaceOthers, true); stretch = v(.Stretch, VisualStretch.uniform)
        knownDuration = v(.KnownDuration, 0.0); holdTime = v(.HoldTime, 0.0); page = max(1, v(.Page, 1))
        target = v(.Target, ""); fadeTime = v(.FadeTime, fadeTime); fadeAudio = v(.FadeAudio, true)
        targetDb = v(.TargetDb, -60.0); fadeVisual = v(.FadeVisual, true); targetOpacity = v(.TargetOpacity, 0.0)
        stopWhenDone = v(.StopWhenDone, true)
        host = v(.Host, "127.0.0.1"); port = v(.Port, 53000); address = v(.Address, "/"); arguments = v(.Arguments, "")
        device = v(.Device, ""); messageType = v(.MessageType, MidiMessageType.noteOn); channel = v(.Channel, 1)
        data1 = v(.Data1, 60); data2 = v(.Data2, 127); mscDeviceId = v(.MscDeviceId, 127)
        mscCommandFormat = v(.MscCommandFormat, 1); mscCueNumber = v(.MscCueNumber, "1")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(type, forKey: .type)
        try c.encode(number, forKey: .Number)
        try c.encode(name, forKey: .Name)
        try c.encode(notes, forKey: .Notes)
        try c.encode(preWait, forKey: .PreWait)
        try c.encode(continueMode, forKey: .ContinueMode)
        try c.encode(hotkey, forKey: .Hotkey)
        try c.encode(disabled, forKey: .Disabled)
        try c.encode(color, forKey: .Color)
        try c.encode(midiTrigger, forKey: .MidiTrigger)
        switch type {
        case .audio:
            try c.encode(filePath, forKey: .FilePath)
            try c.encode(volumeDb, forKey: .VolumeDb)
            try c.encode(startTime, forKey: .StartTime)
            try c.encode(endTime, forKey: .EndTime)
            try c.encode(loop, forKey: .Loop)
            try c.encode(fadeIn, forKey: .FadeIn)
            try c.encode(fadeOut, forKey: .FadeOut)
            try c.encode(fileDuration, forKey: .FileDuration)
            try c.encode(fileChannels, forKey: .FileChannels)
            try c.encode(routes, forKey: .Routes)
        case .video, .image, .pdf:
            try c.encode(filePath, forKey: .FilePath)
            try c.encode(fadeIn, forKey: .FadeIn)
            try c.encode(fadeOut, forKey: .FadeOut)
            try c.encode(replaceOthers, forKey: .ReplaceOthers)
            try c.encode(stretch, forKey: .Stretch)
            if type == .video {
                try c.encode(volumeDb, forKey: .VolumeDb)
                try c.encode(startTime, forKey: .StartTime)
                try c.encode(endTime, forKey: .EndTime)
                try c.encode(loop, forKey: .Loop)
                try c.encode(knownDuration, forKey: .KnownDuration)
                try c.encode(fileChannels, forKey: .FileChannels)
                try c.encode(routes, forKey: .Routes)
            } else {
                try c.encode(holdTime, forKey: .HoldTime)
                if type == .pdf { try c.encode(page, forKey: .Page) }
            }
        case .fade:
            try c.encode(target, forKey: .Target)
            try c.encode(fadeTime, forKey: .FadeTime)
            try c.encode(fadeAudio, forKey: .FadeAudio)
            try c.encode(targetDb, forKey: .TargetDb)
            try c.encode(fadeVisual, forKey: .FadeVisual)
            try c.encode(targetOpacity, forKey: .TargetOpacity)
            try c.encode(stopWhenDone, forKey: .StopWhenDone)
        case .stop:
            try c.encode(target, forKey: .Target)
            try c.encode(fadeTime, forKey: .FadeTime)
        case .osc:
            try c.encode(host, forKey: .Host)
            try c.encode(port, forKey: .Port)
            try c.encode(address, forKey: .Address)
            try c.encode(arguments, forKey: .Arguments)
        case .midi:
            try c.encode(device, forKey: .Device)
            try c.encode(messageType, forKey: .MessageType)
            try c.encode(channel, forKey: .Channel)
            try c.encode(data1, forKey: .Data1)
            try c.encode(data2, forKey: .Data2)
            try c.encode(mscDeviceId, forKey: .MscDeviceId)
            try c.encode(mscCommandFormat, forKey: .MscCommandFormat)
            try c.encode(mscCueNumber, forKey: .MscCueNumber)
        }
    }
}

// MARK: - Showfil

/// Innholdet i en .showcue-fil (samme format som Windows-versjonen).
struct ShowDocument: Codable {
    var formatVersion = 1
    var title = "Nytt show"
    var cues: [Cue] = []

    enum CodingKeys: String, CodingKey { case formatVersion = "FormatVersion", title = "Title", cues = "Cues" }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = (try? c.decodeIfPresent(Int.self, forKey: .formatVersion)) ?? 1
        title = ((try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil) ?? "Show"
        cues = try c.decodeIfPresent([Cue].self, forKey: .cues) ?? []
    }

    func jsonData() throws -> Data {
        let e = JSONEncoder()
        // Sorterte nøkler gir alltid lik fil for likt show (brukes også til «ulagrede endringer»).
        // Windows-versjonen (0.4+) leser "type" uansett hvor i objektet det står.
        e.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        return try e.encode(self)
    }

    func save(to url: URL) throws {
        try jsonData().write(to: url, options: .atomic)
    }

    /// Leser et show. Mediefiler som er flyttet (f.eks. fra en Windows-PC) letes opp ved siden av
    /// showfila, i undermappa «Media», og i Media-mappa ett nivå opp.
    static func load(from url: URL) throws -> ShowDocument {
        var doc = try JSONDecoder().decode(ShowDocument.self, from: Data(contentsOf: url))
        let dir = url.deletingLastPathComponent()
        let fm = FileManager.default
        for cue in doc.cues where cue.isFileCue && !cue.filePath.isEmpty && !fm.fileExists(atPath: cue.filePath) {
            let name = Cue.lastPathComponent(cue.filePath)
            let candidates = [dir.appendingPathComponent(name),
                              dir.appendingPathComponent("Media").appendingPathComponent(name),
                              dir.deletingLastPathComponent().appendingPathComponent("Media").appendingPathComponent(name)]
            if let found = candidates.first(where: { fm.fileExists(atPath: $0.path) }) { cue.filePath = found.path }
        }
        doc.title = url.deletingPathExtension().lastPathComponent
        return doc
    }
}

// MARK: - Tid

enum TimeFormat {
    /// mm:ss.t, eller t:mm:ss over en time.
    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "" }
        let neg = seconds < 0
        let s = abs(seconds)
        let total = Int(s)
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        let tenth = Int((s - Double(total)) * 10)
        let str = h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d.%d", m, sec, tenth)
        return neg ? "-" + str : str
    }
}
