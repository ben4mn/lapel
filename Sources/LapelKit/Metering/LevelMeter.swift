import Accelerate
import Foundation

/// A single metering snapshot for one channel, in dBFS.
///
/// `peakDB` is a *held* peak that falls at a fixed rate rather than snapping back
/// to the instantaneous value — without that, a bar drawn at 60 fps from raw peaks
/// reads as noise rather than as a level.
public struct LevelReading: Equatable, Sendable {
    public let rmsDB: Float
    public let peakDB: Float

    public init(rmsDB: Float, peakDB: Float) {
        self.rmsDB = rmsDB
        self.peakDB = peakDB
    }

    /// A level within 0.1 dB of full scale is almost certainly a clipped converter.
    public var isClipping: Bool { peakDB >= -0.1 }

    public var rmsPosition: Float { Self.normalizedPosition(forDB: rmsDB) }
    public var peakPosition: Float { Self.normalizedPosition(forDB: peakDB) }

    public static let silent = LevelReading(rmsDB: LevelMeter.floorDB, peakDB: LevelMeter.floorDB)

    /// Maps dBFS onto `0...1` for drawing.
    ///
    /// The exponent biases pixels toward the loud end: conversational speech lives
    /// around -30 to -12 dBFS, and a straight linear-in-dB mapping pins that band
    /// uncomfortably high up the bar.
    public static func normalizedPosition(forDB db: Float) -> Float {
        let span = -LevelMeter.floorDB
        let t = min(max((db - LevelMeter.floorDB) / span, 0), 1)
        return pow(t, 1.6)
    }
}

/// Converts blocks of PCM samples into displayable levels.
///
/// Deliberately free of any CoreAudio or AVFoundation type so it can be exercised
/// with synthetic signals and exact arithmetic, no hardware attached.
public struct LevelMeter: Sendable {
    /// Levels below this are reported as this value rather than `-infinity`.
    public static let floorDB: Float = -80

    private let peakHoldDecayDBPerSecond: Float
    private var heldPeakDB: Float = LevelMeter.floorDB

    public init(peakHoldDecayDBPerSecond: Float = 20) {
        self.peakHoldDecayDBPerSecond = peakHoldDecayDBPerSecond
    }

    public mutating func process(_ samples: [Float], sampleRate: Double) -> LevelReading {
        guard !samples.isEmpty, sampleRate > 0 else {
            return LevelReading(rmsDB: Self.floorDB, peakDB: heldPeakDB)
        }

        var rms: Float = 0
        var peak: Float = 0
        samples.withUnsafeBufferPointer { buf in
            vDSP_rmsqv(buf.baseAddress!, 1, &rms, vDSP_Length(buf.count))
            vDSP_maxmgv(buf.baseAddress!, 1, &peak, vDSP_Length(buf.count))
        }

        let duration = Float(Double(samples.count) / sampleRate)
        heldPeakDB = max(heldPeakDB - peakHoldDecayDBPerSecond * duration, Self.floorDB)
        heldPeakDB = max(heldPeakDB, Self.decibels(peak))

        return LevelReading(rmsDB: Self.decibels(rms), peakDB: heldPeakDB)
    }

    /// Resets held state — call when a device disappears so a stale bar doesn't linger.
    public mutating func reset() {
        heldPeakDB = Self.floorDB
    }

    /// Amplitude to dBFS, floored and hardened against the NaN/inf a misbehaving
    /// driver can hand you mid-stream.
    static func decibels(_ amplitude: Float) -> Float {
        guard amplitude.isFinite, amplitude > 0 else { return floorDB }
        return max(20 * log10(amplitude), floorDB)
    }
}
