import XCTest
import AVFoundation
@testable import ShowCue

/// Start/slutt-redigering: bølgeform, forhåndslytting og video-start/slutt.
final class TrimTests: XCTestCase {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("showcue-trim", isDirectory: true)

    private func writeMono(_ name: String, rate: Double, frames: Int, _ value: (Int) -> Float) throws -> String {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { buf.floatChannelData![0][i] = value(i) }
        try file.write(from: buf)
        return url.path
    }

    func testWaveformMinMax() throws {
        let path = try writeMono("wave.wav", rate: 48000, frames: 96000) { $0 < 48000 ? 0.5 : -0.25 }
        let dec = try AudioFileDecoder(url: URL(fileURLWithPath: path), outputRate: 48000)
        let w = WaveformData.compute(decoder: dec, sampleRate: 48000, buckets: 100)
        XCTAssertEqual(w.buckets, 100)
        XCTAssertEqual(w.duration, 2.0, accuracy: 0.001)
        XCTAssertEqual(w.max[10], 0.5, accuracy: 1e-4)
        XCTAssertEqual(w.min[10], 0, accuracy: 1e-4)
        XCTAssertEqual(w.min[70], -0.25, accuracy: 1e-4)
        XCTAssertEqual(w.max[70], 0, accuracy: 1e-4)

        let cached = WaveformCache.load(path: path, isVideo: false)
        XCTAssertNotNil(cached)
        XCTAssertEqual(cached?.duration ?? 0, 2.0, accuracy: 0.01)
    }

    func testPreviewThroughPatch() throws {
        let rate = 48000.0
        let path = try writeMono("ramp.wav", rate: rate, frames: 48000 * 3) { Float($0) / 48000 / 10 } // verdi = tid/10
        let m = PatchMixer(sampleRate: rate, deviceChannels: 8, patch: PatchBus.defaultPatch(8))
        let prev = AudioPreview(mixer: { m })
        let cue = Cue(type: .audio)
        cue.filePath = path
        cue.startTime = 0.5
        cue.endTime = 2.0

        XCTAssertTrue(prev.play(cue, from: 1.5, to: cue.endTime))
        prev.stream?.fill()
        var o = m.renderInterleaved(frames: 1000)
        let expect = (1.5 + 900 / rate) / 10
        XCTAssertEqual(Double(o[900 * 8]), expect, accuracy: 0.002, "kanal 1 fra 1,5 s")
        XCTAssertEqual(Double(o[900 * 8 + 1]), expect, accuracy: 0.002, "mono → kanal 2 også")
        XCTAssertEqual(prev.position ?? 0, 1.5 + 1000 / rate, accuracy: 0.002)

        prev.stream?.fill()
        _ = m.renderInterleaved(frames: 48000)
        XCTAssertFalse(prev.isActive, "stopper ved sluttpunktet")
        XCTAssertNil(prev.position)

        // Fra etter sluttpunktet: spiller til filslutt
        XCTAssertTrue(prev.play(cue, from: 2.5, to: cue.endTime))
        prev.stream?.fill()
        o = m.renderInterleaved(frames: 1000)
        XCTAssertEqual(Double(o[500 * 8]), (2.5 + 500 / rate) / 10, accuracy: 0.002)
        XCTAssertTrue(prev.isActive)

        prev.stop()
        _ = m.renderInterleaved(frames: 2000)
        o = m.renderInterleaved(frames: 100)
        XCTAssertEqual(o[50 * 8], 0, accuracy: 1e-6, "stopp gir stillhet")
    }

    func testVideoStartEndModel() throws {
        let v = Cue(type: .video)
        v.startTime = 10; v.endTime = 30; v.knownDuration = 60
        XCTAssertEqual(v.videoEnd, 30)
        XCTAssertEqual(v.duration, 20, "lengde = slutt − start")
        v.endTime = 0
        XCTAssertEqual(v.duration, 50, "slutt 0 = filslutt")
        v.endTime = 90
        XCTAssertEqual(v.videoEnd, 60, "slutt etter filslutt kappes")
        v.loop = true
        XCTAssertEqual(v.duration, 0)

        // Lagres med samme feltnavn som Windows
        v.loop = false; v.endTime = 30
        var doc = ShowDocument()
        doc.cues = [v]
        let obj = try JSONSerialization.jsonObject(with: try doc.jsonData()) as! [String: Any]
        let c = (obj["Cues"] as! [[String: Any]])[0]
        XCTAssertEqual(c["StartTime"] as? Double, 10)
        XCTAssertEqual(c["EndTime"] as? Double, 30)
        let back = try JSONDecoder().decode(ShowDocument.self, from: try doc.jsonData())
        XCTAssertEqual(back.cues[0].startTime, 10)
        XCTAssertEqual(back.cues[0].endTime, 30)
    }
}
