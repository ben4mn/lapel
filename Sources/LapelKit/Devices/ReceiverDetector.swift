import Foundation

/// Picks the DJI receiver out of whatever audio devices the machine currently has.
///
/// Matching is on vendor identity rather than an exact product string: DJI has
/// shipped the receiver under several names ("DJI MIC MINI", "DJI Mic"), and the
/// manufacturer field varies between "DJI" and "SZ DJI Technology".
public enum ReceiverDetector {
    static let vendorTokens = ["dji"]

    public static func detect(in devices: [AudioDeviceDescriptor]) -> Receiver? {
        devices
            .filter(\.canCapture)
            .filter(isVendorMatch)
            // Several entries can share a vendor; the widest input is the capture path.
            .max { $0.inputChannelCount < $1.inputChannelCount }
            .map(Receiver.init(device:))
    }

    static func isVendorMatch(_ device: AudioDeviceDescriptor) -> Bool {
        let haystack = "\(device.name) \(device.manufacturer)".lowercased()
        return vendorTokens.contains { haystack.contains($0) }
    }
}
