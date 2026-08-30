import Foundation

public enum SessionStoreError: Error, Equatable {
    /// Refused an operation on a path that is not inside the store.
    case pathOutsideStore(String)
    case metadataUnreadable(String)
}

/// A session directory that exists on disk.
public struct SessionHandle: Equatable, Sendable {
    public let id: UUID
    public let directory: URL

    public init(id: UUID, directory: URL) {
        self.id = id
        self.directory = directory
    }

    /// One file per channel, prefixed with a zero-padded index so the tracks list
    /// in Finder in the same order as on screen.
    public func trackURL(channelIndex: Int, speakerName: String, format: RecordingFormat) -> URL {
        let speaker = SessionSlug.make(from: speakerName, fallback: "track")
        let name = String(format: "%02d-%@.%@", channelIndex + 1, speaker, format.fileExtension)
        return directory.appendingPathComponent(name)
    }

    public var metadataURL: URL { directory.appendingPathComponent(SessionStore.metadataFileName) }
}

/// A session plus its location, as returned when browsing the library.
public struct StoredSession: Equatable, Sendable, Identifiable {
    public let directory: URL
    public var metadata: SessionMetadata

    public var id: UUID { metadata.id }
    public var title: String { metadata.title }
    public var createdAt: Date { metadata.createdAt }
    public var duration: TimeInterval { metadata.duration }

    public init(directory: URL, metadata: SessionMetadata) {
        self.directory = directory
        self.metadata = metadata
    }
}

/// Owns the on-disk layout of recorded sessions.
///
/// Sessions are plain directories of audio files beside a readable `session.json`,
/// deliberately not a database: a recording should outlive this app and be openable
/// with anything.
public struct SessionStore: Sendable {
    public static let metadataFileName = "session.json"

    public let root: URL

    public init(root: URL) {
        self.root = root.resolvingSymlinksInPath()
    }

    /// `~/Library/Application Support/Lapel/Sessions`
    public static func defaultRoot() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Lapel", isDirectory: true)
            .appendingPathComponent("Sessions", isDirectory: true)
    }

    private static let directoryDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        // Sorts chronologically as plain text, which is why the components run
        // largest to smallest and are zero padded.
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    public func createSession(title: String, at date: Date = Date()) throws -> SessionHandle {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let base = "\(Self.directoryDateFormatter.string(from: date))-\(SessionSlug.make(from: title))"
        var directory = root.appendingPathComponent(base, isDirectory: true)
        var attempt = 2
        while FileManager.default.fileExists(atPath: directory.path) {
            directory = root.appendingPathComponent("\(base)-\(attempt)", isDirectory: true)
            attempt += 1
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return SessionHandle(id: UUID(), directory: directory)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func write(_ metadata: SessionMetadata, to session: SessionHandle) throws {
        let data = try Self.makeEncoder().encode(metadata)
        try data.write(to: session.metadataURL, options: .atomic)
    }

    public func readMetadata(from directory: URL) throws -> SessionMetadata {
        let url = directory.appendingPathComponent(Self.metadataFileName)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw SessionStoreError.metadataUnreadable(url.path)
        }
        return try Self.makeDecoder().decode(SessionMetadata.self, from: data)
    }

    /// Newest first. A directory whose metadata will not parse is skipped rather
    /// than failing the listing — one corrupt session must not hide the rest.
    public func listSessions() throws -> [StoredSession] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries
            .compactMap { url -> StoredSession? in
                guard let metadata = try? readMetadata(from: url) else { return nil }
                return StoredSession(directory: url, metadata: metadata)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Transcripts

    public static let transcriptFileName = "transcript.json"

    /// Writes the transcript beside the audio and records its name in the metadata,
    /// which the caller then persists.
    public func write(_ transcript: Transcript, to session: SessionHandle, updating metadata: inout SessionMetadata) throws {
        let url = session.directory.appendingPathComponent(Self.transcriptFileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(transcript).write(to: url, options: .atomic)
        metadata.transcriptFileName = Self.transcriptFileName
    }

    /// Writes the transcript and updates the session's metadata on disk in one step,
    /// so a saved transcript is never orphaned by metadata that does not mention it.
    public func attachTranscript(_ transcript: Transcript, to session: StoredSession) throws {
        let handle = SessionHandle(id: session.metadata.id, directory: session.directory)
        var metadata = session.metadata
        try write(transcript, to: handle, updating: &metadata)
        try write(metadata, to: handle)
    }

    /// Nil rather than throwing for both of the ordinary cases: a session that was
    /// never transcribed, and metadata naming a file that has since been removed.
    public func readTranscript(for session: StoredSession) -> Transcript? {
        guard let name = session.metadata.transcriptFileName else { return nil }
        let url = session.directory.appendingPathComponent(name)
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return try? JSONDecoder().decode(Transcript.self, from: data)
    }

    /// Removes a session directory, refusing anything that is not a direct child of
    /// the store so a bad URL cannot take out an unrelated folder.
    public func delete(_ directory: URL) throws {
        let resolved = directory.resolvingSymlinksInPath().standardizedFileURL
        let parent = resolved.deletingLastPathComponent().standardizedFileURL
        guard parent.path == root.standardizedFileURL.path else {
            throw SessionStoreError.pathOutsideStore(directory.path)
        }
        try FileManager.default.removeItem(at: resolved)
    }
}
