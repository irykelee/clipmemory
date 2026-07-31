import AppKit

/// Full-size floating preview for image items: long-press to peek, release
/// to dismiss. The old in-row enlarge capped at 300 px height, which left
/// screenshot text unreadable — and did nothing at all for wide shots,
/// whose width (not height) was the binding constraint.
///
/// Sizing: native size whenever it fits the screen; when larger than 90%
/// of the screen, keep native size inside a scroll view so text stays
/// crisp instead of downscaling back to unreadable.
enum ImagePreviewPanel {

    struct Layout {
        let panelSize: NSSize
        let imageSize: NSSize
        let scrollable: Bool
    }

    /// Pure sizing decision, unit-tested.
    static func layout(imageSize: NSSize, screenSize: NSSize) -> Layout {
        let cap = NSSize(width: floor(screenSize.width * 0.9), height: floor(screenSize.height * 0.9))
        guard imageSize.width > 0, imageSize.height > 0 else {
            return Layout(panelSize: cap, imageSize: imageSize, scrollable: false)
        }
        if imageSize.width <= cap.width && imageSize.height <= cap.height {
            return Layout(panelSize: imageSize, imageSize: imageSize, scrollable: false)
        }
        // DIAG-2026-07-31: when the image fits in cap.height but is wider
        // than cap.width (typical: a wide landscape screenshot on a
        // portrait-rotated main display, e.g. 1313×226 image on a
        // 1216×2277 cap), the "scrollable" branch used to produce a
        // giant panel of cap size with the image crammed into a tiny
        // top strip and ~2000 px of empty white below. Fit the panel
        // to the image's actual aspect ratio so the user sees a single
        // tightly-cropped strip instead of a sea of whitespace.
        if imageSize.height <= cap.height {
            // The image is shorter than the cap. Don't fill the cap —
            // it would create dead space. Size the panel to the image
            // (centered later by the caller) and keep the imageView at
            // native size. `scrollable: false` because the image fits
            // within the panel; no scrolling needed.
            return Layout(panelSize: imageSize, imageSize: imageSize, scrollable: false)
        }
        // Too big in BOTH dimensions: keep native resolution and scroll —
        // downscaling a wide screenshot makes its text unreadable again.
        return Layout(panelSize: cap, imageSize: imageSize, scrollable: true)
    }

    // L-18 (2026-07-25 audit): `panel` is a static mutable shared across the
    // main thread and any background callers that touch the preview. Guard
    // read/write with a lock so `show()` and `hide()` cannot race and leak or
    // double-close a panel.
    private static var panel: NSPanel?

    #if DEBUG
    /// DIAG-2026-07-31: test-only accessor for the active panel. The
    /// production lock is bypassed because tests always run on the main
    /// thread; verifying the panel's view tree is the only way to
    /// reproduce the wide-image long-press bug. Removed once the bug is
    /// closed.
    static var testPanel: NSPanel? { panel }
    #endif
    private static let panelLock = NSLock()

    static func show(image: NSImage, screen: NSScreen? = NSScreen.main) {
        panelLock.lock()
        defer { panelLock.unlock() }
        hideUnlocked()
        let screenSize = screen?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let layout = layout(imageSize: image.size, screenSize: screenSize)

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
        // CLIP-5 (2026-07-24 review): NSPanel.center() always centers on the
        // MAIN screen, ignoring the `screen` argument used for sizing above.
        // Center manually within the target screen's visibleFrame so the
        // panel lands where the image actually is on multi-display setups.
        if let visibleFrame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: visibleFrame.midX - layout.panelSize.width / 2,
                y: visibleFrame.midY - layout.panelSize.height / 2
            ))
        } else {
            panel.center()
        }
        panel.orderFront(nil)
        self.panel = panel
    }

    static func hide() {
        panelLock.lock()
        defer { panelLock.unlock() }
        hideUnlocked()
    }

    private static func hideUnlocked() {
        panel?.close()
        panel = nil
    }
}
