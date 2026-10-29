import Foundation

/// Forhåndslytting: spiller lyden i en cue fra et valgfritt punkt, gjennom lydpatchen, uten å påvirke showet.
final class AudioPreview: ObservableObject {
    private let mixer: () -> PatchMixer?
    @Published private(set) var cue: Cue?
    @Published private(set) var isPlaying = false
    private(set) var voice: Voice?
    private(set) var stream: StreamingSource?
    private var from = 0.0

    init(mixer: @escaping () -> PatchMixer?) { self.mixer = mixer }

    /// Spiller fortsatt (sjekker selve stemmen, ikke bare UI-flagget).
    var isActive: Bool { voice.map { !$0.isFinished } ?? false }

    /// Posisjon i fila (sekunder) mens det spilles, ellers nil.
    var position: Double? {
        guard let v = voice, !v.isFinished else { return nil }
        return from + v.passPosition
    }

    /// Spill fra `from` til `to` (0 = filslutt). Starter man etter sluttpunktet, spilles det til filslutt.
    @discardableResult
    func play(_ cue: Cue, from: Double, to: Double = 0) -> Bool {
        stop()
        guard let m = mixer(), !cue.filePath.isEmpty, FileManager.default.fileExists(atPath: cue.filePath) else { return false }
        let url = URL(fileURLWithPath: cue.filePath)
        let decoder: FrameDecoder
        if cue.type == .video {
            guard let d = try? AssetDecoder(url: url, outputRate: m.sampleRate) else { return false }
            decoder = d
        } else if let d = try? AudioFileDecoder(url: url, outputRate: m.sampleRate) {
            decoder = d
        } else if let d = try? AssetDecoder(url: url, outputRate: m.sampleRate) {
            decoder = d
        } else {
            return false
        }
        let start = max(0, from)
        var end = to
        if end > 0 && end <= start + 0.05 { end = 0 }
        let s = StreamingSource(decoder: decoder, sampleRate: m.sampleRate, startTime: start, endTime: end, loop: false)
        let v = Voice(source: s, sampleRate: m.sampleRate, volumeDb: cue.volumeDb, fadeIn: 0.01, fadeOut: 0.02, loop: false,
                      routes: cue.effectiveRoutes(fileChannels: decoder.channels))
        v.onFinished = { [weak self, weak v, weak s] in
            DispatchQueue.main.async {
                if let s { AudioFeeder.shared.remove(s) }
                guard let self, let v, self.voice === v else { return }
                self.clear()
            }
        }
        s.fill(minimumFrames: Int(0.3 * m.sampleRate))
        AudioFeeder.shared.add(s)
        voice = v
        stream = s
        self.from = s.startTime
        self.cue = cue
        isPlaying = true
        m.add(v)
        return true
    }

    func stop() {
        guard let v = voice else { return }
        v.stop(fade: 0.02)
        let s = stream
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            if let s { AudioFeeder.shared.remove(s) }
            self?.mixer()?.remove(v)
        }
        clear()
    }

    private func clear() {
        voice = nil
        stream = nil
        cue = nil
        isPlaying = false
    }
}
