import AVFoundation
import Foundation
import LapelKit

/// Exercises the editing chain end to end against real files: mix, waveform, trim,
/// and the pair of exported files. The GUI shows the same thing, but this runs
/// without a display and prints numbers you can check.
enum PreviewCheck {

    static func run(sessionDirectory: URL, output: URL) {
        func emit(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }

        let store = SessionStore(root: sessionDirectory.deletingLastPathComponent())
        guard let metadata = try? store.readMetadata(from: sessionDirectory) else {
            emit("No session.json in \(sessionDirectory.path)"); return
        }
        let session = StoredSession(directory: sessionDirectory, metadata: metadata)

        do {
            let mix = try SessionMixLoader().load(session)
            emit("mix: \(mix.samples.count) frames @ \(Int(mix.sampleRate)) Hz "
                 + "= \(String(format: "%.2f", mix.duration))s, skipped \(mix.skippedTracks)")

            let summary = WaveformSummary.make(from: mix.samples, sampleRate: mix.sampleRate, binCount: 64)
            emit("peak: \(String(format: "%.3f", summary.peak))  (\(String(format: "%.1f", LevelMeter.decibels(summary.peak))) dBFS)")
            emit("waveform:")
            emit("  " + summary.normalizedBins.map { bar($0) }.joined())

            var trim = TrimSelection(duration: mix.duration)
            trim.setStart(mix.duration * 0.25)
            trim.setEnd(mix.duration * 0.75)
            emit("trim: \(Transcript.timecode(trim.start))–\(Transcript.timecode(trim.end)) "
                 + "(\(String(format: "%.2f", trim.selectedDuration))s of \(String(format: "%.2f", mix.duration))s)")

            var options = ExportOptions()
            options.audioFormat = .wav
            options.trim = trim
            let result = try SessionExporter().export(
                session, transcript: store.readTranscript(for: session), to: output, options: options
            )

            if let audio = result.audioURL {
                let written = try AVAudioFileTrackReader().readMono(from: audio)
                emit("exported audio: \(audio.lastPathComponent) "
                     + "= \(String(format: "%.2f", Double(written.samples.count) / written.sampleRate))s")
            }
            if let text = result.transcriptURL {
                emit("exported transcript: \(text.lastPathComponent)")
                emit((try String(contentsOf: text, encoding: .utf8))
                    .split(separator: "\n").map { "   | " + $0 }.joined(separator: "\n"))
            }
        } catch {
            emit("FAILED: \(error)")
        }
    }

    private static func bar(_ value: Float) -> String {
        let levels = [" ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
        return levels[min(Int(value * Float(levels.count - 1) + 0.5), levels.count - 1)]
    }
}
