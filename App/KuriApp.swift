import KuriConfig
import SwiftUI

@main
struct KuriApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel
    /// Read at launch: with it, only the menu bar icon appears.
    private let startsInBackground: Bool

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        MiniController.shared.main = model
        FontLibrary.prepare()
        // Read now, before the first window draws; the engine's copy of the
        // config, loaded asynchronously, takes over from there.
        let config = try? ConfigLoader(home: KuriHome.resolve()).loadConfig()
        AppModel.apply(config?.appearance)
        startsInBackground = config?.startInBackground ?? false
        MiniController.shared.startsInBackground = startsInBackground
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
                .modifier(Themed())
                .frame(minWidth: 640, minHeight: 420)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1040, height: 760)
        .defaultLaunchBehavior(startsInBackground ? .suppressed : .automatic)
        .commands {
            // View › Show Sidebar (⌃⌘S): Kuri draws its own sidebar toggle.
            SidebarCommands()
            CommandGroup(after: .sidebar) {
                InspectorCommands(model: model)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// View › Show Inspector (⌥⌘I), next to the sidebar's own item.
private struct InspectorCommands: View {
    @Bindable var model: AppModel

    var body: some View {
        Button(model.showsInspector ? "Hide Inspector" : "Show Inspector") {
            model.toggleInspector()
        }
        .keyboardShortcut("i", modifiers: [.command, .option])
        .disabled(model.phase.isReady == false)
        Divider()
    }
}

/// The menu bar icon goes in once AppKit has finished launching; closing
/// every window leaves Kuri running there.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MiniController.shared.install()
        // Starting in the background: no window, so no Dock icon either.
        if MiniController.shared.startsInBackground { Dock.update() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
