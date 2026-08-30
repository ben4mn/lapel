import AVFoundation
import Foundation
import LapelKit

/// Writes a plausible two-speaker session to disk.
///
/// Exists so the app's library, playback and export can be exercised without a
/// receiver to hand — and so anyone who clones the repo can see what Lapel does
/// before buying a microphone.
enum DemoSession {

    private static let script: [(speaker: String, channel: Int, start: Double, end: Double, text: String)] = [
        ("Ben", 0, 0.4, 3.1, "Right — so the whole point is that the hardware already keeps you apart."),
        ("Dana", 1, 3.4, 6.2, "Because we're each wearing our own transmitter."),
        ("Ben", 0, 6.4, 10.8, "Exactly. TX1 goes to the left channel, TX2 goes to the right. Nothing has to guess."),
        ("Dana", 1, 11.2, 14.6, "And that's why the transcript can say who said what without a diarization model."),
        ("Ben", 0, 14.9, 17.2, "Right. It was never mixed together in the first place."),
        ("Dana", 1, 17.5, 20.0, "Good. Let's ship it."),
    ]

    static func write(to root: URL) throws -> URL {
        let store = SessionStore(root: root)
        let handle = try store.createSession(title: "Demo conversation", at: Date())

        let sampleRate = 48_000.0
        let duration = 21.0
        let speakers = ["Ben", "Dana"]

        var metadata = SessionMetadata(
            id: handle.id, title: "Demo conversation", createdAt: Date(),
            deviceName: "DJI MIC MINI (demo)", inputChannelCount: 2,
            sampleRate: sampleRate, format: .wav
        )
        metadata.duration = duration

        for (channel, speaker) in speakers.enumerated() {
            let url = handle.trackURL(channelIndex: channel, speakerName: speaker, format: .wav)
            let samples = track(forChannel: channel, sampleRate: sampleRate, duration: duration)

            let writer = try AudioFileTrackWriter(url: url, sampleRate: sampleRate, format: .wav)
            try writer.write(samples)
            try writer.finish()

            metadata.tracks.append(TrackMetadata(
                channelIndex: channel,
                speakerName: speaker,
                fileName: url.lastPathComponent,
                peakDB: LevelMeter.decibels(samples.reduce(0) { max($0, abs($1)) })
            ))
        }

        try store.write(transcript(), to: handle, updating: &metadata)
        try store.write(metadata, to: handle)
        return handle.directory
    }

    static func transcript() -> Transcript {
        Transcript.merge([
            script.filter { $0.channel == 0 }.map(segment),
            script.filter { $0.channel == 1 }.map(segment),
        ])
    }

    private static func segment(_ line: (speaker: String, channel: Int, start: Double, end: Double, text: String)) -> TranscriptSegment {
        TranscriptSegment(speaker: line.speaker, channelIndex: line.channel,
                          start: line.start, end: line.end, text: line.text)
    }

    /// One voice per speaker, so the two tracks are as distinguishable as two real
    /// people wearing two lapels.
    private static let voices = ["Daniel", "Samantha"]

    /// Builds one speaker's track: their lines at their timestamps, true digital
    /// zero everywhere else — the same shape a real receiver produces on a channel
    /// whose wearer is not talking.
    ///
    /// Uses `say` so the fixture contains genuine speech and transcription can be
    /// exercised against it. Falls back to a synthetic hum if speech synthesis is
    /// unavailable, because a fixture that cannot be built at all is worse than one
    /// that only drives the meters.
    private static func track(forChannel channel: Int, sampleRate: Double, duration: Double) -> [Float] {
        let frames = Int(duration * sampleRate)
        var samples = [Float](repeating: 0, count: frames)

        for line in script where line.channel == channel {
            let start = Int(line.start * sampleRate)
            guard start < frames else { continue }

            let spoken = speak(line.text, voice: voices[channel % voices.count], sampleRate: sampleRate)
                ?? hum(seconds: line.end - line.start, channel: channel, sampleRate: sampleRate)

            for (offset, sample) in spoken.enumerated() where start + offset < frames {
                samples[start + offset] = sample
            }
        }
        return samples
    }

    /// Renders one line with macOS speech synthesis, straight to float samples.
    private static func speak(_ text: String, voice: String, sampleRate: Double) -> [Float]? {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lapel-say-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: url) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = [
            "-v", voice,
            "-o", url.path,
            "--data-format=LEF32@\(Int(sampleRate))",
            text,
        ]
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
        } catch {
            return nil
        }

        guard let read = try? AVAudioFileTrackReader().readMono(from: url), !read.samples.isEmpty else {
            return nil
        }

        // Backed off from full scale so the two tracks sum without the mixdown
        // having to pull the whole conversation down.
        return read.samples.map { $0 * 0.7 }
    }

    private static func hum(seconds: Double, channel: Int, sampleRate: Double) -> [Float] {
        let pitch = channel == 0 ? 130.0 : 210.0
        return (0..<max(0, Int(seconds * sampleRate))).map { frame in
            let t = Double(frame) / sampleRate
            let envelope = 0.35 * (0.6 + 0.4 * sin(2 * .pi * 3.1 * t))
            return Float(envelope * (sin(2 * .pi * pitch * t) + 0.4 * sin(2 * .pi * pitch * 2.5 * t)))
        }
    }
}
