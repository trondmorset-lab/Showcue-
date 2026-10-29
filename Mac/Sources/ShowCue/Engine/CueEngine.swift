import Foundation
import QuartzCore

/// Kjører cuer: pre-wait, auto-continue, auto-follow, stopp og panikk. Alt skjer på hovedtråden;
/// bare selve lydmiksingen og dekodingen går på egne tråder.
final class CueEngine: ObservableObject {
    let audio: AudioEngine
    let output: OutputCompositor
    let midi: MidiSystem
    private let cueList: () -> [Cue]
    private let t0 = CACurrentMediaTime()
    private var timer: Timer?

    @Published private(set) var active: [ActiveCue] = []
    var onTick: (() -> Void)?
    var onLog: ((String) -> Void)?

    var now: Double { CACurrentMediaTime() - t0 }

    init(audio: AudioEngine, output: OutputCompositor, midi: MidiSystem, cueList: @escaping () -> [Cue]) {
        self.audio = audio
        self.output = output
        self.midi = midi
        self.cueList = cueList
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common) // går også mens menyer er åpne
        timer = t
    }

    deinit { timer?.invalidate() }

    // MARK: Avfyring

    func fire(_ cue: Cue) {
        let a = make(cue)
        a.startAt = now + cue.preWait
        a.onCompleted = { [weak self] in self?.completed($0) }
        cue.error = nil
        cue.activeCount += 1
        active.append(a)
        if cue.preWait > 0 { cue.isPreWaiting = true } else { start(a) }
    }

    private func make(_ cue: Cue) -> ActiveCue {
        switch cue.type {
        case .audio: return AudioActive(cue: cue, engine: self)
        case .video: return VideoActive(cue: cue, engine: self)
        case .image, .pdf: return StillActive(cue: cue, engine: self)
        case .fade: return FadeActive(cue: cue, engine: self)
        case .stop: return StopActive(cue: cue, engine: self)
        case .osc, .midi: return InstantActive(cue: cue, engine: self)
        }
    }

    private func start(_ a: ActiveCue) {
        a.cue.isPreWaiting = active.contains { $0.cue === a.cue && $0 !== a && !$0.started }
        do {
            try a.begin()
        } catch {
            a.cue.error = error.localizedDescription
            onLog?("Cue \(a.cue.number): \(error.localizedDescription)")
            if !a.done { a.stop(fade: 0) }
            if !a.done { forceRemove(a) }
        }
        if a.cue.continueMode == .autoContinue { fireNext(after: a.cue) }
    }

    private func completed(_ a: ActiveCue) {
        active.removeAll { $0 === a }
        a.cue.activeCount = max(0, a.cue.activeCount - 1)
        if !a.cue.isRunning { a.cue.progress = 0; a.cue.isPreWaiting = false }
        if a.started && !a.wasStopped && a.cue.continueMode == .autoFollow { fireNext(after: a.cue) }
    }

    private func forceRemove(_ a: ActiveCue) {
        a.onCompleted = nil
        if active.contains(where: { $0 === a }) {
            active.removeAll { $0 === a }
            a.cue.activeCount = max(0, a.cue.activeCount - 1)
        }
    }

    private func fireNext(after cue: Cue) {
        let list = cueList()
        guard let i = list.firstIndex(where: { $0 === cue }) else { return }
        if let next = list[(i + 1)...].first(where: { !$0.disabled }) { fire(next) }
    }

    /// Indeksen GO-markøren skal til etter at cuen på `fired` er avfyrt (hopper over kjeder og deaktiverte).
    static func nextPlayheadIndex(_ list: [Cue], fired: Int) -> Int {
        var i = fired
        while i < list.count && list[i].continueMode != .none {
            i += 1
            while i < list.count && list[i].disabled { i += 1 }
        }
        i += 1
        while i < list.count && list[i].disabled { i += 1 }
        return min(i, list.count)
    }

    func findActive(_ number: String) -> [ActiveCue] {
        let n = number.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return [] }
        return active.filter { $0.started && !$0.done && $0.cue.number.caseInsensitiveCompare(n) == .orderedSame }
    }

    func stop(_ cue: Cue, fade: Double) {
        active.filter { $0.cue === cue }.forEach { $0.stop(fade: fade) }
    }

    func stopAll(fade: Double) {
        active.forEach { $0.stop(fade: fade) }
    }

    // MARK: Takt

    private func tick() {
        let t = now
        for a in active {
            if a.done { continue }
            if !a.started && t >= a.startAt { start(a) }
            if a.done { continue }
            a.tick()
            let p = a.progress
            if abs(a.cue.progress - p) > 0.002 { a.cue.progress = p }
        }
        onTick?()
    }
}
