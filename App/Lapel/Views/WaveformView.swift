import LapelKit
import SwiftUI

/// The combined mix, drawn with trim handles and a playhead.
struct WaveformView: View {
    let summary: WaveformSummary
    @Binding var trim: TrimSelection
    let playhead: TimeInterval
    let onScrub: (TimeInterval) -> Void

    /// Which handle a drag grabbed, decided once at drag start so a fast drag past
    /// the other handle cannot hand control over mid-gesture.
    @State private var dragging: Handle?

    private enum Handle { case start, end, scrub }
    private static let handleHitWidth: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width

            ZStack(alignment: .leading) {
                Canvas { context, size in draw(&context, size: size) }

                // Everything outside the selection is dimmed rather than hidden, so
                // the trimmed material stays visible and the cut is reversible in
                // the user's head as well as in the data.
                dim(x: 0, width: x(for: trim.start, in: width))
                dim(x: x(for: trim.end, in: width), width: width - x(for: trim.end, in: width))

                handle(at: x(for: trim.start, in: width))
                handle(at: x(for: trim.end, in: width))

                if playhead > 0 {
                    Rectangle()
                        .fill(.primary)
                        .frame(width: 1.5)
                        .offset(x: x(for: playhead, in: width))
                }
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let handle = dragging ?? nearestHandle(to: value.startLocation.x, width: width)
                        dragging = handle
                        let time = self.time(for: value.location.x, in: width)

                        switch handle {
                        case .start: trim.setStart(time)
                        case .end: trim.setEnd(time)
                        case .scrub: onScrub(time)
                        }
                    }
                    .onEnded { _ in dragging = nil }
            )
        }
        .frame(height: 96)
        .background(.quaternary.opacity(0.2), in: .rect(cornerRadius: 8))
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let bins = summary.normalizedBins
        guard !bins.isEmpty else { return }

        let midpoint = size.height / 2
        let step = size.width / CGFloat(bins.count)

        for (index, value) in bins.enumerated() {
            // A floor of half a point keeps silence as a visible centre line rather
            // than a gap, so the recording's full length stays legible.
            let height = max(CGFloat(value) * size.height * 0.92, 0.5)
            let x = CGFloat(index) * step
            let time = summary.time(atBin: index)

            context.fill(
                Path(CGRect(x: x, y: midpoint - height / 2, width: max(step - 0.5, 0.5), height: height)),
                with: .color(trim.contains(time) ? .accentColor : .secondary.opacity(0.5))
            )
        }
    }

    private func dim(x: CGFloat, width: CGFloat) -> some View {
        Rectangle()
            .fill(.background.opacity(0.55))
            .frame(width: max(0, width))
            .offset(x: x)
            .allowsHitTesting(false)
    }

    private func handle(at x: CGFloat) -> some View {
        Rectangle()
            .fill(.primary.opacity(0.75))
            .frame(width: 3)
            .offset(x: x - 1.5)
            .allowsHitTesting(false)
    }

    private func x(for time: TimeInterval, in width: CGFloat) -> CGFloat {
        guard summary.duration > 0 else { return 0 }
        return CGFloat(time / summary.duration) * width
    }

    private func time(for x: CGFloat, in width: CGFloat) -> TimeInterval {
        guard width > 0 else { return 0 }
        return min(max(0, Double(x / width) * summary.duration), summary.duration)
    }

    private func nearestHandle(to x: CGFloat, width: CGFloat) -> Handle {
        let startX = self.x(for: trim.start, in: width)
        let endX = self.x(for: trim.end, in: width)

        if abs(x - startX) <= Self.handleHitWidth { return .start }
        if abs(x - endX) <= Self.handleHitWidth { return .end }
        return .scrub
    }
}
