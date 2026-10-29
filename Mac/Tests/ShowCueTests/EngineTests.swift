import XCTest
@testable import ShowCue

// MARK: - OSC

final class OscTests: XCTestCase {
    private func hex(_ d: Data) -> String { d.map { String(format: "%02X", $0) }.joined() }
    private func asciiHex(_ s: String) -> String { hex(Data(s.utf8)) }

    func testEncodeMatchesSpec() {
        // Samme testvektorer som Windows-versjonen.
        XCTAssertEqual(hex(Osc.encode("/ch/01/mix/fader", Osc.parseArguments("0.75"))),
                       asciiHex("/ch/01/mix/fader") + "00000000" + "2C660000" + "3F400000")
        XCTAssertEqual(hex(Osc.encode("/go", [.int(7), .string("ab")])), "2F676F00" + "2C697300" + "00000007" + "61620000")
        XCTAssertEqual(Osc.encode("/x", []).count, 8)
    }

    func testParseArguments() {
        XCTAssertEqual(Osc.parseArguments("1 0,5 hei \"to ord\" true"),
                       [.int(1), .float(0.5), .string("hei"), .string("to ord"), .bool(true)])
    }

    func testDecodeRoundTripAndBundle() {
        let enc = Osc.encode("/cue/12/start", [.int(1), .float(0.5), .string("hei"), .bool(true)])
        XCTAssertEqual(Osc.decode(enc), [OscMessage(address: "/cue/12/start", args: [.int(1), .float(0.5), .string("hei"), .bool(true)])])

        var b = Data("#bundle\0".utf8)
        b.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 1])
        for m in [Osc.encode("/go", []), Osc.encode("/cue/3/stop", [])] {
            let n = UInt32(m.count)
            b.append(contentsOf: [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
            b.append(m)
        }
        XCTAssertEqual(Osc.decode(b).map(\.address), ["/go", "/cue/3/stop"])
    }

    func testDecodeRobustness() {
        XCTAssertEqual(Osc.decode(Data([0x2F, 0x67, 0x6F, 0x00])).first?.args.count, 0, "uten typetagger")
        XCTAssertTrue(Osc.decode(Data([1, 2, 3])).isEmpty)
        let t = Osc.encode("/x", [.int(5)])
        XCTAssertEqual(Osc.decode(t.prefix(t.count - 2)).count, 1, "avkuttet pakke krasjer ikke")
    }

    func testUdpRoundTrip() throws {
        let server = OscServer()
        server.queue = DispatchQueue(label: "test")
        let got = expectation(description: "melding")
        server.onMessage = { m, from in
            if m.address == "/test" { XCTAssertEqual(from, "127.0.0.1"); got.fulfill() }
        }
        try server.start(port: 39124)
        XCTAssertTrue(OscSender.shared.send(host: "127.0.0.1", port: 39124, address: "/test", args: [.int(1)]))
        wait(for: [got], timeout: 2)
        server.stop()
    }
}

// MARK: - Status til Companion

final class FeedbackTests: XCTestCase {
    let status = ShowStatus(showName: "Konsert", nextNumber: "3", nextName: "Walk-in", nextNotes: "Vent på lys",
                            playheadPosition: 3, cueCount: 10, playing: [
                                PlayingCue(number: "1", name: "Intro", elapsed: 12.3, remaining: 47.6, hasDuration: true, preWaiting: false),
                                PlayingCue(number: "2", name: "Jingle", elapsed: 2, remaining: 4.2, hasDuration: true, preWaiting: false),
                                PlayingCue(number: "5", name: "Loop", elapsed: 30, remaining: 0, hasDuration: false, preWaiting: false),
                                PlayingCue(number: "7", name: "Venter", elapsed: 0, remaining: 0, hasDuration: false, preWaiting: true),
                            ])

