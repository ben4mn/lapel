import Testing
import Foundation
@testable import LapelKit

/// Returns canned words per file, so the orchestration is tested without a
/// speech model anywhere near it.
private struct FakeEngine: Transcribing {
    var lines: [String: [(Double, Double, String)]] = [:]
    var failing: Set<String> = []
    var available = true

    var isAvailable: Bool { available }
    var unavailableReason: String? { available ? nil : "fake unavailable" }

    func transcribe(fileURL: URL, speaker: String, channelIndex: Int) async throws -> [TranscriptSegment] {
        let name = fileURL.lastPathComponent
        if failing.contains(name) { throw TranscriptionError.failed(name) }
        return (lines[name] ?? []).map {
            TranscriptSegment(speaker: speaker, channelIndex: channelIndex, start: $0.0, end: $0.1, text: $0.2)
        }
    }
}

private let tracks = [
    TrackMetadata(channelIndex: 0, speakerName: "Ben", fileName: "01-ben.m4a", peakDB: -6),
    TrackMetadata(channelIndex: 1, speakerName: "Dana", fileName: "02-dana.m4a", peakDB: -9),
]

private func makeSession(_ tracks: [TrackMetadata]) -> StoredSession {
    var metadata = SessionMetadata(
        id: UUID(), title: "Kickoff", createdAt: Date(),
        deviceName: "DJI", inputChannelCount: 2, sampleRate: 48_000, format: .aac)
    metadata.tracks = tracks
    return StoredSession(directory: URL(fileURLWithPath: "/tmp/s"), metadata: metadata)
}

@Suite("SessionTranscription")
struct SessionTranscriptionTests {

    @Test("each track is transcribed separately and merged into one chronological script")
    func mergesTracks() async throws {
        let engine = FakeEngine(lines: [
            "01-ben.m4a": [(0.0, 2.0, "morning"), (6.0, 8.0, "sounds good")],
            "02-dana.m4a": [(3.0, 5.0, "morning to you")],
        ])
        let transcript = try await SessionTranscription(engine: engine).transcribe(makeSession(tracks))

        #expect(transcript.turns.map(\.text) == ["morning", "morning to you", "sounds good"])
        #expect(transcript.turns.map(\.speaker) == ["Ben", "Dana", "Ben"])
    }

    @Test("attribution comes from the track metadata, never from the audio")
    func attributionFromMetadata() async throws {
        let engine = FakeEngine(lines: ["01-ben.m4a": [(0, 1, "hello")]])
        let transcript = try await SessionTranscription(engine: engine).transcribe(makeSession(tracks))

        #expect(transcript.turns.first?.speaker == "Ben")
        #expect(transcript.turns.first?.channelIndex == 0)
    }

    @Test("one track failing does not cost the other speaker their transcript")
    func partialFailure() async throws {
        let engine = FakeEngine(
            lines: ["02-dana.m4a": [(3, 5, "still here")]],
            failing: ["01-ben.m4a"]
        )
        let transcript = try await SessionTranscription(engine: engine).transcribe(makeSession(tracks))

        #expect(transcript.turns.map(\.text) == ["still here"])
    }

    @Test("every track failing is reported rather than returning an empty transcript")
    func totalFailure() async {
        let engine = FakeEngine(failing: ["01-ben.m4a", "02-dana.m4a"])

        await #expect(throws: TranscriptionError.self) {
            try await SessionTranscription(engine: engine).transcribe(makeSession(tracks))
        }
    }

    @Test("an unavailable engine says so before reading any audio")
    func unavailableEngine() async {
        let engine = FakeEngine(available: false)

        await #expect(throws: TranscriptionError.self) {
            try await SessionTranscription(engine: engine).transcribe(makeSession(tracks))
        }
    }

    @Test("a session with no tracks is refused")
    func noTracks() async {
        await #expect(throws: TranscriptionError.self) {
            try await SessionTranscription(engine: FakeEngine()).transcribe(makeSession([]))
        }
    }

    @Test("a track that yields no speech contributes nothing but does not fail the run")
    func silentTrack() async throws {
        let engine = FakeEngine(lines: ["01-ben.m4a": [(0, 1, "hello")], "02-dana.m4a": []])
        let transcript = try await SessionTranscription(engine: engine).transcribe(makeSession(tracks))

        #expect(transcript.turns.count == 1)
    }
}

@MainActor
@Suite("RecorderModel transcription")
struct RecorderModelTranscriptionTests {

    private func makeModel(_ engine: FakeEngine) throws -> (RecorderModel, SessionStore, StoredSession) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LapelTx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = SessionStore(root: root)

        let handle = try store.createSession(title: "Kickoff", at: Date())
        var metadata = SessionMetadata(
            id: handle.id, title: "Kickoff", createdAt: Date(),
            deviceName: "DJI", inputChannelCount: 2, sampleRate: 48_000, format: .aac)
        metadata.tracks = tracks
        try store.write(metadata, to: handle)

        let model = RecorderModel(store: store, transcriber: engine)
        return (model, store, StoredSession(directory: handle.directory, metadata: metadata))
    }

    @Test("transcribing a session saves the transcript so it survives a relaunch")
    func persistsTranscript() async throws {
        let engine = FakeEngine(lines: [
            "01-ben.m4a": [(0, 2, "morning")],
            "02-dana.m4a": [(3, 5, "morning to you")],
        ])
        let (model, store, session) = try makeModel(engine)

        await model.transcribe(session)

        let reloaded = try store.listSessions().first!
        #expect(reloaded.metadata.transcriptFileName == "transcript.json")
        #expect(store.readTranscript(for: reloaded)?.turns.map(\.text) == ["morning", "morning to you"])
        #expect(model.transcript(for: reloaded)?.turns.count == 2)
    }

    @Test("the session being transcribed is marked while it runs and cleared after")
    func tracksProgress() async throws {
        let (model, _, session) = try makeModel(FakeEngine(lines: ["01-ben.m4a": [(0, 1, "hi")]]))
        #expect(model.transcribingSessionID == nil)

        await model.transcribe(session)

        #expect(model.transcribingSessionID == nil)
        #expect(model.errorMessage == nil)
    }

    @Test("a failed run surfaces the reason and leaves no transcript behind")
    func failureIsSurfaced() async throws {
        let (model, store, session) = try makeModel(FakeEngine(available: false))

        await model.transcribe(session)

        #expect(model.errorMessage != nil)
        #expect(store.readTranscript(for: session) == nil)
    }
}
