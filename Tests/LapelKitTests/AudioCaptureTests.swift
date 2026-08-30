import Testing
import AVFoundation
@testable import LapelKit

/// AVAudioFormat(commonFormat:sampleRate:channels:interleaved:) returns nil above
/// two channels, so wider formats are built from an explicit ASBD and a discrete
/// channel layout — the same shape a four-transmitter receiver would present.
private func makeFormat(channelCount: Int, interleaved: Bool) -> AVAudioFormat {
    if channelCount <= 2 {
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
            channels: AVAudioChannelCount(channelCount), interleaved: interleaved
        )!
    }

    let bytesPerSample = UInt32(MemoryLayout<Float>.size)
    var asbd = AudioStreamBasicDescription(
        mSampleRate: 48_000,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
            | (interleaved ? 0 : kAudioFormatFlagIsNonInterleaved),
        mBytesPerPacket: interleaved ? bytesPerSample * UInt32(channelCount) : bytesPerSample,
        mFramesPerPacket: 1,
        mBytesPerFrame: interleaved ? bytesPerSample * UInt32(channelCount) : bytesPerSample,
        mChannelsPerFrame: UInt32(channelCount),
        mBitsPerChannel: bytesPerSample * 8,
        mReserved: 0
    )
    let layout = AVAudioChannelLayout(
        layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channelCount)
    )!
    return AVAudioFormat(streamDescription: &asbd, channelLayout: layout)!
}

private func makeBuffer(interleaved: Bool, channels: [[Float]]) -> AVAudioPCMBuffer {
    let frames = channels[0].count
    let format = makeFormat(channelCount: channels.count, interleaved: interleaved)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)

    let data = buffer.floatChannelData!
    if interleaved {
        for frame in 0..<frames {
            for channel in channels.indices {
                data[0][frame * channels.count + channel] = channels[channel][frame]
            }
        }
    } else {
        for channel in channels.indices {
            for frame in 0..<frames { data[channel][frame] = channels[channel][frame] }
        }
    }
    return buffer
}

@Suite("AudioCapture.deinterleave")
struct AudioCaptureDeinterleaveTests {

    @Test("an interleaved stereo buffer splits back into the two original channels")
    func splitsInterleaved() {
        let buffer = makeBuffer(interleaved: true, channels: [[1, 2, 3], [10, 20, 30]])
        let channels = AudioCapture.deinterleave(buffer)

        // The bug this guards: reading only floatChannelData[0] on an interleaved
        // buffer yields [1, 10, 2] — both speakers chopped together at half rate.
        #expect(channels?.count == 2)
        #expect(channels?[0] == [1, 2, 3])
        #expect(channels?[1] == [10, 20, 30])
    }

    @Test("a planar stereo buffer is read straight through")
    func splitsPlanar() {
        let buffer = makeBuffer(interleaved: false, channels: [[1, 2, 3], [10, 20, 30]])
        let channels = AudioCapture.deinterleave(buffer)

        #expect(channels?[0] == [1, 2, 3])
        #expect(channels?[1] == [10, 20, 30])
    }

    @Test("a mono buffer yields exactly one channel")
    func handlesMono() {
        let buffer = makeBuffer(interleaved: false, channels: [[1, 2, 3, 4]])
        #expect(AudioCapture.deinterleave(buffer)?.count == 1)
        #expect(AudioCapture.deinterleave(buffer)?[0] == [1, 2, 3, 4])
    }

    @Test("a four-channel interleaved buffer keeps every channel distinct")
    func handlesFourChannels() {
        let buffer = makeBuffer(interleaved: true, channels: [[1, 2], [3, 4], [5, 6], [7, 8]])
        let channels = AudioCapture.deinterleave(buffer)

        #expect(channels?.count == 4)
        #expect(channels?[2] == [5, 6])
        #expect(channels?[3] == [7, 8])
    }

    @Test("an empty buffer yields no channels rather than crashing")
    func handlesEmptyBuffer() {
        let buffer = AVAudioPCMBuffer(pcmFormat: makeFormat(channelCount: 2, interleaved: true), frameCapacity: 128)!
        buffer.frameLength = 0

        #expect(AudioCapture.deinterleave(buffer) == [])
    }

    @Test("a deinterleaved channel meters the same as the signal that went in")
    func roundTripsThroughTheMeter() {
        let loud = (0..<4_800).map { _ in Float(1.0) }
        let quiet = (0..<4_800).map { _ in Float(0.5) }
        let buffer = makeBuffer(interleaved: true, channels: [loud, quiet])
        let channels = AudioCapture.deinterleave(buffer)!

        var left = LevelMeter(), right = LevelMeter()
        #expect(abs(left.process(channels[0], sampleRate: 48_000).rmsDB - 0) < 0.05)
        #expect(abs(right.process(channels[1], sampleRate: 48_000).rmsDB - (-6.02)) < 0.05)
    }
}
