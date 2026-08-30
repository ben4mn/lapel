// Apple's SpeechAnalyzer landed in the macOS 26 SDK, which ships with Xcode 26 and
// its Swift 6.2 toolchain. There is no `#if canImport` for a *type*, so the compiler
// version stands in for the SDK version: with Xcode 16.4 (Swift 6.1) this file is
// skipped entirely and LapelKit still builds, falling back to UnavailableTranscriber.
#if compiler(>=6.2)

import AVFoundation
import Foundation
import Speech

/// Transcribes one recorded track with Apple's on-device speech engine.
///
/// One track at a time, and that is the point: because each speaker wore their own
/// microphone, this only ever has to answer "what words". It is never asked "whose
/// words" — the question diarization exists to guess at, and gets wrong.
@available(macOS 26.0, *)
public struct SpeechAnalyzerTranscriber: Transcribing {

    public let locale: Locale

    public init(locale: Locale = .current) {
        self.locale = locale
    }

    public var isAvailable: Bool { SpeechTranscriber.isAvailable }

    public var unavailableReason: String? {
        isAvailable ? nil : "On-device transcription is not available on this Mac."
    }

    public func transcribe(
        fileURL: URL,
        speaker: String,
        channelIndex: Int
    ) async throws -> [TranscriptSegment] {
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.unavailable("On-device transcription is not available on this Mac.")
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: fileURL)
        } catch {
            throw TranscriptionError.failed("Could not open \(fileURL.lastPathComponent).")
        }

        // Falls back to the nearest supported locale rather than failing outright:
        // en_GB and en_US should not be the difference between a transcript and none.
        let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? locale

        let transcriber = SpeechTranscriber(
            locale: resolved,
            transcriptionOptions: [],
            // No volatile results: this is a finished file, so partial hypotheses
            // that will be revised are noise. Every result that arrives is final.
            reportingOptions: [],
            // The whole reason segments can be interleaved back into a conversation.
            attributeOptions: [.audioTimeRange]
        )

        try await installModelIfNeeded(for: transcriber, locale: resolved)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        // finishAfterFile ends the results sequence when the file runs out, which is
        // what lets the loop below simply terminate.
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)

        var segments: [TranscriptSegment] = []
        do {
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

                segments.append(TranscriptSegment(
                    speaker: speaker,
                    channelIndex: channelIndex,
                    start: result.range.start.seconds,
                    end: result.range.end.seconds,
                    text: text
                ))
            }
        } catch {
            throw TranscriptionError.failed(error.localizedDescription)
        }

        return segments
    }

    /// The language model is downloaded on demand, once per locale.
    private func installModelIfNeeded(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        guard await AssetInventory.status(forModules: [transcriber]) != .installed else { return }
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            throw TranscriptionError.unavailable(
                "The speech model for \(locale.identifier) could not be downloaded: \(error.localizedDescription)"
            )
        }
    }
}

#endif
