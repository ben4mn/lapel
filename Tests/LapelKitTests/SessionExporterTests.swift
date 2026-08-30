import Testing
import Foundation
@testable import LapelKit

/// Serves canned samples for known filenames, so export is exercised without
/// encoding or decoding anything.
private struct FakeTrackReader: AudioTrackReading {
    var tracks: [String: [Float]]
    var sampleRate: Double = 48_000

    func readMono(from url: URL) throws -> (samples: [Float], sampleRate: Double) {
        guard let samples = tracks[url.lastPathComponent] else {
            throw ExportError.trackUnreadable(url.lastPathComponent)
        }
        return (samples, sampleRate)
    }
}

private func makeSession(tracks: [TrackMetadata], title: String = "Kickoff") -> StoredSession {
    var metadata = SessionMetadata(
        id: UUID(), title: title, createdAt: Date(timeIntervalSince1970: 1_756_000_000),
        deviceName: "DJI MIC MINI", inputChannelCount: 2, sampleRate: 48_000, format: .aac
    )
    metadata.duration = 12
    metadata.tracks = tracks
    return StoredSession(directory: URL(fileURLWithPath: "/tmp/session"), metadata: metadata)
}

private let twoTracks = [
    TrackMetadata(channelIndex: 0, speakerName: "Ben", fileName: "01-ben.m4a", peakDB: -6),
    TrackMetadata(channelIndex: 1, speakerName: "Dana", fileName: "02-dana.m4a", peakDB: -9),
]

private let transcript = Transcript(turns: [
    TranscriptTurn(speaker: "Ben", channelIndex: 0, start: 0, end: 2, text: "morning"),
    TranscriptTurn(speaker: "Dana", channelIndex: 1, start: 3, end: 5, text: "morning to you"),
])

