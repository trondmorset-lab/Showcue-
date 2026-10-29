import Foundation
import os

/// Rask lås med prioritetsarv (trygg å bruke kortvarig fra lydtråden).
final class UnfairLock {
    private let p: UnsafeMutablePointer<os_unfair_lock>
    init() {
        p = .allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
    }
    deinit { p.deinitialize(count: 1); p.deallocate() }
    @inline(__always) func lock() { os_unfair_lock_lock(p) }
    @inline(__always) func unlock() { os_unfair_lock_unlock(p) }
    @inline(__always) func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}

@inline(__always) func dbToGain(_ db: Double) -> Float { db <= -60 ? 0 : Float(pow(10, db / 20)) }

/// En lydkilde som mikser seg selv inn i bussene. Kalles fra lydtråden.
protocol BusSource: AnyObject {
    /// Legg til `frames` rammer i `bus` (interleaved, `busCount` busser). Returner false når kilden er ferdig.
    func render(bus: UnsafeMutablePointer<Float>, frames: Int, busCount: Int) -> Bool
}

// MARK: - PatchMixer

/// cue → (routing) → busser → (patch) → kanaler på lydkortet. Patch og kilder kan endres mens det spilles.
final class PatchMixer {
    static let maxFrames = 4096
    static let maxBuses = 128

    private final class PatchState {
        let gains: [Float]
        let channels: [[Int]] // 0-baserte kanaler på lydkortet
        init(gains: [Float], channels: [[Int]]) { self.gains = gains; self.channels = channels }
    }

    let deviceChannels: Int
    let sampleRate: Double

    private let lock = UnfairLock()
    private var sources: [BusSource] = []
    private var pendingPatch: PatchState
    private var dirty = true

    // Bare lydtråden rører disse:
    private var snapshot: [BusSource] = []
    private var patch: PatchState
    private let bus: UnsafeMutablePointer<Float>
    private let decayPerSecondDb = 20.0

    // Toppnivå per buss og per kanal (0…1+), faller ca. 20 dB/s. Rått minne: lydtråden skriver, UI leser.
    private let busLevelPtr: UnsafeMutablePointer<Float>
    private let channelLevelPtr: UnsafeMutablePointer<Float>
    var busLevels: [Float] { (0..<PatchMixer.maxBuses).map { busLevelPtr[$0] } }
    var channelLevels: [Float] { (0..<deviceChannels).map { channelLevelPtr[$0] } }
    func busLevel(_ i: Int) -> Float { i >= 0 && i < PatchMixer.maxBuses ? busLevelPtr[i] : 0 }
    func channelLevel(_ i: Int) -> Float { i >= 0 && i < deviceChannels ? channelLevelPtr[i] : 0 }

    /// Kalles fra lydtråden når en kilde er ferdig og fjernet.
    var onSourceFinished: ((BusSource) -> Void)?

    init(sampleRate: Double, deviceChannels: Int, patch: [PatchBus]) {
        self.sampleRate = sampleRate
        self.deviceChannels = max(1, deviceChannels)
        let p = PatchMixer.build(patch, deviceChannels: max(1, deviceChannels))
        self.pendingPatch = p
        self.patch = p
        bus = .allocate(capacity: PatchMixer.maxFrames * PatchMixer.maxBuses)
        busLevelPtr = .allocate(capacity: PatchMixer.maxBuses)
        busLevelPtr.initialize(repeating: 0, count: PatchMixer.maxBuses)
        channelLevelPtr = .allocate(capacity: max(1, deviceChannels))
        channelLevelPtr.initialize(repeating: 0, count: max(1, deviceChannels))
    }

    deinit { bus.deallocate(); busLevelPtr.deallocate(); channelLevelPtr.deallocate() }

    var busCount: Int { lock.locked { pendingPatch.gains.count } }

    private static func build(_ patch: [PatchBus], deviceChannels: Int) -> PatchState {
        let list = Array(patch.prefix(maxBuses))
        return PatchState(
            gains: list.map { dbToGain($0.gainDb) },
            channels: list.map { b in Array(Set(b.channels.filter { $0 >= 1 && $0 <= deviceChannels }.map { $0 - 1 })).sorted() })
    }

    func setPatch(_ patch: [PatchBus]) {
        let p = PatchMixer.build(patch, deviceChannels: deviceChannels)
        lock.locked { pendingPatch = p; dirty = true }
    }

