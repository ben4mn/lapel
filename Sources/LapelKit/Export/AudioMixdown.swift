import Accelerate
import Foundation

/// Sums per-speaker tracks back into one listenable file.
///
/// Pure arithmetic over `[Float]` so the clipping behaviour is provable rather than
/// judged by ear.
public enum AudioMixdown {

    /// -1 dBFS. A decibel of headroom, so an encoder's own overshoot on the way to
    /// AAC cannot push a sample past full scale.
    public static let ceiling: Float = 0.891_251

    /// Mixes tracks to mono, limiting only if the sum would actually clip.
    ///
    /// Deliberately *not* an average. Dividing by the track count is the textbook
    /// answer and it is wrong here: two people taking turns is the normal case, and
    /// in that case only one track is loud at any instant, so averaging would halve
    /// the volume of a recording that never came close to clipping. Instead the sum
    /// is taken at full weight and a single gain is applied across the whole mix
    /// only if its peak exceeds the ceiling — which preserves both the loudness and
    /// the relative balance between speakers.
    public static func mix(_ tracks: [[Float]]) -> [Float] {
        let frames = tracks.map(\.count).max() ?? 0
        guard frames > 0 else { return [] }

        var sum = [Float](repeating: 0, count: frames)
        for track in tracks where !track.isEmpty {
            // Shorter tracks are zero-padded: a speaker who stopped early must not
            // truncate the person still talking.
            track.withUnsafeBufferPointer { source in
                sum.withUnsafeMutableBufferPointer { destination in
                    vDSP_vadd(destination.baseAddress!, 1, source.baseAddress!, 1,
                              destination.baseAddress!, 1, vDSP_Length(track.count))
                }
            }
        }

        var peak: Float = 0
        sum.withUnsafeBufferPointer { vDSP_maxmgv($0.baseAddress!, 1, &peak, vDSP_Length(frames)) }
        guard peak > ceiling else { return sum }

        var gain = ceiling / peak
        vDSP_vsmul(sum, 1, &gain, &sum, 1, vDSP_Length(frames))
        return sum
    }

    /// Takes the samples between two times, clamped to what actually exists.
    ///
    /// Out-of-range bounds are clamped rather than rejected: a trim handle dragged
    /// to the very edge should export the edge, not fail.
    public static func slice(
        _ samples: [Float],
        from start: TimeInterval,
        to end: TimeInterval,
        sampleRate: Double
    ) -> [Float] {
        guard !samples.isEmpty, sampleRate > 0 else { return [] }

        let first = min(max(0, Int((start * sampleRate).rounded())), samples.count)
        let last = min(max(0, Int((end * sampleRate).rounded())), samples.count)
        guard first < last else { return [] }

        return Array(samples[first..<last])
    }
}
