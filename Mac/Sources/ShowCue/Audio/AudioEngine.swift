import Foundation
import AVFoundation

/// Én avspilling (lyd-cue eller lydsporet i en video).
final class Playback {
    let voice: Voice
    let stream: StreamingSource
    weak var engine: AudioEngine?
    var onFinished: (() -> Void)?
    private(set) var started = false

    init(voice: Voice, stream: StreamingSource) {
        self.voice = voice
        self.stream = stream
    }

    var fileChannels: Int { stream.channels }
    var passPosition: Double { voice.passPosition }
    var passLength: Double? { voice.passLength }
    var elapsed: Double { voice.elapsed }

    /// Starter lyden (fyller litt buffer først så starten blir umiddelbar).
    func start() {
        guard !started, let e = engine, let m = e.mixer else { return }
        started = true
        stream.fill(minimumFrames: Int(0.3 * stream.sampleRate))
        AudioFeeder.shared.add(stream)
        m.add(voice)
    }

    func fadeTo(_ db: Double, seconds: Double, stopWhenDone: Bool) { voice.fadeTo(db, seconds: seconds, stopWhenDone: stopWhenDone) }
    func adjustLevel(_ db: Double) { voice.adjustLevel(db) }
    func setRouting(_ routes: [AudioRoute]) { voice.setRouting(routes) }
    func requestRewind() { stream.requestRewind() }

    func stop(fade: Double) {
        voice.stop(fade: fade)
        if fade <= 0 { cleanup() }
    }

    /// Fjern fra mikser og dekoder (trygt å kalle flere ganger).
    func cleanup() {
        engine?.mixer?.remove(voice)
        AudioFeeder.shared.remove(stream)
    }
}

/// Lydmotoren: én CoreAudio-utgang med PatchMixer, testtoner og avspillinger.
final class AudioEngine: ObservableObject {
    private let output = AudioOutput()
    @Published private(set) var status = "Lyd ikke startet"
    @Published private(set) var deviceChannels = 0
    @Published private(set) var sampleRate: Double = 0
    @Published private(set) var channelNames: [String] = []
    @Published private(set) var testTones: Set<Int> = []
    private var toneSources: [Int: TestToneSource] = [:]

    var mixer: PatchMixer? { output.isRunning ? mixerRef : nil }
    private var mixerRef: PatchMixer?
    var isRunning: Bool { output.isRunning }

    func start(_ s: AppSettings) {
        stop()
        do {
            try open(s, uid: s.audioDeviceUID)
        } catch {
            let reason = error.localizedDescription
            do {
                try open(s, uid: "")
                status = "Kunne ikke åpne valgt lydenhet (\(reason)). Bruker systemets standard utgang."
            } catch {
                status = "Ingen lydutgang: \(error.localizedDescription)"
            }
        }
    }

    private func open(_ s: AppSettings, uid: String) throws {
        guard let dev = CoreAudioDevices.device(uid: uid) else {
            throw NSError(domain: "ShowCue.Audio", code: -10, userInfo: [NSLocalizedDescriptionKey: "Lydenheten finnes ikke (er den koblet til?)"])
        }
        let m = try output.start(device: dev, maxChannels: s.maxChannels, bufferFrames: s.bufferFrames, patch: s.buses)
        m.onSourceFinished = { [weak self] src in
            guard let tone = src as? TestToneSource else { return }
            DispatchQueue.main.async { self?.toneFinished(tone) }
        }
        mixerRef = m
        deviceChannels = m.deviceChannels
        sampleRate = m.sampleRate
        channelNames = CoreAudioDevices.channelNames(dev.id, count: m.deviceChannels)
        status = "\(dev.name) · \(m.deviceChannels) kanaler · \(Cue.fmt(m.sampleRate / 1000)) kHz"
    }

    func stop() {
        output.stop()
        mixerRef = nil
        toneSources.removeAll()
        testTones.removeAll()
        deviceChannels = 0
        channelNames = []
    }

    func applyPatch(_ buses: [PatchBus]) { mixer?.setPatch(buses) }

    // MARK: Avspilling

    /// Lager en avspilling av en lyd-cue (startes med `start()`).
    func makePlayback(audio cue: Cue) throws -> Playback {
        guard let m = mixer else { throw NSError(domain: "ShowCue.Audio", code: -20, userInfo: [NSLocalizedDescriptionKey: "Lydutgangen er ikke startet. Sjekk innstillinger."]) }
        let url = URL(fileURLWithPath: cue.filePath)
        let decoder: FrameDecoder
        do { decoder = try AudioFileDecoder(url: url, outputRate: m.sampleRate) }
        catch { decoder = try AssetDecoder(url: url, outputRate: m.sampleRate) } // reserve for formater AVAudioFile ikke åpner
        let stream = StreamingSource(decoder: decoder, sampleRate: m.sampleRate, startTime: cue.startTime, endTime: cue.endTime, loop: cue.loop)
        let voice = Voice(source: stream, sampleRate: m.sampleRate, volumeDb: cue.volumeDb, fadeIn: cue.fadeIn, fadeOut: cue.fadeOut,
                          loop: stream.loop, routes: cue.effectiveRoutes(fileChannels: decoder.channels))
        return wire(voice, stream)
    }

    /// Lydsporet i en video. nil hvis videoen ikke har lyd.
    func makePlayback(videoAudio cue: Cue) -> Playback? {
        guard let m = mixer, let decoder = try? AssetDecoder(url: URL(fileURLWithPath: cue.filePath), outputRate: m.sampleRate) else { return nil }
        let stream = StreamingSource(decoder: decoder, sampleRate: m.sampleRate, startTime: cue.startTime, endTime: cue.endTime, loop: cue.loop)
        // Fade ut styres av video-cuen (samme tid for bilde og lyd).
        let voice = Voice(source: stream, sampleRate: m.sampleRate, volumeDb: cue.volumeDb, fadeIn: cue.fadeIn, fadeOut: 0,
                          loop: stream.loop, routes: cue.effectiveRoutes(fileChannels: decoder.channels))
        return wire(voice, stream)
    }

    private func wire(_ voice: Voice, _ stream: StreamingSource) -> Playback {
        let p = Playback(voice: voice, stream: stream)
        p.engine = self
        voice.onFinished = { [weak p] in
            guard let p else { return }
            p.cleanup()
            p.onFinished?()
        }
        return p
    }

    // MARK: Testtone

    func setTestTone(bus: Int, on: Bool) {
        guard let m = mixer else { return }
        if on, toneSources[bus] == nil {
            let t = TestToneSource(busIndex: bus)
            toneSources[bus] = t
            m.add(t)
            testTones.insert(bus)
        } else if !on, let t = toneSources.removeValue(forKey: bus) {
            t.stop()
            testTones.remove(bus)
        }
    }

    func stopAllTestTones() {
        toneSources.values.forEach { $0.stop() }
        toneSources.removeAll()
        testTones.removeAll()
    }

    private func toneFinished(_ t: TestToneSource) {
        if toneSources[t.busIndex] === t { toneSources.removeValue(forKey: t.busIndex); testTones.remove(t.busIndex) }
    }

    // MARK: Undersøk filer

    /// Lengde og kanaler i en lydfil (0, 0 ved feil).
    static func probeAudio(_ path: String) -> (duration: Double, channels: Int) {
        let url = URL(fileURLWithPath: path)
        if let f = try? AVAudioFile(forReading: url) {
            let fmt = f.processingFormat
            return (fmt.sampleRate > 0 ? Double(f.length) / fmt.sampleRate : 0, Int(fmt.channelCount))
        }
        return AssetDecoder.probe(url: url)
    }
}
