import AppKit
import SwiftUI

class WindowManager: NSObject, NSWindowDelegate {
    private(set) var mainWindow: NSWindow?
    private var quickBarPopover: NSPopover?
    private var statusItem: NSStatusItem?
    private let windowFrameKey = "WindowFrame"
    /// C2 fix: keep a stable ContentView instance to preserve @State across window show/hide cycles
    private(set) var mainContentView: ContentView?

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
        // Sync SwiftUI content to current NSApp.appearance so colorScheme follows app theme
        popover.contentViewController?.view.window?.appearance = NSApp.appearance
    }

    func showMainWindow() {
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
        } else {
            if mainContentView == nil {
                mainContentView = ContentView()
            }
            // NEW-6 (2026-07-21): replace `mainContentView!` with a guard.
            // The property is always set by the `if mainContentView == nil`
            // block above, but a future refactor could rearrange the
            // branches — a guard makes the invariant explicit and avoids
            // a crash if the property is ever nil at this line.
            guard let contentView = mainContentView else { return }
            let window = NSWindow(
                contentRect: savedWindowFrame,
                // Reverted (2026-07-24, was .fullScreen): adding the
                // NSFullScreenTransition on an LSUIElement (menu-bar-only) app
                // shows the screen filled, but:
                //   - The system status menu bar (Apple/Control Center/Clock)
                //     overlays the window instead of auto-hiding.
                //   - Traffic lights disappear (so user has no visible exit
                //     affordance).
                //   - The window refuses to shrink (correct fullscreen behavior,
                //     but combined with the missing traffic lights feels
                //     "trapped in fullscreen").
                // Net effect: the regression the previous `.fullScreen` fix
                // introduced felt worse than the legacy-zoom behavior it was
                // trying to replace. Reverting to legacy zoom (window grows to
                // its userFrame via the green button's standard-frame toggle)
                // keeps traffic lights visible AND lets the user drag any edge
                // to untrap. A proper fullscreen toggle can be re-introduced via
                // a custom menu item + `.toggleFullScreen(_:)` if needed.
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.toolbarStyle = .unified
            window.delegate = self
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: contentView)
            window.makeKeyAndOrderFront(nil)
            mainWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var saveFrameWorkItem: DispatchWorkItem?

    func windowWillClose(_ notification: Notification) {
        // Persist the final frame immediately before hiding so a later quit
        // or crash does not lose the user's last window position.
        saveFrameWorkItem?.cancel()
        if let w = mainWindow { savedWindowFrame = w.frame }
        // Keep mainWindow and mainContentView alive so @State survives close/reopen.
        // isReleasedWhenClosed=false already prevents the window from deallocating.
        NSApp.setActivationPolicy(.accessory)
    }

    private func saveWindowFrameDebounced() {
        saveFrameWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, let window = self.mainWindow else { return }
            self.savedWindowFrame = window.frame
        }
        saveFrameWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
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

    func windowDidMove(_ n: Notification) { saveWindowFrameDebounced() }
    func windowDidResize(_ n: Notification) { saveWindowFrameDebounced() }
}
