import Testing
import Foundation
@testable import LapelKit

private struct Reader: AudioTrackReading {
    var tracks: [String: [Float]]
    var rate: Double = 48_000
    func readMono(from url: URL) throws -> (samples: [Float], sampleRate: Double) {
        guard let samples = tracks[url.lastPathComponent] else {
            throw ExportError.trackUnreadable(url.lastPathComponent)
        }
        return (samples, rate)
    }
}

private func session(_ files: [String]) -> StoredSession {
    var metadata = SessionMetadata(
        id: UUID(), title: "Take", createdAt: Date(),
        deviceName: "DJI", inputChannelCount: 2, sampleRate: 48_000, format: .aac)
    metadata.tracks = files.enumerated().map {
        TrackMetadata(channelIndex: $0.offset, speakerName: "S\($0.offset)", fileName: $0.element, peakDB: -6)
    }
    return StoredSession(directory: URL(fileURLWithPath: "/tmp/s"), metadata: metadata)
}

@Suite("SessionMixLoader")
struct SessionMixLoaderTests {

    @Test("every track is read and summed into one mix")
    func mixesTracks() throws {
        let loader = SessionMixLoader(reader: Reader(tracks: ["a.m4a": [0.1, 0.2], "b.m4a": [0.3, 0.1]]))
        let mix = try loader.load(session(["a.m4a", "b.m4a"]))

        #expect(mix.samples == [0.4, 0.3000000])
        #expect(mix.sampleRate == 48_000)
    }

    @Test("an unreadable track is skipped and named, and the rest still mixes")
    func skipsUnreadable() throws {
        let loader = SessionMixLoader(reader: Reader(tracks: ["a.m4a": [0.5, 0.5]]))
        let mix = try loader.load(session(["a.m4a", "missing.m4a"]))

        #expect(mix.samples == [0.5, 0.5])
        #expect(mix.skippedTracks == ["missing.m4a"])
    }

    @Test("a session with nothing readable fails rather than returning silence")
    func failsWhenNothingReadable() {
        let loader = SessionMixLoader(reader: Reader(tracks: [:]))
        #expect(throws: ExportError.self) { try loader.load(session(["a.m4a"])) }
    }

    @Test("the mix is summarised into drawable bins with the right duration")
    func summarises() throws {
        let samples = (0..<48_000).map { Float(sin(Double($0) * 0.01)) }
        let loader = SessionMixLoader(reader: Reader(tracks: ["a.m4a": samples]))
        let summary = try loader.summary(session(["a.m4a"]), binCount: 120)

        #expect(summary.bins.count == 120)
        #expect(abs(summary.duration - 1.0) < 0.0001)
        #expect(summary.peak > 0)
    }
}
