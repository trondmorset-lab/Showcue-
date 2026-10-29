import Foundation
import AVFoundation
import Combine

/// En cue som er avfyrt: venter (pre-wait), spiller, eller holder på å fade ut.
class ActiveCue: ObservableObject, Identifiable {
    let id = UUID()
    let cue: Cue
    unowned let engine: CueEngine
    var startAt: Double = 0

    @Published private(set) var started = false
    @Published var elapsed: Double = 0
    @Published var duration: Double = 0
    @Published var isStopping = false
    private(set) var done = false
    /// Stoppet manuelt eller av stopp-/fade-cue (utløser ikke auto-follow).
    var wasStopped = false
    var onCompleted: ((ActiveCue) -> Void)?

    init(cue: Cue, engine: CueEngine) {
        self.cue = cue
        self.engine = engine
    }

    var progress: Double { duration > 0 ? min(1, max(0, elapsed / duration)) : 0 }
    var elapsedText: String { started ? TimeFormat.format(elapsed) : "-" + TimeFormat.format(max(0, startAt - engine.now)) }
    var remainingText: String { started ? (duration > 0 ? "-" + TimeFormat.format(max(0, duration - elapsed)) : "∞") : "" }
    var stateText: String { !started ? "Pre-wait" : isStopping ? "Fader ut" : "Spiller" }

    func begin() throws {
        started = true
        try onBegin()
    }

    func onBegin() throws {}
    /// Ca. 60 ganger i sekundet.
    func tick() { if !started { objectWillChange.send() } }

    func stop(fade: Double) {
        wasStopped = true
        if !started { complete() }
    }

    func applyFade(_ fade: Cue) {}

    func complete() {
        guard !done else { return }
        done = true
        onComplete()
        onCompleted?(self)
    }

    func onComplete() {}
}

// MARK: - Lyd

final class AudioActive: ActiveCue {
    private var playback: Playback?
    private var subs: Set<AnyCancellable> = []

    override func onBegin() throws {
        guard FileManager.default.fileExists(atPath: cue.filePath) else { throw CueError.fileMissing(cue.filePath) }
        let pb = try engine.audio.makePlayback(audio: cue)
        playback = pb
        pb.onFinished = { [weak self] in self?.complete() }
        duration = cue.loop ? 0 : (pb.passLength ?? 0)
        if cue.fileChannels != pb.fileChannels { cue.fileChannels = pb.fileChannels }
        if cue.fileDuration <= 0, let len = pb.passLength, cue.endTime <= 0 { cue.fileDuration = cue.startTime + len }
        pb.start()
        // Endringer i routing og nivå høres med en gang (nyttig under lydsjekk).
        cue.$routes.dropFirst().sink { [weak self] _ in
            guard let self, let pb = self.playback else { return }
            DispatchQueue.main.async { pb.setRouting(self.cue.effectiveRoutes(fileChannels: pb.fileChannels)) }
        }.store(in: &subs)
        cue.$volumeDb.dropFirst().sink { [weak self] db in
            guard let self, !self.isStopping else { return }
            self.playback?.adjustLevel(db)
        }.store(in: &subs)
    }

    override func tick() {
        super.tick()
        guard let pb = playback, started, !done else { return }
        elapsed = cue.loop ? pb.elapsed : pb.passPosition
    }

    override func stop(fade: Double) {
        super.stop(fade: fade)
        guard let pb = playback, !done else { return }
        isStopping = true
        pb.stop(fade: fade)
        if fade <= 0 { complete() }
    }

    override func applyFade(_ f: Cue) {
        guard let pb = playback else { return }
        if f.fadeAudio {
            if f.stopWhenDone { wasStopped = true; isStopping = true }
            pb.fadeTo(f.targetDb, seconds: f.fadeTime, stopWhenDone: f.stopWhenDone)
        } else if f.stopWhenDone {
            stop(fade: 0)
        }
    }

    override func onComplete() {
        subs.removeAll()
        playback?.cleanup()
    }
}

enum CueError: LocalizedError {
    case fileMissing(String)
    var errorDescription: String? {
        switch self { case .fileMissing(let p): return "Fila finnes ikke: \(p)" }
    }
}

// MARK: - Visuelt (felles)

class VisualActive: ActiveCue {
    var layers: LayerPair?
    var startedAt: Double = 0
    private var finishAt: Double?

    func makeLayers() throws -> LayerPair { fatalError("overstyres") }

