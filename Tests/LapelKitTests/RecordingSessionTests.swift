import Testing
import Foundation
@testable import LapelKit

/// An in-memory stand-in for an AVAudioFile, so the state machine is exercised
/// without touching an encoder or an audio device.
private final class FakeTrackWriter: TrackWriting, @unchecked Sendable {
    let url: URL
    private(set) var samples: [Float] = []
    private(set) var isFinished = false
    private(set) var isDiscarded = false
    var failOnWrite: Bool = false

    init(url: URL) { self.url = url }

    var framesWritten: Int { samples.count }

    func write(_ block: [Float]) throws {
        if failOnWrite { throw TrackWriterError.writeFailed("fake") }
        samples.append(contentsOf: block)
    }

    func finish() throws { isFinished = true }
    func discard() { isDiscarded = true }
}

private final class FakeWriterFactory: TrackWriterFactory, @unchecked Sendable {
    private(set) var made: [FakeTrackWriter] = []
    var failChannel: Int?

    func makeWriter(url: URL, sampleRate: Double, format: RecordingFormat) throws -> TrackWriting {
        let writer = FakeTrackWriter(url: url)
        if made.count == failChannel { writer.failOnWrite = true }
        made.append(writer)
        return writer
    }
}

private func makeStore() throws -> SessionStore {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("LapelRec-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return SessionStore(root: root)
}

private func makeReceiver(channels: Int = 2) -> Receiver {
    Receiver(device: AudioDeviceDescriptor(
        uid: "DJI-1", name: "DJI MIC MINI", manufacturer: "DJI",
        inputChannelCount: channels, sampleRate: 48_000, transport: .usb
    ))
}

/// One second of a steady tone at a known amplitude, so peak assertions are exact.
private func tone(amplitude: Float, frames: Int = 48_000) -> [Float] {
    (0..<frames).map { i in amplitude * Float(sin(2 * Double.pi * 1_000 * Double(i) / 48_000)) }
}

@Suite("RecordingSession")
struct RecordingSessionTests {

    private func makeSession(
        channels: Int = 2,
        store: SessionStore? = nil,
        factory: FakeWriterFactory = FakeWriterFactory(),
        speakers: [String] = []
    ) throws -> (RecordingSession, FakeWriterFactory, SessionStore) {
        let store = try store ?? makeStore()
        let session = RecordingSession(
            receiver: makeReceiver(channels: channels),
            store: store,
            writerFactory: factory,
            title: "Kickoff",
            speakerNames: speakers,
            format: .aac
        )
        return (session, factory, store)
    }

    @Test("a new session is idle and has recorded nothing")
    func startsIdle() throws {
        let (session, _, _) = try makeSession()
        #expect(session.state == .idle)
        #expect(session.duration == 0)
    }

    @Test("starting opens one writer per receiver channel")
    func startOpensWritersPerChannel() throws {
        let (session, factory, _) = try makeSession(channels: 2)
        try session.start()

        #expect(session.state == .recording)
        #expect(factory.made.count == 2)
        #expect(factory.made.map { $0.url.lastPathComponent } == ["01-tx1.m4a", "02-tx2.m4a"])
    }

    @Test("speaker names given up front become the track filenames")
    func speakerNamesDriveFilenames() throws {
        let (session, factory, _) = try makeSession(speakers: ["Ben", "Dana"])
        try session.start()

        #expect(factory.made.map { $0.url.lastPathComponent } == ["01-ben.m4a", "02-dana.m4a"])
    }

    @Test("a mono receiver records a single mixed track")
    func monoRecordsOneTrack() throws {
        let (session, factory, _) = try makeSession(channels: 1)
        try session.start()

        #expect(factory.made.count == 1)
        #expect(factory.made[0].url.lastPathComponent == "01-mixed.m4a")
    }

    @Test("starting twice is refused rather than silently reopening files")
    func doubleStartIsRefused() throws {
        let (session, _, _) = try makeSession()
        try session.start()
        #expect(throws: RecordingError.alreadyRecording) { try session.start() }
    }

    @Test("each channel's audio lands in its own writer")
    func channelsRouteToOwnWriters() throws {
        let (session, factory, _) = try makeSession()
        try session.start()
        session.append(channels: [[0.1, 0.2], [0.7, 0.8]])

        #expect(factory.made[0].samples == [0.1, 0.2])
        #expect(factory.made[1].samples == [0.7, 0.8])
    }

    @Test("duration comes from frames written, not from the wall clock")
    func durationDerivesFromFrames() throws {
        let (session, _, _) = try makeSession()
        try session.start()
        session.append(channels: [tone(amplitude: 0.5), tone(amplitude: 0.5)])

        #expect(abs(session.duration - 1.0) < 0.0001)
    }

    @Test("audio arriving before start is dropped instead of crashing")
    func appendBeforeStartIsIgnored() throws {
        let (session, factory, _) = try makeSession()
        session.append(channels: [[0.1], [0.2]])

        #expect(factory.made.isEmpty)
        #expect(session.duration == 0)
    }

    @Test("while paused, audio is dropped and duration holds still")
    func pauseDropsAudio() throws {
        let (session, factory, _) = try makeSession()
        try session.start()
        session.append(channels: [tone(amplitude: 0.5), tone(amplitude: 0.5)])
        session.pause()
        session.append(channels: [tone(amplitude: 0.5), tone(amplitude: 0.5)])

        #expect(session.state == .paused)
        #expect(factory.made[0].framesWritten == 48_000)
        #expect(abs(session.duration - 1.0) < 0.0001)
    }

    @Test("resuming continues into the same files")
    func resumeContinues() throws {
        let (session, factory, _) = try makeSession()
        try session.start()
        session.append(channels: [[0.1], [0.1]])
        session.pause()
        session.resume()
        session.append(channels: [[0.2], [0.2]])

        #expect(session.state == .recording)
        #expect(factory.made[0].samples == [0.1, 0.2])
    }

    @Test("stopping finishes every writer and returns the saved session")
    func stopFinishesWriters() throws {
        let (session, factory, _) = try makeSession()
        try session.start()
        session.append(channels: [tone(amplitude: 0.5), tone(amplitude: 0.25)])
        let saved = try session.stop()

        #expect(session.state == .finished)
        #expect(factory.made.filter(\.isFinished).count == 2)
        #expect(saved.title == "Kickoff")
        #expect(abs(saved.duration - 1.0) < 0.0001)
    }

    @Test("the saved metadata records each track's peak level")
    func metadataCapturesPeaks() throws {
        let (session, _, _) = try makeSession(speakers: ["Ben", "Dana"])
        try session.start()
        session.append(channels: [tone(amplitude: 1.0), tone(amplitude: 0.5)])
        let saved = try session.stop()

        #expect(saved.metadata.tracks.map(\.speakerName) == ["Ben", "Dana"])
        #expect(abs(saved.metadata.tracks[0].peakDB - 0) < 0.05)
        #expect(abs(saved.metadata.tracks[1].peakDB - (-6.02)) < 0.05)
    }

    @Test("stopping writes session.json so the recording is readable without the app")
    func stopPersistsMetadata() throws {
        let (session, _, store) = try makeSession()
        try session.start()
        session.append(channels: [[0.5], [0.5]])
        let saved = try session.stop()

        let reloaded = try store.readMetadata(from: saved.directory)
        #expect(reloaded.title == "Kickoff")
        #expect(reloaded.inputChannelCount == 2)
        #expect(reloaded.sampleRate == 48_000)
    }

    @Test("a channel that never carried a transmitter is discarded, not saved as a silent file")
    func discardsSilentChannels() throws {
        let (session, factory, _) = try makeSession()
        try session.start()
        // Only TX1 was switched on; channel 1 carries true digital zero throughout.
        session.append(channels: [tone(amplitude: 0.5), [Float](repeating: 0, count: 48_000)])
        let saved = try session.stop()

        #expect(saved.metadata.tracks.count == 1)
        #expect(saved.metadata.tracks[0].channelIndex == 0)
        #expect(factory.made[1].isDiscarded)
        #expect(!factory.made[0].isDiscarded)
    }

    @Test("stopping without having started is refused")
    func stopWithoutStart() throws {
        let (session, _, _) = try makeSession()
        #expect(throws: RecordingError.notRecording) { _ = try session.stop() }
    }

    @Test("a writer failing mid-session is surfaced and does not silently drop audio")
    func writerFailureIsSurfaced() throws {
        let factory = FakeWriterFactory()
        factory.failChannel = 1
        let (session, _, _) = try makeSession(factory: factory)
        try session.start()
        session.append(channels: [[0.1], [0.2]])

        #expect(session.lastError != nil)
    }

    @Test("stopping is idempotent enough that a second stop is refused, not a crash")
    func doubleStopIsRefused() throws {
        let (session, _, _) = try makeSession()
        try session.start()
        session.append(channels: [[0.5], [0.5]])
        _ = try session.stop()

        #expect(throws: RecordingError.notRecording) { _ = try session.stop() }
    }
}
