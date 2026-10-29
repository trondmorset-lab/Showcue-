import Foundation
import CoreAudio

/// En lydutgang på Macen (innebygde høyttalere, USB-kort, Dante Virtual Soundcard, aggregerte enheter …).
struct AudioDeviceInfo: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let outputChannels: Int
    let sampleRate: Double

    var label: String { "\(name)  (\(outputChannels) kanaler)" }
}

enum CoreAudioDevices {
    private static func address(_ sel: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: element)
    }

    private static func string(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector,
                               _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                               _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> String? {
        var addr = address(sel, scope, element)
        var value: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let st = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        guard st == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    static func outputChannelCount(_ id: AudioDeviceID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func nominalSampleRate(_ id: AudioDeviceID) -> Double {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr ? rate : 48000
    }

    static func info(_ id: AudioDeviceID) -> AudioDeviceInfo {
        AudioDeviceInfo(id: id,
                        uid: string(id, kAudioDevicePropertyDeviceUID) ?? "",
                        name: string(id, kAudioObjectPropertyName) ?? "Lydenhet \(id)",
                        outputChannels: outputChannelCount(id),
                        sampleRate: nominalSampleRate(id))
    }

    /// Alle enheter med utganger.
    static func outputDevices() -> [AudioDeviceInfo] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map(info).filter { $0.outputChannels > 0 }
    }

    static func defaultOutput() -> AudioDeviceInfo? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return info(id)
    }

    /// Finn enhet fra UID (tom = standard utgang).
    static func device(uid: String) -> AudioDeviceInfo? {
        if uid.isEmpty { return defaultOutput() }
        return outputDevices().first { $0.uid == uid }
    }

    /// Kanalnavn fra driveren (Dante Virtual Soundcard o.l. kan ha egne navn).
    static func channelNames(_ id: AudioDeviceID, count: Int) -> [String] {
        (0..<count).map { i in
            let n = string(id, kAudioObjectPropertyElementName, kAudioObjectPropertyScopeOutput, AudioObjectPropertyElement(i + 1)) ?? ""
            return n.isEmpty ? "Ut \(i + 1)" : n
        }
    }

    /// Ber enheten om en bestemt bufferstørrelse (rammer). Feil ignoreres.
    static func setBufferFrameSize(_ id: AudioDeviceID, _ frames: Int) {
        var addr = address(kAudioDevicePropertyBufferFrameSize)
        var value = UInt32(frames)
        _ = AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}