    override func onBegin() throws {
        guard FileManager.default.fileExists(atPath: cue.filePath) else { throw CueError.fileMissing(cue.filePath) }
        if cue.replaceOthers {
            // Krysstoning: de andre fades ut mens denne fades inn.
            for other in engine.active.compactMap({ $0 as? VisualActive }) where other !== self && other.started && !other.done && !other.isStopping {
                other.stop(fade: cue.fadeIn > 0 ? cue.fadeIn : other.cue.fadeOut)
            }
        }
        let l = try makeLayers()
        layers = l
        startedAt = engine.now
        l.setOpacity(1, duration: cue.fadeIn)
    }

    override func tick() {
        super.tick()
        if let t = finishAt, engine.now >= t { finish() }
    }

    override func stop(fade: Double) {
        super.stop(fade: fade)
        guard started, !done else { return }
        isStopping = true
        layers?.setOpacity(0, duration: fade)
        onStopping(fade)
        if fade <= 0 { finish() } else { finishAt = engine.now + fade }
    }

    func onStopping(_ fade: Double) {}

    override func applyFade(_ f: Cue) {
        guard let l = layers, !done else { return }
        if f.fadeVisual { l.setOpacity(Float(f.targetOpacity / 100), duration: f.fadeTime) }
        if f.stopWhenDone {
            wasStopped = true
            isStopping = true
            finishAt = engine.now + f.fadeTime
        }
    }

    func finish() {
        guard !done else { return }
        finishAt = nil
        onRemove()
        layers?.remove()
        complete()
    }

    func onRemove() {}
}

// MARK: - Bilde og PDF

final class StillActive: VisualActive {
    override func makeLayers() throws -> LayerPair {
        let page = cue.type == .pdf ? cue.page : 0
        var image = MediaCache.shared.cached(path: cue.filePath, page: page)
        if image == nil { image = MediaCache.shared.image(path: cue.filePath, page: page) }
        guard let img = image else {
            throw CueError.fileMissing(cue.type == .pdf ? "\(cue.filePath) (side \(cue.page))" : cue.filePath)
        }
        duration = cue.duration
        return engine.output.addImage(img, stretch: cue.stretch)
    }

    override func tick() {
        super.tick()
        guard started, !done else { return }
        elapsed = engine.now - startedAt
        if cue.holdTime > 0, !isStopping, elapsed >= cue.fadeIn + cue.holdTime {
            stop(fade: cue.fadeOut)
            wasStopped = false // naturlig slutt → auto-follow skal virke
        }
    }
}

// MARK: - Video

/// Bildet spilles av AVPlayer (dempet). Lyden pakkes ut og spilles gjennom lydpatchen, og er «master»:
/// glir bildet mer enn 0,12 s fra lyden (f.eks. fordi Dante-klokka og Mac-klokka går litt ulikt), justeres bildet.
final class VideoActive: VisualActive {
    private var player: AVPlayer?
    private var audio: Playback?
    private var audioStarted = false
    private var statusObs: NSKeyValueObservation?
    private var endObs: NSObjectProtocol?
    private var lastResync: Double = 0
    private var subs: Set<AnyCancellable> = []
    static let maxDrift = 0.12