    func testCompanionValues() {
        var sent: [(String, OscArg)] = []
        let fb = OscFeedback { a, args in sent.append((a, args[0])) }
        fb.update(status, now: 0)
        func v(_ k: String) -> String? { sent.last { $0.0 == "/custom-variable/sc_\(k)/value" }?.1.text }
        XCTAssertEqual(v("next_name"), "Walk-in")
        XCTAssertEqual(v("playhead"), "3/10")
        XCTAssertEqual(v("playing"), "Loop")
        XCTAssertEqual(v("playing_count"), "3")
        XCTAssertEqual(v("playing_all"), "Intro · Jingle · Loop")
        XCTAssertEqual(v("running"), "1,2,5")
        XCTAssertEqual(v("remaining"), "-0:05")
        XCTAssertEqual(v("remaining_name"), "Jingle")
        XCTAssertEqual(v("state"), "spiller")
        XCTAssertTrue(sent.allSatisfy { $0.1.isString }, "Companion får alltid tekst")

        let n = sent.count
        sent.removeAll()
        fb.update(status, now: 0.1)
        XCTAssertTrue(sent.isEmpty, "uendret status sendes ikke")
        var changed = status; changed.nextName = "Pause"
        fb.update(changed, now: 0.2)
        XCTAssertEqual(sent.map(\.0), ["/custom-variable/sc_next_name/value"])
        sent.removeAll(); fb.update(status, now: 6)
        XCTAssertEqual(sent.count, n, "full oppfriskning etter 5 s")
        sent.removeAll(); fb.requestRefresh(); fb.update(status, now: 6.1)
        XCTAssertEqual(sent.count, n)
    }

    func testGenericAndRunning() {
        var sent: [(String, OscArg)] = []
        let fb = OscFeedback { a, args in sent.append((a, args[0])) }
        fb.format = .generic
        fb.update(status, now: 0)
        XCTAssertTrue(sent.contains { $0.0 == "/showcue/next/name" && $0.1 == .string("Walk-in") })
        XCTAssertTrue(sent.contains { $0.0 == "/showcue/playing/count" && $0.1 == .int(3) })
        XCTAssertEqual(sent.filter { $0.0.hasSuffix("/running") && $0.1 == .int(1) }.count, 3)
        XCTAssertFalse(sent.contains { $0.0 == "/showcue/cue/7/running" })
        sent.removeAll()
        var s = status; s.playing.removeAll { $0.number == "2" }
        fb.update(s, now: 0.5)
        XCTAssertTrue(sent.contains { $0.0 == "/showcue/cue/2/running" && $0.1 == .int(0) })
        XCTAssertFalse(sent.contains { $0.0 == "/showcue/cue/1/running" })
    }

    func testIdleAndClock() {
        let v = Dictionary(uniqueKeysWithValues: OscFeedback.values(ShowStatus(showName: "S", nextNumber: "", nextName: "", nextNotes: "",
                                                                                 playheadPosition: 0, cueCount: 4, playing: [])).map { ($0.0, $0.1.description) })
        XCTAssertEqual(v["playhead"], "slutt/4")
        XCTAssertEqual(v["state"], "klar")
        XCTAssertEqual(v["remaining"], "")
        XCTAssertEqual(OscFeedback.clock(3725), "1:02:05")
        XCTAssertEqual(OscFeedback.clock(59.9), "0:59")
    }
}

// MARK: - Fjernstyring

final class FakeShow: ShowControl {
    var log: [String] = []
    var remote: [String] = []
    func go() { log.append("go") }
    func stopAll() { log.append("stopall") }
    func panic() { log.append("panic") }
    func hardStop() { log.append("hardstop") }
    func movePlayhead(_ d: Int) { log.append("move \(d)") }
    func selectCue(_ n: String) -> Bool { log.append("select \(n)"); return true }
    func startCue(_ n: String) -> Bool { log.append("start \(n)"); return true }
    func stopCue(_ n: String) -> Bool { log.append("stop \(n)"); return true }
    func goCue(_ n: String) -> Bool { log.append("gocue \(n)"); return true }
    func fireHotkey(_ k: String) -> Bool { log.append("hotkey \(k)"); return true }
    func fireMidiTrigger(_ t: String) -> Int { log.append("midi \(t)"); return 1 }
    func remoteLog(_ text: String) { remote.append(text) }
    func refreshFeedback() { log.append("refresh") }
}

