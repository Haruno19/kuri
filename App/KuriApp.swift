import SwiftUI

@main
struct KuriApp: App {
    @State private var model: AppModel

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        // The engine starts with the app, not with a window: Kuri keeps
        // running from the menu bar when every window is closed.
        Task { await model.start() }
        // Give MCP servers a chance to exit cleanly on quit.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                // The engine is its own actor, so it can finish while the
                // main thread waits here.
                guard let engine = model.engine else { return }
                let done = DispatchSemaphore(value: 0)
                Task.detached {
                    await engine.shutdown()
                    done.signal()
                }
                _ = done.wait(timeout: .now() + 2)
            }
        }
    }

    var body: some Scene {
        Window("Kuri", id: "main") {
            MainView()
                .environment(model)
                .frame(minWidth: 640, minHeight: 420)
        }
        .defaultSize(width: 960, height: 680)

        MenuBarExtra("Kuri", systemImage: "sparkle") {
            MenuBarView()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
