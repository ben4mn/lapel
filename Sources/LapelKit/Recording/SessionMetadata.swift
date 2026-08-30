import Foundation

/// Container and codec for recorded tracks.
public enum RecordingFormat: String, Codable, Sendable, CaseIterable {
    /// AAC in an .m4a container — roughly a tenth the size, which matters when every
    /// session writes one file per speaker.
    case aac
    /// Uncompressed PCM, for when the recording will be edited afterwards.
    case wav

    public var fileExtension: String {
        switch self {
        case .aac: "m4a"
        case .wav: "wav"
        }
    }

    public var isLossless: Bool { self == .wav }

    public var displayName: String {
        switch self {
        case .aac: "Compressed (AAC)"
        case .wav: "Lossless (WAV)"
        }
    }
}

/// One recorded channel: which transmitter it came from, who was wearing it,
/// and where the audio landed.
public struct TrackMetadata: Codable, Equatable, Sendable, Identifiable {
    public var channelIndex: Int
    public var speakerName: String
    public var fileName: String
    public var peakDB: Float

    public var id: Int { channelIndex }

    public init(channelIndex: Int, speakerName: String, fileName: String, peakDB: Float) {
        self.channelIndex = channelIndex
        self.speakerName = speakerName
        self.fileName = fileName
        self.peakDB = peakDB
    }

    /// What to show when the user never named this speaker.
    public var displayName: String {
        speakerName.isEmpty ? "Track \(channelIndex + 1)" : speakerName
    }
}

/// Everything about a session that is not the audio itself.
///
/// Written beside the audio as `session.json` so a recording remains fully
/// interpretable without the app that made it.
public struct SessionMetadata: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var title: String
    public var createdAt: Date
    public var duration: TimeInterval
    public var deviceName: String
    /// Stored as a count rather than a `ChannelMode` so the file stays trivially
    /// readable and the mode can be re-derived.
    public var inputChannelCount: Int
    public var sampleRate: Double
    public var format: RecordingFormat
    public var tracks: [TrackMetadata]
    public var transcriptFileName: String?

    public init(
        id: UUID,
        title: String,
        createdAt: Date,
        deviceName: String,
        inputChannelCount: Int,
        sampleRate: Double,
        format: RecordingFormat
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = 0
        self.deviceName = deviceName
        self.inputChannelCount = inputChannelCount
        self.sampleRate = sampleRate
        self.format = format
        self.tracks = []
        self.transcriptFileName = nil
    }

    public var channelMode: ChannelMode { ChannelMode(inputChannelCount: inputChannelCount) }
}
