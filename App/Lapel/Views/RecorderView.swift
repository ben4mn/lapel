import LapelKit
import SwiftUI

/// The live pane: what is plugged in, what it hears, and the transport.
struct RecorderView: View {
    @Environment(RecorderModel.self) private var recorder

    var body: some View {
        @Bindable var recorder = recorder

        VStack(spacing: 0) {
            StatusHeader()

            if let advisory = recorder.advisory {
                AdvisoryBanner(message: advisory.message)
            }

            ScrollView {
                VStack(spacing: 10) {
                    if let receiver = recorder.receiver {
                        ForEach(receiver.tracks) { track in
                            TrackRow(
                                track: track,
                                reading: reading(at: track.channelIndex),
                                presence: presence(at: track.channelIndex),
                                isEditable: !recorder.isRecording,
                                speakerName: binding(for: track.channelIndex)
                            )
                        }
                    } else {
                        EmptyStatePrompt()
                    }
                }
                .padding(18)
            }

            Divider()
            TransportBar()
        }
        .background(.background)
        .overlay(alignment: .top) {
            if let message = recorder.errorMessage {
                ErrorToast(message: message) { recorder.dismissError() }
            }
        }
    }

    private func reading(at index: Int) -> LevelReading {
        index < recorder.readings.count ? recorder.readings[index] : .silent
    }

    private func presence(at index: Int) -> MicPresence {
        index < recorder.presences.count ? recorder.presences[index] : .absent
    }

    /// Speaker names are stored as a flat array on the model; this keeps a row's
    /// text field bound to its channel even as the array is resized by a hotplug.
    private func binding(for index: Int) -> Binding<String> {
        Binding(
            get: { index < recorder.speakerNames.count ? recorder.speakerNames[index] : "" },
            set: { newValue in
                guard index < recorder.speakerNames.count else { return }
                recorder.speakerNames[index] = newValue
            }
        )
    }
}

private struct StatusHeader: View {
    @Environment(RecorderModel.self) private var recorder

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: recorder.receiver == nil ? "cable.connector.slash" : "cable.connector")
                .font(.title2)
                .foregroundStyle(recorder.receiver == nil ? .secondary : .primary)
                .contentTransition(.symbolEffect(.replace))

            VStack(alignment: .leading, spacing: 2) {
                Text(recorder.statusSummary)
                    .font(.headline)
                if let receiver = recorder.receiver {
                    Text("\(Int(receiver.device.sampleRate)) Hz · \(receiver.device.transport.rawValue.uppercased())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.thinMaterial)
    }
}

/// Mono mode is a hardware problem with a hardware fix, so it is shown as an
/// instruction rather than an error.
private struct AdvisoryBanner: View {
    let message: String

    var body: some View {
        // No Spacer and no fixedSize. A wrapping Text with fixedSize(vertical:)
        // next to a Spacer inside this stack sends SwiftUI into a layout loop that
        // blanks the entire window — responsive, no error, just nothing drawn.
        // Width is claimed with an explicit frame instead.
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12))
    }
}

private struct EmptyStatePrompt: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "cable.connector.horizontal")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Plug in your receiver")
                .font(.title3.weight(.medium))
            Text("Connect the DJI receiver over USB-C and switch on a transmitter.\nSet the receiver to S (Stereo) so each lapel gets its own track.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

private struct TransportBar: View {
    @Environment(RecorderModel.self) private var recorder

    var body: some View {
        @Bindable var recorder = recorder

        HStack(spacing: 14) {
            TextField("Recording name", text: $recorder.title)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
                .disabled(recorder.isRecording)

            Spacer()

            Text(Transcript.timecode(recorder.elapsed))
                .font(.system(.title3, design: .monospaced))
                .foregroundStyle(recorder.isRecording ? .primary : .tertiary)
                .contentTransition(.numericText())

            if recorder.isRecording {
                Button {
                    recorder.recordingState == .paused ? recorder.resumeRecording() : recorder.pauseRecording()
                } label: {
                    Image(systemName: recorder.recordingState == .paused ? "play.fill" : "pause.fill")
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.bordered)
                .help(recorder.recordingState == .paused ? "Resume" : "Pause")

                Button { recorder.stopRecording() } label: {
                    Image(systemName: "stop.fill").frame(width: 30, height: 30)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
                .help("Stop and save")
            } else {
                Button { recorder.startRecording() } label: {
                    Label("Record", systemImage: "record.circle.fill")
                        .frame(height: 30)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!recorder.canRecord)
                .keyboardShortcut("r", modifiers: .command)
                .help(recorder.canRecord ? "Start recording" : "Connect a receiver and switch on a transmitter")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.thinMaterial)
    }
}

private struct ErrorToast: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill").foregroundStyle(.orange)
            Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
        .shadow(radius: 8, y: 2)
        .padding(.top, 12)
        .frame(maxWidth: 460)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
