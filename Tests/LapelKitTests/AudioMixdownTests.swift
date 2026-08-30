import Testing
import Foundation
@testable import LapelKit

private func flat(_ value: Float, _ count: Int) -> [Float] {
    [Float](repeating: value, count: count)
}

@Suite("AudioMixdown")
struct AudioMixdownTests {

    @Test("two tracks sum sample by sample")
    func sumsTracks() {
        #expect(AudioMixdown.mix([[0.1, 0.2, 0.3], [0.2, 0.2, 0.2]]) == [0.3, 0.4, 0.5])
    }

    @Test("a shorter track is padded rather than truncating the longer one")
    func padsShorterTrack() {
        let mixed = AudioMixdown.mix([[0.1, 0.1, 0.1, 0.1], [0.2, 0.2]])

        #expect(mixed.count == 4)
        #expect(mixed == [0.3, 0.3, 0.1, 0.1])
    }

    @Test("a mix that stays inside the ceiling is left at full loudness")
    func quietMixIsUntouched() {
        // The common case: two people taking turns. Dividing by the track count here
        // would halve the volume of a recording that never actually clipped.
        let mixed = AudioMixdown.mix([flat(0.4, 8), flat(0.0, 8)])
        #expect(mixed == flat(0.4, 8))
    }

    @Test("a mix that would clip is scaled down to the ceiling")
    func loudMixIsScaledToCeiling() {
        let mixed = AudioMixdown.mix([flat(0.8, 8), flat(0.8, 8)])

        #expect(abs(mixed.max()! - AudioMixdown.ceiling) < 0.0001)
        #expect(mixed.allSatisfy { $0 <= 1.0 })
    }

    @Test("scaling is one gain across the whole mix, so balance is preserved")
    func scalingPreservesBalance() {
        let mixed = AudioMixdown.mix([[1.6, 0.8, 0.4], [0, 0, 0]])
        let ratios = [mixed[0] / mixed[1], mixed[1] / mixed[2]]

        #expect(abs(ratios[0] - 2) < 0.0001)
        #expect(abs(ratios[1] - 2) < 0.0001)
    }

    @Test("negative peaks are limited too, not just positive ones")
    func limitsNegativePeaks() {
        let mixed = AudioMixdown.mix([flat(-0.9, 4), flat(-0.9, 4)])

        #expect(abs(mixed.min()! + AudioMixdown.ceiling) < 0.0001)
        #expect(mixed.allSatisfy { $0 >= -1.0 })
    }

    @Test("a single track passes through, still protected by the ceiling")
    func singleTrack() {
        #expect(AudioMixdown.mix([[0.5, -0.5]]) == [0.5, -0.5])

        let hot = AudioMixdown.mix([[2.0, -1.0]])
        #expect(abs(hot[0] - AudioMixdown.ceiling) < 0.0001)
    }

    @Test("silence mixes to silence without dividing by zero")
    func allSilent() {
        let mixed = AudioMixdown.mix([flat(0, 4), flat(0, 4)])

        #expect(mixed == flat(0, 4))
        #expect(mixed.allSatisfy { $0.isFinite })
    }

    @Test("mixing nothing yields nothing")
    func emptyInput() {
        #expect(AudioMixdown.mix([]).isEmpty)
        #expect(AudioMixdown.mix([[], []]).isEmpty)
    }

    @Test("an empty track alongside a real one contributes nothing")
    func emptyTrackAlongsideReal() {
        #expect(AudioMixdown.mix([[0.1, 0.2], []]) == [0.1, 0.2])
    }

    @Test("the ceiling leaves a decibel of headroom below full scale")
    func ceilingHasHeadroom() {
        #expect(abs(LevelMeter.decibels(AudioMixdown.ceiling) - (-1.0)) < 0.01)
    }

    @Test("three tracks mix as readily as two")
    func threeTracks() {
        let mixed = AudioMixdown.mix([[0.1], [0.2], [0.3]])
        // Compared with a tolerance: exact equality on a sum of binary floats is a
        // statement about rounding, not about mixing.
        #expect(mixed.count == 1)
        #expect(abs(mixed[0] - 0.6) < 0.0001)
    }
}
