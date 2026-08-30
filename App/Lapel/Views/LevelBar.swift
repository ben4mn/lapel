import LapelKit
import SwiftUI

/// A horizontal level meter: filled RMS body, held peak tick, clip indication.
///
/// Drawn in a `Canvas` rather than composed from shapes because it redraws every
/// frame per channel, and a stack of animated `Rectangle`s at that rate is a
/// measurable amount of layout work for no visual gain.
struct LevelBar: View {
    let reading: LevelReading
    let presence: MicPresence

    private var isLive: Bool { presence != .absent }

    var body: some View {
        Canvas { context, size in
            let radius = size.height / 2
            let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: radius)
            context.fill(track, with: .color(.primary.opacity(0.07)))

            guard isLive else { return }

            let fillWidth = max(0, min(CGFloat(reading.rmsPosition) * size.width, size.width))
            if fillWidth > 1 {
                context.clip(to: track)
                context.fill(
                    Path(CGRect(x: 0, y: 0, width: fillWidth, height: size.height)),
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: .green, location: 0),
                            // Positions match the dBFS ladder: comfortable speech sits
                            // in the green, the amber shoulder starts around -12 dBFS.
                            .init(color: .green, location: 0.62),
                            .init(color: .yellow, location: 0.82),
                            .init(color: .red, location: 1.0),
                        ]),
                        startPoint: .zero,
                        endPoint: CGPoint(x: size.width, y: 0)
                    )
                )
            }

            let peakX = min(CGFloat(reading.peakPosition) * size.width, size.width - 2)
            if peakX > 1 {
                context.fill(
                    Path(CGRect(x: peakX, y: 0, width: 2, height: size.height)),
                    with: .color(reading.isClipping ? .red : .primary.opacity(0.55))
                )
            }
        }
        .frame(height: 10)
        .animation(.linear(duration: 0.05), value: reading)
        .accessibilityLabel("Level")
        .accessibilityValue(isLive ? String(format: "%.0f decibels full scale", reading.rmsDB) : "No transmitter")
    }
}
