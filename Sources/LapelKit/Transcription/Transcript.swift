import Foundation

/// One recognised stretch of speech on one track.
public struct TranscriptSegment: Codable, Equatable, Sendable {
    public var speaker: String
    public var channelIndex: Int
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String

    public init(speaker: String, channelIndex: Int, start: TimeInterval, end: TimeInterval, text: String) {
        self.speaker = speaker
        self.channelIndex = channelIndex
        self.start = start
        self.end = end
        self.text = text
    }
}

/// A contiguous run of speech from one person — what a reader thinks of as a line.
public struct TranscriptTurn: Codable, Equatable, Sendable, Identifiable {
    public var id: String { "\(channelIndex)-\(start)" }

    public var speaker: String
    public var channelIndex: Int
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String

    public var duration: TimeInterval { max(0, end - start) }

    /// True when both people were talking at once — worth showing, since it is
    /// invisible in a single-track recording.
    public func overlaps(_ other: TranscriptTurn) -> Bool {
        start < other.end && other.start < end
    }
}

/// The conversation, reassembled.
///
/// Each speaker is transcribed from their own file, which is what makes attribution
/// exact rather than guessed. Putting them back in order is this type's job.
public struct Transcript: Codable, Equatable, Sendable {

    public var turns: [TranscriptTurn]

    public init(turns: [TranscriptTurn]) { self.turns = turns }

    public var isEmpty: Bool { turns.isEmpty }

    /// Interleaves per-track segments into one chronological script.
    ///
    /// - Parameter maximumGap: how long one speaker may pause before their next
    ///   segment counts as a new turn. Without this, a transcriber that emits a
    ///   segment per phrase produces a wall of one-line entries.
    public static func merge(_ perTrack: [[TranscriptSegment]], maximumGap: TimeInterval = 2.0) -> Transcript {
        let ordered = perTrack
            .flatMap { $0 }
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }

        var turns: [TranscriptTurn] = []
        for segment in ordered {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)

            // Continues the previous turn only if it is the *same* speaker and the
            // pause was short. A different speaker in between always starts a turn,
            // which is what keeps an interjection from being swallowed.
            if var last = turns.last,
               last.channelIndex == segment.channelIndex,
               segment.start - last.end <= maximumGap {
                last.text += " " + text
                last.end = max(last.end, segment.end)
                turns[turns.count - 1] = last
                continue
            }

            turns.append(TranscriptTurn(
                speaker: segment.speaker,
                channelIndex: segment.channelIndex,
                start: segment.start,
                end: segment.end,
                text: text
            ))
        }
        return Transcript(turns: turns)
    }

    /// `Ben: morning`, one line per turn.
    public var plainText: String {
        turns.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
    }

    /// `[01:05] Ben: still here`
    public var timestampedText: String {
        turns.map { "[\(Self.timecode($0.start))] \($0.speaker): \($0.text)" }.joined(separator: "\n")
    }

    /// How long each person spoke — the number people actually want from a
    /// two-microphone recording.
    public var speakingTime: [String: TimeInterval] {
        turns.reduce(into: [:]) { totals, turn in
            totals[turn.speaker, default: 0] += turn.duration
        }
    }

    /// `mm:ss`, growing an hours field only when the recording needs one.
    public static func timecode(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%02d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }
}
