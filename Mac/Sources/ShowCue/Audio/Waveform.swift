import Foundation

/// Bølgeform for en lydfil eller lydsporet i en video: min/maks per bit, samlet over alle kanaler.
struct WaveformData {
    let min: [Float]
    let max: [Float]
    /// Lengde i sekunder.
    let duration: Double
    let channels: Int
    var buckets: Int { min.count }

    static let defaultBuckets = 6000
    /// Bølgeformen leses i lav samplingsfrekvens – det holder for tegning og går fort.
    static let analysisRate = 22050.0

    /// Leser hele dekoderen og regner ut min/maks per bit.
    static func compute(decoder: FrameDecoder, sampleRate: Double, buckets wanted: Int = defaultBuckets) -> WaveformData {
        let ch = Swift.max(1, decoder.channels)
        let totalFrames = Swift.max(1, Int(decoder.duration * sampleRate))
        let buckets = Swift.max(1, Swift.min(wanted, totalFrames))
        let framesPerBucket = Swift.max(1.0, Double(totalFrames) / Double(buckets))
        var mn = [Float](repeating: 0, count: buckets)
        var mx = [Float](repeating: 0, count: buckets)
        let chunk = 8192
        let buf = UnsafeMutablePointer<Float>.allocate(capacity: chunk * ch)
        defer { buf.deallocate() }
        var frame = 0
        while true {
            let n = decoder.read(into: buf, maxFrames: chunk)
            if n <= 0 { break }
            for f in 0..<n {
                let b = Swift.min(buckets - 1, Int(Double(frame + f) / framesPerBucket))
                let i = f * ch
                for c in 0..<ch {
                    let v = buf[i + c]
                    if v < mn[b] { mn[b] = v }
                    if v > mx[b] { mx[b] = v }
                }
            }
            frame += n
        }
        return WaveformData(min: mn, max: mx, duration: Double(frame) / sampleRate, channels: ch)
    }
}

/// Regner ut bølgeformer i bakgrunnen og husker dem (per fil og endringstid).
final class WaveformCache {
    static let shared = WaveformCache()
    private let lock = UnfairLock()
    private var done: [String: WaveformData?] = [:]
    private var waiting: [String: [(WaveformData?) -> Void]] = [:]
    private let queue = DispatchQueue(label: "ShowCue.Waveform", qos: .userInitiated, attributes: .concurrent)

    /// Svarer på hovedtråden.
    func get(path: String, isVideo: Bool, _ completion: @escaping (WaveformData?) -> Void) {
        guard !path.isEmpty, let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = path + "|" + String(mtime)
        let start: Bool = lock.locked {
            if let d = done[key] { DispatchQueue.main.async { completion(d) }; return false }
            if waiting[key] != nil { waiting[key]!.append(completion); return false }
            waiting[key] = [completion]
            return true
        }
        guard start else { return }
        queue.async {
            let data = WaveformCache.load(path: path, isVideo: isVideo)
            let callbacks: [(WaveformData?) -> Void] = self.lock.locked {
                self.done[key] = data
                return self.waiting.removeValue(forKey: key) ?? []
            }
            DispatchQueue.main.async { callbacks.forEach { $0(data) } }
        }
    }

    /// Synkron variant (brukes av testene).
    static func load(path: String, isVideo: Bool) -> WaveformData? {
        let url = URL(fileURLWithPath: path)
        let rate = WaveformData.analysisRate
        let decoder: FrameDecoder
        if isVideo {
            guard let d = try? AssetDecoder(url: url, outputRate: rate) else { return nil }
            decoder = d
        } else if let d = try? AudioFileDecoder(url: url, outputRate: rate) {
            decoder = d
        } else if let d = try? AssetDecoder(url: url, outputRate: rate) {
            decoder = d
        } else {
            return nil
        }
        return WaveformData.compute(decoder: decoder, sampleRate: rate)
    }
}
