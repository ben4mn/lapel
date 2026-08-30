import Foundation
import Observation

/// The app's live state: what is plugged in, what the meters read, what is being
/// recorded, and what has been recorded before.
///
/// Every dependency is injected — the session store, the writer factory and the
/// capture factory — so the whole thing runs against synthetic buffers. The device
/// list arrives through `devicesChanged(to:)` rather than being polled, which keeps
/// `AudioDeviceMonitor` out of here entirely.
@MainActor
@Observable
public final class RecorderModel {

    // MARK: - Published state

    public private(set) var readings: [LevelReading] = []
    public private(set) var recordingState: RecordingState = .idle
    public private(set) var sessions: [StoredSession] = []
    public private(set) var errorMessage: String?
    /// The session currently being transcribed, if any — one at a time, because the
    /// speech engine is the bottleneck and queuing more would only slow the first.
    public private(set) var transcribingSessionID: UUID?

    /// What the user is about to record, or is recording.
    public var title: String
    /// One per channel; edited in place as the user names each speaker.
    public var speakerNames: [String] = []
    public var format: RecordingFormat = .aac

    // MARK: - Dependencies

    private let store: SessionStore
    private let writerFactory: TrackWriterFactory
    private let captureFactory: AudioCaptureFactory
    private let transcriber: any Transcribing

    // MARK: - Internals

    private var receiverState = ReceiverState()
    private var meters: [LevelMeter] = []
    private var capture: AudioCapturing?
    private var session: RecordingSession?

    public init(
        store: SessionStore,
        writerFactory: TrackWriterFactory = AudioFileTrackWriterFactory(),
        captureFactory: AudioCaptureFactory = LiveAudioCaptureFactory(),
        transcriber: (any Transcribing)? = nil
    ) {
        self.store = store
        self.writerFactory = writerFactory
        self.captureFactory = captureFactory
        self.transcriber = transcriber ?? TranscriberFactory.makeDefault()
        self.title = Self.defaultTitle()
        self.sessions = (try? store.listSessions()) ?? []
    }

    // MARK: - Derived state

    public var receiver: Receiver? { receiverState.receiver }
    public var statusSummary: String { receiverState.statusSummary }
    public var advisory: ReceiverAdvisory? { receiverState.advisory }
    public var canSeparateSpeakers: Bool { receiverState.canSeparateSpeakers }
    public var presences: [MicPresence] { receiverState.presences }
    public var connectedMicCount: Int { receiverState.connectedMicCount }
    public var isRecording: Bool { recordingState == .recording || recordingState == .paused }
    public var elapsed: TimeInterval { session?.duration ?? 0 }

    /// Arming needs a receiver, at least one live transmitter, and nothing already running.
    public var canRecord: Bool { receiverState.canRecord && !isRecording && capture != nil }

    // MARK: - Hardware changes

    /// Folds in a fresh device list. Wire this to `AudioDeviceMonitor`.
    public func devicesChanged(to devices: [AudioDeviceDescriptor]) {
        switch receiverState.devicesChanged(to: devices) {
        case .connected, .reconfigured:
            guard let receiver = receiverState.receiver else { return }
            // A reconfiguration means the channel layout moved under us, so the
            // in-flight take belongs to hardware that no longer exists.
            finishInterruptedRecording(reason: "The receiver was reconfigured — the recording was saved.")
            restartCapture(for: receiver)

        case .disconnected:
            finishInterruptedRecording(reason: "The receiver was disconnected — the recording was saved.")
            stopCapture()
            readings = []
            meters = []
            speakerNames = []

        case nil:
            break
        }
    }

    private func restartCapture(for receiver: Receiver) {
        stopCapture()

        let channels = receiver.channelMode.trackCount
        meters = (0..<channels).map { _ in LevelMeter() }
        readings = Array(repeating: .silent, count: channels)
        speakerNames = receiver.tracks.map(\.defaultName)

        let capture = captureFactory.makeCapture(device: receiver.device)
        do {
            // AudioCapturing guarantees main-actor, in-order delivery, so this
            // needs no hop of its own.
            try capture.start { [weak self] channels, sampleRate in
                self?.consume(channels: channels, sampleRate: sampleRate)
            }
            self.capture = capture
            errorMessage = nil
        } catch {
            self.capture = nil
            errorMessage = "Could not open \(receiver.device.name): \(error.localizedDescription)"
        }
    }

    private func stopCapture() {
        capture?.stop()
        capture = nil
    }

