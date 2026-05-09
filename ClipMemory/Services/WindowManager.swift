import AppKit
import SwiftUI

class WindowManager: NSObject, NSWindowDelegate {
    private(set) var mainWindow: NSWindow?
    private var quickBarPopover: NSPopover?
    private var statusItem: NSStatusItem?
    private let windowFrameKey = "WindowFrame"

    override init() { super.init() }

    func setStatusItem(_ item: NSStatusItem) { self.statusItem = item }

    func showQuickBar() {
        if quickBarPopover == nil {
            let popover = NSPopover()
            popover.behavior = .transient
            quickBarPopover = popover
        }
        guard let popover = quickBarPopover, let button = statusItem?.button else { return }
        if popover.isShown { popover.close(); return }
        popover.contentViewController = NSHostingController(rootView: QuickBarView(onDismiss: { [weak self] in
            self?.quickBarPopover?.close()
        }))
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func showMainWindow() {
        if mainWindow == nil {
            let contentView = ContentView()
            let window = NSWindow(
                contentRect: savedWindowFrame,
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            window.title = L10n.appName
            window.toolbarStyle = .unified
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.delegate = self
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: contentView)
            window.makeKeyAndOrderFront(nil)
            mainWindow = window
        } else {
            mainWindow?.contentView = NSHostingView(rootView: ContentView())
            mainWindow?.makeKeyAndOrderFront(nil)
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    private var savedWindowFrame: NSRect {
        get {
            let defaultFrame = NSRect(x: 0, y: 0, width: 680, height: 500)
            guard let data = UserDefaults.standard.data(forKey: windowFrameKey),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: CGFloat],
                  let x = dict["x"], let y = dict["y"],
                  let w = dict["w"], let h = dict["h"] else { return defaultFrame }
            let saved = NSRect(x: x, y: y, width: w, height: h)
            if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(saved) }) {
                let v = NSScreen.main?.visibleFrame ?? defaultFrame
                return NSRect(x: v.midX - 340, y: v.midY - 250, width: 680, height: 500)
            }
            return saved
        }
        set {
            let d: [String: CGFloat] = ["x": newValue.origin.x, "y": newValue.origin.y, "w": newValue.size.width, "h": newValue.size.height]
            if let data = try? JSONSerialization.data(withJSONObject: d) { UserDefaults.standard.set(data, forKey: windowFrameKey) }
        }
    }

    func windowDidMove(_ n: Notification) { if let w = mainWindow { savedWindowFrame = w.frame } }
    func windowDidResize(_ n: Notification) { if let w = mainWindow { savedWindowFrame = w.frame } }
}