final class RemoteTests: XCTestCase {
    func testOscCommands() {
        let fake = FakeShow()
        var s = AppSettings(); s.midiGo = "N:60"; s.midiStopAll = "CC:20"
        let r = RemoteRouter(settings: s)
        r.show = fake
        func osc(_ a: String, _ args: OscArg...) { r.handleOsc(OscMessage(address: a, args: args), from: "test") }
        osc("/go"); osc("/go", .float(1)); osc("/go", .float(0)); osc("/go", .int(0))
        XCTAssertEqual(fake.log, ["go", "go"], "/go 0 (knapp sluppet) ignoreres")
        fake.log.removeAll()
        osc("/cue/12/start"); osc("/cue/1.5/stop"); osc("/cue/7/go"); osc("/cue/start", .string("9")); osc("/cue/start", .int(4))
        osc("/playhead/3"); osc("/select/next"); osc("/previous"); osc("/hotkey/f1"); osc("/stop"); osc("/panic"); osc("/hardstop")
        osc("/showcue/go"); osc("/go", .string("22")); osc("/go/23"); osc("/refresh")
        XCTAssertEqual(fake.log, ["start 12", "stop 1.5", "gocue 7", "start 9", "start 4", "select 3", "move 1", "move -1", "hotkey F1",
                                  "stopall", "panic", "hardstop", "go", "gocue 22", "gocue 23", "refresh"])
        osc("/tull")
        XCTAssertTrue(fake.remote.last?.contains("ukjent") ?? false)
    }

    func testMidiAndLearnAndMsc() {
        let fake = FakeShow()
        var s = AppSettings(); s.midiGo = "N:60"; s.midiStopAll = "CC:20"; s.mscInDeviceId = 127
        let r = RemoteRouter(settings: s)
        r.show = fake
        r.handleMidiTrigger("N:60", channel: 1); r.handleMidiTrigger("CC:20", channel: 1); r.handleMidiTrigger("N:61", channel: 1)
        XCTAssertEqual(fake.log, ["go", "panic", "midi N:61"])
        var learned: String?
        r.beginLearn { learned = $0 }
        fake.log.removeAll()
        r.handleMidiTrigger("N:60", channel: 1)
        XCTAssertEqual(learned, "N:60")
        XCTAssertTrue(fake.log.isEmpty, "Lær utfører ikke meldingen")
        XCTAssertFalse(r.isLearning)

        r.handleMsc(MscCommand(deviceId: 127, commandFormat: 1, command: MscCommand.go, cueNumber: "5"))
        r.handleMsc(MscCommand(deviceId: 127, commandFormat: 1, command: MscCommand.go, cueNumber: ""))
        r.settings.mscInDeviceId = 3
        r.handleMsc(MscCommand(deviceId: 4, commandFormat: 1, command: MscCommand.go, cueNumber: "6"))
        XCTAssertEqual(fake.log, ["gocue 5", "go"])
    }
}

// MARK: - MIDI

final class MidiTests: XCTestCase {
    func testParserRunningStatusAndSysex() {
        let p = MidiByteParser()
        // Note on ch1 60/100, running status note 62/0 (= note off), CC ch2, sysex delt over to pakker
        var ev = p.feed([0x90, 60, 100, 62, 0, 0xB1, 20, 127, 0xF8, 0xF0, 0x7F, 0x7F])
        ev += p.feed([0x02, 0x01, 0x01, 0x31, 0x32, 0xF7, 0xC0, 5])
        XCTAssertEqual(ev[0], .noteOn(channel: 1, note: 60, velocity: 100))
        XCTAssertEqual(ev[1], .noteOff(channel: 1, note: 62))
        XCTAssertEqual(ev[2], .controlChange(channel: 2, controller: 20, value: 127))
        XCTAssertEqual(ev[3], .sysex([0xF0, 0x7F, 0x7F, 0x02, 0x01, 0x01, 0x31, 0x32, 0xF7]))
        XCTAssertEqual(ev[4], .programChange(channel: 1, program: 5))
    }

