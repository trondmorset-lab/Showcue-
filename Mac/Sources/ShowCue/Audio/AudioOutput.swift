import Foundation
import AudioToolbox
import CoreAudio

/// Direkte CoreAudio-utgang (AUHAL) mot én enhet, med så mange kanaler som enheten har (opptil maks).
/// Lydtråden kaller PatchMixer.render for hver blokk.
final class AudioOutput {
    private var unit: AudioUnit?
    fileprivate var mixer: PatchMixer?
    fileprivate var channelCount = 0
    fileprivate let ptrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: 512)

    private(set) var device: AudioDeviceInfo?
    var isRunning: Bool { unit != nil }

    deinit {
        stop()
        ptrs.deallocate()
    }

    private func check(_ st: OSStatus, _ what: String) throws {
        guard st == noErr else {
            throw NSError(domain: "ShowCue.Audio", code: Int(st), userInfo: [NSLocalizedDescriptionKey: "\(what) feilet (kode \(st))"])
        }
    }

    /// Starter utgangen og returnerer mikseren som skal fylles.
    func start(device: AudioDeviceInfo, maxChannels: Int, bufferFrames: Int, patch: [PatchBus]) throws -> PatchMixer {
        stop()
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw NSError(domain: "ShowCue.Audio", code: -1, userInfo: [NSLocalizedDescriptionKey: "Fant ikke CoreAudio-utgang"])
        }
        var au: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &au), "Åpne lydutgang")
        guard let u = au else { throw NSError(domain: "ShowCue.Audio", code: -2) }

        do {
            var devID = device.id
            try check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                           &devID, UInt32(MemoryLayout<AudioDeviceID>.size)), "Velge lydenhet")

            let channels = max(1, min(device.outputChannels, max(2, maxChannels), 512))
            let rate = device.sampleRate > 0 ? device.sampleRate : 48000
            var asbd = AudioStreamBasicDescription(
                mSampleRate: rate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
            try check(AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                           &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "Sette lydformat")

            CoreAudioDevices.setBufferFrameSize(device.id, bufferFrames)

            let m = PatchMixer(sampleRate: rate, deviceChannels: channels, patch: patch)
            mixer = m
            channelCount = channels

            var cb = AURenderCallbackStruct(inputProc: renderCallback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try check(AudioUnitSetProperty(u, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                           &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "Koble til mikser")
            try check(AudioUnitInitialize(u), "Starte lydenhet")
            try check(AudioOutputUnitStart(u), "Starte avspilling")
            unit = u
            self.device = device
            return m
        } catch {
            AudioComponentInstanceDispose(u)
            mixer = nil
            throw error
        }
    }

    func stop() {
        if let u = unit {
            AudioOutputUnitStop(u)
            AudioUnitUninitialize(u)
            AudioComponentInstanceDispose(u)
        }
        unit = nil
        mixer?.removeAll()
        mixer = nil
        device = nil
    }
}

/// Lydtråden: hent én blokk fra mikseren.
private let renderCallback: AURenderCallback = { refCon, _, _, _, frameCount, ioData in
    let out = Unmanaged<AudioOutput>.fromOpaque(refCon).takeUnretainedValue()
    guard let ioData else { return noErr }
    let list = UnsafeMutableAudioBufferListPointer(ioData)
    let frames = Int(frameCount)
    guard let mixer = out.mixer else {
        for b in list { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
        return noErr
    }
    let n = min(list.count, out.channelCount, 512)
    for i in 0..<n { out.ptrs[i] = list[i].mData?.assumingMemoryBound(to: Float.self) }
    let mixerChannels = min(mixer.deviceChannels, 512)
    if mixerChannels > n { for i in n..<mixerChannels { out.ptrs[i] = nil } }
    mixer.render(out.ptrs, frames: frames)
    // Kanaler utover det mikseren kjenner til (skal ikke skje) nulles.
    if list.count > n { for i in n..<list.count { if let d = list[i].mData { memset(d, 0, Int(list[i].mDataByteSize)) } } }
    return noErr
}