    func add(_ s: BusSource) { lock.locked { sources.append(s); dirty = true } }
    func remove(_ s: BusSource) { lock.locked { sources.removeAll { $0 === s }; dirty = true } }
    func removeAll() { lock.locked { sources.removeAll(); dirty = true } }
    func contains(_ s: BusSource) -> Bool { lock.locked { sources.contains { $0 === s } } }

    /// Fyller `out[0..<deviceChannels]` (ikke-interleaved) med `frames` rammer.
    func render(_ out: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>, frames total: Int) {
        lock.lock()
        if dirty { snapshot = sources; patch = pendingPatch; dirty = false }
        lock.unlock()

        let D = deviceChannels
        for c in 0..<D { out[c]?.update(repeating: 0, count: total) }

        var offset = 0
        while offset < total {
            let frames = min(PatchMixer.maxFrames, total - offset)
            renderChunk(out, offset: offset, frames: frames)
            offset += frames
        }
    }

    private func renderChunk(_ out: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>, offset: Int, frames: Int) {
        let p = patch
        let B = p.gains.count
        let D = deviceChannels
        guard B > 0 else { return }
        bus.update(repeating: 0, count: frames * B)

        var finished: [BusSource] = []
        for s in snapshot {
            if !s.render(bus: bus, frames: frames, busCount: B) { finished.append(s) }
        }
        if !finished.isEmpty {
            lock.locked {
                sources.removeAll { src in finished.contains { $0 === src } }
                dirty = true
            }
            finished.forEach { onSourceFinished?($0) }
        }

        let decay = Float(pow(10, -decayPerSecondDb / 20 * Double(frames) / sampleRate))
        for b in 0..<B {
            let g = p.gains[b]
            let chans = p.channels[b]
            var peak: Float = 0
            for f in 0..<frames {
                let v = bus[f * B + b] * g
                let a = abs(v)
                if a > peak { peak = a }
                for c in chans { out[c]?[offset + f] += v }
            }
            busLevelPtr[b] = max(peak, busLevelPtr[b] * decay)
        }
        for b in B..<PatchMixer.maxBuses where busLevelPtr[b] != 0 { busLevelPtr[b] = 0 }
        for c in 0..<D {
            guard let ch = out[c] else { continue }
            var peak: Float = 0
            for f in 0..<frames { let a = abs(ch[offset + f]); if a > peak { peak = a } }
            channelLevelPtr[c] = max(peak, channelLevelPtr[c] * decay)
        }
    }

    /// Testhjelp: mikser til et interleaved buffer (D kanaler).
    func renderInterleaved(frames: Int) -> [Float] {
        let ptrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: deviceChannels)
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: frames * deviceChannels)
        defer { ptrs.deallocate(); storage.deallocate() }
        for c in 0..<deviceChannels { ptrs[c] = storage + c * frames }
        render(ptrs, frames: frames)
        var result = [Float](repeating: 0, count: frames * deviceChannels)
        for c in 0..<deviceChannels { for f in 0..<frames { result[f * deviceChannels + c] = storage[c * frames + f] } }
        return result
    }
}

// MARK: - Testtone

/// Rosa støy på ca. −18 dBFS til én buss, for linjesjekk av patchen.
final class TestToneSource: BusSource {
    let busIndex: Int
    private var b0 = 0.0, b1 = 0.0, b2 = 0.0, b3 = 0.0, b4 = 0.0, b5 = 0.0, b6 = 0.0
    private var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    private var stopped = false
    static let pinkScale = 0.075

    init(busIndex: Int) { self.busIndex = busIndex }
    func stop() { stopped = true }

    @inline(__always) private func white() -> Double {
        // xorshift64* – rask og uten allokering
        seed ^= seed >> 12; seed ^= seed << 25; seed ^= seed >> 27
        let v = seed &* 2_685_821_657_736_338_717
        return Double(v >> 11) / Double(1 << 53) * 2 - 1
    }

    func render(bus: UnsafeMutablePointer<Float>, frames: Int, busCount: Int) -> Bool {
        if stopped { return false }
        guard busIndex < busCount else { return true }
        for f in 0..<frames {
            // Paul Kellett sitt rosa støy-filter
            let w = white()
            b0 = 0.99886 * b0 + w * 0.0555179
            b1 = 0.99332 * b1 + w * 0.0750759
            b2 = 0.96900 * b2 + w * 0.1538520
            b3 = 0.86650 * b3 + w * 0.3104856
            b4 = 0.55000 * b4 + w * 0.5329522
            b5 = -0.7616 * b5 - w * 0.0168980
            let pink = b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362
            b6 = w * 0.115926
            bus[f * busCount + busIndex] += Float(pink * TestToneSource.pinkScale)
        }
        return true
    }
}

