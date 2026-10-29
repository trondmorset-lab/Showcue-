import Foundation
import AVFoundation
import CoreMedia

/// Dekoder som gir interleaved Float32 i mikserens samplingsfrekvens.
protocol FrameDecoder: AnyObject {
    var channels: Int { get }
    /// Lengde i sekunder (0 = ukjent).
    var duration: Double { get }
    func seek(to seconds: Double)
    /// Leser opptil `maxFrames` rammer. 0 = slutt på fila.
    func read(into dst: UnsafeMutablePointer<Float>, maxFrames: Int) -> Int
}

enum DecoderError: LocalizedError {
    case noAudio
    case unsupported(String)
    var errorDescription: String? {
        switch self {
        case .noAudio: return "Fila har ikke noe lydspor."
        case .unsupported(let s): return s
        }
    }
}

// MARK: - Lydfiler (AVAudioFile): WAV, AIFF, MP3, M4A/AAC, FLAC, CAF …

final class AudioFileDecoder: FrameDecoder {
    private let file: AVAudioFile
    private let inFormat: AVAudioFormat
    private let outFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private let inBuf: AVAudioPCMBuffer
    private var eof = false

    let channels: Int
    let duration: Double

    init(url: URL, outputRate: Double) throws {
        file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        inFormat = file.processingFormat
        channels = Int(inFormat.channelCount)
        guard channels > 0 else { throw DecoderError.noAudio }
        duration = inFormat.sampleRate > 0 ? Double(file.length) / inFormat.sampleRate : 0

        if inFormat.sampleRate == outputRate {
            outFormat = inFormat
            converter = nil
        } else {
            // Samme kanaloppsett inn og ut: konverteren skal bare endre samplingsfrekvens, aldri mikse ned.
            if let layout = inFormat.channelLayout {
                outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputRate, interleaved: false, channelLayout: layout)
            } else if let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputRate, channels: inFormat.channelCount, interleaved: false) {
                outFormat = f
            } else {
                throw DecoderError.unsupported("Kan ikke konvertere \(channels) kanaler")
            }
            converter = AVAudioConverter(from: inFormat, to: outFormat)
            converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        }
        guard let b = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: 4096) else { throw DecoderError.unsupported("Minnefeil") }
        inBuf = b
    }

    func seek(to seconds: Double) {
        file.framePosition = AVAudioFramePosition(max(0, seconds) * inFormat.sampleRate)
        eof = false
        converter?.reset()
    }

    func read(into dst: UnsafeMutablePointer<Float>, maxFrames: Int) -> Int {
        guard maxFrames > 0, let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(maxFrames)) else { return 0 }
        if let conv = converter {
            if eof { return 0 }
            var err: NSError?
            let status = conv.convert(to: out, error: &err) { [weak self] want, inStatus in
                guard let self, !self.eof else { inStatus.pointee = .endOfStream; return nil }
                self.inBuf.frameLength = 0
                do {
                    try self.file.read(into: self.inBuf, frameCount: min(want, self.inBuf.frameCapacity))
                } catch {
                    self.eof = true; inStatus.pointee = .endOfStream; return nil
                }
                if self.inBuf.frameLength == 0 { self.eof = true; inStatus.pointee = .endOfStream; return nil }
                inStatus.pointee = .haveData
                return self.inBuf
            }
            if status == .error { return 0 }
        } else {
            do { try file.read(into: out, frameCount: AVAudioFrameCount(maxFrames)) } catch { return 0 }
        }
        return interleave(out, into: dst)
    }

    private func interleave(_ b: AVAudioPCMBuffer, into dst: UnsafeMutablePointer<Float>) -> Int {
        let n = Int(b.frameLength)
        guard n > 0, let data = b.floatChannelData else { return 0 }
        let ch = channels
        for c in 0..<ch {
            let src = data[c]
            for f in 0..<n { dst[f * ch + c] = src[f] }
        }
        return n
    }
}

// MARK: - Lydspor i video (AVAssetReader): MP4, MOV, M4V …

final class AssetDecoder: FrameDecoder {
    private let asset: AVURLAsset
    private let track: AVAssetTrack
    private let outputRate: Double
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var pending: [Float] = []
    private var pendingOffset = 0

    let channels: Int
    let duration: Double

