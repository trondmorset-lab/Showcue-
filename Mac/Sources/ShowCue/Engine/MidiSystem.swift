import Foundation
import CoreMIDI

/// CoreMIDI: utganger for MIDI-cuer og én inngang for fjernstyring (triggere og MSC).
final class MidiSystem {
    private var client = MIDIClientRef()
    private var outPort = MIDIPortRef()
    private var inPort = MIDIPortRef()
    private var connectedSource: MIDIEndpointRef = 0
    private let parser = MidiByteParser()
    let detector = MidiTriggerDetector()
    private(set) var inputName = ""

    /// Kalles på hovedtråden.
    var onTrigger: ((String, Int) -> Void)?
    var onMsc: ((MscCommand) -> Void)?

    init() {
        MIDIClientCreateWithBlock("ShowCue" as CFString, &client) { _ in }
        MIDIOutputPortCreate(client, "ShowCue ut" as CFString, &outPort)
        MIDIInputPortCreateWithBlock(client, "ShowCue inn" as CFString, &inPort) { [weak self] list, _ in
            self?.receive(list)
        }
    }

    private static func name(_ ep: MIDIEndpointRef) -> String {
        var s: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(ep, kMIDIPropertyDisplayName, &s) == noErr, let v = s {
            return v.takeRetainedValue() as String
        }
        if MIDIObjectGetStringProperty(ep, kMIDIPropertyName, &s) == noErr, let v = s {
            return v.takeRetainedValue() as String
        }
        return "MIDI \(ep)"
    }

    static func destinations() -> [String] {
        (0..<MIDIGetNumberOfDestinations()).map { name(MIDIGetDestination($0)) }
    }

    static func sources() -> [String] {
        (0..<MIDIGetNumberOfSources()).map { name(MIDIGetSource($0)) }
    }

    private static func destination(named n: String) -> MIDIEndpointRef? {
        let count = MIDIGetNumberOfDestinations()
        guard count > 0 else { return nil }
        if n.isEmpty { return MIDIGetDestination(0) }
        for i in 0..<count where name(MIDIGetDestination(i)) == n { return MIDIGetDestination(i) }
        return nil
    }

    // MARK: Ut

    func send(_ bytes: [UInt8], device: String) throws {
        guard let dest = MidiSystem.destination(named: device) else {
            throw NSError(domain: "ShowCue.MIDI", code: 1, userInfo: [NSLocalizedDescriptionKey:
                device.isEmpty ? "Ingen MIDI-utganger funnet." : "MIDI-enheten «\(device)» finnes ikke."])
        }
        let bufferSize = 1024
        let raw = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: MemoryLayout<MIDIPacketList>.alignment)
        defer { raw.deallocate() }
        let list = raw.assumingMemoryBound(to: MIDIPacketList.self)
        var packet = MIDIPacketListInit(list)
        packet = MIDIPacketListAdd(list, bufferSize, packet, 0, bytes.count, bytes)
        MIDISend(outPort, dest, list)
    }

    // MARK: Inn

    func openInput(named n: String, channel: Int) throws {
        closeInput()
        detector.channel = channel
        guard !n.isEmpty else { return }
        let count = MIDIGetNumberOfSources()
        for i in 0..<count {
            let src = MIDIGetSource(i)
            if MidiSystem.name(src) == n {
                let st = MIDIPortConnectSource(inPort, src, nil)
                guard st == noErr else { throw NSError(domain: "ShowCue.MIDI", code: Int(st), userInfo: [NSLocalizedDescriptionKey: "Kunne ikke åpne «\(n)»"]) }
                connectedSource = src
                inputName = n
                return
            }
        }
        throw NSError(domain: "ShowCue.MIDI", code: 2, userInfo: [NSLocalizedDescriptionKey: "MIDI-inngangen «\(n)» finnes ikke."])
    }

    func closeInput() {
        if connectedSource != 0 { MIDIPortDisconnectSource(inPort, connectedSource) }
        connectedSource = 0
        inputName = ""
    }

    var isInputOpen: Bool { connectedSource != 0 }

    /// Kalles på CoreMIDI sin tråd.
    private func receive(_ list: UnsafePointer<MIDIPacketList>) {
        var bytes: [UInt8] = []
        let n = list.pointee.numPackets
        let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \MIDIPacket.data) ?? 10
        var p = UnsafeRawPointer(list) + (MemoryLayout<MIDIPacketList>.offset(of: \MIDIPacketList.packet) ?? 4)
        for _ in 0..<n {
            let packet = p.assumingMemoryBound(to: MIDIPacket.self)
            let len = Int(packet.pointee.length)
            let data = (p + dataOffset).assumingMemoryBound(to: UInt8.self)
            bytes.append(contentsOf: UnsafeBufferPointer(start: data, count: len))
            p = UnsafeRawPointer(MIDIPacketNext(packet))
        }
        let events = parser.feed(bytes)
        guard !events.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for e in events {
                if case .sysex(let s) = e {
                    if let m = MscCommand.parse(s) { self.onMsc?(m) }
                } else if let hit = self.detector.trigger(for: e) {
                    self.onTrigger?(hit.0, hit.1)
                }
            }
        }
    }
}
