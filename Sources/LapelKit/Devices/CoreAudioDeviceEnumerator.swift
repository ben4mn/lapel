import CoreAudio
import Foundation

/// Reads the machine's audio devices straight from the CoreAudio HAL.
///
/// Worth knowing: none of this needs microphone permission. The HAL will name
/// every device before the user has granted anything, which is why Lapel can show
/// "DJI MIC MINI connected, 2 microphones live" on first launch and only prompt
/// when the user actually presses record. The browser equivalent cannot: it hides
/// device labels until permission is granted.
public struct CoreAudioDeviceEnumerator: AudioDeviceEnumerating {

    public init() {}

    public func inputDevices() -> [AudioDeviceDescriptor] {
        deviceIDs().compactMap(Self.describe).filter(\.canCapture)
    }

    // MARK: - Device list

    func deviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids
    }

    // MARK: - Per-device properties

    static func describe(_ id: AudioObjectID) -> AudioDeviceDescriptor? {
        guard let uid: String = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        return AudioDeviceDescriptor(
            uid: uid,
            name: string(id, kAudioObjectPropertyName) ?? "Unknown Device",
            manufacturer: string(id, kAudioObjectPropertyManufacturer) ?? "",
            inputChannelCount: inputChannelCount(id),
            sampleRate: sampleRate(id),
            transport: TransportType(coreAudioValue: transportType(id))
        )
    }

    /// Sums the channels across every input stream. A device can present its inputs
    /// as several streams rather than one wide one, so taking the first stream's
    /// count would under-report a two-transmitter receiver as mono.
    static func inputChannelCount(_ id: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else { return 0 }

        let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func sampleRate(_ id: AudioObjectID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr else { return 0 }
        return rate
    }

    static func transportType(_ id: AudioObjectID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // CoreAudio hands back a +1 CFString for these selectors, so it is taken
        // retained rather than unretained.
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
