import AVFoundation
import Foundation

/// Writes one channel to a real file on disk.
///
/// The production counterpart to the fakes the recording tests run against.
public final class AudioFileTrackWriter: TrackWriting, @unchecked Sendable {

    public let url: URL
    public private(set) var framesWritten: Int = 0

    private var file: AVAudioFile?
    private let processingFormat: AVAudioFormat

    public init(url: URL, sampleRate: Double, format: RecordingFormat) throws {
        self.url = url

        guard let processing = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        ) else {
            throw TrackWriterError.cannotCreateFile(url.lastPathComponent)
        }
        self.processingFormat = processing

        let settings: [String: Any]
        switch format {
        case .aac:
            settings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                // 96 kbps mono is transparent for speech and keeps an hour-long
                // two-speaker session well under 100 MB.
                AVEncoderBitRateKey: 96_000,
            ]
        case .wav:
            settings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 24,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
        }

        do {
            self.file = try AVAudioFile(forWriting: url, settings: settings)
        } catch {
            throw TrackWriterError.cannotCreateFile("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    public func write(_ samples: [Float]) throws {
        guard let file, !samples.isEmpty else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let destination = buffer.floatChannelData?[0] else {
            throw TrackWriterError.writeFailed(url.lastPathComponent)
        }

        samples.withUnsafeBufferPointer { destination.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)

        do {
            try file.write(from: buffer)
            framesWritten += samples.count
        } catch {
            throw TrackWriterError.writeFailed("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    public func finish() throws {
        file = nil   // AVAudioFile finalises the container on deinit
    }

    public func discard() {
        file = nil
        try? FileManager.default.removeItem(at: url)
    }
}

public struct AudioFileTrackWriterFactory: TrackWriterFactory {
    public init() {}

    public func makeWriter(url: URL, sampleRate: Double, format: RecordingFormat) throws -> TrackWriting {
        try AudioFileTrackWriter(url: url, sampleRate: sampleRate, format: format)
    }
}
