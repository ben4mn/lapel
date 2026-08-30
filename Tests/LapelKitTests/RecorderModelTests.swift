import Testing
import Foundation
@testable import LapelKit

private final class FakeCapture: AudioCapturing, @unchecked Sendable {
    let device: AudioDeviceDescriptor
    private(set) var isRunning = false
    @MainActor private var handler: AudioBufferHandler?
    var failToStart = false

    init(device: AudioDeviceDescriptor) { self.device = device }

    @MainActor func start(onBuffer: @escaping AudioBufferHandler) throws {
        if failToStart { throw AudioCaptureError.engineFailedToStart("fake") }
        handler = onBuffer
        isRunning = true
    }

    @MainActor func stop() { isRunning = false; handler = nil }

    /// Pushes one block into whatever the model wired up.
    @MainActor func emit(_ channels: [[Float]], sampleRate: Double = 48_000) { handler?(channels, sampleRate) }
}

private final class FakeCaptureFactory: AudioCaptureFactory, @unchecked Sendable {
    private(set) var made: [FakeCapture] = []
    var failToStart = false

    func makeCapture(device: AudioDeviceDescriptor) -> AudioCapturing {
        let capture = FakeCapture(device: device)
        capture.failToStart = failToStart
        made.append(capture)
        return capture
    }
    var latest: FakeCapture? { made.last }
}

private final class FakeWriter: TrackWriting, @unchecked Sendable {
    let url: URL
    private(set) var samples: [Float] = []
    private(set) var isDiscarded = false
    init(url: URL) { self.url = url }
    var framesWritten: Int { samples.count }
    func write(_ block: [Float]) throws { samples.append(contentsOf: block) }
    func finish() throws {}
    func discard() { isDiscarded = true }
}

private final class FakeWriterFactory: TrackWriterFactory, @unchecked Sendable {
    private(set) var made: [FakeWriter] = []
    func makeWriter(url: URL, sampleRate: Double, format: RecordingFormat) throws -> TrackWriting {
        let writer = FakeWriter(url: url); made.append(writer); return writer
    }
}

private func dji(channels: Int = 2) -> AudioDeviceDescriptor {
    AudioDeviceDescriptor(uid: "DJI-1", name: "DJI MIC MINI", manufacturer: "DJI",
                          inputChannelCount: channels, sampleRate: 48_000, transport: .usb)
}

private let builtIn = AudioDeviceDescriptor(
    uid: "builtin", name: "MacBook Air Microphone", manufacturer: "Apple Inc.",
    inputChannelCount: 1, sampleRate: 48_000, transport: .builtIn)

/// One second of steady tone per channel — enough signal to read as a live mic.
private func liveAudio(_ channels: Int = 2, amplitude: Float = 0.3, frames: Int = 48_000) -> [[Float]] {
    (0..<channels).map { _ in (0..<frames).map { i in amplitude * Float(sin(Double(i) * 0.1)) } }
}

private func silentAudio(_ channels: Int = 2, frames: Int = 48_000) -> [[Float]] {
    (0..<channels).map { _ in [Float](repeating: 0, count: frames) }
}

@MainActor
@Suite("RecorderModel")
struct RecorderModelTests {

