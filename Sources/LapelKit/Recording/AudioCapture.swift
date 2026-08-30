import AVFoundation
import CoreAudio
import Foundation

public enum AudioCaptureError: Error, Equatable {
    case couldNotSelectDevice(String)
    case engineFailedToStart(String)
}

/// Pulls deinterleaved audio off a specific input device.
///
/// The only place in Lapel that touches AVAudioEngine. Everything downstream —
/// metering, presence, recording — receives plain `[[Float]]`, one array per
/// channel, which is why all of it is testable without an audio device.
public final class AudioCapture: @unchecked Sendable {

    public typealias BufferHandler = @Sendable (_ channels: [[Float]], _ sampleRate: Double) -> Void

    private let engine = AVAudioEngine()
    private let device: AudioDeviceDescriptor
    private var isRunning = false

    public init(device: AudioDeviceDescriptor) {
        self.device = device
    }

    public func start(onBuffer: @escaping BufferHandler) throws {
        guard !isRunning else { return }
        try selectInputDevice()

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw AudioCaptureError.couldNotSelectDevice(device.name)
        }

        // 4096 frames is ~85 ms at 48 kHz: long enough that the tap is cheap, short
        // enough that a meter still looks live.
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            guard let channels = Self.deinterleave(buffer) else { return }
            onBuffer(channels, buffer.format.sampleRate)
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioCaptureError.engineFailedToStart(error.localizedDescription)
        }
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    deinit { stop() }

    /// Points the engine's input at our device rather than the system default.
    ///
    /// This has to happen before the input format is read: AVAudioEngine caches the
    /// input format on first access, so asking for it first and setting the device
    /// afterwards silently leaves you recording the built-in microphone.
    private func selectInputDevice() throws {
        guard let unit = engine.inputNode.audioUnit else {
            throw AudioCaptureError.couldNotSelectDevice(device.name)
        }
        guard let id = Self.deviceID(forUID: device.uid) else {
            throw AudioCaptureError.couldNotSelectDevice(device.uid)
        }

        var deviceID = id
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw AudioCaptureError.couldNotSelectDevice("\(device.name) (OSStatus \(status))")
        }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        CoreAudioDeviceEnumerator().deviceIDs().first {
            CoreAudioDeviceEnumerator.string($0, kAudioDevicePropertyDeviceUID) == uid
        }
    }

    /// Splits an interleaved-or-not PCM buffer into one `[Float]` per channel.
    ///
    /// Interleaved input is the case that matters: a USB receiver commonly hands
    /// over `[L, R, L, R, ...]` in a single buffer, and reading only `floatChannelData[0]`
    /// there would give you both speakers chopped together at half rate.
    static func deinterleave(_ buffer: AVAudioPCMBuffer) -> [[Float]]? {
        guard let data = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frames > 0, channelCount > 0 else { return [] }

        if buffer.format.isInterleaved {
            let source = data[0]
            return (0..<channelCount).map { channel in
                var out = [Float](repeating: 0, count: frames)
                for frame in 0..<frames { out[frame] = source[frame * channelCount + channel] }
                return out
            }
        }

        return (0..<channelCount).map { channel in
            Array(UnsafeBufferPointer(start: data[channel], count: frames))
        }
    }
}
