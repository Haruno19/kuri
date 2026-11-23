import AppKit
import SwiftUI

/// SwiftUI's own actions for opening the main window and Settings,
/// captured from the main window when it first appears, so AppKit code
/// (the status item, the mini window) can call them.
enum WindowActions {
    static var openWindow: OpenWindowAction?
    static var openSettings: OpenSettingsAction?

    static func openMain() {
        openWindow?(id: "main")
        NSApplication.shared.activate()
    }

    static func showSettings() {
        if let openSettings {
            openSettings()
        } else {
            NSApplication.shared.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        NSApplication.shared.activate()
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
    private let mini = AppModel()
    private var statusItem: NSStatusItem?
    private var panel: MiniPanel?

    static let defaultSize = NSSize(width: 380, height: 520)
    static let minSize = NSSize(width: 300, height: 320)
    static let maxSize = NSSize(width: 560, height: 820)

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(named: "MenuBarIcon")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Kuri"
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
        menu.addItem(withTitle: "Open Kuri", action: #selector(openMain), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Kuri", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func openMain() { WindowActions.openMain() }
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
            zoom.toolTip = "Open in the main window"
        }

        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = 18
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
