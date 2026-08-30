import Testing
import Foundation
@testable import LapelKit

@Suite("WaveformSummary")
struct WaveformSummaryTests {

    @Test("the summary has exactly the number of bins asked for")
    func binCount() {
        let samples = (0..<10_000).map { Float(sin(Double($0) * 0.01)) }
        #expect(WaveformSummary.make(from: samples, sampleRate: 48_000, binCount: 200).bins.count == 200)
    }

    @Test("each bin holds the loudest magnitude in its slice")
    func binsHoldPeaks() {
        // Four samples into two bins: one quiet half, one loud half.
        let summary = WaveformSummary.make(from: [0.1, 0.2, 0.8, 0.3], sampleRate: 4, binCount: 2)

        #expect(summary.bins == [0.2, 0.8])
    }

    @Test("negative peaks count, since a waveform is symmetric")
    func negativePeaks() {
        let summary = WaveformSummary.make(from: [-0.9, 0.1], sampleRate: 2, binCount: 1)
        #expect(summary.bins == [0.9])
    }

    @Test("duration comes from the sample count and rate")
    func duration() {
        let summary = WaveformSummary.make(from: [Float](repeating: 0, count: 96_000), sampleRate: 48_000, binCount: 10)
        #expect(abs(summary.duration - 2.0) < 0.0001)
    }

    @Test("fewer samples than bins still yields the requested bins rather than crashing")
    func sparseSamples() {
        let summary = WaveformSummary.make(from: [0.5, 0.25], sampleRate: 48_000, binCount: 8)

        #expect(summary.bins.count == 8)
        #expect(summary.bins.allSatisfy { $0.isFinite })
        #expect(summary.bins.max() == 0.5)
    }

    @Test("no samples yields an empty summary, not a division by zero")
    func emptySamples() {
        let summary = WaveformSummary.make(from: [], sampleRate: 48_000, binCount: 100)

        #expect(summary.bins.isEmpty)
        #expect(summary.duration == 0)
    }

    @Test("a nonsensical bin count is refused rather than trusted")
    func invalidBinCount() {
        #expect(WaveformSummary.make(from: [0.5], sampleRate: 48_000, binCount: 0).bins.isEmpty)
        #expect(WaveformSummary.make(from: [0.5], sampleRate: 48_000, binCount: -3).bins.isEmpty)
    }

    @Test("normalising scales the loudest bin to full height so quiet takes stay readable")
    func normalisation() {
        let summary = WaveformSummary.make(from: [0.01, 0.02, 0.005, 0.001], sampleRate: 4, binCount: 2)

        #expect(summary.peak == 0.02)
        #expect(summary.normalizedBins.max() == 1.0)
        // Relative shape is preserved, only the scale changes.
        #expect(abs(summary.normalizedBins[0] - 1.0) < 0.0001)
        #expect(abs(summary.normalizedBins[1] - 0.25) < 0.0001)
    }

    @Test("a silent recording normalises to a flat line instead of dividing by zero")
    func silentNormalisation() {
        let summary = WaveformSummary.make(from: [Float](repeating: 0, count: 100), sampleRate: 48_000, binCount: 10)

        #expect(summary.peak == 0)
        #expect(summary.normalizedBins == [Float](repeating: 0, count: 10))
    }

    @Test("a bin index maps back to the time it represents")
    func timeForBin() {
        let summary = WaveformSummary.make(from: [Float](repeating: 0, count: 48_000), sampleRate: 48_000, binCount: 10)

        #expect(abs(summary.time(atBin: 0) - 0) < 0.0001)
        #expect(abs(summary.time(atBin: 5) - 0.5) < 0.0001)
        #expect(abs(summary.time(atBin: 10) - 1.0) < 0.0001)
    }
}

@Suite("TrimSelection")
struct TrimSelectionTests {

    @Test("a new selection covers the whole recording")
    func defaultsToFullRange() {
        let trim = TrimSelection(duration: 60)

        #expect(trim.start == 0)
        #expect(trim.end == 60)
        #expect(!trim.isTrimmed)
        #expect(trim.selectedDuration == 60)
    }

    @Test("the start cannot be dragged before the beginning")
    func startClampsAtZero() {
        var trim = TrimSelection(duration: 60)
        trim.setStart(-10)
        #expect(trim.start == 0)
    }

    @Test("the end cannot be dragged past the end of the audio")
    func endClampsAtDuration() {
        var trim = TrimSelection(duration: 60)
        trim.setEnd(999)
        #expect(trim.end == 60)
    }

    @Test("the handles cannot cross, leaving at least a usable sliver selected")
    func handlesCannotCross() {
        var trim = TrimSelection(duration: 60)
        trim.setEnd(10)
        trim.setStart(30)

        #expect(trim.start < trim.end)
        #expect(abs(trim.selectedDuration - TrimSelection.minimumLength) < 0.0001)
    }

    @Test("dragging the end below the start is clamped the same way")
    func endCannotPassStart() {
        var trim = TrimSelection(duration: 60)
        trim.setStart(30)
        trim.setEnd(5)

        #expect(trim.end > trim.start)
        #expect(abs(trim.selectedDuration - TrimSelection.minimumLength) < 0.0001)
    }

    @Test("any adjustment marks the selection as trimmed")
    func isTrimmedTracksEdits() {
        var trim = TrimSelection(duration: 60)
        trim.setStart(1)
        #expect(trim.isTrimmed)

        trim.reset()
        #expect(!trim.isTrimmed)
        #expect(trim.start == 0 && trim.end == 60)
    }

    @Test("times inside the selection are recognised, and those outside are not")
    func containsTime() {
        var trim = TrimSelection(duration: 60)
        trim.setStart(10)
        trim.setEnd(20)

        #expect(trim.contains(15))
        #expect(!trim.contains(5))
        #expect(!trim.contains(25))
    }

    @Test("a recording shorter than the minimum selection is handled without inverting")
    func degenerateDuration() {
        var trim = TrimSelection(duration: 0.1)
        trim.setStart(0.09)

        #expect(trim.start >= 0)
        #expect(trim.end <= 0.1)
        #expect(trim.start <= trim.end)
    }
}
