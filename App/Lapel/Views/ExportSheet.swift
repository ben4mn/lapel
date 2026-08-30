import AppKit
import LapelKit
import SwiftUI

/// Combines a session into one audio file and one transcript, alongside the
/// per-speaker files rather than instead of them.
struct ExportSheet: View {
    let session: StoredSession
    let transcript: Transcript?
    /// Carried in from the preview so the export matches what was auditioned.
    var trim: TrimSelection?

    @Environment(\.dismiss) private var dismiss
    @State private var options = ExportOptions()
    @State private var isExporting = false
    @State private var failure: String?

    private var hasTranscript: Bool { transcript != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            Form {
                Section {
                    Toggle("Combined audio", isOn: $options.includeAudio)
                    Picker("Format", selection: $options.audioFormat) {
                        ForEach(RecordingFormat.allCases, id: \.self) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .disabled(!options.includeAudio)
                } footer: {
                    Text("All \(session.metadata.tracks.count) speaker tracks mixed to a single file. "
                         + "The individual tracks are kept."
                         + (trim.map { " Trimmed to \(Transcript.timecode($0.selectedDuration))." } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Combined transcript", isOn: $options.includeTranscript)
                        .disabled(!hasTranscript)
                    Picker("Format", selection: $options.transcriptFormat) {
                        ForEach(TranscriptFormat.allCases) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .disabled(!hasTranscript || !options.includeTranscript)
                    Picker("Label speakers as", selection: $options.labeling) {
                        ForEach(SpeakerLabeling.allCases) { labeling in
                            Text(labeling.displayName).tag(labeling)
                        }
                    }
                    .disabled(!hasTranscript || !options.includeTranscript)
                } footer: {
                    Text(hasTranscript
                         ? "One script with every speaker attributed, since mixing the audio discards the separation."
                         : "This recording has not been transcribed yet.")
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            footerBar
        }
        .frame(width: 460)
        .onAppear {
            options.includeTranscript = hasTranscript
            options.trim = trim
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Export “\(session.title)”").font(.headline)
            Text("Choose what to combine, then pick where to save.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footerBar: some View {
        HStack {
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).lineLimit(2)
            }
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Export…") { chooseDestination() }
                .keyboardShortcut(.defaultAction)
                .disabled(isExporting || (!options.includeAudio && !options.includeTranscript))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// A directory rather than a file: an export is a *pair* of files, and the
    /// sandbox needs the folder scope to write both.
    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for the combined files."

        guard panel.runModal() == .OK, let directory = panel.url else { return }
        run(to: directory)
    }

    private func run(to directory: URL) {
        isExporting = true
        failure = nil
        do {
            let result = try SessionExporter().export(
                session, transcript: transcript, to: directory, options: options
            )
            // Reveals both files at once, so it is obvious what was produced.
            NSWorkspace.shared.activateFileViewerSelecting([result.audioURL, result.transcriptURL].compactMap { $0 })
            dismiss()
        } catch {
            failure = Self.message(for: error)
        }
        isExporting = false
    }

    private static func message(for error: Error) -> String {
        switch error {
        case ExportError.noReadableAudio: "None of this recording's tracks could be read."
        case ExportError.trackUnreadable(let name): "Could not read \(name)."
        case ExportError.writeFailed(let name): "Could not write \(name)."
        default: error.localizedDescription
        }
    }
}
