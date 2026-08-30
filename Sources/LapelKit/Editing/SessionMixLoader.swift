import Foundation

/// One session's tracks read back and summed to a single mono buffer.
public struct SessionMix: Sendable {
    public let samples: [Float]
    public let sampleRate: Double
    /// Tracks that could not be read, so the caller can say what is missing from
    /// the mix rather than leaving someone silently inaudible.
    public let skippedTracks: [String]

    public var duration: TimeInterval { sampleRate > 0 ? Double(samples.count) / sampleRate : 0 }
}

/// Reads a recorded session back and mixes it down.
///
/// Shared by preview and export so the waveform the user trims against is
/// produced by exactly the same arithmetic as the file they end up with.
public struct SessionMixLoader: Sendable {

    private let reader: AudioTrackReading

    public init(reader: AudioTrackReading = AVAudioFileTrackReader()) {
        self.reader = reader
    }

    public func load(_ session: StoredSession) throws -> SessionMix {
        var tracks: [[Float]] = []
        var skipped: [String] = []
        var sampleRate = session.metadata.sampleRate

        for track in session.metadata.tracks {
            let url = session.directory.appendingPathComponent(track.fileName)
            do {
                let (samples, rate) = try reader.readMono(from: url)
                tracks.append(samples)
                if rate > 0 { sampleRate = rate }
            } catch {
                skipped.append(track.fileName)
            }
        }

        guard !tracks.isEmpty else { throw ExportError.noReadableAudio }

        return SessionMix(samples: AudioMixdown.mix(tracks), sampleRate: sampleRate, skippedTracks: skipped)
    }

    public func summary(_ session: StoredSession, binCount: Int) throws -> WaveformSummary {
        let mix = try load(session)
        return WaveformSummary.make(from: mix.samples, sampleRate: mix.sampleRate, binCount: binCount)
    }
}
