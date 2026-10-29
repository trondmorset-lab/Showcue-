import Foundation

enum AppTheme: String, Codable, CaseIterable {
    case dark = "Dark", light = "Light", night = "Night"
    var label: String {
        switch self {
        case .dark: return "Mørk"
        case .light: return "Lys"
        case .night: return "Nattmodus (ekstra dempet)"
        }
    }
    var next: AppTheme {
        switch self {
        case .dark: return .light
        case .light: return .night
        case .night: return .dark
        }
    }
}

enum OscFeedbackFormat: String, Codable, CaseIterable {
    case companion = "Companion", generic = "Generic"
    var label: String { self == .companion ? "Companion (Custom Variables)" : "Generisk (/showcue/…)" }
}

/// En logisk utgang i lydpatchen.
struct PatchBus: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var gainDb: Double = 0
    /// Kanaler på lydkortet (fra 1).
    var channels: [Int] = []

    enum CodingKeys: String, CodingKey { case name, gainDb, channels }

    init(name: String, gainDb: Double = 0, channels: [Int] = []) {
        self.name = name; self.gainDb = gainDb; self.channels = channels
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? "Utgang"
        gainDb = (try? c.decode(Double.self, forKey: .gainDb)) ?? 0
        channels = (try? c.decode([Int].self, forKey: .channels)) ?? []
    }

    static func defaultPatch(_ count: Int) -> [PatchBus] {
        (1...count).map { i in
            PatchBus(name: i == 1 ? "Main L" : i == 2 ? "Main R" : "Utgang \(i)", channels: [i])
        }
    }
}

/// Maskininnstillinger (lagres i ~/Library/Application Support/ShowCue, ikke i showfila).
struct AppSettings: Codable, Equatable {
    // Lyd
    /// CoreAudio-enhetens UID. Tom = systemets standard utgang.
    var audioDeviceUID = ""
    var maxChannels = 64
    var bufferFrames = 256
    var buses: [PatchBus] = PatchBus.defaultPatch(8)

    // Video
    /// -1 = eget vindu, ellers skjermnummer (0 = hovedskjerm).
    var videoScreen = -1

    // OSC inn
    var oscInEnabled = true
    var oscInPort = 53000

    // OSC ut (status)
    var oscFeedbackEnabled = false
    var oscFeedbackHost = "127.0.0.1"
    var oscFeedbackPort = 12321
    var oscFeedbackFormat: OscFeedbackFormat = .companion

    // MIDI inn
    var midiInDevice = ""
    var midiInChannel = 0
    var midiGo = ""
    var midiStopAll = ""
    var midiNext = ""
    var midiPrevious = ""
    var mscInEnabled = true
    var mscInDeviceId = 127

    // Utseende og sikkerhet
    var theme: AppTheme = .dark
    var panicFadeTime = 1.0
    var doubleGoProtectionMs = 300

    var lastShowPath = ""

    init() {}

    enum CodingKeys: String, CodingKey {
        case audioDeviceUID, maxChannels, bufferFrames, buses, videoScreen, oscInEnabled, oscInPort
        case oscFeedbackEnabled, oscFeedbackHost, oscFeedbackPort, oscFeedbackFormat
        case midiInDevice, midiInChannel, midiGo, midiStopAll, midiNext, midiPrevious, mscInEnabled, mscInDeviceId
        case theme, panicFadeTime, doubleGoProtectionMs, lastShowPath
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? def }
        audioDeviceUID = v(.audioDeviceUID, d.audioDeviceUID)
        maxChannels = v(.maxChannels, d.maxChannels)
        bufferFrames = v(.bufferFrames, d.bufferFrames)
        buses = v(.buses, d.buses)
        if buses.isEmpty { buses = PatchBus.defaultPatch(8) }
        videoScreen = v(.videoScreen, d.videoScreen)
        oscInEnabled = v(.oscInEnabled, d.oscInEnabled)
        oscInPort = v(.oscInPort, d.oscInPort)
        oscFeedbackEnabled = v(.oscFeedbackEnabled, d.oscFeedbackEnabled)
        oscFeedbackHost = v(.oscFeedbackHost, d.oscFeedbackHost)
        oscFeedbackPort = v(.oscFeedbackPort, d.oscFeedbackPort)
        oscFeedbackFormat = v(.oscFeedbackFormat, d.oscFeedbackFormat)
        midiInDevice = v(.midiInDevice, d.midiInDevice)
        midiInChannel = v(.midiInChannel, d.midiInChannel)
        midiGo = v(.midiGo, d.midiGo)
        midiStopAll = v(.midiStopAll, d.midiStopAll)
        midiNext = v(.midiNext, d.midiNext)
        midiPrevious = v(.midiPrevious, d.midiPrevious)
        mscInEnabled = v(.mscInEnabled, d.mscInEnabled)
        mscInDeviceId = v(.mscInDeviceId, d.mscInDeviceId)
        theme = v(.theme, d.theme)
        panicFadeTime = v(.panicFadeTime, d.panicFadeTime)
        doubleGoProtectionMs = v(.doubleGoProtectionMs, d.doubleGoProtectionMs)
        lastShowPath = v(.lastShowPath, d.lastShowPath)
    }

    /// Nøkkel for lydoppsettet: bare endringer her krever omstart av lyden.
    var audioKey: String { "\(audioDeviceUID)|\(maxChannels)|\(bufferFrames)" }

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("ShowCue").appendingPathComponent("settings.json")
    }

    static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: AppSettings.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let e = JSONEncoder()
            e.outputFormatting = [.prettyPrinted]
            try e.encode(self).write(to: AppSettings.fileURL, options: .atomic)
        } catch {
            NSLog("ShowCue: kunne ikke lagre innstillinger: \(error)")
        }
    }
}
