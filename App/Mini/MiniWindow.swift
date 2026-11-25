import AppKit
import SwiftUI

/// SwiftUI's own actions for opening the main window and Settings, for
/// AppKit code (the status item, the mini window). They're captured at
/// launch by a SwiftUI view in a hidden one-point window, so they exist
/// even when the main window never appeared (`startInBackground`).
enum WindowActions {
    static var openWindow: OpenWindowAction?
    static var openSettings: OpenSettingsAction?
    private static var catcher: NSWindow?

    static func capture() {
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 1, height: 1),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Catcher { window.orderOut(nil) })
        window.orderBack(nil)
        catcher = window
    }

    private struct Catcher: View {
        let done: () -> Void
        @Environment(\.openWindow) private var openWindow
        @Environment(\.openSettings) private var openSettings

        var body: some View {
            Color.clear.frame(width: 1, height: 1).onAppear {
                WindowActions.openWindow = openWindow
                WindowActions.openSettings = openSettings
                done()
            }
        }
    }

    static func openMain() {
        Dock.show()
        openWindow?(id: "main")
        NSApplication.shared.activate()
    }

    static func showSettings() {
        Dock.show()
        if let openSettings {
            openSettings()
        } else {
            NSApplication.shared.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        NSApplication.shared.activate()
    }
}

/// Kuri is in the Dock (and ⌘-Tab) only while the main window or Settings
/// is open; otherwise it lives in the menu bar, like a menu bar app, and
/// the mini window and its folder picker don't bring the icon up.
enum Dock {
    static func show() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    /// After a window closes: the icon goes if no regular window is left,
    /// unless there's no menu bar icon to reach Kuri by instead.
    static func update() {
        let open = NSApplication.shared.windows.contains { window in
            window.isVisible && !(window is NSPanel) && window.level == .normal && window.canBecomeMain
        }
        let reachable = open || !MiniController.shared.showsIcon
        NSApplication.shared.setActivationPolicy(reachable ? .regular : .accessory)
    }

    /// Watches regular windows opening and closing.
    static func follow() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            // Once the window is gone from the list.
            DispatchQueue.main.async { MainActor.assumeIsolated { update() } }
        }
        center.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { update() }
        }
    }
}

/// The menu bar icon and the mini window it opens: a small chat in Liquid
/// Glass that floats above other windows, like picture in picture. Left
/// click shows or hides it; right click opens a menu.
final class MiniController: NSObject, NSWindowDelegate {
    static let shared = MiniController()

    /// The main window's model; the mini window has its own, on the same
    /// engine, so the two can show different chats.
    var main: AppModel?
    /// Set at launch from `startInBackground`.
    var startsInBackground = false
    /// `menuBarIcon`: set at launch, then followed as the config changes.
    private(set) var showsIcon = true
    private var installed = false
    private let mini = AppModel()
    private var statusItem: NSStatusItem?
    private var panel: MiniPanel?

    static let defaultSize = NSSize(width: 380, height: 520)
    static let minSize = NSSize(width: 300, height: 320)
    static let maxSize = NSSize(width: 560, height: 820)

    func install() {
        WindowActions.capture()
        Dock.follow()
        installed = true
        if showsIcon { addIcon() }
    }

    /// Shows or hides the menu bar icon (`menuBarIcon`). Without it the mini
    /// window goes too, and Kuri keeps its Dock icon.
    func setShowsIcon(_ shows: Bool) {
        guard shows != showsIcon else { return }
        showsIcon = shows
        guard installed else { return }
        if shows {
            addIcon()
        } else {
            panel?.orderOut(nil)
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
        }
        Dock.update()
    }

    private func addIcon() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(named: "MenuBarIcon")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Kuri"
            button.setAccessibilityLabel("Kuri")
        }
        statusItem = item
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApplication.shared.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            toggle()
        }
    }

    /// A native menu, placed and highlighted like any menu bar extra's.
    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Open Kuri"), action: #selector(openMain), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "New Chat"), action: #selector(newChat), keyEquivalent: "n").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Settings…"), action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit Kuri"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func openMain() { WindowActions.openMain() }

    /// A new chat in the main window, as File › New Chat.
    @objc private func newChat() {
        main?.selection = nil
        WindowActions.openMain()
    }

    /// The mini window's chat in the main window.
    func openInMain() { expand() }
    @objc private func openSettings() { WindowActions.showSettings() }

    func toggle() {
        let panel = panel ?? makePanel()
        if panel.isVisible && panel.isKeyWindow {
            panel.orderOut(nil)
            return
        }
        if !panel.isVisible && !panel.hasPlacement {
            place(panel)
            panel.hasPlacement = true
        }
        panel.makeKeyAndOrderFront(nil)
    }

    /// Maximize: the same chat, in the main window.
    @objc private func expand() {
        main?.selection = mini.selection
        panel?.orderOut(nil)
        WindowActions.openMain()
    }

    private func makePanel() -> MiniPanel {
        let panel = MiniPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.minSize = Self.minSize
        panel.maxSize = Self.maxSize
        panel.delegate = self
        // Close and maximize only; maximize opens the main window.
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        if let zoom = panel.standardWindowButton(.zoomButton) {
            zoom.target = self
            zoom.action = #selector(expand)
            zoom.toolTip = String(localized: "Open in the main window")
        }

        // No corner radius of its own: the window's mask rounds it, so it
        // follows the system's radius (and any override of it).
        let glass = NSGlassEffectView()
        glass.style = .regular
        let host = NSHostingView(rootView: MiniChat().environment(mini).modifier(Themed()))
        host.sizingOptions = []
        glass.contentView = host
        panel.contentView = glass
        panel.hasPlacement = panel.setFrameUsingName(Self.frameName)
        panel.setFrameAutosaveName(Self.frameName)

        panel.closeUpButtons()
        self.panel = panel
        Task { await startMini() }
        return panel
    }

    /// Joins the main model's engine once it's running.
    private func startMini() async {
        for _ in 0..<200 {
            if let engine = main?.engine {
                await mini.start(sharing: engine)
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// The first time: just under the menu bar icon.
    private func place(_ panel: NSWindow) {
        guard let button = statusItem?.button, let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: visible.maxY - size.height - 8))
    }

    private static let frameName = "KuriMiniWindow"

    // The title bar lays its buttons out again on resize.
    func windowDidResize(_ notification: Notification) { panel?.closeUpButtons() }
    func windowDidBecomeKey(_ notification: Notification) { panel?.closeUpButtons() }
}

/// A floating panel that takes typing without making Kuri the active app.
final class MiniPanel: NSPanel {
    /// Whether it has a frame of its own yet (saved, or placed once).
    var hasPlacement = false

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// With minimize hidden, maximize moves into its place, so the two
    /// buttons left sit side by side.
    func closeUpButtons() {
        guard let minimize = standardWindowButton(.miniaturizeButton),
              let zoom = standardWindowButton(.zoomButton) else { return }
        minimize.isHidden = true
        if zoom.frame.origin.x != minimize.frame.origin.x {
            zoom.setFrameOrigin(NSPoint(x: minimize.frame.origin.x, y: zoom.frame.origin.y))
        }
    }

    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        closeUpButtons()
    }

    /// Escape hides it, like the close button.
    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}
