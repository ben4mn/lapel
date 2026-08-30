import Foundation
import LapelKit

/// A terminal harness for the hardware layer.
///
/// Exists so the receiver, its channel mode and its live levels can be verified
/// against real hardware without launching the app — and so a bug report can be a
/// pasted table rather than a description of some bars moving.
final class Probe: @unchecked Sendable {

    /// All output goes through one path. Swift's `print` is buffered while
    /// `FileHandle.write` is not, so mixing them reorders the device table behind
    /// the live meter block whenever stdout is a pipe rather than a terminal.
    private func emit(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    private let lock = NSLock()
    private var state = ReceiverState()
    private var meters: [LevelMeter] = []
    private var capture: AudioCapture?
    private var captureUID: String?
    private var readings: [LevelReading] = []
    private var lastDraw = Date()
    private var drawnLines = 0

    private let monitor = AudioDeviceMonitor()

    func run() {
        printDeviceTable()

        monitor.start { [weak self] devices in
            self?.handle(devices: devices)
        }

        Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            self?.draw()
        }

        emit("\nWatching for changes. Plug or unplug the receiver, or press the mode button. Ctrl-C to quit.\n" + "\n")
        RunLoop.main.run()
    }

    // MARK: - Device table

    private func printDeviceTable() {
        let devices = CoreAudioDeviceEnumerator().inputDevices()
        emit("\nInput devices\n" + String(repeating: "─", count: 72) + "\n")
        guard !devices.isEmpty else { emit("  (none)\n"); return }

        for device in devices {
            let marker = ReceiverDetector.isVendorMatch(device) ? "▸" : " "
            let channels = device.inputChannelCount == 1 ? "1 channel" : "\(device.inputChannelCount) channels"
            emit("  \(marker) \(device.name.padded(to: 30)) \(channels.padded(to: 12)) "
                 + "\(Int(device.sampleRate)) Hz  \(device.transport.rawValue)\n")
        }
        emit(String(repeating: "─", count: 72) + "\n")
    }

    // MARK: - Reacting to hardware

    private func handle(devices: [AudioDeviceDescriptor]) {
        lock.lock()
        let event = state.devicesChanged(to: devices)
        let receiver = state.receiver
        lock.unlock()

        switch event {
        case .connected, .reconfigured:
            if let receiver { startCapture(for: receiver) }
        case .disconnected:
            stopCapture()
        case nil:
            break
        }
    }

    private func startCapture(for receiver: Receiver) {
        guard captureUID != receiver.device.uid || capture == nil else { return }
        stopCapture()

        let channels = receiver.channelMode.trackCount
        lock.lock()
        meters = (0..<channels).map { _ in LevelMeter() }
        readings = Array(repeating: .silent, count: channels)
        lock.unlock()

        let capture = AudioCapture(device: receiver.device)
        do {
            try capture.start { [weak self] channels, sampleRate in
                self?.consume(channels: channels, sampleRate: sampleRate)
            }
            self.capture = capture
            self.captureUID = receiver.device.uid
        } catch {
            FileHandle.standardError.write(Data("\nCapture failed: \(error)\n".utf8))
        }
    }

    private func stopCapture() {
        capture?.stop()
        capture = nil
        captureUID = nil
        lock.lock(); meters = []; readings = []; lock.unlock()
    }

    private func consume(channels: [[Float]], sampleRate: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard meters.count == channels.count else { return }

        readings = channels.indices.map { meters[$0].process(channels[$0], sampleRate: sampleRate) }
        let elapsed = Double(channels[0].count) / sampleRate
        state.levelsChanged(readings: readings, elapsed: elapsed)
    }

    // MARK: - Drawing

    private func draw() {
        lock.lock()
        let summary = state.statusSummary
        let advisory = state.advisory
        let presences = state.presences
        let readings = self.readings
        let receiver = state.receiver
        lock.unlock()

        var lines: [String] = [summary]
        if let advisory { lines.append("  ⚠︎ \(advisory.message)") }

        for (index, reading) in readings.enumerated() {
            let presence = index < presences.count ? presences[index] : .absent
            let label = receiver?.tracks.first { $0.channelIndex == index }?.defaultName ?? "CH\(index + 1)"
            lines.append("  \(label.padded(to: 6)) \(Self.bar(reading))  "
                         + "\(String(format: "%6.1f", reading.rmsDB)) dBFS  \(Self.badge(presence))")
        }

        redraw(lines)
    }

    private static func bar(_ reading: LevelReading, width: Int = 32) -> String {
        let filled = Int((reading.rmsPosition * Float(width)).rounded())
        let peakAt = min(Int((reading.peakPosition * Float(width)).rounded()), width - 1)
        return "[" + (0..<width).map { index in
            if index == peakAt { return reading.isClipping ? "!" : "|" }
            return index < filled ? "█" : "·"
        }.joined() + "]"
    }

    private static func badge(_ presence: MicPresence) -> String {
        switch presence {
        case .absent: "— no transmitter"
        case .idle: "○ live"
        case .speaking: "● speaking"
        }
    }

    private func redraw(_ lines: [String]) {
        var output = ""
        if drawnLines > 0 { output += "\u{1B}[\(drawnLines)A" }
        for line in lines { output += "\u{1B}[2K" + line + "\n" }
        drawnLines = lines.count
        emit(output)
    }
}

private extension String {
    func padded(to width: Int) -> String {
        count >= width ? String(prefix(width)) : self + String(repeating: " ", count: width - count)
    }
}

// Held in a binding rather than called on a temporary: the timer and the device
// monitor capture the probe weakly, and a temporary would be gone before either fires.
let probe = Probe()
probe.run()
