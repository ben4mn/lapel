import Accelerate
import Foundation

/// A drawable reduction of an audio file: one peak magnitude per horizontal pixel.
///
/// A minute of speech is nearly three million samples and a waveform view is a few
/// hundred points wide, so the reduction happens once, off the main thread, rather
/// than inside a redraw.
public struct WaveformSummary: Equatable, Sendable {

    /// Peak magnitude per bin, in the sample domain (0…1 for unclipped audio).
    public let bins: [Float]
    public let duration: TimeInterval

    public init(bins: [Float], duration: TimeInterval) {
        self.bins = bins
        self.duration = duration
    }

    public static let empty = WaveformSummary(bins: [], duration: 0)

    public static func make(from samples: [Float], sampleRate: Double, binCount: Int) -> WaveformSummary {
        guard binCount > 0, !samples.isEmpty, sampleRate > 0 else { return .empty }

        let duration = Double(samples.count) / sampleRate
        var bins = [Float](repeating: 0, count: binCount)

        samples.withUnsafeBufferPointer { buffer in
            for bin in 0..<binCount {
                let from = samples.count * bin / binCount
                let to = samples.count * (bin + 1) / binCount
                // With fewer samples than bins, several bins map to the same empty
                // slice. They stay at zero rather than reading out of bounds.
                guard from < to else { continue }

                var peak: Float = 0
                vDSP_maxmgv(buffer.baseAddress! + from, 1, &peak, vDSP_Length(to - from))
                bins[bin] = peak
            }
        }

        return WaveformSummary(bins: bins, duration: duration)
    }

    public var peak: Float { bins.max() ?? 0 }

    /// Bins scaled so the loudest reaches full height. A lapel recording at a sane
    /// level peaks around -12 dBFS, and drawing that raw wastes three quarters of
    /// the view.
    public var normalizedBins: [Float] {
        guard peak > 0 else { return bins }
        return bins.map { $0 / peak }
    }

    /// The time a bin boundary represents, for placing a playhead or a trim handle.
    public func time(atBin index: Int) -> TimeInterval {
        guard !bins.isEmpty else { return 0 }
        return duration * Double(index) / Double(bins.count)
    }
}
