import Testing
import Foundation
@testable import LapelKit

private func seg(_ speaker: String, _ channel: Int, _ start: Double, _ end: Double, _ text: String) -> TranscriptSegment {
    TranscriptSegment(speaker: speaker, channelIndex: channel, start: start, end: end, text: text)
}

@Suite("Transcript")
struct TranscriptTests {

    @Test("two speakers' segments interleave in the order they were spoken")
    func interleavesByTime() {
        let transcript = Transcript.merge([
            [seg("Ben", 0, 0.0, 1.0, "morning"), seg("Ben", 0, 4.0, 5.0, "sounds good")],
            [seg("Dana", 1, 2.0, 3.0, "morning to you")],
        ])

        #expect(transcript.turns.map(\.speaker) == ["Ben", "Dana", "Ben"])
        #expect(transcript.turns.map(\.text) == ["morning", "morning to you", "sounds good"])
    }

    @Test("consecutive segments from one speaker collapse into a single turn")
    func mergesConsecutiveSegments() {
        let transcript = Transcript.merge([
            [seg("Ben", 0, 0.0, 1.0, "so the thing is"),
             seg("Ben", 0, 1.2, 2.0, "we shipped it")],
        ])

        #expect(transcript.turns.count == 1)
        #expect(transcript.turns[0].text == "so the thing is we shipped it")
        #expect(transcript.turns[0].start == 0.0)
        #expect(transcript.turns[0].end == 2.0)
    }

    @Test("a long pause breaks one speaker's run into separate turns")
    func longPauseBreaksTurn() {
        let transcript = Transcript.merge([
            [seg("Ben", 0, 0.0, 1.0, "one"), seg("Ben", 0, 30.0, 31.0, "two")]
        ], maximumGap: 2.0)

        #expect(transcript.turns.count == 2)
        #expect(transcript.turns.map(\.text) == ["one", "two"])
    }

    @Test("overlapping speech keeps both turns, ordered by who started first")
    func overlappingSpeechIsPreserved() {
        let transcript = Transcript.merge([
            [seg("Ben", 0, 0.0, 5.0, "I was going to say")],
            [seg("Dana", 1, 3.0, 6.0, "sorry, go ahead")],
        ])

        #expect(transcript.turns.count == 2)
        #expect(transcript.turns.map(\.speaker) == ["Ben", "Dana"])
        #expect(transcript.turns[0].overlaps(transcript.turns[1]))
    }

    @Test("a track with no speech contributes nothing")
    func emptyTrackIgnored() {
        let transcript = Transcript.merge([[seg("Ben", 0, 0, 1, "hello")], []])
        #expect(transcript.turns.count == 1)
    }

    @Test("merging nothing yields an empty transcript rather than nil")
    func mergingNothing() {
        #expect(Transcript.merge([]).turns.isEmpty)
        #expect(Transcript.merge([[], []]).isEmpty)
    }

    @Test("blank segments are dropped so the transcript has no empty turns")
    func dropsBlankSegments() {
        let transcript = Transcript.merge([[
            seg("Ben", 0, 0, 1, "  "), seg("Ben", 0, 1, 2, ""), seg("Ben", 0, 2, 3, "real words"),
        ]])

        #expect(transcript.turns.count == 1)
        #expect(transcript.turns[0].text == "real words")
    }

    @Test("plain text reads as a script, one attributed line per turn")
    func plainTextFormat() {
        let transcript = Transcript.merge([
            [seg("Ben", 0, 0.0, 1.0, "morning")],
            [seg("Dana", 1, 2.0, 3.0, "morning")],
        ])

        #expect(transcript.plainText == "Ben: morning\nDana: morning")
    }

    @Test("timestamped text prefixes each turn with its start time")
    func timestampedFormat() {
        let transcript = Transcript.merge([[seg("Ben", 0, 65.0, 70.0, "still here")]])
        #expect(transcript.timestampedText == "[01:05] Ben: still here")
    }

    @Test("timestamps carry an hours field once a recording passes an hour")
    func longRecordingTimestamps() {
        let transcript = Transcript.merge([[seg("Ben", 0, 3_725, 3_730, "long meeting")]])
        #expect(transcript.timestampedText == "[01:02:05] Ben: long meeting")
    }

    @Test("speaking time per speaker is totalled from their turns")
    func speakingTime() {
        let transcript = Transcript.merge([
            [seg("Ben", 0, 0.0, 10.0, "a")],
            [seg("Dana", 1, 12.0, 15.0, "b")],
        ])

        #expect(transcript.speakingTime["Ben"] == 10.0)
        #expect(transcript.speakingTime["Dana"] == 3.0)
    }

    @Test("a transcript survives a JSON round trip")
    func codableRoundTrip() throws {
        let transcript = Transcript.merge([
            [seg("Ben", 0, 0.0, 1.0, "hello")],
            [seg("Dana", 1, 2.0, 3.0, "hi")],
        ])

        let data = try JSONEncoder().encode(transcript)
        #expect(try JSONDecoder().decode(Transcript.self, from: data) == transcript)
    }
}
