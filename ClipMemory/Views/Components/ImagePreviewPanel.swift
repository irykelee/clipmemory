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

    /// ID-CRASH-0055 (USER-FEEDBACK-2026-09-26 round 6): forward a
    /// scrollWheel event into the panel's content view so the user
    /// sees the image scroll while holding the long-press. The local
    /// monitor at `LongPressView` swallows the event (returns nil) to
    /// prevent `NSPressGestureRecognizer` from firing `.cancelled` —
    /// without this swallow the panel dismisses (the original bug).
    /// With the swallow alone (0054) the dismissal was fixed but
    /// the image stopped scrolling too. This re-dispatch restores
    /// the visible-scroll behavior while keeping the swallow.
    ///
    /// `contentView` is either `NSImageView` (non-scrollable, ignores)
    /// or `NSScrollView` (scrollable, scrolls). Both accept
    /// `scrollWheel(with:)`; dispatch on main since the panel is
    /// main-actor only.
    @MainActor
    static func dispatchScroll(_ event: NSEvent) {
        guard let panel else { return }
        DispatchQueue.main.async {
            panel.contentView?.scrollWheel(with: event)
        }
    }
    @MainActor private static var escapeMonitor: Any?
    // ID-VIEW-0047 (2026-09-27): DI hook for the Escape monitor so tests
    // can verify install/remove pairing without a real NSEvent system.
    // When `installer` is nil, install creates the real monitor via
    // NSEvent.addLocalMonitorForEvents; when non-nil, the closure is
    // called instead and its value is stored as the monitor token. The
    // same applies to `uninstaller` for `removeMonitor`. ID-CRASH-0050
    // removed the scrollWheel / leftMouseUp monitor install paths
    // (USER-FEEDBACK 2026-09-26 race); this DI seam now only serves
    // the single Escape key.
    @MainActor static var keyDownInstaller: (() -> Any?)?
    @MainActor static var keyDownUninstaller: ((Any) -> Void)?

    @MainActor
    static func show(image: NSImage, screen: NSScreen? = NSScreen.main) {
        panelLock.lock()
        defer { panelLock.unlock() }
        hideUnlocked()

        // ID-VIEW-0048 (2026-09-27, USER-FEEDBACK portrait): `flipped: true`
        // matches `NSScreen.visibleFrame` semantics. Per AppKit,
        // visibleFrame is in screen coordinates with origin at the
        // TOP-LEFT and y-axis pointing DOWN. NSMouseInRect's `flipped`
        // param tells the function which system the rect is in: `false`
        // assumes y-up (Cocoa view default); `true` assumes y-down
        // (Quartz screen default). The previous `false` was wrong for
        // y-down visibleFrame — on a portrait display where the mouse
        // sat near the top, NSMouseInRect returned false for every
        // screen (because the y-axis was flipped), the `.first(where:)`
        // returned nil, and the panel fell through to the
        // `?? screen` branch with `screen = nil`, sizing for the
        // 1440×900 default and positioning at (0, 0) — the bottom-
        // left of the actual portrait display. The user saw the
        // preview appear far from the cursor.
        let mouse = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first(where: {
            NSMouseInRect(mouse, $0.visibleFrame, true)
        }) ?? screen
        let frame = targetScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let layout = layout(imageSize: image.size, screenSize: frame.size)
        let content = makeContent(image: image, layout: layout)
        let panel = makePanel(content: content, layout: layout)
        panel.setFrameOrigin(origin(panelSize: layout.panelSize, mouse: mouse, frame: frame))
        panel.orderFront(nil)
        installDismissalMonitors()

        self.panel = panel
    }

    /// Build the scrollable or non-scrollable view wrapping `imageView`.
    /// Extracted from `show()` to keep the parent under the
    /// swiftlint `function_body_length` warning limit (50).
    @MainActor
    private static func makeContent(image: NSImage, layout: Layout) -> NSView {
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: layout.imageSize))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        if !layout.scrollable {
            imageView.frame = NSRect(origin: .zero, size: layout.panelSize)
            return imageView
        }
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: layout.panelSize))
        scroll.documentView = imageView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    /// Build the borderless floating NSPanel wrapping `content`.
    /// Extracted from `show()` for the same reason as `makeContent`.
    @MainActor
    private static func makePanel(content: NSView, layout: Layout) -> NSPanel {
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
        return panel
    }

    /// Install the single dismissal monitor (Escape). Extracted from
    /// `show()` so the parent stays under the function_body_length warning.
    ///
    /// ID-CRASH-0050 (USER-FEEDBACK 2026-09-26, ID-VIEW-0047 follow-up
    /// — the doc said "no leftMouseUp monitor" but the install path
    /// was never removed; USER-FEEDBACK-2026-09-26 then layered a
    /// scrollWheel timestamp suppression on top, which was racy).
    /// Final fix: **only Escape is installed**. The natural dismissal
    /// path is `NSPressGestureRecognizer.ended` →
    /// `ClipboardItemRow.onChange(of: imageLongPressing)` →
    /// `ImagePreviewPanel.hide()` (ClipboardItemRow.swift:570). The
    /// `mouseUp` monitor was the buggy fallback — trackpad two-finger-scroll
    /// + Tap-to-Click synthesised `leftMouseUp` alongside `scrollWheel`;
    /// the suppression relied on `lastScrollWheelAt` being updated
    /// BEFORE mouseUp arrives (not guaranteed; the 200ms threshold
    /// raced the scroll velocity). Without the mouseUp monitor the
    /// race goes away, and the scrollWheel timestamp infrastructure
    /// becomes dead code. Escape is the only "system gesture hijack /
    /// focus loss" escape hatch (mirrors ID-VIEW-0047 §"Fallback" intent
    /// — the doc got the design right; the code now matches it).
    @MainActor
    private static func installDismissalMonitors() {
        // Escape (keyCode 53) — fallback for the cases where the
        // gesture recognizer fails to deliver .ended (focus loss,
        // accessibility event, system gesture hijack).
        let keyHandler: (NSEvent) -> NSEvent? = { event in
            if event.keyCode == 53 { hide(); return nil }
            return event
        }
        escapeMonitor = keyDownInstaller?() ?? NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: keyHandler)
        Self.panel = panel
    }

    @MainActor
    static func hide() {
        panelLock.lock()
        defer { panelLock.unlock() }
        hideUnlocked()
    }

    @MainActor
    private static func hideUnlocked() {
        if let m = escapeMonitor {
            (keyDownUninstaller ?? NSEvent.removeMonitor)(m)
            escapeMonitor = nil
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
