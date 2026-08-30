import CoreAudio
import Foundation

/// Publishes the input device list whenever the hardware picture changes.
///
/// Two listeners, because there are two distinct events to catch:
///
/// 1. `kAudioHardwarePropertyDevices` on the system object — the receiver being
///    plugged in or pulled out.
/// 2. `kAudioDevicePropertyStreamConfiguration` on each input device — the channel
///    count changing *without* the device list changing, which is what happens when
///    the user presses the receiver's mode button from M to S. Watching only the
///    device list would leave Lapel insisting the receiver is still in mono.
public final class AudioDeviceMonitor: @unchecked Sendable {

    private let enumerator: AudioDeviceEnumerating
    private let queue = DispatchQueue(label: "com.lapel.device-monitor")
    private var systemListener: AudioObjectPropertyListenerBlock?
    private var watchedDevices: [AudioObjectID] = []
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var onChange: (@Sendable ([AudioDeviceDescriptor]) -> Void)?

    // Instance-owned because AudioObject{Add,Remove}PropertyListenerBlock take these
    // inout; a shared static would be mutable global state across threads.
    private var systemAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var streamConfigAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )

    public init(enumerator: AudioDeviceEnumerating = CoreAudioDeviceEnumerator()) {
        self.enumerator = enumerator
    }

    /// Emits the device list immediately, then again on every change.
    public func start(onChange: @escaping @Sendable ([AudioDeviceDescriptor]) -> Void) {
        queue.async {
            self.onChange = onChange
            self.installSystemListener()
            self.refresh()
        }
    }

    public func stop() {
        queue.async {
            self.removeSystemListener()
            self.removeDeviceListeners()
            self.onChange = nil
        }
    }

    deinit {
        removeSystemListener()
        removeDeviceListeners()
    }

    /// An `AsyncStream` wrapper, for call sites that prefer to await changes.
    public func changes() -> AsyncStream<[AudioDeviceDescriptor]> {
        AsyncStream { continuation in
            self.start { continuation.yield($0) }
            continuation.onTermination = { [weak self] _ in self?.stop() }
        }
    }

    // MARK: - Internals

    private func refresh() {
        let devices = enumerator.inputDevices()
        installDeviceListeners()
        onChange?(devices)
    }

    private func installSystemListener() {
        guard systemListener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.queue.async { self.refresh() }
        }
        systemListener = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &systemAddress, queue, block
        )
    }

    private func removeSystemListener() {
        guard let systemListener else { return }
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &systemAddress, queue, systemListener
        )
        self.systemListener = nil
    }

    /// Re-points the per-device listeners at whatever is currently attached.
    private func installDeviceListeners() {
        guard let coreAudio = enumerator as? CoreAudioDeviceEnumerator else { return }
        removeDeviceListeners()

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.queue.async { self.refresh() }
        }
        deviceListener = block

        for id in coreAudio.deviceIDs() where CoreAudioDeviceEnumerator.inputChannelCount(id) > 0 {
            AudioObjectAddPropertyListenerBlock(id, &streamConfigAddress, queue, block)
            watchedDevices.append(id)
        }
    }

    private func removeDeviceListeners() {
        guard let deviceListener else { return }
        for id in watchedDevices {
            AudioObjectRemovePropertyListenerBlock(id, &streamConfigAddress, queue, deviceListener)
        }
        watchedDevices.removeAll()
        self.deviceListener = nil
    }
}
