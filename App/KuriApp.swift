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
        // Without the menu bar icon there'd be no way back to a window.
        let showsIcon = config?.menuBarIcon ?? true
        MiniController.shared.setShowsIcon(showsIcon)
        startsInBackground = showsIcon && (config?.startInBackground ?? false)
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
            // File › New Chat: the main window has a single chat page, so
            // this takes the place of New Window.
            CommandGroup(replacing: .newItem) {
                Button("New Chat") {
                    model.selection = nil
                    WindowActions.openMain()
                }
                .keyboardShortcut("n")
                .disabled(model.phase.isReady == false)
            }
            // View › Show Sidebar (⌃⌘S): Kuri draws its own sidebar toggle.
            SidebarCommands()
            CommandGroup(after: .sidebar) {
                InspectorCommands(model: model)
            }
            CommandMenu("Chat") {
                ChatCommands(model: model)
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

/// Chat: every action the chat page offers, so each has a menu item and
/// the buttons are shortcuts to it. They act on the main window's chat.
private struct ChatCommands: View {
    @Bindable var model: AppModel

    var body: some View {
        let ready = model.phase.isReady
        let chosen = ready && model.selection != nil
        Button("Stop") { Task { await model.cancel() } }
            .keyboardShortcut(".")
            .disabled(!model.isSelectedBusy)
        Button("Retry") { Task { await model.retrySelected() } }
            .keyboardShortcut("r")
            .disabled(!model.canRetry)
        Button("Continue") { Task { await model.continueSelected() } }
            .disabled(!model.canContinue)
        Divider()
        Button("Attach Folder…") {
            WindowActions.openMain()
            model.choosingFolder = true
        }
        .keyboardShortcut("o", modifiers: [.command, .shift])
        .disabled(!ready)
        Button("Compact Chat") { Task { await model.compactSelected() } }
            .disabled(!chosen || model.isSelectedBusy)
        Divider()
        Button("Rename Chat") { withAnimation(Tune.move) { model.renameSelected() } }
            .disabled(!chosen)
        Button("Delete Chat…") { model.pendingDeletion = model.selection }
            .disabled(!chosen)
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

    /// Clicking the Dock icon with no window open brings the main one back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { WindowActions.openMain() }
        return true
    }
}
