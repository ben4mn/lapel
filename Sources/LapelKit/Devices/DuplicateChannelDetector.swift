import Accelerate
import Foundation

/// Notices when a receiver is sending one mix down two channels.
///
/// The channel count cannot answer this. A real DJI Mic Mini in M (Mono) mode still
/// enumerates as a two-channel USB device and streams the same mixed audio to both
/// channels — so a receiver that reports "stereo" can still be incapable of
/// separating speakers. The audio is the only honest witness.
///
/// Silence is deliberately not evidence. Two channels carrying digital zero are
/// identical, but that is what a correctly configured stereo receiver looks like
/// with both lapels switched off, and accusing it of mono would be wrong.
/// What the audio has actually shown about whether the two channels differ.
public enum ChannelSeparation: Equatable, Sendable {
    /// Not enough signal yet to say. Never treat this as good news.
    case unknown
    /// Both channels carry the same mix — speakers cannot be separated.
    case identical
    /// The channels genuinely differ, so each transmitter is on its own track.
    case independent
}

public struct DuplicateChannelDetector: Sendable {

    /// Two copies of one mix can differ in the last bit or two. Anything below this
    /// is not a second microphone.
    static let epsilon: Float = 1e-6
    /// A block quieter than this proves nothing either way.
    static let silenceThreshold: Float = 1e-4

    private let confirmationSeconds: TimeInterval
    private var identicalFor: TimeInterval = 0

    public init(confirmationSeconds: TimeInterval = 1.5) {
        self.confirmationSeconds = confirmationSeconds
    }

    public private(set) var isDuplicated = false
    /// Set once a block carrying signal has shown the channels differing. One such
    /// block is proof; no amount of silence is.
    private var hasSeenDivergence = false

    public var separation: ChannelSeparation {
        if isDuplicated { return .identical }
        return hasSeenDivergence ? .independent : .unknown
    }

    public mutating func update(channels: [[Float]], elapsed: TimeInterval) {
        guard channels.count >= 2 else { return }
        let left = channels[0], right = channels[1]
        guard left.count == right.count, !left.isEmpty else { return }

        guard peak(left) > Self.silenceThreshold, peak(right) > Self.silenceThreshold else {
            return   // no signal to compare; hold the current verdict
        }

        var difference = [Float](repeating: 0, count: left.count)
        vDSP_vsub(right, 1, left, 1, &difference, 1, vDSP_Length(left.count))

        if peak(difference) <= Self.epsilon {
            hasSeenDivergence = false
            identicalFor += elapsed
            // Confirmed only after sustained agreement: two people can briefly make
            // near-identical noise, but not sample-for-sample and not for seconds.
            if identicalFor >= confirmationSeconds { isDuplicated = true }
        } else {
            // One divergent block is proof the channels are independent, so the
            // finding is dropped at once rather than aged out.
            identicalFor = 0
            isDuplicated = false
            hasSeenDivergence = true
        }
    }

    public mutating func reset() {
        identicalFor = 0
        isDuplicated = false
        hasSeenDivergence = false
    }

    private func peak(_ samples: [Float]) -> Float {
        var value: Float = 0
        samples.withUnsafeBufferPointer { vDSP_maxmgv($0.baseAddress!, 1, &value, vDSP_Length($0.count)) }
        return value
    }
}
