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
        // Too big for the screen: keep native resolution and scroll —
        // downscaling a wide screenshot makes its text unreadable again.
        return Layout(panelSize: cap, imageSize: imageSize, scrollable: true)
    }

    private static var panel: NSPanel?

    static func show(image: NSImage, screen: NSScreen? = NSScreen.main) {
        hide()
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
        panel.center()
        panel.orderFront(nil)
        self.panel = panel
    }

    static func hide() {
        panel?.close()
        panel = nil
    }
}
