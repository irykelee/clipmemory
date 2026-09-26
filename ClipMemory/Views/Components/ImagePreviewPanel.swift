import AppKit

/// Full-size floating preview for image items: long-press to peek, release
/// to dismiss. The old in-row enlarge capped at 300 px height, which left
/// screenshot text unreadable — and did nothing at all for wide shots,
/// whose width (not height) was the binding constraint.
enum ImagePreviewPanel {

    struct Layout {
        let panelSize: NSSize
        let imageSize: NSSize
        let scrollable: Bool
    }

    /// Pure sizing decision, unit-tested. Takes the visible frame
    /// size (not the NSScreen) so tests can drive it with a hardcoded
    /// NSSize. The `show` caller uses `screen.visibleFrame.size` to
    /// keep sizing screen == positioning screen (the frame used in
    /// the `origin` helper below).
    static func layout(imageSize: NSSize, screenSize: NSSize) -> Layout {
        let cap = NSSize(width: floor(screenSize.width * 0.9), height: floor(screenSize.height * 0.9))
        guard imageSize.width > 0, imageSize.height > 0 else {
            return Layout(panelSize: cap, imageSize: imageSize, scrollable: false)
        }
        if imageSize.width <= cap.width && imageSize.height <= cap.height {
            return Layout(panelSize: imageSize, imageSize: imageSize, scrollable: false)
        }
        // DIAG-2026-07-31: hug the image's actual aspect ratio when only
        // one dimension overflows, instead of cramming it into a cap-sized
        // panel with dead space on the other axis.
        if imageSize.height <= cap.height {
            return Layout(panelSize: imageSize, imageSize: imageSize, scrollable: false)
        }
        if imageSize.width <= cap.width {
            return Layout(
                panelSize: NSSize(width: imageSize.width, height: cap.height),
                imageSize: imageSize,
                scrollable: true
            )
        }
        return Layout(panelSize: cap, imageSize: imageSize, scrollable: true)
    }

    /// Pure origin math, unit-testable. Centers the panel on `mouse`
    /// and clamps to `frame` so the scrollbar can't end up off-screen.
    static func origin(panelSize: NSSize, mouse: NSPoint, frame: NSRect) -> NSPoint {
        let raw = NSPoint(
            x: mouse.x - panelSize.width / 2,
            y: mouse.y - panelSize.height / 2
        )
        return NSPoint(
            x: max(frame.minX, min(raw.x, frame.maxX - panelSize.width)),
            y: max(frame.minY, min(raw.y, frame.maxY - panelSize.height))
        )
    }

    @MainActor private static var panel: NSPanel?
    @MainActor private static var mouseUpMonitor: Any?
    // ID-VIEW-0047 (2026-09-26): install/remove are the only operations
    // on `mouseUpMonitor`; exposing them as static methods lets a test
    // verify the install-on-show / remove-on-hide pairing without
    // requiring a real NSEvent system call. The install closure calls
    // `hide()`; a fake monitor's `onInstall` closure can record the
    // call for assertion.
    @MainActor static var mouseUpMonitorInstaller: (@MainActor () -> Any?)?
    @MainActor static var mouseUpMonitorUninstaller: ((Any) -> Void)?
    @MainActor static func installMouseUpMonitor() -> Any? {
        if let installer = mouseUpMonitorInstaller {
            let token = installer()
            return token
        }
        return NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
            hide()
            return event
        }
    }
    @MainActor static func uninstallMouseUpMonitor(_ token: Any) {
        if let uninstaller = mouseUpMonitorUninstaller {
            uninstaller(token)
        } else {
            NSEvent.removeMonitor(token)
        }
    }

    @MainActor
    static func show(image: NSImage, screen: NSScreen? = NSScreen.main) {
        panelLock.lock()
        defer { panelLock.unlock() }
        hideUnlocked()

        // CLIP-5 (2026-07-24): NSPanel.center() always centers on MAIN
        // screen. Pick the screen the cursor is on (or the argument as
        // fallback) and size + position within the SAME screen's visible
        // frame so a multi-display setup doesn't overflow off-screen.
        let mouse = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first(where: {
            NSMouseInRect(mouse, $0.visibleFrame, false)
        }) ?? screen
        let frame = targetScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let layout = layout(imageSize: image.size, screenSize: frame.size)
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: layout.imageSize))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown

        let content: NSView
        if layout.scrollable {
            let scroll = NSScrollView(frame: NSRect(origin: .zero, size: layout.panelSize))
            scroll.documentView = imageView
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true
            scroll.autohidesScrollers = true
            content = scroll
        } else {
            imageView.frame = NSRect(origin: .zero, size: layout.panelSize)
            content = imageView
        }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: layout.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = content
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .windowBackgroundColor
        panel.hasShadow = true
        panel.setFrameOrigin(origin(panelSize: layout.panelSize, mouse: mouse, frame: frame))
        panel.orderFront(nil)

        // USER-FEEDBACK-2026-09-26 follow-up: anchoring to the cursor
        // puts the panel directly over the cursor, so the mouseUp
        // release goes to the panel (which is hit-testable, not
        // .ignoresMouseEvents) — the NSPressGestureRecognizer on
        // ClipboardItemRow never sees the release and the panel
        // stays open. Install a LOCAL leftMouseUp monitor (not
        // global — global only sees events to OTHER apps, the
        // release here is to our own panel) while shown so the
        // release dismisses the preview from anywhere on screen.
        if let existing = mouseUpMonitor {
            uninstallMouseUpMonitor(existing)
        }
        mouseUpMonitor = installMouseUpMonitor()
        self.panel = panel
    }

    @MainActor
    static func hide() {
        panelLock.lock()
        defer { panelLock.unlock() }
        hideUnlocked()
    }

    @MainActor
    private static func hideUnlocked() {
        if let m = mouseUpMonitor {
            uninstallMouseUpMonitor(m)
            mouseUpMonitor = nil
        }
        panel?.close()
        panel = nil
    }

    // Lock guards the panel reference. Now strict @MainActor (added
    // in this commit) means the lock is belt-and-suspenders; kept for
    // defence-in-depth in case a future caller bypasses the actor.
    private static let panelLock = NSLock()

    #if DEBUG
    /// DIAG-2026-07-31: test-only accessor for the active panel. The
    /// production lock is bypassed because tests always run on the main
    /// thread; verifying the panel's view tree is the only way to
    /// reproduce the wide-image long-press bug. Removed once the bug is
    /// closed.
    @MainActor static var testPanel: NSPanel? { panel }
    #endif
}