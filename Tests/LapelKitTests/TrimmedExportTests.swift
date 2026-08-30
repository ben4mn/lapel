import Testing
import AVFoundation
import Foundation
@testable import LapelKit

private func turn(_ speaker: String, _ channel: Int, _ start: Double, _ end: Double, _ text: String) -> TranscriptTurn {
    TranscriptTurn(speaker: speaker, channelIndex: channel, start: start, end: end, text: text)
}

@Suite("Transcript trimming")
struct TranscriptTrimTests {

    private let transcript = Transcript(turns: [
        turn("Ben", 0, 0, 4, "before the good bit"),
        turn("Dana", 1, 10, 14, "the good bit"),
        turn("Ben", 0, 16, 20, "still good"),
        turn("Dana", 1, 40, 44, "after the good bit"),
    ])

    @Test("turns outside the selection are dropped")
    func dropsOutsideTurns() {
        var trim = TrimSelection(duration: 50)
        trim.setStart(8)
        trim.setEnd(24)

        #expect(transcript.trimmed(to: trim).turns.map(\.text) == ["the good bit", "still good"])
    }

    @Test("times are rebased so the transcript lines up with the trimmed audio")
    func rebasesTimes() {
        var trim = TrimSelection(duration: 50)
        trim.setStart(8)
        trim.setEnd(24)
        let trimmed = transcript.trimmed(to: trim)

        // The turn that began at 10s starts 2s into a clip that begins at 8s.
        #expect(abs(trimmed.turns[0].start - 2) < 0.0001)
        #expect(abs(trimmed.turns[0].end - 6) < 0.0001)
    }

    @Test("a turn straddling the cut is kept and clipped to the selection")
    func clipsStraddlingTurns() {
        var trim = TrimSelection(duration: 50)
        trim.setStart(12)
        trim.setEnd(18)
        let trimmed = transcript.trimmed(to: trim)

        // Someone mid-sentence at the cut still said something inside the clip.
        #expect(trimmed.turns.count == 2)
        #expect(trimmed.turns[0].start == 0)
        #expect(abs(trimmed.turns[0].end - 2) < 0.0001)
    }

    @Test("an untrimmed selection leaves the transcript exactly as it was")
    func untrimmedIsIdentity() {
        #expect(transcript.trimmed(to: TrimSelection(duration: 50)) == transcript)
    }

    @Test("a selection covering no speech yields an empty transcript, not nil")
    func selectionWithNoSpeech() {
        var trim = TrimSelection(duration: 50)
        trim.setStart(30)
        trim.setEnd(36)

        #expect(transcript.trimmed(to: trim).isEmpty)
    }

    @Test("speaker attribution survives trimming")
    func attributionSurvives() {
        var trim = TrimSelection(duration: 50)
        trim.setStart(8)
        trim.setEnd(24)
        let trimmed = transcript.trimmed(to: trim)

        #expect(trimmed.turns.map(\.speaker) == ["Dana", "Ben"])
        #expect(trimmed.turns.map(\.channelIndex) == [1, 0])
    }
}

@Suite("AudioMixdown slicing")
struct AudioSliceTests {

    @Test("a slice contains exactly the selected seconds")
    func sliceLength() {
        let samples = [Float](repeating: 0.5, count: 48_000)   // one second
        let slice = AudioMixdown.slice(samples, from: 0.25, to: 0.75, sampleRate: 48_000)

        #expect(slice.count == 24_000)
    }

    @Test("a slice takes the samples from the right place")
    func sliceContent() {
        let samples: [Float] = [0, 1, 2, 3, 4, 5, 6, 7]
        #expect(AudioMixdown.slice(samples, from: 0.25, to: 0.75, sampleRate: 8) == [2, 3, 4, 5])
    }

    @Test("a slice reaching past the end is clamped rather than crashing")
    func sliceClamps() {
        let samples: [Float] = [0, 1, 2, 3]
        #expect(AudioMixdown.slice(samples, from: -5, to: 99, sampleRate: 4) == samples)
    }

    @Test("an inverted or empty range yields nothing")
    func emptySlice() {
        let samples: [Float] = [0, 1, 2, 3]
        #expect(AudioMixdown.slice(samples, from: 0.75, to: 0.25, sampleRate: 4).isEmpty)
        #expect(AudioMixdown.slice([], from: 0, to: 1, sampleRate: 4).isEmpty)
    }
}

@Suite("SessionExporter trimming")
struct SessionExporterTrimTests {

    private struct Reader: AudioTrackReading {
        let samples: [Float]
        func readMono(from url: URL) throws -> (samples: [Float], sampleRate: Double) {
            (samples, 48_000)
        }
    }

    private func makeSession() -> StoredSession {
        var metadata = SessionMetadata(
            id: UUID(), title: "Long take", createdAt: Date(),
            deviceName: "DJI", inputChannelCount: 2, sampleRate: 48_000, format: .aac)
        metadata.duration = 4
        metadata.tracks = [TrackMetadata(channelIndex: 0, speakerName: "Ben", fileName: "01-ben.m4a", peakDB: -6)]
        return StoredSession(directory: URL(fileURLWithPath: "/tmp/s"), metadata: metadata)
    }

    private func makeDestination() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LapelTrim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("the exported audio is only the selected stretch")
    func exportsTrimmedAudio() throws {
        let destination = try makeDestination()
        var options = ExportOptions()
        options.audioFormat = .wav
        var trim = TrimSelection(duration: 4)
        trim.setStart(1)
        trim.setEnd(3)
        options.trim = trim

        let result = try SessionExporter(reader: Reader(samples: [Float](repeating: 0.4, count: 192_000)))
            .export(makeSession(), transcript: nil, to: destination, options: options)

        let (written, _) = try AVAudioFileTrackReader().readMono(from: result.audioURL!)
        #expect(abs(Double(written.count) / 48_000 - 2.0) < 0.01)
    }

    @Test("the exported transcript is trimmed and re-timed to match the audio")
    func exportsTrimmedTranscript() throws {
        let destination = try makeDestination()
        var options = ExportOptions()
        options.audioFormat = .wav
        var trim = TrimSelection(duration: 4)
        trim.setStart(1)
        trim.setEnd(3)
        options.trim = trim

        let transcript = Transcript(turns: [
            turn("Ben", 0, 0.0, 0.5, "cut this"),
            turn("Ben", 0, 1.5, 2.5, "keep this"),
        ])

        let result = try SessionExporter(reader: Reader(samples: [Float](repeating: 0.4, count: 192_000)))
            .export(makeSession(), transcript: transcript, to: destination, options: options)

        #expect(try String(contentsOf: result.transcriptURL!, encoding: .utf8) == "Ben: keep this")
    }

    @Test("without a trim the whole recording is exported as before")
    func untrimmedExportIsUnchanged() throws {
        let destination = try makeDestination()
        var options = ExportOptions()
        options.audioFormat = .wav

        let result = try SessionExporter(reader: Reader(samples: [Float](repeating: 0.4, count: 192_000)))
            .export(makeSession(), transcript: nil, to: destination, options: options)

        let (written, _) = try AVAudioFileTrackReader().readMono(from: result.audioURL!)
        #expect(abs(Double(written.count) / 48_000 - 4.0) < 0.01)
    }
}
