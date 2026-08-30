import AVFoundation
import LapelKit
import SwiftUI

/// A finished recording: its tracks, and eventually its transcript.
struct SessionDetailView: View {
    let session: StoredSession

    @Environment(RecorderModel.self) private var recorder
    @State private var player = TrackPlayer()
    @State private var preview = MixPreview()
    @State private var isExporting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                CombinedSection(preview: preview)

                VStack(spacing: 10) {
                    ForEach(session.metadata.tracks) { track in
                        TrackPlaybackRow(
                            track: track,
                            url: session.directory.appendingPathComponent(track.fileName),
                            player: player
                        )
                    }
                }

                TranscriptSection(session: session, transcript: recorder.transcript(for: session))
            }
            .padding(22)
        }
        .navigationTitle(session.title)
        .task(id: session.id) { await preview.load(session) }
        .onDisappear { player.stop(); preview.discard() }
        .toolbar {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([session.directory])
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            Button { isExporting = true } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Combine into one audio file and one transcript")
        }
        .sheet(isPresented: $isExporting) {
            ExportSheet(
                session: session,
                transcript: recorder.transcript(for: session),
                trim: preview.trim.isTrimmed ? preview.trim : nil
            )
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

/// The mix of every speaker, with a waveform to trim against and playback of the
/// selection, so what you hear before exporting is what the export contains.
private struct CombinedSection: View {
    @Bindable var preview: MixPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Combined").font(.title3.weight(.semibold))
                Spacer()
                if preview.trim.isTrimmed {
                    Text("\(Transcript.timecode(preview.trim.start)) – \(Transcript.timecode(preview.trim.end))"
                         + "  ·  \(Transcript.timecode(preview.trim.selectedDuration)) selected")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button("Reset") { preview.trim.reset() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }

            if preview.isLoading {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 96)
                    .background(.quaternary.opacity(0.2), in: .rect(cornerRadius: 8))
            } else if let message = preview.errorMessage {
                Text(message)
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 96)
                    .background(.quaternary.opacity(0.2), in: .rect(cornerRadius: 8))
            } else if preview.hasAudio {
                WaveformView(
                    summary: preview.summary,
                    trim: $preview.trim,
                    playhead: preview.playhead,
                    onScrub: { preview.seek(to: $0) }
                )

                HStack(spacing: 12) {
                    Button { preview.toggle() } label: {
                        Image(systemName: preview.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.space, modifiers: [])
                    .help("Play the selection")

                    Text(Transcript.timecode(preview.playhead))
                        .font(.callout.monospacedDigit())
                    Text("/").foregroundStyle(.tertiary)
                    Text(Transcript.timecode(preview.duration))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Spacer()
                    Text("Drag the ends to trim · click to scrub")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
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

/// Shows the combined script when there is one, and is explicit about being
/// unavailable when there is not, so the requirement stays discoverable.
private struct TranscriptSection: View {
    let session: StoredSession
    let transcript: Transcript?

    @Environment(RecorderModel.self) private var recorder

    private var isRunning: Bool { recorder.transcribingSessionID == session.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Transcript").font(.title3.weight(.semibold))
                Spacer()
                if let transcript, !transcript.isEmpty {
                    Text(speakingSummary(transcript))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if recorder.canTranscribe {
                    Button {
                        Task { await recorder.transcribe(session) }
                    } label: {
                        if isRunning {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Transcribing…")
                            }
                        } else {
                            Label(transcript == nil ? "Transcribe" : "Redo", systemImage: "text.bubble")
                        }
                    }
                    .disabled(recorder.transcribingSessionID != nil)
                }
            }

            if let transcript, !transcript.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(transcript.turns) { turn in
                        TurnRow(turn: turn)
                    }
                }
                .padding(16)
                .background(.quaternary.opacity(0.2), in: .rect(cornerRadius: 10))
            } else {
                HStack(spacing: 10) {
                    Image(systemName: isRunning ? "waveform" : "text.bubble").foregroundStyle(.secondary)
                    Text(placeholder)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(14)
                .background(.quaternary.opacity(0.2), in: .rect(cornerRadius: 10))
            }
        }
    }

    private var placeholder: String {
        if isRunning { return "Transcribing each speaker's track separately…" }
        if let reason = recorder.transcriptionUnavailableReason { return reason }
        return "Not transcribed yet. Each speaker's track is transcribed on this Mac, separately."
    }

    /// How long each person spoke — the number a two-microphone recording can
    /// answer and a single-track one cannot.
    private func speakingSummary(_ transcript: Transcript) -> String {
        transcript.speakingTime
            .sorted { $0.key < $1.key }
            .map { "\($0.key) \(Transcript.timecode($0.value))" }
            .joined(separator: "  ·  ")
    }
}

private struct TurnRow: View {
    let turn: TranscriptTurn

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(Transcript.timecode(turn.start))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(SpeakerLabeling.names.label(for: turn))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(turn.channelIndex == 0 ? Color.accentColor : Color.orange)
                Text(turn.text).font(.callout).textSelection(.enabled)
            }
            Spacer(minLength: 0)
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
