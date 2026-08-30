import AVFoundation
import LapelKit
import SwiftUI

/// Loads a session's combined mix, draws it, and plays the selected stretch.
///
/// Playback goes through a temporary WAV rather than an in-memory buffer: writing
/// the mix once buys accurate seeking and a reliable `currentTime` from
/// AVAudioPlayer, which a raw buffer would mean reimplementing.
@MainActor
@Observable
final class MixPreview {

    private(set) var summary: WaveformSummary = .empty
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var isPlaying = false
    private(set) var playhead: TimeInterval = 0

    var trim = TrimSelection(duration: 0)

    private var player: AVAudioPlayer?
    private var temporaryFile: URL?
    private var ticker: Timer?
    private var loadedSessionID: UUID?

    var duration: TimeInterval { summary.duration }
    var hasAudio: Bool { !summary.bins.isEmpty }

    func load(_ session: StoredSession, binCount: Int = 900) async {
        guard loadedSessionID != session.id else { return }
        loadedSessionID = session.id
        isLoading = true
        errorMessage = nil
        stop()

        let directory = session.directory
        let result: Result<(WaveformSummary, URL), Error> = await Task.detached(priority: .userInitiated) {
            do {
                let mix = try SessionMixLoader().load(session)
                let summary = WaveformSummary.make(
                    from: mix.samples, sampleRate: mix.sampleRate, binCount: binCount
                )

                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("lapel-preview-\(session.id.uuidString).wav")
                try? FileManager.default.removeItem(at: url)
                let writer = try AudioFileTrackWriter(url: url, sampleRate: mix.sampleRate, format: .wav)
                try writer.write(mix.samples)
                try writer.finish()

                return .success((summary, url))
            } catch {
                _ = directory
                return .failure(error)
            }
        }.value

        switch result {
        case .success(let (summary, url)):
            self.summary = summary
            self.temporaryFile = url
            self.trim = TrimSelection(duration: summary.duration)
            self.player = try? AVAudioPlayer(contentsOf: url)
            self.player?.prepareToPlay()
        case .failure:
            // Distinguished because the two need different responses: a missing
            // folder means the recording is gone, not that decoding failed.
            self.errorMessage = FileManager.default.fileExists(atPath: directory.path)
                ? "This recording's audio could not be read."
                : "This recording's files are no longer on disk."
        }
        isLoading = false
    }

    /// Plays the selection, from the playhead if it sits inside it.
    func play() {
        guard let player else { return }
        let from = trim.contains(playhead) && playhead < trim.end - 0.05 ? playhead : trim.start

        player.currentTime = from
        player.play()
        isPlaying = true

        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
    }

    func stop() {
        player?.pause()
        isPlaying = false
        ticker?.invalidate()
        ticker = nil
    }

    func toggle() { isPlaying ? stop() : play() }

    func seek(to time: TimeInterval) {
        playhead = min(max(0, time), duration)
        player?.currentTime = playhead
    }

    private func tick() {
        guard let player else { return }
        playhead = player.currentTime
        // Stops at the out point rather than running past it, so what you hear is
        // exactly what export will produce.
        if playhead >= trim.end || !player.isPlaying {
            stop()
            playhead = min(playhead, trim.end)
        }
    }

    func discard() {
        stop()
        player = nil
        if let temporaryFile { try? FileManager.default.removeItem(at: temporaryFile) }
        temporaryFile = nil
        loadedSessionID = nil
    }
}