    private func makeModel() throws -> (RecorderModel, FakeCaptureFactory, FakeWriterFactory) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LapelModel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let captures = FakeCaptureFactory()
        let writers = FakeWriterFactory()
        let model = RecorderModel(
            store: SessionStore(root: root),
            writerFactory: writers,
            captureFactory: captures
        )
        return (model, captures, writers)
    }

    @Test("with nothing plugged in the model is idle and cannot record")
    func idleWithNoHardware() throws {
        let (model, captures, _) = try makeModel()

        #expect(model.statusSummary == "No receiver connected")
        #expect(!model.canRecord)
        #expect(model.readings.isEmpty)
        #expect(captures.made.isEmpty)
    }

    @Test("connecting the receiver opens capture so meters run before recording")
    func connectingStartsCapture() throws {
        let (model, captures, _) = try makeModel()
        model.devicesChanged(to: [builtIn, dji()])

        #expect(captures.made.count == 1)
        #expect(captures.latest?.isRunning == true)
        #expect(model.readings.count == 2)
    }

    @Test("incoming audio drives the meters and the live microphone count")
    func audioDrivesMeters() throws {
        let (model, captures, _) = try makeModel()
        model.devicesChanged(to: [dji()])
        captures.latest?.emit(liveAudio())

        #expect(model.readings[0].rmsDB > -40)
        #expect(model.statusSummary == "DJI MIC MINI — 2 of 2 microphones live")
        #expect(model.canRecord)
    }

    @Test("a channel carrying digital silence is not counted as a microphone")
    func silentChannelNotCounted() throws {
        let (model, captures, _) = try makeModel()
        model.devicesChanged(to: [dji()])
        captures.latest?.emit([liveAudio(1)[0], silentAudio(1)[0]])

        #expect(model.statusSummary == "DJI MIC MINI — 1 of 2 microphones live")
    }

    @Test("recording is refused when no transmitter is live, with a reason")
    func cannotRecordWithoutLiveMic() throws {
        let (model, _, writers) = try makeModel()
        model.devicesChanged(to: [dji()])
        model.startRecording()

        #expect(model.recordingState == .idle)
        #expect(model.errorMessage != nil)
        #expect(writers.made.isEmpty)
    }

    @Test("recording routes each channel to its own writer")
    func recordingRoutesChannels() throws {
        let (model, captures, writers) = try makeModel()
        model.devicesChanged(to: [dji()])
        captures.latest?.emit(liveAudio())
        model.startRecording()
        captures.latest?.emit([[0.1, 0.2], [0.7, 0.8]])

        #expect(model.recordingState == .recording)
        #expect(writers.made.count == 2)
        #expect(writers.made[0].samples == [0.1, 0.2])
        #expect(writers.made[1].samples == [0.7, 0.8])
    }

    @Test("speaker names typed before recording become the track filenames")
    func speakerNamesDriveFiles() throws {
        let (model, captures, writers) = try makeModel()
        model.devicesChanged(to: [dji()])
        captures.latest?.emit(liveAudio())
        model.speakerNames = ["Ben", "Dana"]
        model.startRecording()

        #expect(writers.made.map { $0.url.lastPathComponent } == ["01-ben.m4a", "02-dana.m4a"])
    }

    @Test("elapsed time tracks the audio actually committed")
    func elapsedTracksAudio() throws {
        let (model, captures, _) = try makeModel()
        model.devicesChanged(to: [dji()])
        captures.latest?.emit(liveAudio())
        model.startRecording()
        captures.latest?.emit(liveAudio())

        #expect(abs(model.elapsed - 1.0) < 0.0001)
    }

    @Test("stopping saves the session and it appears in the library")
    func stoppingSaves() throws {
        let (model, captures, _) = try makeModel()
        model.devicesChanged(to: [dji()])
        captures.latest?.emit(liveAudio())
        model.title = "Kickoff"
        model.startRecording()
        captures.latest?.emit(liveAudio())
        model.stopRecording()

        #expect(model.recordingState == .idle)
        #expect(model.sessions.count == 1)
        #expect(model.sessions[0].title == "Kickoff")
        #expect(model.elapsed == 0)
    }

    @Test("pulling the receiver mid-recording saves the take rather than losing it")
    func unplugMidRecordingSavesTake() throws {
        let (model, captures, _) = try makeModel()
        model.devicesChanged(to: [dji()])
        captures.latest?.emit(liveAudio())
        model.title = "Interrupted"
        model.startRecording()
        captures.latest?.emit(liveAudio())

        model.devicesChanged(to: [builtIn])   // receiver yanked

        #expect(model.recordingState == .idle)
        #expect(model.sessions.count == 1)
        #expect(model.sessions[0].title == "Interrupted")
        #expect(abs(model.sessions[0].duration - 1.0) < 0.0001)
        #expect(model.errorMessage?.contains("disconnected") == true)
    }

    @Test("unplugging while idle simply clears the meters")
    func unplugWhileIdleIsQuiet() throws {
        let (model, captures, _) = try makeModel()
        model.devicesChanged(to: [dji()])
        captures.latest?.emit(liveAudio())
        model.devicesChanged(to: [builtIn])

        #expect(model.readings.isEmpty)
        #expect(!model.canRecord)
        #expect(model.errorMessage == nil)
        #expect(captures.latest?.isRunning == false)
    }

    @Test("switching the receiver from mono to stereo re-opens capture with two channels")
    func modeFlipReopensCapture() throws {
        let (model, captures, _) = try makeModel()
        model.devicesChanged(to: [dji(channels: 1)])
        #expect(model.readings.count == 1)
        #expect(model.advisory == .receiverInMonoMode)

        model.devicesChanged(to: [dji(channels: 2)])

        #expect(model.readings.count == 2)
        #expect(model.advisory == nil)
        #expect(captures.made.count == 2)
        #expect(captures.made[0].isRunning == false)
        #expect(captures.latest?.isRunning == true)
    }

    @Test("audio arriving with the wrong channel count is ignored rather than mis-routed")
    func mismatchedChannelCountIgnored() throws {
        let (model, captures, _) = try makeModel()
        model.devicesChanged(to: [dji()])
        captures.latest?.emit(liveAudio(3))

        #expect(model.readings.count == 2)
        #expect(model.readings.filter { $0.rmsDB == LevelMeter.floorDB }.count == 2)
    }

    @Test("a capture that fails to start surfaces the reason instead of showing dead meters")
    func captureFailureIsSurfaced() throws {
        let (model, captures, _) = try makeModel()
        captures.failToStart = true
        model.devicesChanged(to: [dji()])

        #expect(model.errorMessage != nil)
        #expect(!model.canRecord)
    }

    @Test("the default title is dated, non-empty, and cleared after saving")
    func defaultTitle() throws {
        let (model, captures, _) = try makeModel()
        #expect(!model.title.isEmpty)

        model.devicesChanged(to: [dji()])
        captures.latest?.emit(liveAudio())
        model.startRecording()
        model.stopRecording()

        #expect(!model.title.isEmpty)
    }

    @Test("speaker names default to the transmitter labels")
    func defaultSpeakerNames() throws {
        let (model, _, _) = try makeModel()
        model.devicesChanged(to: [dji()])

        #expect(model.speakerNames == ["TX1", "TX2"])
    }
}