// MARK: - Avspillingsstemme

/// Kilde med ferdig dekodede rammer (interleaved, mikserens samplingsfrekvens).
protocol PcmSource: AnyObject {
    var channels: Int { get }
    /// Leser opptil `frames` rammer. Færre betyr at dekoderen ikke har rukket (underrun) eller at kilden er slutt.
    func read(_ dst: UnsafeMutablePointer<Float>, frames: Int) -> Int
    /// Ingen flere data kommer.
    var isEnded: Bool { get }
    /// Rammer lest i gjeldende runde (nullstilles ved loop).
    var passPosition: Int { get }
    /// Rammer per runde, nil = ukjent.
    var passLength: Int? { get }
}

/// Spiller én kilde: nivå, fades (i dB-domenet), automatisk fade ut og routing fra kilde­kanaler til busser.
final class Voice: BusSource {
    static let silenceDb = -80.0

    struct Send { let bus: Int; let gain: Float }

    let source: PcmSource
    let sampleRate: Double
    let autoFadeOutFrames: Int
    private let lock = UnfairLock()
    private var routing: [[Send]]
    private let tmp: UnsafeMutablePointer<Float>

    private var currentDb: Double
    private var targetDb: Double
    private var stepPerFrame = 0.0
    private var rampLeft = 0
    private var stopAfterRamp = false
    private var autoFadeStarted = false
    private var finished = false
    private var finishedReported = false
    private(set) var totalFrames = 0

    /// Kalles (fra lydtråden) én gang når stemmen er ferdig.
    var onFinished: (() -> Void)?

    init(source: PcmSource, sampleRate: Double, volumeDb: Double, fadeIn: Double, fadeOut: Double, loop: Bool, routes: [AudioRoute]) {
        self.source = source
        self.sampleRate = sampleRate
        self.autoFadeOutFrames = (!loop && fadeOut > 0) ? Int(fadeOut * sampleRate) : 0
        self.routing = Voice.buildRouting(routes, channels: source.channels)
        self.tmp = .allocate(capacity: PatchMixer.maxFrames * max(1, source.channels))
        let level = volumeDb <= -60 ? Voice.silenceDb : volumeDb
        if fadeIn > 0 {
            currentDb = Voice.silenceDb; targetDb = level
            beginRamp(level, fadeIn, stop: false)
        } else {
            currentDb = level; targetDb = level
        }
    }

    deinit { tmp.deallocate() }

    static func buildRouting(_ routes: [AudioRoute], channels: Int) -> [[Send]] {
        (0..<max(1, channels)).map { s in
            routes.filter { $0.source == s + 1 && $0.bus >= 1 }
                .map { Send(bus: $0.bus - 1, gain: dbToGain($0.gainDb)) }
                .filter { $0.gain > 0 }
        }
    }

    var elapsed: Double { lock.locked { Double(totalFrames) / sampleRate } }
    var passPosition: Double { Double(source.passPosition) / sampleRate }
    var passLength: Double? { source.passLength.map { Double($0) / sampleRate } }
    var isFinished: Bool { lock.locked { finished } }
    var isRamping: Bool { lock.locked { rampLeft > 0 || stopAfterRamp } }

    func setRouting(_ routes: [AudioRoute]) {
        let r = Voice.buildRouting(routes, channels: source.channels)
        lock.locked { routing = r }
    }

    func fadeTo(_ db: Double, seconds: Double, stopWhenDone: Bool) {
        lock.locked { beginRamp(db <= -60 ? Voice.silenceDb : db, seconds, stop: stopWhenDone) }
    }

    /// Juster nivå med en kort rampe – bare hvis ingen fade pågår.
    func adjustLevel(_ db: Double) {
        lock.locked {
            guard rampLeft == 0, !stopAfterRamp, !autoFadeStarted else { return }
            beginRamp(db <= -60 ? Voice.silenceDb : db, 0.05, stop: false)
        }
    }

    func stop(fade: Double) {
        if fade <= 0 { lock.locked { finished = true } } else { fadeTo(Voice.silenceDb, seconds: fade, stopWhenDone: true) }
    }

