import Testing
import Foundation
import CoreAudio
@testable import LapelKit

private let builtIn = AudioDeviceDescriptor(
    uid: "builtin", name: "MacBook Air Microphone", manufacturer: "Apple Inc.",
    inputChannelCount: 1, sampleRate: 48_000, transport: .builtIn
)

private func dji(uid: String = "DJI-1", channels: Int = 2) -> AudioDeviceDescriptor {
    AudioDeviceDescriptor(uid: uid, name: "DJI MIC MINI", manufacturer: "DJI",
                          inputChannelCount: channels, sampleRate: 48_000, transport: .usb)
}

private let speech = LevelReading(rmsDB: -22, peakDB: -14)
private let selfNoise = LevelReading(rmsDB: -64, peakDB: -58)
private let digitalSilence = LevelReading(rmsDB: LevelMeter.floorDB, peakDB: LevelMeter.floorDB)

@Suite("TransportType mapping")
struct TransportTypeTests {

    @Test("CoreAudio transport codes map to the transports we care about")
    func mapsKnownCodes() {
        #expect(TransportType(coreAudioValue: kAudioDeviceTransportTypeUSB) == .usb)
        #expect(TransportType(coreAudioValue: kAudioDeviceTransportTypeBuiltIn) == .builtIn)
        #expect(TransportType(coreAudioValue: kAudioDeviceTransportTypeBluetooth) == .bluetooth)
        #expect(TransportType(coreAudioValue: kAudioDeviceTransportTypeAggregate) == .aggregate)
        #expect(TransportType(coreAudioValue: kAudioDeviceTransportTypeVirtual) == .virtual)
    }

    @Test("an unrecognised transport code degrades to unknown rather than failing")
    func unknownCodeIsTolerated() {
        #expect(TransportType(coreAudioValue: 0) == .unknown)
        #expect(TransportType(coreAudioValue: 0xDEADBEEF) == .unknown)
    }
}

@Suite("ReceiverState")
struct ReceiverStateTests {

    @Test("nothing is connected before any device list arrives")
    func startsEmpty() {
        let state = ReceiverState()
        #expect(state.receiver == nil)
        #expect(state.isConnected == false)
        #expect(state.connectedMicCount == 0)
        #expect(state.presences.isEmpty)
    }

    @Test("a device list containing the receiver reports it as newly connected")
    func connects() {
        var state = ReceiverState()
        let event = state.devicesChanged(to: [builtIn, dji()])

        #expect(event == .connected)
        #expect(state.isConnected)
        #expect(state.receiver?.device.uid == "DJI-1")
        #expect(state.presences == [.absent, .absent])
    }

    @Test("an unchanged device list produces no event, so the UI does not churn")
    func idempotentUpdate() {
        var state = ReceiverState()
        _ = state.devicesChanged(to: [dji()])
        #expect(state.devicesChanged(to: [dji()]) == nil)
    }

    @Test("unplugging the receiver reports a disconnect and clears everything")
    func disconnects() {
        var state = ReceiverState()
        _ = state.devicesChanged(to: [dji()])
        state.levelsChanged(readings: [speech, speech], elapsed: 0.1)
        #expect(state.connectedMicCount == 2)

        let event = state.devicesChanged(to: [builtIn])

        #expect(event == .disconnected)
        #expect(state.receiver == nil)
        // A stale mic count outliving the hardware is exactly the bug this guards.
        #expect(state.connectedMicCount == 0)
        #expect(state.presences.isEmpty)
    }

    @Test("switching the receiver from mono to stereo is reported as a reconfiguration")
    func modeFlipReconfigures() {
        var state = ReceiverState()
        _ = state.devicesChanged(to: [dji(channels: 1)])
        #expect(state.advisory == .receiverInMonoMode)

        let event = state.devicesChanged(to: [dji(channels: 2)])

        #expect(event == .reconfigured)
        #expect(state.advisory == nil)
        #expect(state.presences.count == 2)
        #expect(state.receiver?.canSeparateSpeakers == true)
    }

    @Test("swapping in a different receiver is a reconfiguration, not a no-op")
    func differentReceiverReconfigures() {
        var state = ReceiverState()
        _ = state.devicesChanged(to: [dji(uid: "DJI-1")])
        #expect(state.devicesChanged(to: [dji(uid: "DJI-2")]) == .reconfigured)
        #expect(state.receiver?.device.uid == "DJI-2")
    }

    @Test("levels drive the live mic count and speaking indicator")
    func levelsDrivePresence() {
        var state = ReceiverState()
        _ = state.devicesChanged(to: [dji()])
        state.levelsChanged(readings: [speech, selfNoise], elapsed: 0.1)

        #expect(state.presences == [.speaking, .idle])
        #expect(state.connectedMicCount == 2)
        #expect(state.speakingChannels == [0])
    }

    @Test("a channel with no transmitter is not counted as a microphone")
    func absentChannelNotCounted() {
        var state = ReceiverState()
        _ = state.devicesChanged(to: [dji()])
        state.levelsChanged(readings: [speech, digitalSilence], elapsed: 2.0)

        #expect(state.presences == [.speaking, .absent])
        #expect(state.connectedMicCount == 1)
    }

    @Test("levels arriving with no receiver attached are ignored")
    func levelsWithoutReceiverIgnored() {
        var state = ReceiverState()
        state.levelsChanged(readings: [speech, speech], elapsed: 0.1)

        #expect(state.connectedMicCount == 0)
    }

    @Test("reconnecting after an unplug starts the mic count from scratch")
    func reconnectStartsClean() {
        var state = ReceiverState()
        _ = state.devicesChanged(to: [dji()])
        state.levelsChanged(readings: [speech, speech], elapsed: 0.1)
        _ = state.devicesChanged(to: [builtIn])

        #expect(state.devicesChanged(to: [dji()]) == .connected)
        #expect(state.connectedMicCount == 0)
    }

    @Test("readiness requires a receiver with at least one live transmitter")
    func readinessToRecord() {
        var state = ReceiverState()
        #expect(!state.canRecord)

        _ = state.devicesChanged(to: [dji()])
        #expect(!state.canRecord)                                   // connected, but no lapel is on yet

        state.levelsChanged(readings: [selfNoise, digitalSilence], elapsed: 0.1)
        #expect(state.canRecord)
    }

    @Test("the status line names the state a user would want to read")
    func statusSummary() {
        var state = ReceiverState()
        #expect(state.statusSummary == "No receiver connected")

        _ = state.devicesChanged(to: [dji()])
        #expect(state.statusSummary == "DJI MIC MINI — no microphones detected")

        state.levelsChanged(readings: [selfNoise, digitalSilence], elapsed: 0.1)
        #expect(state.statusSummary == "DJI MIC MINI — 1 of 2 microphones live")

        state.levelsChanged(readings: [selfNoise, selfNoise], elapsed: 0.1)
        #expect(state.statusSummary == "DJI MIC MINI — 2 of 2 microphones live")
    }
}
