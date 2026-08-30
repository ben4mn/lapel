import Foundation

/// Picks the best transcription engine this machine can actually run.
///
/// Kept separate from the engines themselves so call sites never carry an
/// availability check — they ask for a `Transcribing` and get one that either works
/// or explains why it does not.
public enum TranscriberFactory {

    public static func makeDefault(locale: Locale = .current) -> any Transcribing {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let transcriber = SpeechAnalyzerTranscriber(locale: locale)
            if transcriber.isAvailable { return transcriber }
            return UnavailableTranscriber(
                reason: transcriber.unavailableReason ?? "On-device transcription is not available on this Mac."
            )
        }
        return UnavailableTranscriber(reason: "On-device transcription requires macOS 26 or later.")
        #else
        // Built with a toolchain older than the macOS 26 SDK, so the engine was not
        // compiled in at all.
        return UnavailableTranscriber(
            reason: "This build of Lapel was compiled without on-device transcription. Rebuild with Xcode 26 or later."
        )
        #endif
    }
}