@MainActor
@Suite("RecorderModel session library")
struct RecorderModelLibraryTests {

    @Test("reloading picks up sessions written by something other than this app")
    func reloadSeesExternalChanges() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LapelReload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = SessionStore(root: root)
        let model = RecorderModel(store: store)

        #expect(model.sessions.isEmpty)

        // Written behind the model's back — the same thing that happens when a
        // recording is added or removed in Finder while the app is open.
        let handle = try store.createSession(title: "Elsewhere", at: Date())
        try store.write(SessionMetadata(
            id: handle.id, title: "Elsewhere", createdAt: Date(),
            deviceName: "DJI", inputChannelCount: 2, sampleRate: 48_000, format: .aac), to: handle)

        model.reloadSessions()
        #expect(model.sessions.map(\.title) == ["Elsewhere"])
    }

    @Test("a session whose files have been removed drops out of the library on reload")
    func reloadDropsDeletedSessions() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LapelReload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = SessionStore(root: root)

        let handle = try store.createSession(title: "Doomed", at: Date())
        try store.write(SessionMetadata(
            id: handle.id, title: "Doomed", createdAt: Date(),
            deviceName: "DJI", inputChannelCount: 2, sampleRate: 48_000, format: .aac), to: handle)

        let model = RecorderModel(store: store)
        #expect(model.sessions.count == 1)

        try FileManager.default.removeItem(at: handle.directory)
        model.reloadSessions()

        #expect(model.sessions.isEmpty)
    }
}
