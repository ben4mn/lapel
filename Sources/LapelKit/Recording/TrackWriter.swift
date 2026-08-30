import Foundation

public enum TrackWriterError: Error, Equatable {
    case writeFailed(String)
    case cannotCreateFile(String)
}

/// Somewhere a single channel of audio is being written.
///
/// A protocol rather than a concrete `AVAudioFile` so the recording state machine
/// can be driven by fakes, with no encoder and no audio device involved.
public protocol TrackWriting: AnyObject, Sendable {
    var url: URL { get }
    var framesWritten: Int { get }
    func write(_ samples: [Float]) throws
    /// Closes the file, keeping it.
    func finish() throws
    /// Closes the file and removes it — used for channels that never carried a transmitter.
    func discard()
}

public protocol TrackWriterFactory: Sendable {
    func makeWriter(url: URL, sampleRate: Double, format: RecordingFormat) throws -> TrackWriting
}
