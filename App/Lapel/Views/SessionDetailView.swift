import AVFoundation
import LapelKit
import SwiftUI

/// A finished recording: its tracks, and eventually its transcript.
struct SessionDetailView: View {
    let session: StoredSession
    @State private var player = TrackPlayer()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                VStack(spacing: 10) {
                    ForEach(session.metadata.tracks) { track in
                        TrackPlaybackRow(
                            track: track,
                            url: session.directory.appendingPathComponent(track.fileName),
                            player: player
                        )
                    }
                }

                TranscriptSection(session: session)
            }
            .padding(22)
        }
        .navigationTitle(session.title)
        .onDisappear { player.stop() }
        .toolbar {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([session.directory])
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.title).font(.largeTitle.weight(.semibold))
            Text("\(session.createdAt.formatted(date: .abbreviated, time: .shortened)) · "
                 + "\(Transcript.timecode(session.duration)) · "
                 + "\(session.metadata.deviceName) · \(session.metadata.format.displayName)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct TrackPlaybackRow: View {
    let track: TrackMetadata
    let url: URL
    let player: TrackPlayer

    private var isPlaying: Bool { player.playingURL == url }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                isPlaying ? player.stop() : player.play(url)
            } label: {
                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                    .font(.title)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.displayName).font(.body.weight(.medium))
                Text("\(track.fileName) · peak \(String(format: "%.1f", track.peakDB)) dBFS")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 10))
    }
}

/// Transcription is deliberately explicit about being unavailable rather than
/// hiding the feature, so the requirement is discoverable.
private struct TranscriptSection: View {
    let session: StoredSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Transcript").font(.title3.weight(.semibold))

            HStack(spacing: 10) {
                Image(systemName: "text.bubble").foregroundStyle(.secondary)
                Text(UnavailableTranscriber().unavailableReason ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(14)
            .background(.quaternary.opacity(0.2), in: .rect(cornerRadius: 10))
        }
    }
}

@MainActor
@Observable
final class TrackPlayer {
    private(set) var playingURL: URL?
    private var player: AVAudioPlayer?

    func play(_ url: URL) {
        stop()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.play()
            self.player = player
            playingURL = url
        } catch {
            playingURL = nil
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingURL = nil
    }
}
