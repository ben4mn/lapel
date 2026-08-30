import Foundation

/// What a single receiver channel is currently carrying.
public enum MicPresence: Equatable, Sendable {
    /// Nothing on this channel — the transmitter is off, out of range, or unlinked.
    case absent
    /// A transmitter is linked and sending, but nobody is talking into it.
    case idle
    /// Someone is speaking into this lapel.
    case speaking

    public var isConnected: Bool { self != .absent }
}

/// Infers how many lapels are actually live, and which one is talking.
///
/// CoreAudio cannot answer this. The receiver enumerates as a fixed two-channel
/// USB device whether one transmitter is linked or both, so the channel count
/// tells you the receiver's capacity, never its occupancy.
///
/// The signal does tell you. A channel with no transmitter carries true digital
/// zero, while a linked transmitter sitting silent still sends its own self-noise
/// — typically around -60 dBFS and never exactly zero. That gap is the whole
/// discriminator.
///
/// The timing is deliberately asymmetric: presence is believed instantly so the UI
/// lights up the moment a lapel is switched on, while absence must be sustained
/// before it is believed, so a momentary RF dropout does not make the count flicker.
public struct MicPresenceDetector: Sendable {

    public struct Configuration: Sendable {
        /// Above this RMS, treat the channel as carrying speech rather than room tone.
        public var speechThresholdDB: Float
        /// How long digital silence must persist before a transmitter is called gone.
        public var absenceConfirmationSeconds: TimeInterval
        /// How long "speaking" is held through the pauses between words.
        public var silenceHangoverSeconds: TimeInterval

        public init(
            speechThresholdDB: Float = -45,
            absenceConfirmationSeconds: TimeInterval = 1.5,
            silenceHangoverSeconds: TimeInterval = 0.4
        ) {
            self.speechThresholdDB = speechThresholdDB
            self.absenceConfirmationSeconds = absenceConfirmationSeconds
            self.silenceHangoverSeconds = silenceHangoverSeconds
        }
    }

    private struct ChannelState {
        /// Seconds since this channel last carried anything above the digital floor.
        var sinceSignal: TimeInterval = .infinity
        /// Seconds since this channel last carried speech.
        var sinceSpeech: TimeInterval = .infinity
    }

    public let channelCount: Int
    public let configuration: Configuration
    private var states: [ChannelState]

    public init(channelCount: Int, configuration: Configuration = Configuration()) {
        self.channelCount = max(0, channelCount)
        self.configuration = configuration
        self.states = Array(repeating: ChannelState(), count: max(0, channelCount))
    }

    /// Folds one block of per-channel levels into the running presence estimate.
    ///
    /// `readings` shorter than the channel count is not an error: a channel with no
    /// reading simply ages, which is exactly what should happen when a device drops
    /// channels mid-stream.
    public mutating func update(readings: [LevelReading], elapsed: TimeInterval) {
        for channel in states.indices {
            let reading = channel < readings.count ? readings[channel] : nil
            let carriesSignal = (reading?.rmsDB ?? LevelMeter.floorDB) > LevelMeter.floorDB
            let carriesSpeech = (reading?.rmsDB ?? LevelMeter.floorDB) >= configuration.speechThresholdDB

            states[channel].sinceSignal = carriesSignal ? 0 : states[channel].sinceSignal + elapsed
            states[channel].sinceSpeech = carriesSpeech ? 0 : states[channel].sinceSpeech + elapsed
        }
    }

    public var presences: [MicPresence] {
        states.map { state in
            if state.sinceSignal >= configuration.absenceConfirmationSeconds { return .absent }
            if state.sinceSpeech < configuration.silenceHangoverSeconds { return .speaking }
            return .idle
        }
    }

    /// How many lapels are live — the honest answer to "how many mics are plugged in".
    public var connectedMicCount: Int { presences.count(where: \.isConnected) }

    public var speakingChannels: [Int] {
        presences.enumerated().compactMap { $0.element == .speaking ? $0.offset : nil }
    }

    /// Clears all inference — call when the receiver is unplugged so no stale count lingers.
    public mutating func reset() {
        states = Array(repeating: ChannelState(), count: channelCount)
    }
}
