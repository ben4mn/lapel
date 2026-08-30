import AVFoundation
import Foundation

public enum ExportError: Error, Equatable {
    case trackUnreadable(String)
    /// Every track failed to read, so there is nothing to mix.
    case noReadableAudio
    case writeFailed(String)
}

/// Reads one recorded track back as mono samples.
public protocol AudioTrackReading: Sendable {
    func readMono(from url: URL) throws -> (samples: [Float], sampleRate: Double)
}

/// Decodes a recorded track with AVFoundation, AAC or PCM alike.
public struct AVAudioFileTrackReader: AudioTrackReading {
    public init() {}

    public func readMono(from url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw ExportError.trackUnreadable(url.lastPathComponent)
        }

        // Read into float32 regardless of how the file is stored, so AAC and 24-bit
        // PCM arrive in the same shape the mixer expects.
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return ([], format.sampleRate)
        }

        do {
            try file.read(into: buffer)
        } catch {
            throw ExportError.trackUnreadable(url.lastPathComponent)
        }

        guard let channels = AudioCapture.deinterleave(buffer), let first = channels.first else {
            return ([], format.sampleRate)
        }
        // A track should be mono, but a stereo one is folded rather than half-dropped.
        return (channels.count == 1 ? first : AudioMixdown.mix(channels), format.sampleRate)
    }
}

public struct ExportOptions: Sendable {
    public var includeAudio: Bool = true
    public var includeTranscript: Bool = true
    public var audioFormat: RecordingFormat = .aac
    public var transcriptFormat: TranscriptFormat = .plainText
    public var labeling: SpeakerLabeling = .names

    public init() {}
}

public struct ExportResult: Equatable, Sendable {
    public let audioURL: URL?
    public let transcriptURL: URL?
    /// Tracks that could not be read, named so the user knows what is missing from
    /// the mix rather than wondering why someone is inaudible.
    public let skippedTracks: [String]
}

/// Combines a recorded session into one audio file and one transcript.
///
/// The per-speaker files stay untouched — this produces the shareable pair
/// alongside them, not instead of them.
public struct SessionExporter: Sendable {

    private let reader: AudioTrackReading

    public init(reader: AudioTrackReading = AVAudioFileTrackReader()) {
        self.reader = reader
    }

    public func export(
        _ session: StoredSession,
        transcript: Transcript?,
        to directory: URL,
        options: ExportOptions = ExportOptions()
    ) throws -> ExportResult {
        let base = SessionSlug.make(from: session.title, fallback: "recording")

        var audioURL: URL?
        var skipped: [String] = []

        if options.includeAudio {
            var tracks: [[Float]] = []
            var sampleRate = session.metadata.sampleRate

            for track in session.metadata.tracks {
                let url = session.directory.appendingPathComponent(track.fileName)
                do {
                    let (samples, rate) = try reader.readMono(from: url)
                    tracks.append(samples)
                    if rate > 0 { sampleRate = rate }
                } catch {
                    // One damaged file must not cost the user the whole export.
                    skipped.append(track.fileName)
                }
            }

            guard !tracks.isEmpty else { throw ExportError.noReadableAudio }

            let url = Self.availableURL(in: directory, base: base, extension: options.audioFormat.fileExtension)
            try write(AudioMixdown.mix(tracks), to: url, sampleRate: sampleRate, format: options.audioFormat)
            audioURL = url
        }

        var transcriptURL: URL?
        if options.includeTranscript, let transcript {
            let url = Self.availableURL(in: directory, base: base, extension: options.transcriptFormat.fileExtension)
            let text = options.transcriptFormat.render(transcript, title: session.title, labeling: options.labeling)
            do {
                try Data(text.utf8).write(to: url, options: .atomic)
            } catch {
                throw ExportError.writeFailed(url.lastPathComponent)
            }
            transcriptURL = url
        }

        return ExportResult(audioURL: audioURL, transcriptURL: transcriptURL, skippedTracks: skipped)
    }

    private func write(_ samples: [Float], to url: URL, sampleRate: Double, format: RecordingFormat) throws {
        let writer = try AudioFileTrackWriter(url: url, sampleRate: sampleRate, format: format)
        try writer.write(samples)
        try writer.finish()
    }

    /// Exporting twice adds a suffix rather than quietly replacing the first export —
    /// the previous file may already have been sent to someone.
    static func availableURL(in directory: URL, base: String, extension ext: String) -> URL {
        var url = directory.appendingPathComponent("\(base).\(ext)")
        var attempt = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base)-\(attempt).\(ext)")
            attempt += 1
        }
        return url
    }
}
