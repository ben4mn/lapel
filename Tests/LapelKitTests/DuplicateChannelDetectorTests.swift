import Testing
import Foundation
@testable import LapelKit

private func speech(_ frames: Int = 4_800, amplitude: Float = 0.3, phase: Double = 0) -> [Float] {
    (0..<frames).map { i in amplitude * Float(sin(Double(i) * 0.05 + phase)) }
}

private func silence(_ frames: Int = 4_800) -> [Float] { [Float](repeating: 0, count: frames) }

@Suite("DuplicateChannelDetector")
struct DuplicateChannelDetectorTests {

    @Test("channels carrying the same samples are reported as duplicated")
    func detectsDuplication() {
        var detector = DuplicateChannelDetector(confirmationSeconds: 1.0)
        let block = speech()

        detector.update(channels: [block, block], elapsed: 0.6)
        #expect(!detector.isDuplicated)          // not yet confirmed

        detector.update(channels: [block, block], elapsed: 0.6)
        #expect(detector.isDuplicated)
    }

    @Test("genuinely different channels are never reported as duplicated")
    func independentChannelsAreNot() {
        var detector = DuplicateChannelDetector(confirmationSeconds: 1.0)

        for _ in 0..<10 {
            detector.update(channels: [speech(), speech(phase: 1.2)], elapsed: 0.5)
        }
        #expect(!detector.isDuplicated)
    }

    @Test("two silent channels prove nothing and must not raise the alarm")
    func silenceIsNotEvidence() {
        var detector = DuplicateChannelDetector(confirmationSeconds: 1.0)

        // Identical, but only because nobody is transmitting. A receiver in stereo
        // with both lapels off looks exactly like this.
        for _ in 0..<10 { detector.update(channels: [silence(), silence()], elapsed: 0.5) }
        #expect(!detector.isDuplicated)
    }

    @Test("one live channel beside a dead one is not duplication")
    func oneLiveChannel() {
        var detector = DuplicateChannelDetector(confirmationSeconds: 1.0)

        for _ in 0..<10 { detector.update(channels: [speech(), silence()], elapsed: 0.5) }
        #expect(!detector.isDuplicated)
    }

    @Test("a single divergent block clears a previously confirmed duplication")
    func divergenceResetsImmediately() {
        var detector = DuplicateChannelDetector(confirmationSeconds: 1.0)
        let block = speech()
        for _ in 0..<4 { detector.update(channels: [block, block], elapsed: 0.5) }
        #expect(detector.isDuplicated)

        detector.update(channels: [speech(), speech(phase: 2.0)], elapsed: 0.1)
        #expect(!detector.isDuplicated)
    }

    @Test("channels differing only below the noise floor still count as duplicated")
    func toleratesTinyDifferences() {
        var detector = DuplicateChannelDetector(confirmationSeconds: 1.0)
        let left = speech()
        // A receiver's two copies of one mix can differ in the last bit or two.
        let right = left.map { $0 + 1e-7 }

        for _ in 0..<4 { detector.update(channels: [left, right], elapsed: 0.5) }
        #expect(detector.isDuplicated)
    }

    @Test("a mono receiver has nothing to compare and is never flagged")
    func singleChannelNeverFlags() {
        var detector = DuplicateChannelDetector(confirmationSeconds: 1.0)

        for _ in 0..<10 { detector.update(channels: [speech()], elapsed: 0.5) }
        #expect(!detector.isDuplicated)
    }

    @Test("resetting clears a confirmed duplication so a new receiver starts clean")
    func resetClears() {
        var detector = DuplicateChannelDetector(confirmationSeconds: 1.0)
        let block = speech()
        for _ in 0..<4 { detector.update(channels: [block, block], elapsed: 0.5) }

        detector.reset()
        #expect(!detector.isDuplicated)
    }
}

@Suite("ReceiverState duplicate channels")
struct ReceiverStateDuplicateTests {

    private let dji = AudioDeviceDescriptor(
        uid: "DJI-1", name: "Wireless Mic Rx", manufacturer: "DJI Technology Co., Ltd.",
        inputChannelCount: 2, sampleRate: 48_000, transport: .usb)

    @Test("a two-channel receiver sending one mix twice raises the mono advisory")
    func duplicatedChannelsRaiseAdvisory() {
        var state = ReceiverState()
        state.devicesChanged(to: [dji])
        #expect(state.advisory == nil)

        let block = speech()
        for _ in 0..<4 { state.audioArrived(channels: [block, block], elapsed: 0.5) }

        // The channel count says stereo, but the audio says otherwise, and the audio
        // is the thing that decides whether speakers can be separated.
        #expect(state.advisory == .channelsAreIdentical)
        #expect(state.canSeparateSpeakers == false)
    }

    @Test("independent channels leave the receiver reported as separable")
    func independentChannelsStaySeparable() {
        var state = ReceiverState()
        state.devicesChanged(to: [dji])

        for _ in 0..<6 { state.audioArrived(channels: [speech(), speech(phase: 1.2)], elapsed: 0.5) }

        #expect(state.advisory == nil)
        #expect(state.canSeparateSpeakers == true)
    }

    @Test("the advisory names the fix on the hardware")
    func advisoryIsActionable() {
        let message = ReceiverAdvisory.channelsAreIdentical.message
        #expect(message.lowercased().contains("stereo"))
        #expect(message.lowercased().contains("same"))
    }

    @Test("unplugging clears a duplication finding from the previous receiver")
    func reconnectClearsFinding() {
        var state = ReceiverState()
        state.devicesChanged(to: [dji])
        let block = speech()
        for _ in 0..<4 { state.audioArrived(channels: [block, block], elapsed: 0.5) }
        #expect(state.advisory == .channelsAreIdentical)

        state.devicesChanged(to: [])
        state.devicesChanged(to: [dji])
        #expect(state.advisory == nil)
    }
}
