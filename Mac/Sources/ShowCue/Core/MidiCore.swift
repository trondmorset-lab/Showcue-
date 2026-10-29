import Foundation

/// MIDI-triggere lagres som tekst: "N:60" (note), "CC:20", "PC:5".
enum MidiTriggers {
    static func describe(_ trigger: String) -> String {
        guard !trigger.isEmpty else { return "" }
        let p = trigger.split(separator: ":", maxSplits: 1).map(String.init)
        guard p.count == 2 else { return trigger }
        switch p[0] {
        case "N": return "Note \(p[1])"
        case "CC": return "CC \(p[1])"
        case "PC": return "Prog \(p[1])"
        default: return trigger
        }
    }
}

/// Én MIDI-melding fra en inngang.
enum MidiEvent: Equatable {
    case noteOn(channel: Int, note: Int, velocity: Int)
    case noteOff(channel: Int, note: Int)
    case controlChange(channel: Int, controller: Int, value: Int)
    case programChange(channel: Int, program: Int)
    case sysex([UInt8])
    case other
}

/// Gjør en rå bytestrøm om til meldinger (håndterer running status og sysex over flere pakker).
final class MidiByteParser {
    private var status: UInt8 = 0
    private var data: [UInt8] = []
    private var sysex: [UInt8]? = nil

    func feed(_ bytes: [UInt8]) -> [MidiEvent] {
        var out: [MidiEvent] = []
        for b in bytes {
            if b >= 0xF8 { continue } // sanntidsmeldinger (klokke o.l.) ignoreres og avbryter ikke noe
            if b == 0xF0 { sysex = [0xF0]; continue }
            if b == 0xF7 {
                if var s = sysex { s.append(0xF7); out.append(.sysex(s)) }
                sysex = nil
                continue
            }
            if sysex != nil {
                if b < 0x80 { sysex!.append(b); continue }
                sysex = nil // statusbyte avbryter sysex
            }
            if b >= 0x80 {
                status = b >= 0xF0 ? 0 : b
                data.removeAll(keepingCapacity: true)
                continue
            }
            guard status != 0 else { continue }
            data.append(b)
            let kind = status & 0xF0
            let ch = Int(status & 0x0F) + 1
            let needed = (kind == 0xC0 || kind == 0xD0) ? 1 : 2
            guard data.count >= needed else { continue }
            switch kind {
            case 0x90:
                out.append(data[1] == 0 ? .noteOff(channel: ch, note: Int(data[0])) : .noteOn(channel: ch, note: Int(data[0]), velocity: Int(data[1])))
            case 0x80: out.append(.noteOff(channel: ch, note: Int(data[0])))
            case 0xB0: out.append(.controlChange(channel: ch, controller: Int(data[0]), value: Int(data[1])))
            case 0xC0: out.append(.programChange(channel: ch, program: Int(data[0])))
            default: out.append(.other)
            }
            data.removeAll(keepingCapacity: true) // running status: neste melding kan komme uten statusbyte
        }
        return out
    }
}

/// Gjør meldinger om til triggere, med kanalfilter. CC trigger bare når verdien går fra under 64 til 64 eller mer.
final class MidiTriggerDetector {
    var channel = 0 // 0 = alle
    private var lastCc = [Int](repeating: 0, count: 16 * 128)

    func trigger(for e: MidiEvent) -> (String, Int)? {
        switch e {
        case .noteOn(let ch, let note, let vel) where vel > 0:
            return accept(ch) ? ("N:\(note)", ch) : nil
        case .controlChange(let ch, let cc, let value):
            guard accept(ch) else { return nil }
            let key = (ch - 1) * 128 + (cc & 127)
            let last = lastCc[key]
            lastCc[key] = value
            return value >= 64 && last < 64 ? ("CC:\(cc)", ch) : nil
        case .programChange(let ch, let p):
            return accept(ch) ? ("PC:\(p)", ch) : nil
        default:
            return nil
        }
    }

    private func accept(_ ch: Int) -> Bool { channel == 0 || channel == ch }
}

/// MIDI Show Control: F0 7F <dev> 02 <format> <kommando> [cue 00 liste 00 sti] F7
struct MscCommand: Equatable {
    static let go = 0x01, stop = 0x02, resume = 0x03, allOff = 0x08, reset = 0x0A

    var deviceId: Int
    var commandFormat: Int
    var command: Int
    var cueNumber: String

    static func parse(_ b: [UInt8]) -> MscCommand? {
        let i = (b.first == 0xF0) ? 1 : 0
        guard b.count >= i + 5, b[i] == 0x7F, b[i + 2] == 0x02 else { return nil }
        var cue = ""
        var p = i + 5
        while p < b.count && b[p] != 0x00 && b[p] != 0xF7 { cue.append(Character(UnicodeScalar(b[p]))); p += 1 }
        return MscCommand(deviceId: Int(b[i + 1]), commandFormat: Int(b[i + 3]), command: Int(b[i + 4]), cueNumber: cue)
    }

    static func buildGo(deviceId: Int, commandFormat: Int, cue: String) -> [UInt8] {
        var bytes: [UInt8] = [0xF0, 0x7F, UInt8(clamping: deviceId), 0x02, UInt8(clamping: commandFormat), 0x01]
        bytes.append(contentsOf: cue.unicodeScalars.filter { $0.isASCII }.map { UInt8($0.value) })
        bytes.append(0xF7)
        return bytes
    }
}

enum MidiOut {
    /// Bytene en MIDI-cue sender.
    static func bytes(for c: Cue) -> [UInt8] {
        let ch = UInt8(clamping: max(1, min(16, c.channel)) - 1)
        let d1 = UInt8(clamping: max(0, min(127, c.data1)))
        let d2 = UInt8(clamping: max(0, min(127, c.data2)))
        switch c.messageType {
        case .noteOn: return [0x90 | ch, d1, d2]
        case .noteOff: return [0x80 | ch, d1, 0]
        case .programChange: return [0xC0 | ch, d1]
        case .controlChange: return [0xB0 | ch, d1, d2]
        case .mscGo: return MscCommand.buildGo(deviceId: c.mscDeviceId, commandFormat: c.mscCommandFormat, cue: c.mscCueNumber)
        }
    }
}
