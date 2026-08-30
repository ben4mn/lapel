import Testing
import Foundation
@testable import LapelKit

private func tone(_ frames: Int = 4_800, amplitude: Float = 0.3, phase: Double = 0) -> [Float] {
    (0..<frames).map { i in amplitude * Float(sin(Double(i) * 0.05 + phase)) }
}
private func silence(_ frames: Int = 4_800) -> [Float] { [Float](repeating: 0, count: frames) }

@Suite("ChannelSeparation")
struct ChannelSeparationTests {

    @Test("with no signal yet, separation is honestly unknown rather than assumed good")
    func startsUnknown() {
        var detector = DuplicateChannelDetector(confirmationSeconds: 1.0)
        #expect(detector.separation == .unknown)

        for _ in 0..<10 { detector.update(channels: [silence(), silence()], elapsed: 0.5) }
        #expect(detector.separation == .unknown)
    }

    @Test("one divergent block with signal proves the channels are independent")
    func divergenceProvesIndependence() {
        var detector = DuplicateChannelDetector(confirmationSeconds: 1.0)
        detector.update(channels: [tone(), tone(phase: 1.2)], elapsed: 0.1)

        #expect(detector.separation == .independent)
    }

    @Test("sustained identical signal reports the channels as one duplicated mix")
    func duplicationIsReported() {
        var detector = DuplicateChannelDetector(confirmationSeconds: 1.0)
        let block = tone()
        for _ in 0..<4 { detector.update(channels: [block, block], elapsed: 0.5) }

        #expect(detector.separation == .identical)
    }

    @Test("identical-but-unconfirmed stays unknown, not yet an accusation")
    func shortIdenticalRunIsUnknown() {
        var detector = DuplicateChannelDetector(confirmationSeconds: 2.0)
        let block = tone()
        detector.update(channels: [block, block], elapsed: 0.5)

        #expect(detector.separation == .unknown)
    }

    @Test("a receiver switched to stereo mid-session is recognised immediately")
    func switchingToStereoIsSeenAtOnce() {
        var detector = DuplicateChannelDetector(confirmationSeconds: 1.0)
        let block = tone()
        for _ in 0..<4 { detector.update(channels: [block, block], elapsed: 0.5) }
        #expect(detector.separation == .identical)

        detector.update(channels: [tone(), tone(phase: 2.0)], elapsed: 0.1)
        #expect(detector.separation == .independent)
    }

    @Test("state surfaces separation so the UI can confirm a working stereo receiver")
    func stateSurfacesSeparation() {
        var state = ReceiverState()
        state.devicesChanged(to: [AudioDeviceDescriptor(
            uid: "d", name: "Wireless Mic Rx", manufacturer: "DJI Technology Co., Ltd.",
            inputChannelCount: 2, sampleRate: 48_000, transport: .usb)])

        #expect(state.channelSeparation == .unknown)
        state.audioArrived(channels: [tone(), tone(phase: 1.2)], elapsed: 0.2)
        #expect(state.channelSeparation == .independent)
    }
}