    private func beginRamp(_ db: Double, _ seconds: Double, stop: Bool) {
        targetDb = db
        stopAfterRamp = stop
        let frames = Int(seconds * sampleRate)
        if frames <= 0 {
            currentDb = db; rampLeft = 0
            if stop { finished = true }
            return
        }
        rampLeft = frames
        stepPerFrame = (db - currentDb) / Double(frames)
    }

    func render(bus: UnsafeMutablePointer<Float>, frames: Int, busCount: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if finished { reportFinished(); return false }

        let ch = source.channels
        let got = source.read(tmp, frames: frames)
        let passLen = source.passLength
        let passPos = source.passPosition - got // posisjon ved starten av blokka

        for f in 0..<got {
            if autoFadeOutFrames > 0, !autoFadeStarted, let len = passLen, len - (passPos + f) <= autoFadeOutFrames {
                autoFadeStarted = true
                beginRamp(Voice.silenceDb, Double(len - (passPos + f)) / sampleRate, stop: false)
            }
            if rampLeft > 0 {
                currentDb += stepPerFrame
                rampLeft -= 1
                if rampLeft == 0 {
                    currentDb = targetDb
                    if stopAfterRamp { finished = true; totalFrames += f; reportFinished(); return false }
                }
            }
            let g: Float = currentDb <= Voice.silenceDb + 0.01 ? 0 : Float(pow(10, currentDb / 20))
            if g == 0 { continue }
            let src = f * ch
            let dst = f * busCount
            for c in 0..<ch {
                let v = tmp[src + c] * g
                for s in routing[c] where s.bus < busCount { bus[dst + s.bus] += v * s.gain }
            }
        }
        totalFrames += got
        if got < frames && source.isEnded { finished = true }
        if finished { reportFinished(); return false }
        return true
    }

    private func reportFinished() {
        guard !finishedReported else { return }
        finishedReported = true
        let cb = onFinished
        DispatchQueue.main.async { cb?() }
    }
}

// MARK: - Ringbuffer

/// Ringbuffer mellom dekodertråden (skriver) og lydtråden (leser), med merker for loop-punkter
/// slik at «posisjon i runden» blir riktig også når kilden looper.
final class SampleRing {
    let channels: Int
    let capacity: Int // rammer
    private let buf: UnsafeMutablePointer<Float>
    private let lock = UnfairLock()
    private var readIdx = 0, writeIdx = 0, count = 0
    private var writtenTotal = 0, readTotal = 0, passStart = 0
    private var boundaries: [Int] = []
    private var ended = false

    init(channels: Int, capacityFrames: Int) {
        self.channels = max(1, channels)
        self.capacity = max(64, capacityFrames)
        buf = .allocate(capacity: self.capacity * self.channels)
    }
    deinit { buf.deallocate() }

    var freeFrames: Int { lock.locked { capacity - count } }
    var availableFrames: Int { lock.locked { count } }
    var isEnded: Bool { lock.locked { ended && count == 0 } }
    var passPosition: Int { lock.locked { readTotal - passStart } }

    func setEnded() { lock.locked { ended = true } }

    /// Neste rammer som skrives starter en ny runde (loop).
    func markPassStart() { lock.locked { boundaries.append(writtenTotal) } }

    /// Tøm (ved rewind). Neste skrevne ramme er starten på en ny runde.
    func reset() {
        lock.locked {
            readIdx = writeIdx; count = 0
            readTotal = writtenTotal; passStart = writtenTotal
            boundaries.removeAll(); ended = false
        }
    }

    @discardableResult
    func write(_ src: UnsafePointer<Float>, frames: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        let n = min(frames, capacity - count)
        var done = 0
        while done < n {
            let chunk = min(n - done, capacity - writeIdx)
            (buf + writeIdx * channels).update(from: src + done * channels, count: chunk * channels)
            writeIdx = (writeIdx + chunk) % capacity
            done += chunk
        }
        count += n
        writtenTotal += n
        return n
    }

    func read(_ dst: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        let n = min(frames, count)
        var done = 0
        while done < n {
            let chunk = min(n - done, capacity - readIdx)
            (dst + done * channels).update(from: buf + readIdx * channels, count: chunk * channels)
            readIdx = (readIdx + chunk) % capacity
            done += chunk
        }
        count -= n
        readTotal += n
        while let b = boundaries.first, b <= readTotal { passStart = b; boundaries.removeFirst() }
        return n
    }
}