    // MARK: - Audio

    private func consume(channels: [[Float]], sampleRate: Double) {
        // A block whose width does not match the negotiated layout cannot be routed
        // safely — dropping it beats writing one speaker into another's file.
        guard channels.count == meters.count, sampleRate > 0 else { return }

        let elapsed = Double(channels[0].count) / sampleRate
        readings = channels.indices.map { meters[$0].process(channels[$0], sampleRate: sampleRate) }
        receiverState.levelsChanged(readings: readings, elapsed: elapsed)
        receiverState.audioArrived(channels: channels, elapsed: elapsed)
        session?.append(channels: channels)
        recordingState = session?.state ?? .idle
    }

    // MARK: - Transport

    public func startRecording() {
        guard !isRecording else { return }
        guard let receiver = receiverState.receiver else {
            errorMessage = "No receiver connected."
            return
        }
        guard receiverState.connectedMicCount > 0 else {
            errorMessage = "No microphones are live. Switch on a transmitter and try again."
            return
        }

        let session = RecordingSession(
            receiver: receiver,
            store: store,
            writerFactory: writerFactory,
            title: title,
            speakerNames: speakerNames,
            format: format
        )
        do {
            try session.start()
            self.session = session
            recordingState = .recording
            errorMessage = nil
        } catch {
            errorMessage = "Could not start recording: \(error.localizedDescription)"
        }
    }

    public func pauseRecording() {
        session?.pause()
        recordingState = session?.state ?? .idle
    }

    public func resumeRecording() {
        session?.resume()
        recordingState = session?.state ?? .idle
    }

    @discardableResult
    public func stopRecording() -> StoredSession? {
        guard let session, session.isRunning else { return nil }
        defer { self.session = nil; recordingState = .idle; title = Self.defaultTitle() }

        do {
            let saved = try session.stop()
            refreshSessions()
            return saved
        } catch {
            errorMessage = "Could not save the recording: \(error.localizedDescription)"
            return nil
        }
    }

    public func deleteSession(_ session: StoredSession) {
        do {
            try store.delete(session.directory)
            refreshSessions()
        } catch {
            errorMessage = "Could not delete the recording: \(error.localizedDescription)"
        }
    }

    public func dismissError() { errorMessage = nil }

    /// The stored transcript for a session, if it has been transcribed.
    public func transcript(for session: StoredSession) -> Transcript? {
        store.readTranscript(for: session)
    }

    public var canTranscribe: Bool { transcriber.isAvailable }
    public var transcriptionUnavailableReason: String? { transcriber.unavailableReason }

    /// Transcribes every track and saves the merged script beside the audio.
    public func transcribe(_ session: StoredSession) async {
        guard transcribingSessionID == nil else { return }
        transcribingSessionID = session.id
        errorMessage = nil
        defer { transcribingSessionID = nil }

        do {
            let transcript = try await SessionTranscription(engine: transcriber).transcribe(session)
            try store.attachTranscript(transcript, to: session)
            refreshSessions()
        } catch let error as TranscriptionError {
            errorMessage = Self.message(for: error)
        } catch {
            errorMessage = "Transcription failed: \(error.localizedDescription)"
        }
    }

    private static func message(for error: TranscriptionError) -> String {
        switch error {
        case .unavailable(let reason), .failed(let reason): reason
        }
    }

    /// Re-reads the library from disk.
    ///
    /// Worth calling whenever the app regains focus: recordings can be added or
    /// removed in Finder while it is open, and a list that still shows a session
    /// whose files are gone offers the user nothing but a confusing error.
    public func reloadSessions() {
        refreshSessions()
    }

    private func refreshSessions() {
        sessions = (try? store.listSessions()) ?? []
    }

    /// Saves an in-flight take when the hardware goes away underneath it.
    ///
    /// Losing minutes of a conversation because someone knocked the cable is the
    /// worst failure this app has, so an interrupted recording is committed to disk
    /// and the user is told, rather than being discarded silently.
    private func finishInterruptedRecording(reason: String) {
        guard let session, session.isRunning else { return }
        self.session = nil
        recordingState = .idle
        do {
            _ = try session.stop()
            refreshSessions()
            title = Self.defaultTitle()
            errorMessage = reason
        } catch {
            errorMessage = "The receiver went away and the recording could not be saved: \(error.localizedDescription)"
        }
    }

    static func defaultTitle(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Recording \(formatter.string(from: date))"
    }
}
