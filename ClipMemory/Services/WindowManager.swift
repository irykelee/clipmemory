import AppKit
import SwiftUI

/// Main NSWindow subclass that disables AppKit's NSFullScreenTransition
/// (macOS 13+ green-button → real fullscreen, which has the LSUIElement
/// trap: hidden traffic lights, no exit affordance, can't shrink). Instead
/// `performZoom` toggles the frame between the user's saved frame and
/// `NSScreen.visibleFrame` directly — windowed mode, traffic lights
/// remain visible, menu bar visible, and dragging any edge or clicking
/// the green button again escapes the screen-size state.
///
/// We don't add `.fullScreen` to the styleMask (so AppKit's built-in
/// fullscreen machinery stays disengaged) and we set
/// `collectionBehavior = .fullScreenNone` so the green button falls
/// back to `performZoom`. Windowed mode, traffic lights
final class MainWindow: NSWindow {
    private var userFrame: NSRect?

    override func performZoom(_ sender: Any?) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let currentFrame = self.frame
        let isBigEnough = currentFrame.width >= screenFrame.width - 20
            && currentFrame.height >= screenFrame.height - 20
        if isBigEnough, let saved = userFrame {
            setFrame(saved, display: true, animate: true)
        } else {
            userFrame = currentFrame
            setFrame(screenFrame, display: true, animate: true)
        }
    }
}

/// L-23 (2026-07-24 audit): typed Codable shape for the persisted window
/// frame. Replaces the previous `JSONSerialization` round-trip via a
/// `[String: CGFloat]` dictionary — same wire format ("x"/"y"/"w"/"h" keys
/// with numeric values) so any existing UserDefaults blob continues to
/// decode without migration.
struct WindowFrame: Codable, Equatable {
    var x: CGFloat
    var y: CGFloat
    var w: CGFloat
    var h: CGFloat
}

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
        // L-21 (2026-07-24 audit): sync SwiftUI content to current
        // NSApp.appearance BEFORE show() so the popover window opens with
        // the correct colorScheme on its first frame. Setting
        // `window.appearance` after `show()` left a one-frame flash where
        // the SwiftUI host view rendered with the system default
        // appearance before AppKit applied ours.
        popover.appearance = NSApp.appearance
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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
            let window = MainWindow(
                contentRect: savedWindowFrame,
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            window.delegate = self
            window.isReleasedWhenClosed = false
            window.collectionBehavior = .fullScreenNone
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
                  let frame = try? JSONDecoder().decode(WindowFrame.self, from: data) else { return defaultFrame }
            let saved = NSRect(x: frame.x, y: frame.y, width: frame.w, height: frame.h)
            if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(saved) }) {
                let v = NSScreen.main?.visibleFrame ?? defaultFrame
                return NSRect(x: v.midX - 340, y: v.midY - 250, width: 680, height: 500)
            }
            return saved
        }
        set {
            let f = WindowFrame(x: newValue.origin.x, y: newValue.origin.y, w: newValue.size.width, h: newValue.size.height)
            if let data = try? JSONEncoder().encode(f) { UserDefaults.standard.set(data, forKey: windowFrameKey) }
        }
    }

    func windowDidMove(_ n: Notification) { saveWindowFrameDebounced() }
    func windowDidResize(_ n: Notification) { saveWindowFrameDebounced() }
}
