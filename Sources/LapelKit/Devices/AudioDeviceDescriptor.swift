import Foundation

/// How a device is attached to the machine.
///
/// Mirrors CoreAudio's `kAudioDevicePropertyTransportType` but as a plain enum, so
/// device logic can be tested without a CoreAudio object ID in sight.
public enum TransportType: String, Equatable, Sendable, CaseIterable {
    case builtIn, usb, bluetooth, thunderbolt, aggregate, virtual, unknown
}

/// A snapshot of one input-capable audio device.
///
/// This is the seam between CoreAudio and the rest of Lapel: everything above it
/// reasons about these values, never about `AudioObjectID`s.
public struct AudioDeviceDescriptor: Equatable, Sendable, Identifiable {
    public let uid: String
    public let name: String
    public let manufacturer: String
    public let inputChannelCount: Int
    public let sampleRate: Double
    public let transport: TransportType

    public var id: String { uid }

    public init(
        uid: String,
        name: String,
        manufacturer: String,
        inputChannelCount: Int,
        sampleRate: Double,
        transport: TransportType
    ) {
        self.uid = uid
        self.name = name
        self.manufacturer = manufacturer
        self.inputChannelCount = inputChannelCount
        self.sampleRate = sampleRate
        self.transport = transport
    }

    public var canCapture: Bool { inputChannelCount > 0 }
}

import CoreAudio

extension TransportType {
    /// Maps `kAudioDevicePropertyTransportType`. Unrecognised codes degrade to
    /// `.unknown` rather than failing: CoreAudio can report transports this app
    /// has never heard of, and none of them should stop device enumeration.
    public init(coreAudioValue: UInt32) {
        switch coreAudioValue {
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: self = .bluetooth
        case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
        case kAudioDeviceTransportTypeAggregate: self = .aggregate
        case kAudioDeviceTransportTypeVirtual: self = .virtual
        default: self = .unknown
        }
    }
}
