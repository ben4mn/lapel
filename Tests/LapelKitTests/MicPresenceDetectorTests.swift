import Testing
import Foundation
@testable import LapelKit

/// A channel carrying nothing at all — the receiver emits true digital zero on a
/// channel whose transmitter is off or unlinked.
private let digitalSilence = LevelReading(rmsDB: LevelMeter.floorDB, peakDB: LevelMeter.floorDB)
/// A linked transmitter sitting quiet still sends its own self-noise.
private let selfNoise = LevelReading(rmsDB: -64, peakDB: -58)
private let speech = LevelReading(rmsDB: -22, peakDB: -14)

@Suite("MicPresenceDetector")
struct MicPresenceDetectorTests {

    @Test("before any audio arrives no microphones are reported")
    func startsWithNothingConnected() {
        let detector = MicPresenceDetector(channelCount: 2)
        #expect(detector.presences == [.absent, .absent])
        #expect(detector.connectedMicCount == 0)
    }

    @Test("self-noise alone marks a transmitter as present but idle")
    func selfNoiseMeansPresent() {
        var detector = MicPresenceDetector(channelCount: 2)
        detector.update(readings: [selfNoise, digitalSilence], elapsed: 0.1)

        #expect(detector.presences == [.idle, .absent])
        #expect(detector.connectedMicCount == 1)
    }

    @Test("presence is recognised on the very first buffer, without waiting")
    func presenceIsImmediate() {
        var detector = MicPresenceDetector(channelCount: 2)
        detector.update(readings: [selfNoise, selfNoise], elapsed: 0.01)

        #expect(detector.connectedMicCount == 2)
    }

    @Test("audio above the speech threshold reports the channel as speaking")
    func speechIsDetected() {
        var detector = MicPresenceDetector(channelCount: 2)
        detector.update(readings: [speech, selfNoise], elapsed: 0.1)

        #expect(detector.presences == [.speaking, .idle])
        #expect(detector.speakingChannels == [0])
    }

    @Test("speaking is held briefly through the natural gaps between words")
    func speechHangover() {
        var detector = MicPresenceDetector(channelCount: 1, configuration: .init(silenceHangoverSeconds: 0.4))
        detector.update(readings: [speech], elapsed: 0.1)
        detector.update(readings: [selfNoise], elapsed: 0.2)

        #expect(detector.presences == [.speaking])
    }

    @Test("once the gap outlasts the hangover the channel falls back to idle")
    func speechReleasesAfterHangover() {
        var detector = MicPresenceDetector(channelCount: 1, configuration: .init(silenceHangoverSeconds: 0.4))
        detector.update(readings: [speech], elapsed: 0.1)
        detector.update(readings: [selfNoise], elapsed: 0.5)

        #expect(detector.presences == [.idle])
    }

    @Test("a brief dropout does not make a connected transmitter flicker to absent")
    func absenceRequiresConfirmation() {
        var detector = MicPresenceDetector(channelCount: 1, configuration: .init(absenceConfirmationSeconds: 1.5))
        detector.update(readings: [selfNoise], elapsed: 0.1)
        detector.update(readings: [digitalSilence], elapsed: 1.0)

        #expect(detector.presences == [.idle])
        #expect(detector.connectedMicCount == 1)
    }

    @Test("sustained digital silence eventually confirms the transmitter is gone")
    func absenceIsConfirmedAfterWindow() {
        var detector = MicPresenceDetector(channelCount: 1, configuration: .init(absenceConfirmationSeconds: 1.5))
        detector.update(readings: [selfNoise], elapsed: 0.1)
        detector.update(readings: [digitalSilence], elapsed: 1.0)
        detector.update(readings: [digitalSilence], elapsed: 0.6)

        #expect(detector.presences == [.absent])
        #expect(detector.connectedMicCount == 0)
    }

    @Test("a transmitter switched back on is picked up again immediately")
    func recoversAfterAbsence() {
        var detector = MicPresenceDetector(channelCount: 1)
        detector.update(readings: [digitalSilence], elapsed: 5.0)
        #expect(detector.presences == [.absent])

        detector.update(readings: [selfNoise], elapsed: 0.1)
        #expect(detector.presences == [.idle])
    }

    @Test("missing readings age a channel toward absent instead of crashing")
    func toleratesShortReadingArray() {
        var detector = MicPresenceDetector(channelCount: 2)
        detector.update(readings: [selfNoise, selfNoise], elapsed: 0.1)
        detector.update(readings: [selfNoise], elapsed: 5.0)

        #expect(detector.presences == [.idle, .absent])
    }

    @Test("surplus readings beyond the channel count are ignored")
    func toleratesLongReadingArray() {
        var detector = MicPresenceDetector(channelCount: 1)
        detector.update(readings: [selfNoise, speech, speech], elapsed: 0.1)

        #expect(detector.presences == [.idle])
    }

    @Test("resetting clears presence so a unplugged receiver leaves no stale count")
    func resetClearsState() {
        var detector = MicPresenceDetector(channelCount: 2)
        detector.update(readings: [speech, speech], elapsed: 0.1)
        detector.reset()

        #expect(detector.connectedMicCount == 0)
        #expect(detector.presences == [.absent, .absent])
    }

    @Test("idle and speaking both count as a connected microphone")
    func connectedCountIncludesIdle() {
        #expect(MicPresence.idle.isConnected)
        #expect(MicPresence.speaking.isConnected)
        #expect(!MicPresence.absent.isConnected)
    }
}