    func testTriggerDetectorRisingEdgeAndChannel() {
        let d = MidiTriggerDetector()
        XCTAssertEqual(d.trigger(for: .noteOn(channel: 3, note: 36, velocity: 90))?.0, "N:36")
        XCTAssertNil(d.trigger(for: .noteOn(channel: 3, note: 36, velocity: 0)))
        XCTAssertEqual(d.trigger(for: .controlChange(channel: 1, controller: 20, value: 127))?.0, "CC:20")
        XCTAssertNil(d.trigger(for: .controlChange(channel: 1, controller: 20, value: 100)), "fortsatt trykket")
        XCTAssertNil(d.trigger(for: .controlChange(channel: 1, controller: 20, value: 0)))
        XCTAssertEqual(d.trigger(for: .controlChange(channel: 1, controller: 20, value: 64))?.0, "CC:20")
        d.channel = 2
        XCTAssertNil(d.trigger(for: .programChange(channel: 1, program: 4)))
        XCTAssertEqual(d.trigger(for: .programChange(channel: 2, program: 4))?.0, "PC:4")
    }

    func testMsc() {
        let go = MscCommand.buildGo(deviceId: 127, commandFormat: 1, cue: "12.5")
        XCTAssertEqual(MscCommand.parse(go), MscCommand(deviceId: 127, commandFormat: 1, command: 1, cueNumber: "12.5"))
        XCTAssertEqual(MscCommand.parse([0xF0, 0x7F, 1, 2, 1, 2, 0x33, 0, 0x31, 0xF7])?.cueNumber, "3")
        XCTAssertNil(MscCommand.parse([0xF0, 0x7E, 1, 2]))
        let c = Cue(type: .midi); c.messageType = .controlChange; c.channel = 2; c.data1 = 7; c.data2 = 100
        XCTAssertEqual(MidiOut.bytes(for: c), [0xB1, 7, 100])
        XCTAssertEqual(MidiTriggers.describe("CC:20"), "CC 20")
    }
}

// MARK: - Mikser og avspilling

/// Kilde med konstant verdi per kanal (0.1 × (kanal+1)), som testene i Windows-versjonen.
final class ConstSource: PcmSource {
    let channels: Int
    let total: Int?
    let loop: Bool
    private(set) var position = 0
    private(set) var passStart = 0
    init(channels: Int, frames: Int?, loop: Bool = false) { self.channels = channels; total = frames; self.loop = loop }
    func read(_ dst: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        var n = frames
        if let t = total, !loop { n = min(frames, t - position) }
        for f in 0..<max(0, n) {
            for c in 0..<channels { dst[f * channels + c] = 0.1 * Float(c + 1) }
            position += 1
            if loop, let t = total, position - passStart >= t { passStart = position }
        }
        return max(0, n)
    }
    var isEnded: Bool { !loop && total != nil && position >= total! }
    var passPosition: Int { position - passStart }
    var passLength: Int? { total }
}

final class MixerTests: XCTestCase {
    let rate = 48000.0

    private func at(_ o: [Float], _ D: Int, _ f: Int, _ ch1: Int) -> Float { o[f * D + ch1 - 1] }

