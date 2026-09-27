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
    @MainActor private static var escapeMonitor: Any?
    @MainActor private static var scrollWheelMonitor: Any?
    @MainActor private static var leftMouseUpMonitor: Any?
    // Timestamp of the most recent scrollWheel event received by the
    // app, used to filter trackpad two-finger-scroll synthesized
    // leftMouseUp events (USER-FEEDBACK-2026-09-26 follow-up).
    // 200ms is generous — trackpad scroll-then-fling can synthesize
    // a tap within ~100ms of the last scroll; 200ms gives margin
    // while still accepting a slow deliberate release.
    @MainActor private static var lastScrollWheelAt: Date = .distantPast
    static let scrollSynthesizedThreshold: TimeInterval = 0.2
    // ID-VIEW-0047 (2026-09-27): DI hooks for the 3 monitors so tests
    // can verify install/remove pairing without a real NSEvent system.
    // When `installer` is nil, install creates the real monitor via
    // NSEvent.addLocalMonitorForEvents; when non-nil, the closure is
    // called instead and its value is stored as the monitor token. The
    // same applies to `uninstaller` for `removeMonitor`. This avoids
    // creating real NSEvent monitors in unit tests (which the
    // previous commit's GREEN signal had 0% coverage on).
    @MainActor static var keyDownInstaller: (() -> Any?)?
    @MainActor static var keyDownUninstaller: ((Any) -> Void)?
    @MainActor static var scrollWheelInstaller: (() -> Any?)?
    @MainActor static var scrollWheelUninstaller: ((Any) -> Void)?
    @MainActor static var leftMouseUpInstaller: (() -> Any?)?
    @MainActor static var leftMouseUpUninstaller: ((Any) -> Void)?

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

    /// Install the three dismissal monitors (Escape, scrollWheel,
    /// leftMouseUp with timestamp gating). Extracted from `show()`
    /// so the parent stays under the function_body_length warning.
    @MainActor
    private static func installDismissalMonitors() {
        // global — global only sees events to OTHER apps, the
        // release here is to our own panel) while shown so the
        // release dismisses the preview from anywhere on screen.
        // ID-VIEW-0047 follow-up: no leftMouseUp monitor. Earlier attempt
        // installed one but trackpad two-finger-scroll and Tap-to-Click
        // gestures synthesize .leftMouseUp alongside .scrollWheel, which
        // made the preview disappear mid-scroll. NSPressGestureRecognizer
        // tracks the press across views — started on the list's image
        // NSView, stays in .changed state while the mouse is over the
        // panel — so the natural .ended event dismisses via
        // ClipboardItemRow.onChange(of: imageLongPressing).
        //
        // Fallback: install a local keyDown monitor for Escape (keyCode
        // 53). If the gesture recognizer fails to deliver .ended (focus
        // loss, system gesture hijack, accessibility event), the user
        // still has a way to dismiss. Stays installed for the lifetime
        // of the panel, removed in hideUnlocked.
        // ID-VIEW-0047: use injected installers when set (testing),
        // otherwise create the real NSEvent local monitors.
        let keyHandler: (NSEvent) -> NSEvent? = { event in
            if event.keyCode == 53 { hide(); return nil }
            return event
        }
        escapeMonitor = keyDownInstaller?() ?? NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: keyHandler)

        // USER-FEEDBACK-2026-09-26 (3rd round): install a scrollWheel
        // monitor alongside the leftMouseUp monitor, and use the
        // timestamp delta to suppress dismissal when a synthesized
        // leftMouseUp arrives within ~200ms of a scrollWheel — that's
        // how trackpad two-finger-scroll triggers Tap-to-Click-style
        // synthesized mouseUp that previously dismissed mid-scroll. A
        // real release happens hundreds of ms after the user stops
        // scrolling, so the threshold is well-separated.
        let scrollHandler: (NSEvent) -> NSEvent? = { event in
            Self.lastScrollWheelAt = Date()
            return event
        }
        scrollWheelMonitor = scrollWheelInstaller?() ?? NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: scrollHandler)
        let mouseHandler: (NSEvent) -> NSEvent? = { event in
            let sinceScroll = Date().timeIntervalSince(Self.lastScrollWheelAt)
            if sinceScroll < Self.scrollSynthesizedThreshold {
                return event  // synthesized by trackpad scroll, don't dismiss
            }
            hide()
            return event
        }
        leftMouseUpMonitor = leftMouseUpInstaller?() ?? NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp, handler: mouseHandler)
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
        if let m = scrollWheelMonitor {
            (scrollWheelUninstaller ?? NSEvent.removeMonitor)(m)
            scrollWheelMonitor = nil
        }
        if let m = leftMouseUpMonitor {
            (leftMouseUpUninstaller ?? NSEvent.removeMonitor)(m)
            leftMouseUpMonitor = nil
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
