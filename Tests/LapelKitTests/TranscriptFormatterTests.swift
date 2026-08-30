import Testing
import Foundation
@testable import LapelKit

private func turns(_ items: [(String, Int, Double, Double, String)]) -> Transcript {
    Transcript(turns: items.map {
        TranscriptTurn(speaker: $0.0, channelIndex: $0.1, start: $0.2, end: $0.3, text: $0.4)
    })
}

private let named = turns([
    ("Ben", 0, 0.0, 2.5, "morning"),
    ("Dana", 1, 3.0, 6.25, "morning to you"),
])

private let unnamed = turns([
    ("TX1", 0, 0.0, 2.0, "one"),
    ("TX2", 1, 3.0, 5.0, "two"),
])

@Suite("SpeakerLabeling")
struct SpeakerLabelingTests {

    @Test("names the user typed are used as written")
    func usesRealNames() {
        #expect(SpeakerLabeling.names.label(for: named.turns[0]) == "Ben")
        #expect(SpeakerLabeling.names.label(for: named.turns[1]) == "Dana")
    }

    @Test("an unnamed track falls back to a numbered speaker, not its transmitter label")
    func fallsBackToNumbered() {
        // 'TX1: hello' is a hardware label leaking into a document meant to be read.
        #expect(SpeakerLabeling.names.label(for: unnamed.turns[0]) == "Speaker 1")
        #expect(SpeakerLabeling.names.label(for: unnamed.turns[1]) == "Speaker 2")
    }

    @Test("an empty speaker name also falls back")
    func emptyNameFallsBack() {
        let turn = TranscriptTurn(speaker: "", channelIndex: 0, start: 0, end: 1, text: "x")
        #expect(SpeakerLabeling.names.label(for: turn) == "Speaker 1")
    }

    @Test("numbered labelling overrides real names, for sharing a transcript anonymously")
    func numberedOverridesNames() {
        #expect(SpeakerLabeling.numbered.label(for: named.turns[0]) == "Speaker 1")
        #expect(SpeakerLabeling.numbered.label(for: named.turns[1]) == "Speaker 2")
    }

    @Test("speaker numbers follow the channel, so a person keeps one label throughout")
    func numbersFollowChannel() {
        let later = TranscriptTurn(speaker: "Dana", channelIndex: 1, start: 90, end: 92, text: "again")
        #expect(SpeakerLabeling.numbered.label(for: later) == "Speaker 2")
    }
}

@Suite("TranscriptFormatter")
struct TranscriptFormatterTests {

    @Test("plain text reads as an attributed script")
    func plainText() {
        let text = TranscriptFormatter.plainText(named, labeling: .names)
        #expect(text == "Ben: morning\nDana: morning to you")
    }

    @Test("plain text can carry timecodes for following along with the audio")
    func plainTextTimestamped() {
        let text = TranscriptFormatter.plainText(named, labeling: .names, includeTimecodes: true)
        #expect(text == "[00:00] Ben: morning\n[00:03] Dana: morning to you")
    }

    @Test("numbered labelling anonymises the whole document")
    func plainTextNumbered() {
        let text = TranscriptFormatter.plainText(named, labeling: .numbered)
        #expect(text == "Speaker 1: morning\nSpeaker 2: morning to you")
    }

    @Test("markdown carries a title and bolds each speaker")
    func markdown() {
        let text = TranscriptFormatter.markdown(named, title: "Kickoff", labeling: .names)

        #expect(text.hasPrefix("# Kickoff\n"))
        #expect(text.contains("**Ben**"))
        #expect(text.contains("`00:03`"))
    }

    @Test("SRT numbers its cues from one and uses comma milliseconds")
    func srt() {
        let text = TranscriptFormatter.srt(named, labeling: .names)

        #expect(text == """
        1
        00:00:00,000 --> 00:00:02,500
        Ben: morning

        2
        00:00:03,000 --> 00:00:06,250
        Dana: morning to you
        """)
    }

    @Test("SRT timecodes keep an hours field even under an hour, as the format requires")
    func srtTimecodeFormat() {
        #expect(TranscriptFormatter.srtTimecode(0) == "00:00:00,000")
        #expect(TranscriptFormatter.srtTimecode(65.5) == "00:01:05,500")
        #expect(TranscriptFormatter.srtTimecode(3_725.125) == "01:02:05,125")
    }

    @Test("a cue with no duration is given a readable minimum rather than a zero-length flash")
    func zeroLengthCue() {
        let instant = turns([("Ben", 0, 4.0, 4.0, "hm")])
        let text = TranscriptFormatter.srt(instant, labeling: .names)

        #expect(text.contains("00:00:04,000 --> 00:00:05,000"))
    }

    @Test("an empty transcript formats to an empty document, not to junk")
    func emptyTranscript() {
        let empty = Transcript(turns: [])

        #expect(TranscriptFormatter.plainText(empty, labeling: .names).isEmpty)
        #expect(TranscriptFormatter.srt(empty, labeling: .names).isEmpty)
        #expect(TranscriptFormatter.markdown(empty, title: "Nothing", labeling: .names).contains("# Nothing"))
    }

    @Test("each format declares the file extension it should be written with")
    func fileExtensions() {
        #expect(TranscriptFormat.plainText.fileExtension == "txt")
        #expect(TranscriptFormat.markdown.fileExtension == "md")
        #expect(TranscriptFormat.srt.fileExtension == "srt")
    }

    @Test("formatting dispatches on the chosen format")
    func formatDispatch() {
        #expect(TranscriptFormat.srt.render(named, title: "T", labeling: .names).hasPrefix("1\n"))
        #expect(TranscriptFormat.markdown.render(named, title: "T", labeling: .names).hasPrefix("# T"))
        #expect(TranscriptFormat.plainText.render(named, title: "T", labeling: .names).hasPrefix("Ben:"))
    }
}