    func testRoutingPatchAndFades() {
        let m = PatchMixer(sampleRate: rate, deviceChannels: 8, patch: PatchBus.defaultPatch(8))
        // Stereo standard → 1/2
        let v1 = Voice(source: ConstSource(channels: 2, frames: nil), sampleRate: rate, volumeDb: 0, fadeIn: 0, fadeOut: 0, loop: false,
                       routes: AudioRoute.defaults(fileChannels: 2))
        m.add(v1)
        var o = m.renderInterleaved(frames: 512)
        XCTAssertEqual(at(o, 8, 100, 1), 0.1, accuracy: 1e-4)
        XCTAssertEqual(at(o, 8, 100, 2), 0.2, accuracy: 1e-4)
        XCTAssertEqual(at(o, 8, 100, 3), 0, accuracy: 1e-6)
        v1.stop(fade: 0); _ = m.renderInterleaved(frames: 64)

        // Mono → 1+2
        let v2 = Voice(source: ConstSource(channels: 1, frames: nil), sampleRate: rate, volumeDb: 0, fadeIn: 0, fadeOut: 0, loop: false,
                       routes: AudioRoute.defaults(fileChannels: 1))
        m.add(v2)
        o = m.renderInterleaved(frames: 256)
        XCTAssertEqual(at(o, 8, 10, 1), 0.1, accuracy: 1e-4)
        XCTAssertEqual(at(o, 8, 10, 2), 0.1, accuracy: 1e-4)
        v2.stop(fade: 0); _ = m.renderInterleaved(frames: 64)

        // 4 kanaler: kanal 3 → buss 5 (−6 dB), kanal 4 → buss 8; så live endring og patch +6 dB til 7+8
        let v3 = Voice(source: ConstSource(channels: 4, frames: nil), sampleRate: rate, volumeDb: 0, fadeIn: 0, fadeOut: 0, loop: false,
                       routes: [AudioRoute(3, 5, -6.0206), AudioRoute(4, 8)])
        m.add(v3)
        o = m.renderInterleaved(frames: 256)
        XCTAssertEqual(at(o, 8, 50, 5), 0.15, accuracy: 1e-3)
        XCTAssertEqual(at(o, 8, 50, 8), 0.4, accuracy: 1e-3)
        v3.setRouting([AudioRoute(1, 3)])
        var p = PatchBus.defaultPatch(8); p[2].channels = [7, 8]; p[2].gainDb = 6.0206
        m.setPatch(p)
        o = m.renderInterleaved(frames: 256)
        XCTAssertEqual(at(o, 8, 50, 7), 0.2, accuracy: 1e-3)
        XCTAssertEqual(at(o, 8, 50, 8), 0.2, accuracy: 1e-3)
        XCTAssertEqual(at(o, 8, 50, 3), 0, accuracy: 1e-6)
        XCTAssertEqual(m.busLevel(2), 0.2, accuracy: 0.01)
        XCTAssertEqual(m.channelLevel(6), 0.2, accuracy: 0.01)
        m.setPatch(PatchBus.defaultPatch(8))
        v3.stop(fade: 0); _ = m.renderInterleaved(frames: 64)

        // Fade ut over 0,1 s og stopp
        let v4 = Voice(source: ConstSource(channels: 2, frames: nil), sampleRate: rate, volumeDb: 0, fadeIn: 0, fadeOut: 0, loop: false,
                       routes: AudioRoute.defaults(fileChannels: 2))
        m.add(v4)
        _ = m.renderInterleaved(frames: 480)
        v4.stop(fade: 0.1)
        o = m.renderInterleaved(frames: 2400)
        let mid = at(o, 8, 2399, 1)
        XCTAssertTrue(mid > 0 && mid < 0.1)
        o = m.renderInterleaved(frames: 4800)
        XCTAssertTrue(v4.isFinished)
        XCTAssertEqual(at(o, 8, 4000, 1), 0, accuracy: 1e-6)

        // Fade til −20 dB uten stopp
        let v5 = Voice(source: ConstSource(channels: 2, frames: nil), sampleRate: rate, volumeDb: 0, fadeIn: 0, fadeOut: 0, loop: false,
                       routes: AudioRoute.defaults(fileChannels: 2))
        m.add(v5)
        v5.fadeTo(-20, seconds: 0.05, stopWhenDone: false)
        o = m.renderInterleaved(frames: 4800)
        XCTAssertEqual(at(o, 8, 4700, 1), 0.01, accuracy: 5e-4)
        XCTAssertFalse(v5.isFinished)
        v5.stop(fade: 0); _ = m.renderInterleaved(frames: 64)

        // Fade inn
        let v6 = Voice(source: ConstSource(channels: 2, frames: nil), sampleRate: rate, volumeDb: 0, fadeIn: 0.1, fadeOut: 0, loop: false,
                       routes: AudioRoute.defaults(fileChannels: 2))
        m.add(v6)
        o = m.renderInterleaved(frames: 4800)
        XCTAssertLessThan(at(o, 8, 10, 1), 0.001)
        XCTAssertEqual(at(o, 8, 4799, 1), 0.1, accuracy: 0.002)
        v6.stop(fade: 0); _ = m.renderInterleaved(frames: 64)

        // Alt av
        let v7 = Voice(source: ConstSource(channels: 2, frames: nil), sampleRate: rate, volumeDb: 0, fadeIn: 0, fadeOut: 0, loop: false, routes: [])
        m.add(v7)
        o = m.renderInterleaved(frames: 256)
        XCTAssertTrue(o.allSatisfy { $0 == 0 })
        v7.stop(fade: 0); _ = m.renderInterleaved(frames: 64)
    }