    init(url: URL, outputRate: Double) throws {
        asset = AVURLAsset(url: url)
        guard let t = asset.tracks(withMediaType: .audio).first else { throw DecoderError.noAudio }
        track = t
        self.outputRate = outputRate
        var ch = 2
        if let fd = t.formatDescriptions.first {
            let desc = fd as! CMAudioFormatDescription
            if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) {
                ch = Int(asbd.pointee.mChannelsPerFrame)
            }
        }
        channels = max(1, ch)
        let d = CMTimeGetSeconds(asset.duration)
        duration = d.isFinite ? d : 0
        try makeReader(from: 0)
    }

    /// Leser bare kanaler og lengde (uten å starte dekoding).
    static func probe(url: URL) -> (duration: Double, channels: Int) {
        let asset = AVURLAsset(url: url)
        guard let t = asset.tracks(withMediaType: .audio).first else { return (0, 0) }
        var ch = 2
        if let fd = t.formatDescriptions.first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd as! CMAudioFormatDescription) {
            ch = Int(asbd.pointee.mChannelsPerFrame)
        }
        let d = CMTimeGetSeconds(asset.duration)
        return (d.isFinite ? d : 0, max(1, ch))
    }

    private func makeReader(from seconds: Double) throws {
        reader?.cancelReading()
        let r = try AVAssetReader(asset: asset)
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: outputRate,
            AVNumberOfChannelsKey: channels,
        ]
        if channels > 2 {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
            settings[AVChannelLayoutKey] = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        }
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        o.alwaysCopiesSampleData = false
        guard r.canAdd(o) else { throw DecoderError.unsupported("Lydsporet kan ikke dekodes") }
        r.add(o)
        if seconds > 0 {
            r.timeRange = CMTimeRange(start: CMTime(seconds: seconds, preferredTimescale: 48000), duration: .positiveInfinity)
        }
        guard r.startReading() else { throw r.error ?? DecoderError.unsupported("Kunne ikke starte dekoding") }
        reader = r
        output = o
        pending.removeAll(keepingCapacity: true)
        pendingOffset = 0
    }

    func seek(to seconds: Double) {
        try? makeReader(from: max(0, seconds))
    }

    func read(into dst: UnsafeMutablePointer<Float>, maxFrames: Int) -> Int {
        let ch = channels
        while pendingOffset >= pending.count {
            guard let o = output, reader?.status == .reading, let sb = o.copyNextSampleBuffer() else { return 0 }
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let len = CMBlockBufferGetDataLength(bb)
            let count = len / MemoryLayout<Float>.size
            if count == 0 { continue }
            pending = [Float](repeating: 0, count: count)
            let st = pending.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: count * MemoryLayout<Float>.size, destination: raw.baseAddress!)
            }
            if st != kCMBlockBufferNoErr { pending.removeAll(); return 0 }
            pendingOffset = 0
        }
        let availableFrames = (pending.count - pendingOffset) / ch
        let n = min(maxFrames, availableFrames)
        pending.withUnsafeBufferPointer { src in
            (dst).update(from: src.baseAddress! + pendingOffset, count: n * ch)
        }
        pendingOffset += n * ch
        return n
    }
}

// MARK: - Strømmende kilde

/// Kobler en dekoder til mikseren via en ringbuffer. Dekoderen kjøres av `AudioFeeder` (egen tråd),
/// lydtråden leser bare fra ringbufferen. Håndterer start-/sluttpunkt og loop.
final class StreamingSource: PcmSource {
    let decoder: FrameDecoder
    let ring: SampleRing
    let sampleRate: Double
    let startTime: Double
    let loop: Bool
    let passLength: Int?

    private let lock = UnfairLock()
    private var rewindRequested = false
    private var decodedInPass = 0
    private var doneDecoding = false
    private let scratch: UnsafeMutablePointer<Float>
    static let chunk = 2048

    var channels: Int { decoder.channels }
    var isEnded: Bool { ring.isEnded }
    var passPosition: Int { ring.passPosition }

    init(decoder: FrameDecoder, sampleRate: Double, startTime: Double, endTime: Double, loop: Bool, bufferSeconds: Double = 2) {
        self.decoder = decoder
        self.sampleRate = sampleRate
        let total = decoder.duration
        self.startTime = total > 0 ? min(startTime, max(0, total - 0.01)) : startTime
        let end = endTime > 0 ? (total > 0 ? min(endTime, total) : endTime) : total
        passLength = end > self.startTime ? Int((end - self.startTime) * sampleRate) : nil
        self.loop = loop && passLength != nil
        ring = SampleRing(channels: decoder.channels, capacityFrames: Int(bufferSeconds * sampleRate))
        scratch = .allocate(capacity: StreamingSource.chunk * max(1, decoder.channels))
        if self.startTime > 0 { decoder.seek(to: self.startTime) }
    }

    deinit { scratch.deallocate() }

    func read(_ dst: UnsafeMutablePointer<Float>, frames: Int) -> Int { ring.read(dst, frames: frames) }

    /// Hopp tilbake til start (brukes når en video looper). Utføres av dekodertråden.
    func requestRewind() { lock.locked { rewindRequested = true } }

    /// Fyller ringbufferen. Kalles fra dekodertråden (og én gang fra hovedtråden før start). Returnerer false når ferdig.
    @discardableResult
    func fill(minimumFrames: Int = .max) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if rewindRequested {
            rewindRequested = false
            ring.reset()
            decoder.seek(to: startTime)
            decodedInPass = 0
            doneDecoding = false
        }
        if doneDecoding { return false }
        var produced = 0
        while ring.freeFrames >= StreamingSource.chunk && produced < minimumFrames {
            var want = StreamingSource.chunk
            if let pl = passLength { want = min(want, pl - decodedInPass) }
            if want <= 0 {
                if loop { decoder.seek(to: startTime); decodedInPass = 0; ring.markPassStart(); continue }
                doneDecoding = true; ring.setEnded(); return false
            }
            let n = decoder.read(into: scratch, maxFrames: want)
            if n == 0 {
                if loop && decodedInPass > 0 { decoder.seek(to: startTime); decodedInPass = 0; ring.markPassStart(); continue }
                doneDecoding = true; ring.setEnded(); return false
            }
            ring.write(scratch, frames: n)
            decodedInPass += n
            produced += n
        }
        return true
    }
}

/// Én bakgrunnstråd som holder alle ringbuffere fulle.
final class AudioFeeder {
    static let shared = AudioFeeder()
    private let lock = UnfairLock()
    private var sources: [StreamingSource] = []
    private let queue = DispatchQueue(label: "showcue.audio.feeder", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    private init() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func add(_ s: StreamingSource) { lock.locked { sources.append(s) } }
    func remove(_ s: StreamingSource) { lock.locked { sources.removeAll { $0 === s } } }

    private func tick() {
        let list = lock.locked { sources }
        for s in list { s.fill() }
    }
}
