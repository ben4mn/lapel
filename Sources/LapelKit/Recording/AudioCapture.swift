import AVFoundation
import CoreAudio
import Foundation

public enum AudioCaptureError: Error, Equatable {
    case couldNotSelectDevice(String)
    case engineFailedToStart(String)
}

/// Receives one deinterleaved block: one `[Float]` per channel.
///
/// Main-actor isolated by contract. Conforming captures must deliver blocks **in
/// order**: audio arriving out of sequence would interleave garbage into the
/// recorded files.
public typealias AudioBufferHandler = @MainActor @Sendable (_ channels: [[Float]], _ sampleRate: Double) -> Void

/// Something that can deliver deinterleaved audio. The seam that lets the recorder
/// model be driven by synthetic buffers instead of an audio interface.
/// Main-actor isolated: capture is started and stopped in response to UI and
/// hotplug events, both of which already arrive there.
@MainActor
public protocol AudioCapturing: AnyObject, Sendable {
    func start(onBuffer: @escaping AudioBufferHandler) throws
    func stop()
}

@MainActor
public protocol AudioCaptureFactory: Sendable {
    func makeCapture(device: AudioDeviceDescriptor) -> AudioCapturing
}

public struct LiveAudioCaptureFactory: AudioCaptureFactory {
    public init() {}
    public func makeCapture(device: AudioDeviceDescriptor) -> AudioCapturing {
        AudioCapture(device: device)
    }
}

/// Pulls deinterleaved audio off a specific input device.
///
/// The only place in Lapel that touches AVAudioEngine. Everything downstream —
/// metering, presence, recording — receives plain `[[Float]]`, one array per
/// channel, which is why all of it is testable without an audio device.
public final class AudioCapture: AudioCapturing, @unchecked Sendable {

    private let engine = AVAudioEngine()
    private var isRunning = false
    private let device: AudioDeviceDescriptor

    public init(device: AudioDeviceDescriptor) {
        self.device = device
    }

    @MainActor
    public func start(onBuffer: @escaping AudioBufferHandler) throws {
        guard !isRunning else { return }
        try selectInputDevice()

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw AudioCaptureError.couldNotSelectDevice(device.name)
        }

        // 4096 frames is ~85 ms at 48 kHz: long enough that the tap is cheap, short
        // enough that a meter still looks live.
        //
        // The @Sendable is load-bearing, not decoration. This method is main-actor
        // isolated (AudioCapturing is), so without it the closure *inherits* that
        // isolation and the compiler injects an executor assertion at its entry.
        // AVFAudio calls the tap on its own realtime queue, so that assertion trips
        // and the process dies with SIGTRAP the moment audio first arrives — which
        // no test catches, because it needs a real device attached to fire at all.
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { @Sendable buffer, _ in
            guard let channels = Self.deinterleave(buffer) else { return }
            let sampleRate = buffer.format.sampleRate

            // DispatchQueue.main rather than Task { @MainActor }: tasks carry no
            // ordering guarantee between them, and audio blocks delivered out of
            // sequence would interleave garbage into the recorded files. The main
            // queue is FIFO and is the main actor's own executor, so assumeIsolated
            // is stating a fact rather than making a promise.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { onBuffer(channels, sampleRate) }
            }
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioCaptureError.engineFailedToStart(error.localizedDescription)
        }
        isRunning = true
    }

    /// Must be called explicitly — there is no cleanup in `deinit`.
    ///
    /// AVAudioEngine is not `Sendable`, so a nonisolated deinit cannot legally
    /// touch it. Rather than defeat that with `nonisolated(unsafe)`, ownership is
    /// made explicit: `RecorderModel` stops the capture on every path that drops
    /// it — reconfiguration, disconnect, and replacement.
    @MainActor
    public func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

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

    nonisolated static func deviceID(forUID uid: String) -> AudioDeviceID? {
        CoreAudioDeviceEnumerator().deviceIDs().first {
            CoreAudioDeviceEnumerator.string($0, kAudioDevicePropertyDeviceUID) == uid
        }
    }

    /// Splits an interleaved-or-not PCM buffer into one `[Float]` per channel.
    ///
    /// Interleaved input is the case that matters: a USB receiver commonly hands
    /// over `[L, R, L, R, ...]` in a single buffer, and reading only `floatChannelData[0]`
    /// there would give you both speakers chopped together at half rate.
    /// Explicitly nonisolated: this runs inside the audio tap, off the main actor.
    /// Letting it inherit the class's isolation would be actively wrong.
    nonisolated static func deinterleave(_ buffer: AVAudioPCMBuffer) -> [[Float]]? {
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
