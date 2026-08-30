import Foundation

/// Supplies the current set of input-capable audio devices.
///
/// The seam that lets everything above it run against fixtures. The real
/// implementation is `CoreAudioDeviceEnumerator`.
public protocol AudioDeviceEnumerating: Sendable {
    func inputDevices() -> [AudioDeviceDescriptor]
}

/// A fixed device list, for tests and for previews.
public struct StaticDeviceEnumerator: AudioDeviceEnumerating {
    public var devices: [AudioDeviceDescriptor]
    public init(devices: [AudioDeviceDescriptor]) { self.devices = devices }
    public func inputDevices() -> [AudioDeviceDescriptor] { devices }
}
