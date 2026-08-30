import LapelKit
import SwiftUI

/// One transmitter: who is wearing it, what it is hearing, whether it is alive.
struct TrackRow: View {
    let track: Track
    let reading: LevelReading
    let presence: MicPresence
    let isEditable: Bool
    @Binding var speakerName: String

    var body: some View {
        HStack(spacing: 14) {
            PresenceDot(presence: presence)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField(track.defaultName, text: $speakerName)
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .frame(width: 130, alignment: .leading)
                        .disabled(!isEditable)

                    Text(track.defaultName)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)

                    Spacer()

                    Text(presence == .absent ? "no transmitter" : String(format: "%.0f dB", reading.rmsDB))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(presence == .absent ? .tertiary : .secondary)
                }

                LevelBar(reading: reading, presence: presence)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
        .background(.quaternary.opacity(presence == .absent ? 0.12 : 0.25), in: .rect(cornerRadius: 10))
        .opacity(presence == .absent ? 0.55 : 1)
    }
}

/// Grey when nothing is transmitting, blue when linked, green and pulsing while
/// that person is actually talking.
struct PresenceDot: View {
    let presence: MicPresence

    private var color: Color {
        switch presence {
        case .absent: .secondary.opacity(0.4)
        case .idle: .blue
        case .speaking: .green
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .overlay {
                if presence == .speaking {
                    Circle().stroke(color.opacity(0.35), lineWidth: 6)
                }
            }
            .animation(.easeOut(duration: 0.15), value: presence)
            .accessibilityLabel(label)
    }

    private var label: String {
        switch presence {
        case .absent: "No transmitter"
        case .idle: "Transmitter live"
        case .speaking: "Speaking"
        }
    }
}
