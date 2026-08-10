import AppKit
import SwiftUI
import os.log

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
///
/// WINDOW-0001 (2026-08-10): frame persistence is now handled by
/// AppKit via `setFrameAutosaveName(_:)` — see `MainWindow.init` below.
/// `userFrame` is the zoom-toggle's separate state (NOT persistence):
/// the green button toggles between the user-resized frame and the
/// screen-full visibleFrame. Keeping `userFrame` in-memory only is
/// intentional — autosave handles persistence, this property just
/// remembers what the user resized to.
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
        // the old `WindowManager.savedWindowFrame` did) — a frame saved on a
        // since-detached external display would otherwise zoom the window
        // into unreachable space. Off-screen saved frames are ignored.
        if isBigEnough, let saved = userFrame,
           NSScreen.screens.contains(where: { $0.visibleFrame.intersects(saved) }) {
            setFrame(saved, display: true, animate: true)
        } else {
            userFrame = currentFrame
            setFrame(screenFrame, display: true, animate: true)
        }
    }
}

class WindowManager: NSObject, NSWindowDelegate {
    private let logger = Logger(subsystem: "com.clipmemory.app", category: "WindowManager")
    private(set) var mainWindow: NSWindow?
    private var quickBarPopover: NSPopover?
    private var quickBarHostingController: NSHostingController<QuickBarView>?
    private var statusItem: NSStatusItem?
    /// C2 fix: keep a stable ContentView instance to preserve @State across window show/hide cycles
    private(set) var mainContentView: ContentView?
    /// B-6 (2026-07-27): secondary windows (settings, welcome) registered by
    /// `AppDelegate` so the main-window-close policy switch can leave the
    /// app activated while any of them is still visible. Without this list
    /// closing the main window would sink `NSApp` to `.accessory` and strand
    /// any still-visible window — Dock icon gone, ⌘Tab no longer lists
    /// ClipMemory, the user has no obvious path back to the stranded window.
    private var secondaryWindows: [ObjectIdentifier: NSWindow] = [:]

    /// HIGH-2 (2026-07-26 review): factory closures for View instantiation so
    /// tests can inject mock views without the WindowManager needing to know
    /// concrete ContentView / QuickBarView signatures. Defaults preserve
    /// existing production behavior.
    var mainContentViewFactory: () -> ContentView = { ContentView() }
    var quickBarViewFactory: (@escaping () -> Void) -> QuickBarView = { onDismiss in
        QuickBarView(onDismiss: onDismiss)
    }

    /// M13 (2026-08-03): test seam — static injectable UserDefaults suite.
    /// WINDOW-0001 (2026-08-10): no longer used by WindowManager itself
    /// (frame persistence moved to AppKit's `setFrameAutosaveName`).
    /// Kept as a forward-compatible seam so future code that needs a
    /// test-injectable defaults suite (e.g. settings overlays) doesn't
    /// have to re-introduce the static. `nonisolated(unsafe)` to match
    /// the Swift 6 concurrency posture of the original (this property
    /// is read from main-thread WindowManager methods only).
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    override init() { super.init() }

    func setStatusItem(_ item: NSStatusItem) { self.statusItem = item }

    /// B-6 (2026-07-27): let `AppDelegate` register / unregister secondary
    /// windows (settings, welcome) so the main-window-close policy switch
    /// can leave the app activated while any of them is still visible.
    /// `ObjectIdentifier` is used to deduplicate re-registrations of the same
    /// window without forcing `NSWindow` to be `Hashable` via subclassing.
    func registerSecondaryWindow(_ window: NSWindow) {
        secondaryWindows[ObjectIdentifier(window)] = window
    }

    func unregisterSecondaryWindow(_ window: NSWindow) {
        secondaryWindows.removeValue(forKey: ObjectIdentifier(window))
    }

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
            quickBarHostingController = NSHostingController(rootView: quickBarViewFactory { [weak self] in
                self?.quickBarPopover?.close()
            })
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
                mainContentView = mainContentViewFactory()
            }
            // NEW-6 (2026-07-21): replace `mainContentView!` with a guard.
            // The property is always set by the `if mainContentView == nil`
            // block above, but a future refactor could rearrange the
            // branches — a guard makes the invariant explicit and avoids
            // a crash if the property is ever nil at this line.
            guard let contentView = mainContentView else { return }
            // WINDOW-0001 (2026-08-10): pass an empty contentRect — AppKit's
            // `setFrameAutosaveName` restores the user's saved frame from
            // defaults BEFORE the window first shows, so any initial rect we
            // pass here would be overridden. An empty rect lets AppKit center
            // the window on its first launch (no prior autosave), then
            // restore on every subsequent launch.
            let window = MainWindow(
                contentRect: .zero,
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            // WINDOW-0001: hand frame persistence to AppKit. The name is
            // global to the app (NSWindow uses a single NSUserDefaults key
            // derived from it), so a stable, namespaced identifier avoids
            // colliding with any future secondary-window autosave names.
            // AppKit auto-handles:
            //   - save on move/resize (no 0.5s debounce needed — we trust it)
            //   - restore on show
            //   - off-screen defense (frame on a since-detached display
            //     is pulled back to the main visibleFrame on restore)
            window.setFrameAutosaveName("com.clipmemory.app.MainWindow")
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
        // WINDOW-0001 (2026-08-10): frame persistence is handled by AppKit
        // via setFrameAutosaveName — we no longer write the frame here.
        // Keep mainWindow and mainContentView alive so @State survives close/reopen.
        // isReleasedWhenClosed=false already prevents the window from deallocating.
        // B-6 (2026-07-27): only sink to .accessory when no other registered
        // window is still on screen. Closing the main window while the
        // settings / welcome window is visible used to strand those windows
        // (no Dock icon, not in ⌘Tab) — they remained on screen but the app
        // lost activation, leaving the user no obvious way to bring them
        // back to the front. Iterating registered windows is more robust
        // than title-matching and covers any future secondary surface.
        let otherWindowsVisible = secondaryWindows.values.contains { $0.isVisible }
        if !otherWindowsVisible {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // WINDOW-0001 (2026-08-10): saveWindowFrameDebounced + savedWindowFrame
    // + windowDidMove/Resize removed — AppKit's setFrameAutosaveName persists
    // the frame to NSUserDefaults automatically on move/resize and restores
    // it on show, with built-in off-screen defense (frame on a since-
    // detached display is pulled back to the main visibleFrame).
}
