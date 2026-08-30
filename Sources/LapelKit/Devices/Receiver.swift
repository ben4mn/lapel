import Foundation

/// What the receiver's input channel count tells us about whether the two lapels
/// can be pulled apart.
public enum ChannelMode: Equatable, Sendable {
    /// The receiver is mixing every transmitter down to one channel. No amount of
    /// software can unmix it — the fix is on the hardware.
    case mono
    /// The canonical DJI layout: TX1 on the left channel, TX2 on the right.
    case dualChannel
    /// More channels than the two-transmitter case, one track each.
    case multiChannel(Int)

    public init(inputChannelCount: Int) {
        switch inputChannelCount {
        case ...1: self = .mono
        case 2: self = .dualChannel
        default: self = .multiChannel(inputChannelCount)
        }
    }

    public var trackCount: Int {
        switch self {
        case .mono: 1
        case .dualChannel: 2
        case .multiChannel(let n): n
        }
    }

    /// True when each speaker lands on their own channel.
    public var supportsSeparateTracks: Bool {
        if case .mono = self { return false }
        return true
    }
}

/// A problem the user can actually fix, phrased as an instruction rather than an error.
public enum ReceiverAdvisory: Equatable, Sendable {
    case receiverInMonoMode

    public var message: String {
        switch self {
        case .receiverInMonoMode:
            "The receiver is sending a single mixed channel, so the two lapels cannot be "
            + "separated. Press the receiver's mode button until it shows S (Stereo), then reconnect."
        }
    }
}

/// One capture channel, which for a DJI receiver in stereo means one transmitter.
public struct Track: Equatable, Sendable, Identifiable {
    public let channelIndex: Int
    public let defaultName: String

    public var id: Int { channelIndex }

    public init(channelIndex: Int, defaultName: String) {
        self.channelIndex = channelIndex
        self.defaultName = defaultName
    }
}

/// A detected receiver plus everything derived from how it is currently configured.
public struct Receiver: Equatable, Sendable {
    public let device: AudioDeviceDescriptor

    public init(device: AudioDeviceDescriptor) {
        self.device = device
    }

    public var channelMode: ChannelMode { ChannelMode(inputChannelCount: device.inputChannelCount) }

    public var canSeparateSpeakers: Bool { channelMode.supportsSeparateTracks }

    public var advisory: ReceiverAdvisory? {
        canSeparateSpeakers ? nil : .receiverInMonoMode
    }

    public var tracks: [Track] {
        switch channelMode {
        case .mono:
            [Track(channelIndex: 0, defaultName: "Mixed")]
        case .dualChannel, .multiChannel:
            (0..<channelMode.trackCount).map { Track(channelIndex: $0, defaultName: "TX\($0 + 1)") }
        }
    }
}
