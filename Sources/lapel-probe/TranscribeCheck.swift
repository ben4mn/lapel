#if compiler(>=6.2)

import AVFoundation
import Foundation
import LapelKit
import Speech

/// Diagnostics for the transcription path.
///
/// The GUI can only tell you that a transcript came back empty. This says which
/// stage produced nothing: model availability, locale resolution, audio format, or
/// the analyzer itself.
@available(macOS 26.0, *)
enum TranscribeCheck {

    static func run(sessionDirectory: URL) async {
        func emit(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }

        let store = SessionStore(root: sessionDirectory.deletingLastPathComponent())
        guard let metadata = try? store.readMetadata(from: sessionDirectory) else {
            emit("No session.json in \(sessionDirectory.path)"); return
        }
        let session = StoredSession(directory: sessionDirectory, metadata: metadata)

        emit("Session: \(session.title) — \(metadata.tracks.count) tracks")
        emit("SpeechTranscriber.isAvailable: \(SpeechTranscriber.isAvailable)")

        let current = Locale.current
        let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: current)
        emit("locale: \(current.identifier) → resolved: \(resolved?.identifier ?? "nil")")
        emit("installed locales: \(await SpeechTranscriber.installedLocales.map(\.identifier))")

        let transcriber = SpeechTranscriber(
            locale: resolved ?? current,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        emit("asset status: \(await AssetInventory.status(forModules: [transcriber]))")
        emit("compatible formats: \(await transcriber.availableCompatibleAudioFormats.count)")

        for track in metadata.tracks {
            let url = sessionDirectory.appendingPathComponent(track.fileName)
            if let file = try? AVAudioFile(forReading: url) {
                emit("  \(track.fileName): \(file.length) frames, \(file.processingFormat)")
            }
        }

        do {
            let segments = try await SpeechAnalyzerTranscriber().transcribe(
                fileURL: sessionDirectory.appendingPathComponent(metadata.tracks[0].fileName),
                speaker: metadata.tracks[0].displayName,
                channelIndex: 0
            )
            emit("\nsegments: \(segments.count)")
            for segment in segments {
                emit(String(format: "  [%.2f–%.2f] %@", segment.start, segment.end, segment.text))
            }
        } catch {
            emit("\nFAILED: \(error)")
        }
    }
}

#endif
