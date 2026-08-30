import Foundation

/// Transcribes every track of a session and reassembles the conversation.
///
/// The engine is asked one track at a time, and each answer arrives already
/// attributed — the speaker name comes from the track metadata, never from the
/// audio. Reassembly is then pure ordering.
public struct SessionTranscription: Sendable {

    private let engine: any Transcribing

    public init(engine: any Transcribing) {
        self.engine = engine
    }

    public func transcribe(_ session: StoredSession) async throws -> Transcript {
        guard engine.isAvailable else {
            throw TranscriptionError.unavailable(engine.unavailableReason ?? "Transcription is unavailable.")
        }
        guard !session.metadata.tracks.isEmpty else {
            throw TranscriptionError.failed("This recording has no tracks to transcribe.")
        }

        var perTrack: [[TranscriptSegment]] = []
        var failures: [String] = []

        for track in session.metadata.tracks {
            let url = session.directory.appendingPathComponent(track.fileName)
            do {
                perTrack.append(try await engine.transcribe(
                    fileURL: url,
                    speaker: track.displayName,
                    channelIndex: track.channelIndex
                ))
            } catch {
                // One speaker's file being unreadable must not cost the other their
                // transcript — the recordings are genuinely independent.
                failures.append(track.fileName)
            }
        }

        guard failures.count < session.metadata.tracks.count else {
            throw TranscriptionError.failed("None of this recording's tracks could be transcribed.")
        }

        return Transcript.merge(perTrack)
    }
}
