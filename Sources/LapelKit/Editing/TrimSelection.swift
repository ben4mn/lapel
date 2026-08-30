import Foundation

/// The portion of a recording the user has selected to keep.
///
/// Non-destructive: this describes an intent, and nothing is cut until export. The
/// recorded per-speaker files are never modified.
public struct TrimSelection: Equatable, Sendable {

    /// Short enough to be a deliberate choice, long enough to still be audio.
    public static let minimumLength: TimeInterval = 0.25

    public let duration: TimeInterval
    public private(set) var start: TimeInterval
    public private(set) var end: TimeInterval

    public init(duration: TimeInterval) {
        let safe = max(0, duration)
        self.duration = safe
        self.start = 0
        self.end = safe
    }

    /// The floor on selection length, relaxed for a recording too short to honour it.
    private var minimumLength: TimeInterval { min(Self.minimumLength, duration) }

    public mutating func setStart(_ time: TimeInterval) {
        // Clamped against the far handle rather than swapped: dragging past the other
        // handle should stop, not invert the selection under the user's cursor.
        start = min(max(0, time), max(0, end - minimumLength))
    }

    public mutating func setEnd(_ time: TimeInterval) {
        end = max(min(duration, time), min(duration, start + minimumLength))
    }

    public mutating func reset() {
        start = 0
        end = duration
    }

    public var isTrimmed: Bool { start > 0 || end < duration }
    public var selectedDuration: TimeInterval { max(0, end - start) }

    public func contains(_ time: TimeInterval) -> Bool { time >= start && time <= end }

    /// The selection as a fraction of the whole, for laying out over a waveform.
    public var startFraction: Double { duration > 0 ? start / duration : 0 }
    public var endFraction: Double { duration > 0 ? end / duration : 1 }
}
