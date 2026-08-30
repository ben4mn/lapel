import Foundation

/// A change worth reacting to, as opposed to the constant re-delivery of an
/// unchanged device list.
public enum ReceiverEvent: Equatable, Sendable {
    case connected
    case disconnected
    /// Same receiver family, different hardware or a different channel mode —
    /// typically the user pressing the mode button from M to S.
    case reconfigured
}

/// The live picture of what is plugged in and which lapels are alive.
///
/// A value type folding two inputs — the device list and the metering stream —
/// into one state, so every plug, unplug and mode flip is exercised in tests
/// rather than by pulling a USB cable and watching.
public struct ReceiverState: Sendable {

    public private(set) var receiver: Receiver?
    private var presenceDetector: MicPresenceDetector?
    private var duplicateDetector = DuplicateChannelDetector()

    public init() {}

    public var isConnected: Bool { receiver != nil }

    /// The hardware's own advisory first, then what the audio reveals. A receiver
    /// can claim two channels and still be mixing them.
    public var advisory: ReceiverAdvisory? {
        if let hardware = receiver?.advisory { return hardware }
        return duplicateDetector.isDuplicated ? .channelsAreIdentical : nil
    }

    /// What the audio has shown about the two channels actually differing.
    public var channelSeparation: ChannelSeparation { duplicateDetector.separation }

    /// False when the channel count says mono *or* when the audio shows both
    /// channels carrying the same mix.
    public var canSeparateSpeakers: Bool {
        (receiver?.canSeparateSpeakers ?? false) && !duplicateDetector.isDuplicated
    }
    public var presences: [MicPresence] { presenceDetector?.presences ?? [] }
    public var connectedMicCount: Int { presenceDetector?.connectedMicCount ?? 0 }
    public var speakingChannels: [Int] { presenceDetector?.speakingChannels ?? [] }
    public var channelCount: Int { receiver?.channelMode.trackCount ?? 0 }

    /// Recording needs both a receiver and at least one live transmitter — arming
    /// with every lapel switched off would only produce silent files.
    public var canRecord: Bool { isConnected && connectedMicCount > 0 }

    public var statusSummary: String {
        guard let receiver else { return "No receiver connected" }
        let name = receiver.device.name
        guard connectedMicCount > 0 else { return "\(name) — no microphones detected" }
        return "\(name) — \(connectedMicCount) of \(channelCount) microphones live"
    }

    /// Folds in a fresh device list, returning what actually changed.
    ///
    /// CoreAudio re-delivers the whole list on any hardware change anywhere in the
    /// system, so returning `nil` for an unchanged receiver is what keeps the UI
    /// from churning on unrelated events.
    @discardableResult
    public mutating func devicesChanged(to devices: [AudioDeviceDescriptor]) -> ReceiverEvent? {
        let detected = ReceiverDetector.detect(in: devices)

        switch (receiver, detected) {
        case (nil, nil):
            return nil

        case (nil, .some(let new)):
            adopt(new)
            return .connected

        case (.some, nil):
            receiver = nil
            presenceDetector = nil
            duplicateDetector.reset()
            return .disconnected

        case (.some(let old), .some(let new)):
            let sameHardware = old.device.uid == new.device.uid
            let sameLayout = old.device.inputChannelCount == new.device.inputChannelCount
            guard !(sameHardware && sameLayout) else { return nil }
            adopt(new)
            return .reconfigured
        }
    }

    /// Folds in one block of per-channel levels.
    public mutating func levelsChanged(readings: [LevelReading], elapsed: TimeInterval) {
        presenceDetector?.update(readings: readings, elapsed: elapsed)
    }

    /// Folds in the raw audio, which answers a question the levels cannot: whether
    /// the two channels are actually carrying different microphones.
    public mutating func audioArrived(channels: [[Float]], elapsed: TimeInterval) {
        guard isConnected else { return }
        duplicateDetector.update(channels: channels, elapsed: elapsed)
    }

    /// Adopting always builds a fresh detector: presence inferred from the previous
    /// hardware must not survive into the new one.
    private mutating func adopt(_ new: Receiver) {
        receiver = new
        presenceDetector = MicPresenceDetector(channelCount: new.channelMode.trackCount)
        // A duplication finding belongs to the hardware that produced it.
        duplicateDetector.reset()
    }
}