    override func makeLayers() throws -> LayerPair {
        let item = AVPlayerItem(url: URL(fileURLWithPath: cue.filePath))
        let p = AVPlayer(playerItem: item)
        p.isMuted = true
        p.volume = 0
        p.actionAtItemEnd = .pause
        player = p

        if !(cue.routes?.isEmpty ?? false) {
            audio = engine.audio.makePlayback(videoAudio: cue)
            if let a = audio { if cue.fileChannels != a.fileChannels { cue.fileChannels = a.fileChannels } }
            else if engine.audio.isRunning, cue.fileChannels != 0 { cue.fileChannels = 0 }
        }

        statusObs = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async { self?.itemStatusChanged(item) }
        }
        endObs = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            self?.reachedEnd()
        }
        cue.$routes.dropFirst().sink { [weak self] _ in
            guard let self, let a = self.audio else { return }
            DispatchQueue.main.async { a.setRouting(self.cue.effectiveRoutes(fileChannels: a.fileChannels)) }
        }.store(in: &subs)
        cue.$volumeDb.dropFirst().sink { [weak self] db in
            guard let self, !self.isStopping else { return }
            self.audio?.adjustLevel(db)
        }.store(in: &subs)

        p.play()
        return engine.output.addVideo(p, stretch: cue.stretch)
    }

    private func itemStatusChanged(_ item: AVPlayerItem) {
        guard !done else { return }
        switch item.status {
        case .readyToPlay:
            let d = item.duration.seconds
            if d.isFinite && d > 0 {
                cue.knownDuration = d
                duration = cue.loop ? 0 : d
            }
            startAudio() // bilde og lyd starter samtidig
        case .failed:
            cue.error = "Video: " + (item.error?.localizedDescription ?? "ukjent feil")
            finish()
        default: break
        }
    }

    private func startAudio() {
        guard let a = audio, !audioStarted, !done else { return }
        audioStarted = true
        a.start()
        lastResync = engine.now
    }

    private func reachedEnd() {
        guard !done else { return }
        if cue.loop && !isStopping {
            player?.seek(to: .zero)
            player?.play()
            audio?.requestRewind()
        } else {
            finish()
        }
    }

    override func tick() {
        super.tick()
        guard let p = player, started, !done else { return }
        let pos = p.currentTime().seconds
        if pos.isFinite { elapsed = pos }

        if let a = audio, audioStarted, !isStopping, engine.now - lastResync > 2 {
            let audioPos = a.passPosition
            if audioPos > 0.5, abs(audioPos - elapsed) > VideoActive.maxDrift, duration == 0 || audioPos < duration - 1 {
                p.seek(to: CMTime(seconds: audioPos, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                lastResync = engine.now
            }
        }

        // Automatisk fade ut mot slutten.
        if !cue.loop, !isStopping, cue.fadeOut > 0, duration > 0, duration - elapsed <= cue.fadeOut {
            stop(fade: max(0.05, duration - elapsed))
            wasStopped = false
        }
    }

    override func onStopping(_ fade: Double) { audio?.stop(fade: fade) }

    override func applyFade(_ f: Cue) {
        super.applyFade(f)
        if f.fadeAudio { audio?.fadeTo(f.targetDb, seconds: f.fadeTime, stopWhenDone: false) }
    }

    override func onRemove() {
        subs.removeAll()
        statusObs?.invalidate()
        if let o = endObs { NotificationCenter.default.removeObserver(o) }
        audio?.stop(fade: 0)
        audio?.cleanup()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
    }
}

// MARK: - Fade og stopp

final class FadeActive: ActiveCue {
    private var begin: Double = 0

    override func onBegin() throws {
        begin = engine.now
        duration = cue.fadeTime
        let targets = engine.findActive(cue.target)
        if targets.isEmpty { cue.error = cue.target.isEmpty ? "Mangler mål-cue" : "Cue \(cue.target) kjører ikke" }
        targets.forEach { $0.applyFade(cue) }
        if cue.fadeTime <= 0 { complete() }
    }

    override func tick() {
        super.tick()
        guard started, !done else { return }
        elapsed = engine.now - begin
        if elapsed >= cue.fadeTime { complete() }
    }

    override func stop(fade: Double) { super.stop(fade: fade); complete() }
}

final class StopActive: ActiveCue {
    private var begin: Double = 0

    override func onBegin() throws {
        begin = engine.now
        duration = cue.fadeTime
        let targets = cue.target.isEmpty
            ? engine.active.filter { $0 !== self && !($0 is StopActive) }
            : engine.findActive(cue.target)
        targets.forEach { $0.stop(fade: cue.fadeTime) }
        if cue.fadeTime <= 0 { complete() }
    }

    override func tick() {
        super.tick()
        guard started, !done else { return }
        elapsed = engine.now - begin
        if elapsed >= cue.fadeTime { complete() }
    }

    override func stop(fade: Double) { super.stop(fade: fade); complete() }
}

// MARK: - OSC og MIDI (umiddelbare)

final class InstantActive: ActiveCue {
    override func onBegin() throws {
        defer { complete() }
        switch cue.type {
        case .osc:
            guard OscSender.shared.send(host: cue.host, port: cue.port, address: cue.address.isEmpty ? "/" : cue.address,
                                        args: Osc.parseArguments(cue.arguments)) else {
                throw NSError(domain: "ShowCue.OSC", code: 1, userInfo: [NSLocalizedDescriptionKey: "Kunne ikke sende til \(cue.host):\(cue.port)"])
            }
        case .midi:
            try engine.midi.send(MidiOut.bytes(for: cue), device: cue.device)
        default: break
        }
    }
}
