import Foundation

public enum TranscriptionError: Error, Equatable {
    case unavailable(String)
    case failed(String)
}

/// Turns one recorded track into attributed segments.
///
/// Per *track*, not per session: because each speaker was wearing their own
/// microphone, attribution is already settled before any model runs. The engine
/// only has to answer "what words", never "whose words" — which is the part
/// diarization gets wrong.
public protocol Transcribing: Sendable {
    /// Whether this engine can run on the current machine.
    var isAvailable: Bool { get }
    /// Why it cannot, when it cannot — shown to the user verbatim.
    var unavailableReason: String? { get }

    func transcribe(
        fileURL: URL,
        speaker: String,
        channelIndex: Int
    ) async throws -> [TranscriptSegment]
}

/// Stands in where no on-device engine is available, reporting why rather than
/// failing silently or pretending to work.
public struct UnavailableTranscriber: Transcribing {
    public let unavailableReason: String?

    public init(reason: String = "On-device transcription requires macOS 26 or later.") {
        self.unavailableReason = reason
    }

    public var isAvailable: Bool { false }

    public func transcribe(fileURL: URL, speaker: String, channelIndex: Int) async throws -> [TranscriptSegment] {
        throw TranscriptionError.unavailable(unavailableReason ?? "Transcription is unavailable.")
    }
}
