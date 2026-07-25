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
        // INFRA-5 (2026-07-24 review): zoom against the window's OWN screen —
        // NSScreen.main is the screen with keyboard focus, which differs when
        // the window sits on a second display.
        guard let screen = self.screen ?? NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let currentFrame = self.frame
        let isBigEnough = currentFrame.width >= screenFrame.width - 20
            && currentFrame.height >= screenFrame.height - 20
        // INFRA-5 (2026-07-24 review): validate the saved frame is still
        // on-screen before restoring it (same visibleFrame.intersects check
        // as WindowManager.savedWindowFrame) — a frame saved on a since-
        // detached external display would otherwise zoom the window into
        // unreachable space. Off-screen saved frames are ignored.
        if isBigEnough, let saved = userFrame,
           NSScreen.screens.contains(where: { $0.visibleFrame.intersects(saved) }) {
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
    private var quickBarHostingController: NSHostingController<QuickBarView>?
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
        // L-3 (2026-07-25 audit): create the hosting controller once and reuse
        // it so QuickBarView's @State (search text, selection) survives across
        // show/hide cycles instead of resetting on every popover open.
        if quickBarHostingController == nil {
            quickBarHostingController = NSHostingController(rootView: QuickBarView(onDismiss: { [weak self] in
                self?.quickBarPopover?.close()
            }))
        }
        popover.contentViewController = quickBarHostingController
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
        // 2026-07-25 fix: the policy switch must PRECEDE window ordering.
        // On macOS 14+ `activate(ignoringOtherApps:)` is ignored (treated as
        // plain `activate()`) and `setActivationPolicy(.regular)` is
        // processed asynchronously by LaunchServices. Ordering the window
        // front while the app was still .accessory put the window on screen
        // but left the app un-activated — "Open Clipboard" looked like a
        // no-op: the window was visible behind other apps and the app never
        // became frontmost (reproduced: close main window, reopen → window
        // appears but WorkBuddy/Finder stays active).
        NSApp.setActivationPolicy(.regular)
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
            // 2026-07-25: on macOS 26 (Tahoe) the title bar layer renders
            // as an opaque white band across the window, no matter what
            // SwiftUI `toolbarBackground` says — that modifier only affects
            // the toolbar layer stacked on top. Extending the content view
            // into a transparent title bar lets the sidebar material reach
            // the top edge (traffic lights float over it), restoring the
            // pre-Tahoe unified look and matching Tahoe's own split-view
            // apps (Finder/Notes).
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            // 2026-07-25: add .moveToActiveSpace so a reopened window lands
            // on the user's CURRENT Space. Without it, a window closed on
            // Space A and reopened while the user sits on Space B stays on
            // Space A — combined with macOS 14+ ignoring activate() from
            // non-foreground apps, "Open Clipboard" looked like a no-op
            // (the window was ordered front, just on another Space).
            window.collectionBehavior = [.fullScreenNone, .moveToActiveSpace]
            window.contentView = NSHostingView(rootView: contentView)
            window.makeKeyAndOrderFront(nil)
            mainWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        // The policy change lands asynchronously in LaunchServices, so the
        // synchronous activate above can still be dropped right after an
        // accessory → regular transition. Re-assert on the next runloop
        // tick — standard menu-bar-app practice.
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.mainWindow else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
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
