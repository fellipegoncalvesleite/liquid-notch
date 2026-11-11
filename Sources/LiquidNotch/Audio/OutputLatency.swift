import CoreAudio

/// How late the default output plays what it's given (owner, 11-07: with AirPods the lyrics ran ahead of the voice; they
/// report 0.17 s here, the built-in speakers about none): the device's latency and safety offset, its first output
/// stream's latency and its buffer, in seconds. Read on demand (a few property reads).
enum OutputLatency {
    static func seconds() -> Double {
        let device: AudioDeviceID = read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                                         kAudioObjectPropertyScopeGlobal, AudioDeviceID(0))
        guard device != 0 else { return 0 }
        let out = kAudioObjectPropertyScopeOutput
        let rate: Float64 = read(device, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, 0)
        guard rate > 0 else { return 0 }
        let latency: UInt32 = read(device, kAudioDevicePropertyLatency, out, 0)
        let safety: UInt32 = read(device, kAudioDevicePropertySafetyOffset, out, 0)
        let buffer: UInt32 = read(device, kAudioDevicePropertyBufferFrameSize, out, 0)
        var stream: UInt32 = 0
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: out,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        if AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size >= UInt32(MemoryLayout<AudioStreamID>.size) {
            var ids = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &ids) == noErr, let first = ids.first {
                stream = read(first, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal, 0)
            }
        }
        let total = Double(latency) + Double(safety) + Double(stream) + Double(buffer)
        return min(total / rate, 1)
    }

    private static func read<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                                 _ scope: AudioObjectPropertyScope, _ fallback: T) -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value = fallback
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        return status == noErr ? value : fallback
    }
}
