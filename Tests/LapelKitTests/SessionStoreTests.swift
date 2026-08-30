import Testing
import Foundation
@testable import LapelKit

func makeTemporaryRoot() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("LapelTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Suite("SessionSlug")
struct SessionSlugTests {

    @Test("a plain title becomes a lowercase hyphenated slug")
    func basicSlug() {
        #expect(SessionSlug.make(from: "Kickoff with Dana") == "kickoff-with-dana")
    }

    @Test("path separators and colons are stripped so the slug is always one path component")
    func stripsPathSeparators() {
        let slug = SessionSlug.make(from: "Q3/Q4 review: part 2")
        #expect(!slug.contains("/"))
        #expect(!slug.contains(":"))
        #expect(slug == "q3-q4-review-part-2")
    }

    @Test("runs of punctuation and whitespace collapse to a single hyphen")
    func collapsesSeparators() {
        #expect(SessionSlug.make(from: "  a   ---  b  ") == "a-b")
    }

    @Test("a leading dot cannot produce a hidden directory")
    func noHiddenDirectories() {
        let slug = SessionSlug.make(from: ".hidden thing")
        #expect(!slug.hasPrefix("."))
        #expect(slug == "hidden-thing")
    }

    @Test("titles that reduce to nothing fall back to a usable name")
    func emptyFallback() {
        #expect(SessionSlug.make(from: "") == "untitled")
        #expect(SessionSlug.make(from: "   ") == "untitled")
        #expect(SessionSlug.make(from: "!!!") == "untitled")
        #expect(SessionSlug.make(from: "🎙️") == "untitled")
    }

    @Test("accented characters are folded rather than dropped")
    func foldsDiacritics() {
        #expect(SessionSlug.make(from: "Café résumé") == "cafe-resume")
    }

    @Test("very long titles are truncated well inside the filesystem name limit")
    func truncatesLongTitles() {
        let slug = SessionSlug.make(from: String(repeating: "word ", count: 200))
        #expect(slug.utf8.count <= 80)
        #expect(!slug.hasSuffix("-"))
    }
}

@Suite("SessionStore")
struct SessionStoreTests {

    @Test("creating a session makes a directory named by timestamp and slug")
    func createsDirectory() throws {
        let root = try makeTemporaryRoot()
        let store = SessionStore(root: root)
        let created = try store.createSession(title: "Kickoff with Dana", at: Date(timeIntervalSince1970: 1_756_000_000))

        #expect(FileManager.default.fileExists(atPath: created.directory.path))
        #expect(created.directory.lastPathComponent.hasSuffix("kickoff-with-dana"))
        // Compared by path: URL equality is string equality, and a directory URL may or
        // may not carry a trailing slash depending on how it was constructed.
        #expect(created.directory.deletingLastPathComponent().standardizedFileURL.path
                == root.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    @Test("the directory name sorts chronologically as plain text")
    func directoryNamesSortChronologically() throws {
        let root = try makeTemporaryRoot()
        let store = SessionStore(root: root)
        let earlier = try store.createSession(title: "one", at: Date(timeIntervalSince1970: 1_700_000_000))
        let later = try store.createSession(title: "two", at: Date(timeIntervalSince1970: 1_800_000_000))

        #expect(earlier.directory.lastPathComponent < later.directory.lastPathComponent)
    }

    @Test("two sessions with the same title and timestamp do not collide")
    func handlesCollision() throws {
        let root = try makeTemporaryRoot()
        let store = SessionStore(root: root)
        let when = Date(timeIntervalSince1970: 1_756_000_000)

        let first = try store.createSession(title: "standup", at: when)
        let second = try store.createSession(title: "standup", at: when)

        #expect(first.directory != second.directory)
        #expect(FileManager.default.fileExists(atPath: second.directory.path))
    }

    @Test("each track gets its own file named by channel and speaker")
    func trackFileNaming() throws {
        let root = try makeTemporaryRoot()
        let store = SessionStore(root: root)
        let session = try store.createSession(title: "interview", at: Date())

        let url = session.trackURL(channelIndex: 0, speakerName: "Ben", format: .aac)
        #expect(url.lastPathComponent == "01-ben.m4a")
        #expect(url.deletingLastPathComponent().standardizedFileURL.path == session.directory.standardizedFileURL.path)

        let lossless = session.trackURL(channelIndex: 1, speakerName: "Dana", format: .wav)
        #expect(lossless.lastPathComponent == "02-dana.wav")
    }

    @Test("an unnamed speaker still yields a stable, ordered filename")
    func unnamedTrackNaming() throws {
        let root = try makeTemporaryRoot()
        let session = try SessionStore(root: root).createSession(title: "x", at: Date())

        #expect(session.trackURL(channelIndex: 0, speakerName: "", format: .aac).lastPathComponent == "01-track.m4a")
    }

    @Test("metadata survives a write and read round trip")
    func metadataRoundTrip() throws {
        let root = try makeTemporaryRoot()
        let store = SessionStore(root: root)
        let session = try store.createSession(title: "roundtrip", at: Date(timeIntervalSince1970: 1_756_000_000))

        var metadata = SessionMetadata(
            id: session.id,
            title: "Roundtrip",
            createdAt: Date(timeIntervalSince1970: 1_756_000_000),
            deviceName: "DJI MIC MINI",
            inputChannelCount: 2,
            sampleRate: 48_000,
            format: .aac
        )
        metadata.duration = 91.5
        metadata.tracks = [
            TrackMetadata(channelIndex: 0, speakerName: "Ben", fileName: "01-ben.m4a", peakDB: -6.2),
            TrackMetadata(channelIndex: 1, speakerName: "Dana", fileName: "02-dana.m4a", peakDB: -9.1),
        ]

        try store.write(metadata, to: session)
        let loaded = try store.readMetadata(from: session.directory)

        #expect(loaded == metadata)
    }

    @Test("metadata is written as readable JSON so a session survives the app")
    func metadataIsInspectableJSON() throws {
        let root = try makeTemporaryRoot()
        let store = SessionStore(root: root)
        let session = try store.createSession(title: "json", at: Date())
        let metadata = SessionMetadata(
            id: session.id, title: "JSON", createdAt: Date(),
            deviceName: "DJI", inputChannelCount: 2, sampleRate: 48_000, format: .aac
        )

        try store.write(metadata, to: session)
        let text = try String(contentsOf: session.directory.appendingPathComponent("session.json"), encoding: .utf8)

        #expect(text.contains("\"title\""))
        #expect(text.contains("\n"))
    }

    @Test("listing returns every readable session, newest first")
    func listsSessionsNewestFirst() throws {
        let root = try makeTemporaryRoot()
        let store = SessionStore(root: root)

        for (index, title) in ["one", "two", "three"].enumerated() {
            let when = Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 86_400)
            let session = try store.createSession(title: title, at: when)
            try store.write(
                SessionMetadata(id: session.id, title: title, createdAt: when,
                                deviceName: "DJI", inputChannelCount: 2, sampleRate: 48_000, format: .aac),
                to: session
            )
        }

        #expect(try store.listSessions().map(\.title) == ["three", "two", "one"])
    }

    @Test("a directory without metadata is skipped rather than failing the whole listing")
    func skipsUnreadableSessions() throws {
        let root = try makeTemporaryRoot()
        let store = SessionStore(root: root)
        _ = try store.createSession(title: "orphan", at: Date())   // never written to

        let good = try store.createSession(title: "good", at: Date())
        try store.write(
            SessionMetadata(id: good.id, title: "good", createdAt: Date(),
                            deviceName: "DJI", inputChannelCount: 2, sampleRate: 48_000, format: .aac),
            to: good
        )

        #expect(try store.listSessions().map(\.title) == ["good"])
    }

    @Test("deleting a session removes its whole directory")
    func deleteRemovesDirectory() throws {
        let root = try makeTemporaryRoot()
        let store = SessionStore(root: root)
        let session = try store.createSession(title: "doomed", at: Date())

        try store.delete(session.directory)
        #expect(!FileManager.default.fileExists(atPath: session.directory.path))
    }

    @Test("delete refuses a path outside the store rather than removing it")
    func deleteRefusesEscape() throws {
        let root = try makeTemporaryRoot()
        let outsider = try makeTemporaryRoot()
        let store = SessionStore(root: root)

        #expect(throws: SessionStoreError.self) { try store.delete(outsider) }
        #expect(FileManager.default.fileExists(atPath: outsider.path))
    }
}

@Suite("SessionStore transcripts")
struct SessionStoreTranscriptTests {

    private let transcript = Transcript(turns: [
        TranscriptTurn(speaker: "Ben", channelIndex: 0, start: 0, end: 2, text: "morning"),
        TranscriptTurn(speaker: "Dana", channelIndex: 1, start: 3, end: 5, text: "morning to you"),
    ])

    @Test("a transcript is written beside the audio and read back intact")
    func roundTrip() throws {
        let store = SessionStore(root: try makeTemporaryRoot())
        let handle = try store.createSession(title: "talk", at: Date(timeIntervalSince1970: 1_756_000_000))
        var metadata = SessionMetadata(
            id: handle.id, title: "talk", createdAt: Date(timeIntervalSince1970: 1_756_000_000),
            deviceName: "DJI", inputChannelCount: 2, sampleRate: 48_000, format: .aac)

        try store.write(transcript, to: handle, updating: &metadata)
        try store.write(metadata, to: handle)

        #expect(metadata.transcriptFileName == "transcript.json")
        let stored = StoredSession(directory: handle.directory, metadata: metadata)
        #expect(store.readTranscript(for: stored) == transcript)
    }

    @Test("a session that was never transcribed reads back as no transcript, not an error")
    func absentTranscript() throws {
        let store = SessionStore(root: try makeTemporaryRoot())
        let handle = try store.createSession(title: "silent", at: Date())
        let metadata = SessionMetadata(
            id: handle.id, title: "silent", createdAt: Date(),
            deviceName: "DJI", inputChannelCount: 2, sampleRate: 48_000, format: .aac)

        #expect(store.readTranscript(for: StoredSession(directory: handle.directory, metadata: metadata)) == nil)
    }

    @Test("metadata naming a transcript file that is gone reads back as no transcript")
    func danglingTranscriptReference() throws {
        let store = SessionStore(root: try makeTemporaryRoot())
        let handle = try store.createSession(title: "gone", at: Date())
        var metadata = SessionMetadata(
            id: handle.id, title: "gone", createdAt: Date(),
            deviceName: "DJI", inputChannelCount: 2, sampleRate: 48_000, format: .aac)
        metadata.transcriptFileName = "transcript.json"

        #expect(store.readTranscript(for: StoredSession(directory: handle.directory, metadata: metadata)) == nil)
    }
}