private func makeDestination() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("LapelExport-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("SessionExporter")
struct SessionExporterTests {

    private func exporter(_ samples: [String: [Float]]) -> SessionExporter {
        SessionExporter(reader: FakeTrackReader(tracks: samples))
    }

    @Test("both files are written, named after the session")
    func writesBothFiles() throws {
        let destination = try makeDestination()
        let result = try exporter(["01-ben.m4a": [0.2, 0.2], "02-dana.m4a": [0.1, 0.1]])
            .export(makeSession(tracks: twoTracks), transcript: transcript,
                    to: destination, options: ExportOptions())

        #expect(result.audioURL?.lastPathComponent == "kickoff.m4a")
        #expect(result.transcriptURL?.lastPathComponent == "kickoff.txt")
        #expect(FileManager.default.fileExists(atPath: result.audioURL!.path))
        #expect(FileManager.default.fileExists(atPath: result.transcriptURL!.path))
    }

    @Test("the exported transcript is the combined, attributed script")
    func transcriptContent() throws {
        let destination = try makeDestination()
        let result = try exporter(["01-ben.m4a": [0.2], "02-dana.m4a": [0.1]])
            .export(makeSession(tracks: twoTracks), transcript: transcript,
                    to: destination, options: ExportOptions())

        let text = try String(contentsOf: result.transcriptURL!, encoding: .utf8)
        #expect(text == "Ben: morning\nDana: morning to you")
    }

    @Test("numbered labelling anonymises the exported transcript")
    func numberedLabelling() throws {
        let destination = try makeDestination()
        var options = ExportOptions()
        options.labeling = .numbered

        let result = try exporter(["01-ben.m4a": [0.2], "02-dana.m4a": [0.1]])
            .export(makeSession(tracks: twoTracks), transcript: transcript, to: destination, options: options)

        let text = try String(contentsOf: result.transcriptURL!, encoding: .utf8)
        #expect(text == "Speaker 1: morning\nSpeaker 2: morning to you")
    }

    @Test("the transcript format decides the file extension")
    func transcriptFormatExtension() throws {
        let destination = try makeDestination()
        var options = ExportOptions()
        options.transcriptFormat = .srt

        let result = try exporter(["01-ben.m4a": [0.2], "02-dana.m4a": [0.1]])
            .export(makeSession(tracks: twoTracks), transcript: transcript, to: destination, options: options)

        #expect(result.transcriptURL?.lastPathComponent == "kickoff.srt")
        #expect(try String(contentsOf: result.transcriptURL!, encoding: .utf8).hasPrefix("1\n"))
    }

    @Test("a session with no transcript still exports its audio")
    func audioWithoutTranscript() throws {
        let destination = try makeDestination()
        let result = try exporter(["01-ben.m4a": [0.2], "02-dana.m4a": [0.1]])
            .export(makeSession(tracks: twoTracks), transcript: nil,
                    to: destination, options: ExportOptions())

        #expect(result.audioURL != nil)
        #expect(result.transcriptURL == nil)
    }

    @Test("audio and transcript can each be exported on their own")
    func selectiveExport() throws {
        let destination = try makeDestination()
        var audioOnly = ExportOptions(); audioOnly.includeTranscript = false
        var textOnly = ExportOptions(); textOnly.includeAudio = false
        let exporter = exporter(["01-ben.m4a": [0.2], "02-dana.m4a": [0.1]])
        let session = makeSession(tracks: twoTracks)

        let a = try exporter.export(session, transcript: transcript, to: destination, options: audioOnly)
        #expect(a.audioURL != nil && a.transcriptURL == nil)

        let b = try exporter.export(session, transcript: transcript, to: destination, options: textOnly)
        #expect(b.audioURL == nil && b.transcriptURL != nil)
    }

    @Test("an unreadable track is skipped and reported, and the rest still exports")
    func skipsUnreadableTrack() throws {
        let destination = try makeDestination()
        let result = try exporter(["01-ben.m4a": [0.2, 0.2]])   // Dana's file is missing
            .export(makeSession(tracks: twoTracks), transcript: nil,
                    to: destination, options: ExportOptions())

        #expect(result.skippedTracks == ["02-dana.m4a"])
        #expect(result.audioURL != nil)
    }

    @Test("an export with no readable audio at all fails rather than writing an empty file")
    func failsWhenNoTrackIsReadable() throws {
        let destination = try makeDestination()
        #expect(throws: ExportError.self) {
            try exporter([:]).export(makeSession(tracks: twoTracks), transcript: nil,
                                     to: destination, options: ExportOptions())
        }
    }

    @Test("a second export of the same session does not overwrite the first")
    func doesNotOverwrite() throws {
        let destination = try makeDestination()
        let exporter = exporter(["01-ben.m4a": [0.2], "02-dana.m4a": [0.1]])
        let session = makeSession(tracks: twoTracks)

        let first = try exporter.export(session, transcript: nil, to: destination, options: ExportOptions())
        let second = try exporter.export(session, transcript: nil, to: destination, options: ExportOptions())

        #expect(first.audioURL != second.audioURL)
        #expect(second.audioURL?.lastPathComponent == "kickoff-2.m4a")
    }

    @Test("a title full of punctuation still yields a usable filename")
    func awkwardTitle() throws {
        let destination = try makeDestination()
        let result = try exporter(["01-ben.m4a": [0.2], "02-dana.m4a": [0.1]])
            .export(makeSession(tracks: twoTracks, title: "Q3/Q4 review: part 2"),
                    transcript: nil, to: destination, options: ExportOptions())

        #expect(result.audioURL?.lastPathComponent == "q3-q4-review-part-2.m4a")
    }

    @Test("the mixed file really is the sum of the tracks")
    func mixesTrackContent() throws {
        let destination = try makeDestination()
        var options = ExportOptions(); options.audioFormat = .wav
        let result = try exporter(["01-ben.m4a": [0.25, 0.0], "02-dana.m4a": [0.0, 0.5]])
            .export(makeSession(tracks: twoTracks), transcript: nil, to: destination, options: options)

        let (samples, _) = try AVAudioFileTrackReader().readMono(from: result.audioURL!)
        #expect(samples.count == 2)
        #expect(abs(samples[0] - 0.25) < 0.001)
        #expect(abs(samples[1] - 0.5) < 0.001)
    }
}

@Suite("AVAudioFileTrackReader")
struct AVAudioFileTrackReaderTests {

    @Test("audio written by the recorder reads back with the same samples")
    func roundTripsThroughARealFile() throws {
        let destination = try makeDestination()
        let url = destination.appendingPathComponent("tone.wav")
        let written: [Float] = (0..<4_800).map { i in 0.5 * Float(sin(Double(i) * 0.05)) }

        let writer = try AudioFileTrackWriter(url: url, sampleRate: 48_000, format: .wav)
        try writer.write(written)
        try writer.finish()

        let (read, rate) = try AVAudioFileTrackReader().readMono(from: url)

        #expect(rate == 48_000)
        #expect(read.count == written.count)
        // 24-bit PCM, so the round trip is lossy only below the quantisation step.
        #expect(zip(read, written).allSatisfy { abs($0 - $1) < 0.001 })
    }

    @Test("reading a file that is not there reports which one")
    func missingFile() {
        let url = URL(fileURLWithPath: "/tmp/definitely-not-here-\(UUID().uuidString).wav")
        #expect(throws: ExportError.self) { try AVAudioFileTrackReader().readMono(from: url) }
    }
}
