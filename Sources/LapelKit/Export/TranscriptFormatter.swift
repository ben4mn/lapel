import Foundation

/// How speakers are named in an exported transcript.
public enum SpeakerLabeling: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Use the names typed against each track, falling back to a numbered label.
    case names
    /// Always numbered, for sharing a transcript without naming anyone.
    case numbered

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .names: "Speaker names"
        case .numbered: "Speaker 1, Speaker 2…"
        }
    }

    public func label(for turn: TranscriptTurn) -> String {
        // Numbers follow the channel, not the order of appearance, so one person
        // keeps one label from the first word to the last.
        let numbered = "Speaker \(turn.channelIndex + 1)"
        guard self == .names else { return numbered }

        let name = turn.speaker.trimmingCharacters(in: .whitespaces)
        // "TX1: hello" is a hardware label leaking into a document meant to be read,
        // so an unnamed track is numbered even in .names mode.
        guard !name.isEmpty, !Self.isTransmitterLabel(name) else { return numbered }
        return name
    }

    static func isTransmitterLabel(_ name: String) -> Bool {
        let lowered = name.lowercased()
        guard lowered.hasPrefix("tx") else { return lowered == "mixed" }
        return lowered.dropFirst(2).allSatisfy(\.isNumber)
    }
}

public enum TranscriptFormat: String, Codable, Sendable, CaseIterable, Identifiable {
    case plainText, markdown, srt

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .plainText: "txt"
        case .markdown: "md"
        case .srt: "srt"
        }
    }

    public var displayName: String {
        switch self {
        case .plainText: "Plain text (.txt)"
        case .markdown: "Markdown (.md)"
        case .srt: "Subtitles (.srt)"
        }
    }

    public func render(_ transcript: Transcript, title: String, labeling: SpeakerLabeling) -> String {
        switch self {
        case .plainText: TranscriptFormatter.plainText(transcript, labeling: labeling)
        case .markdown: TranscriptFormatter.markdown(transcript, title: title, labeling: labeling)
        case .srt: TranscriptFormatter.srt(transcript, labeling: labeling)
        }
    }
}

/// Renders a merged transcript into the documents people actually want.
public enum TranscriptFormatter {

    /// An SRT cue this short would flash by unread, so zero-length turns are given
    /// a floor.
    static let minimumCueDuration: TimeInterval = 1.0

    public static func plainText(
        _ transcript: Transcript,
        labeling: SpeakerLabeling,
        includeTimecodes: Bool = false
    ) -> String {
        transcript.turns.map { turn in
            let prefix = includeTimecodes ? "[\(Transcript.timecode(turn.start))] " : ""
            return "\(prefix)\(labeling.label(for: turn)): \(turn.text)"
        }.joined(separator: "\n")
    }

    public static func markdown(_ transcript: Transcript, title: String, labeling: SpeakerLabeling) -> String {
        var lines = ["# \(title)", ""]
        for turn in transcript.turns {
            lines.append("`\(Transcript.timecode(turn.start))` **\(labeling.label(for: turn))**: \(turn.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    /// SRT pairs naturally with the mixed-down audio: one file to listen to, one to
    /// read along with, and any player will line them up.
    public static func srt(_ transcript: Transcript, labeling: SpeakerLabeling) -> String {
        transcript.turns.enumerated().map { index, turn in
            let end = max(turn.end, turn.start + minimumCueDuration)
            return """
            \(index + 1)
            \(srtTimecode(turn.start)) --> \(srtTimecode(end))
            \(labeling.label(for: turn)): \(turn.text)
            """
        }.joined(separator: "\n\n")
    }

    /// `HH:MM:SS,mmm` — SRT requires the hours field even for short recordings, and
    /// a comma rather than a point before the milliseconds.
    public static func srtTimecode(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        let whole = Int(clamped)
        let milliseconds = Int(((clamped - Double(whole)) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", whole / 3600, (whole % 3600) / 60, whole % 60, milliseconds)
    }
}