    func testEndOfSourceAndAutoFadeOut() {
        let m = PatchMixer(sampleRate: rate, deviceChannels: 2, patch: PatchBus.defaultPatch(2))
        let v = Voice(source: ConstSource(channels: 2, frames: 4800), sampleRate: rate, volumeDb: 0, fadeIn: 0, fadeOut: 0.05, loop: false,
                      routes: AudioRoute.defaults(fileChannels: 2))
        m.add(v)
        let o = m.renderInterleaved(frames: 4800)
        XCTAssertEqual(o[1000 * 2], 0.1, accuracy: 1e-4, "før automatisk fade ut")
        XCTAssertLessThan(o[4790 * 2], 0.01, "fader ut mot slutten")
        _ = m.renderInterleaved(frames: 256)
        XCTAssertTrue(v.isFinished)
        XCTAssertFalse(m.contains(v), "fjernet fra mikseren")
    }

    func testTestToneLevel() {
        let m = PatchMixer(sampleRate: rate, deviceChannels: 8, patch: PatchBus.defaultPatch(8))
        let t = TestToneSource(busIndex: 3)
        m.add(t)
        let o = m.renderInterleaved(frames: 96000)
        var sum = 0.0
        for f in 4800..<96000 { let v = Double(o[f * 8 + 3]); sum += v * v }
        let db = 10 * log10(sum / Double(96000 - 4800))
        XCTAssertEqual(db, -18, accuracy: 2)
        XCTAssertTrue((0..<96000).allSatisfy { f in (0..<8).allSatisfy { c in c == 3 || o[f * 8 + c] == 0 } })
    }

    func testRingBufferLoopMarkers() {
        let ring = SampleRing(channels: 1, capacityFrames: 100)
        var data = [Float](repeating: 1, count: 30)
        XCTAssertEqual(ring.write(&data, frames: 30), 30)
        ring.markPassStart()
        XCTAssertEqual(ring.write(&data, frames: 30), 30)
        var out = [Float](repeating: 0, count: 50)
        XCTAssertEqual(ring.read(&out, frames: 20), 20)
        XCTAssertEqual(ring.passPosition, 20)
        XCTAssertEqual(ring.read(&out, frames: 20), 20)
        XCTAssertEqual(ring.passPosition, 10, "ny runde startet etter 30 rammer")
        ring.reset()
        XCTAssertEqual(ring.availableFrames, 0)
        XCTAssertEqual(ring.passPosition, 0)
        XCTAssertFalse(ring.isEnded)
        ring.setEnded()
        XCTAssertTrue(ring.isEnded)
        // Omløp i bufferet
        let r2 = SampleRing(channels: 2, capacityFrames: 64)
        var a = (0..<200).map { Float($0) }
        var b = [Float](repeating: 0, count: 200)
        for _ in 0..<5 { XCTAssertEqual(r2.write(&a, frames: 50), 50); XCTAssertEqual(r2.read(&b, frames: 50), 50); XCTAssertEqual(Array(b[0..<100]), Array(a[0..<100])) }
    }
}
