import LapelKit
import SwiftUI

@main
struct LapelApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model.recorder)
                .frame(minWidth: 820, minHeight: 560)
                .task { model.startMonitoring() }
        }
        .defaultSize(width: 960, height: 640)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// Owns the objects that live for the whole app: the recorder model and the
/// CoreAudio hotplug monitor that feeds it.
@MainActor
@Observable
final class AppModel {
    let recorder: RecorderModel
    private let monitor = AudioDeviceMonitor()
    private var isMonitoring = false

    init() {
        let root = (try? SessionStore.defaultRoot())
            ?? URL.homeDirectory.appending(path: "Lapel/Sessions")
        recorder = RecorderModel(store: SessionStore(root: root))
    }

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        let recorder = self.recorder
        monitor.start { devices in
            // The monitor calls back on its own queue. DispatchQueue.main is the
            // main actor's executor and is FIFO, so this both hops correctly and
            // preserves the order hardware events happened in.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { recorder.devicesChanged(to: devices) }
            }
        }
    }
}
