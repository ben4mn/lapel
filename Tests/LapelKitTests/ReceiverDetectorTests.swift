import Testing
@testable import LapelKit

private extension AudioDeviceDescriptor {
    static func make(
        uid: String = "uid",
        name: String = "Some Device",
        manufacturer: String = "Acme",
        inputChannelCount: Int = 2,
        sampleRate: Double = 48_000,
        transport: TransportType = .usb
    ) -> AudioDeviceDescriptor {
        AudioDeviceDescriptor(
            uid: uid, name: name, manufacturer: manufacturer,
            inputChannelCount: inputChannelCount, sampleRate: sampleRate, transport: transport
        )
    }

    static let builtInMic = make(
        uid: "BuiltInMicrophoneDevice", name: "MacBook Air Microphone",
        manufacturer: "Apple Inc.", inputChannelCount: 1, transport: .builtIn
    )

    static let djiStereo = make(
        uid: "DJI-MIC-MINI-01", name: "DJI MIC MINI",
        manufacturer: "DJI", inputChannelCount: 2
    )

    static let djiMono = make(
        uid: "DJI-MIC-MINI-01", name: "DJI MIC MINI",
        manufacturer: "DJI", inputChannelCount: 1
    )
}

@Suite("ReceiverDetector")
struct ReceiverDetectorTests {

    @Test("no devices at all means no receiver")
    func emptyList() {
        #expect(ReceiverDetector.detect(in: []) == nil)
    }

    @Test("a machine with only its built-in mic has no receiver")
    func builtInOnly() {
        #expect(ReceiverDetector.detect(in: [.builtInMic]) == nil)
    }

    @Test("a DJI receiver is found among unrelated devices")
    func findsDJIAmongOthers() {
        let receiver = ReceiverDetector.detect(in: [.builtInMic, .djiStereo])
        #expect(receiver?.device.uid == "DJI-MIC-MINI-01")
    }

    @Test("matching is case insensitive across vendor spellings")
    func caseInsensitiveMatching() {
        let lowercased = AudioDeviceDescriptor.make(name: "dji mic mini", manufacturer: "SZ DJI Technology")
        #expect(ReceiverDetector.detect(in: [lowercased]) != nil)
    }

    @Test("a device is matched on manufacturer even when its name omits the vendor")
    func matchesOnManufacturer() {
        let oddlyNamed = AudioDeviceDescriptor.make(name: "Wireless Microphone RX", manufacturer: "DJI")
        #expect(ReceiverDetector.detect(in: [oddlyNamed]) != nil)
    }

    @Test("an output-only DJI device is not a capture receiver")
    func ignoresOutputOnlyDevice() {
        let speakerOnly = AudioDeviceDescriptor.make(name: "DJI MIC MINI", manufacturer: "DJI", inputChannelCount: 0)
        #expect(ReceiverDetector.detect(in: [speakerOnly]) == nil)
    }

    @Test("when several DJI inputs are present the widest one wins")
    func prefersMostChannels() {
        let narrow = AudioDeviceDescriptor.make(uid: "a", name: "DJI MIC MINI", manufacturer: "DJI", inputChannelCount: 1)
        let wide = AudioDeviceDescriptor.make(uid: "b", name: "DJI MIC MINI", manufacturer: "DJI", inputChannelCount: 2)
        #expect(ReceiverDetector.detect(in: [narrow, wide])?.device.uid == "b")
    }

    @Test("a non-DJI USB interface is not mistaken for the receiver")
    func ignoresUnrelatedInterface() {
        let scarlett = AudioDeviceDescriptor.make(name: "Scarlett 2i2 USB", manufacturer: "Focusrite")
        #expect(ReceiverDetector.detect(in: [scarlett]) == nil)
    }

    @Test("two input channels means the two lapels can be split into separate tracks")
    func stereoSupportsSeparation() {
        let receiver = ReceiverDetector.detect(in: [.djiStereo])
        #expect(receiver?.channelMode == .dualChannel)
        #expect(receiver?.canSeparateSpeakers == true)
        #expect(receiver?.advisory == nil)
    }

    @Test("one input channel means the receiver is mixing both lapels down and speakers cannot be split")
    func monoCannotSeparate() {
        let receiver = ReceiverDetector.detect(in: [.djiMono])
        #expect(receiver?.channelMode == .mono)
        #expect(receiver?.canSeparateSpeakers == false)
        #expect(receiver?.advisory == .receiverInMonoMode)
    }

    @Test("the mono advisory tells the user the exact fix on the hardware")
    func monoAdvisoryIsActionable() {
        let message = ReceiverAdvisory.receiverInMonoMode.message
        #expect(message.lowercased().contains("stereo"))
        #expect(!message.isEmpty)
    }

    @Test("a receiver exposing more than two channels is reported as multi-channel")
    func multiChannelReceiver() {
        let quad = AudioDeviceDescriptor.make(name: "DJI MIC", manufacturer: "DJI", inputChannelCount: 4)
        #expect(ReceiverDetector.detect(in: [quad])?.channelMode == .multiChannel(4))
        #expect(ReceiverDetector.detect(in: [quad])?.canSeparateSpeakers == true)
    }

    @Test("the receiver reports one capture track per input channel, labelled by transmitter")
    func trackLayout() {
        let receiver = ReceiverDetector.detect(in: [.djiStereo])
        #expect(receiver?.tracks.count == 2)
        #expect(receiver?.tracks.map(\.channelIndex) == [0, 1])
        #expect(receiver?.tracks.map(\.defaultName) == ["TX1", "TX2"])
    }

    @Test("a mono receiver exposes a single mixed track rather than a phantom second one")
    func monoTrackLayout() {
        let receiver = ReceiverDetector.detect(in: [.djiMono])
        #expect(receiver?.tracks.count == 1)
        #expect(receiver?.tracks.first?.defaultName == "Mixed")
    }
}
