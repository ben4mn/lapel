import Foundation

public enum RecordingState: Equatable, Sendable {
    case idle, recording, paused, finished
}

public enum RecordingError: Error, Equatable {
    case alreadyRecording
    case notRecording
    case noChannels
}

/// Drives one recording from start to saved session.
///
/// Holds no CoreAudio or AVFoundation types: audio arrives as deinterleaved
/// `[[Float]]`, one array per channel, and leaves through `TrackWriting`. That is
/// what makes the whole lifecycle — arming, routing, pausing, discarding dead
/// channels, persisting metadata — testable without hardware.
///
/// Not thread safe by design. `append(channels:)` must be called from a single
/// serial context; the capture layer hops buffers off the realtime thread first,
/// because allocating or taking a lock inside a CoreAudio render callback is how
/// you get dropouts.
public final class RecordingSession {

    public let receiver: Receiver
    public let title: String
    public let format: RecordingFormat

    private let store: SessionStore
    private let writerFactory: TrackWriterFactory
    private let speakerNames: [String]

    public private(set) var state: RecordingState = .idle
    /// Errors from the writers, surfaced rather than swallowed — audio silently
    /// failing to reach disk is the worst outcome this app has.
    public private(set) var lastError: Error?

    private var handle: SessionHandle?
    private var writers: [TrackWriting] = []
    private var framesWritten: Int = 0
    /// Highest absolute sample seen per channel, used for the level shown in the
    /// library and to decide whether a channel carried anything at all.
    private var channelPeaks: [Float] = []

    public init(
        receiver: Receiver,
        store: SessionStore,
        writerFactory: TrackWriterFactory,
        title: String,
        speakerNames: [String] = [],
        format: RecordingFormat = .aac
    ) {
        self.receiver = receiver
        self.store = store
        self.writerFactory = writerFactory
        self.title = title
        self.format = format
        self.speakerNames = speakerNames
    }

    /// Duration is derived from frames committed to disk, never from the wall clock:
    /// what the user gets back is the audio that was actually written.
    public var duration: TimeInterval {
        receiver.device.sampleRate > 0 ? Double(framesWritten) / receiver.device.sampleRate : 0
    }

    public var isRunning: Bool { state == .recording || state == .paused }

    /// The name shown for a channel — an explicit speaker name if given, otherwise
    /// the transmitter label ("TX1", or "Mixed" for a mono receiver).
    public func name(forChannel index: Int) -> String {
        if index < speakerNames.count, !speakerNames[index].isEmpty { return speakerNames[index] }
        return receiver.tracks.first { $0.channelIndex == index }?.defaultName ?? "Track \(index + 1)"
    }

    public func start(at date: Date = Date()) throws {
        guard state == .idle else { throw RecordingError.alreadyRecording }
        let tracks = receiver.tracks
        guard !tracks.isEmpty else { throw RecordingError.noChannels }

        let handle = try store.createSession(title: title, at: date)
        self.handle = handle

        writers = try tracks.map { track in
            let url = handle.trackURL(
                channelIndex: track.channelIndex,
                speakerName: name(forChannel: track.channelIndex),
                format: format
            )
            return try writerFactory.makeWriter(url: url, sampleRate: receiver.device.sampleRate, format: format)
        }
        channelPeaks = Array(repeating: 0, count: tracks.count)
        framesWritten = 0
        state = .recording
    }

    /// Accepts one deinterleaved block. Anything arriving outside `.recording` is
    /// dropped: a late buffer after stop must not reopen a finished file.
    public func append(channels: [[Float]]) {
        guard state == .recording else { return }

        for (index, writer) in writers.enumerated() {
            guard index < channels.count else { continue }
            let block = channels[index]
            channelPeaks[index] = max(channelPeaks[index], block.reduce(0) { max($0, abs($1)) })
            do {
                try writer.write(block)
            } catch {
                lastError = error
            }
        }

        framesWritten += channels.first?.count ?? 0
    }

    public func pause() {
        guard state == .recording else { return }
        state = .paused
    }

    public func resume() {
        guard state == .paused else { return }
        state = .recording
    }

    /// Closes every track, drops channels that never carried a transmitter, and
    /// writes `session.json`.
    @discardableResult
    public func stop() throws -> StoredSession {
        guard isRunning, let handle else { throw RecordingError.notRecording }

        var tracks: [TrackMetadata] = []
        for (index, writer) in writers.enumerated() {
            let peak = channelPeaks[index]
            // True digital zero for the whole recording means no transmitter was
            // ever linked on this channel. Keeping the file would hand the user a
            // silent track they have to work out and delete themselves.
            if peak == 0 {
                writer.discard()
                continue
            }
            do { try writer.finish() } catch { lastError = error }
            tracks.append(TrackMetadata(
                channelIndex: index,
                speakerName: name(forChannel: index),
                fileName: writer.url.lastPathComponent,
                peakDB: LevelMeter.decibels(peak)
            ))
        }

        var metadata = SessionMetadata(
            id: handle.id,
            title: title,
            createdAt: Date(),
            deviceName: receiver.device.name,
            inputChannelCount: receiver.device.inputChannelCount,
            sampleRate: receiver.device.sampleRate,
            format: format
        )
        metadata.duration = duration
        metadata.tracks = tracks

        try store.write(metadata, to: handle)
        writers = []
        state = .finished

        return StoredSession(directory: handle.directory, metadata: metadata)
    }
}
