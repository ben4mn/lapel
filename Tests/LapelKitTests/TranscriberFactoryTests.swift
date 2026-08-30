import Testing
import Foundation
@testable import LapelKit

@Suite("TranscriberFactory")
struct TranscriberFactoryTests {

    @Test("on a machine that can transcribe, the real engine is chosen over the fallback")
    func selectsRealEngineWhenAvailable() {
        let transcriber = TranscriberFactory.makeDefault()

        // Guards the #if compiler(>=6.2) gate. Built with an older toolchain the
        // engine compiles out entirely, and this test is how that would be noticed
        // rather than shipping a build that silently cannot transcribe.
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            #expect(transcriber.isAvailable)
            #expect(transcriber.unavailableReason == nil)
            #expect(!(transcriber is UnavailableTranscriber))
            return
        }
        #endif

        #expect(transcriber is UnavailableTranscriber)
        #expect(transcriber.unavailableReason != nil)
    }

    @Test("an unavailable transcriber always explains itself")
    func fallbackAlwaysExplains() {
        let fallback = UnavailableTranscriber()
        #expect(!fallback.isAvailable)
        #expect(fallback.unavailableReason?.isEmpty == false)
    }
}
