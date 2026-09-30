import XCTest
import AppKit
@testable import ClipMemory

/// Image preview sizing: native size when it fits, native + scroll when the
/// screen can't hold it — never downscale a big screenshot into unreadable
/// text (the old 300 px in-row cap complaint).
final class ImagePreviewPanelTests: XCTestCase {

    private let screen = NSSize(width: 1512, height: 982) // 14" MBP visible frame

    func testSmallImageShowsAtNativeSizeNoScroll() {
        let layout = ImagePreviewPanel.layout(imageSize: NSSize(width: 800, height: 600), screenSize: screen)
        XCTAssertEqual(layout.panelSize, NSSize(width: 800, height: 600))
        XCTAssertEqual(layout.imageSize, NSSize(width: 800, height: 600))
        XCTAssertFalse(layout.scrollable)
    }

    func testImageExactlyAtCapIsNotScrollable() {
        let cap = NSSize(width: floor(screen.width * 0.9), height: floor(screen.height * 0.9))
        let layout = ImagePreviewPanel.layout(imageSize: cap, screenSize: screen)
        XCTAssertFalse(layout.scrollable)
        XCTAssertEqual(layout.panelSize, cap)
    }

    func testWideScreenshotKeepsNativeSizeAndScrolls() {
        // A dual-monitor wide shot: downscaling to the row width is exactly
        // the "看不清" case — must stay native and scroll instead.
        let wide = NSSize(width: 5120, height: 1440)
        let layout = ImagePreviewPanel.layout(imageSize: wide, screenSize: screen)
        XCTAssertTrue(layout.scrollable)
        XCTAssertEqual(layout.imageSize, wide, "image keeps native resolution inside the scroll view")
        XCTAssertEqual(layout.panelSize.width, floor(screen.width * 0.9))
        XCTAssertEqual(layout.panelSize.height, floor(screen.height * 0.9))
    }

    func testTallScreenshotScrollsVertically() {
        let tall = NSSize(width: 1200, height: 4000)
        let layout = ImagePreviewPanel.layout(imageSize: tall, screenSize: screen)
        XCTAssertTrue(layout.scrollable)
        XCTAssertEqual(layout.imageSize, tall)
    }

    func testZeroSizeImageDoesNotProduceZeroPanel() {
        let layout = ImagePreviewPanel.layout(imageSize: .zero, screenSize: screen)
        XCTAssertFalse(layout.scrollable)
        XCTAssertGreaterThan(layout.panelSize.width, 0)
        XCTAssertGreaterThan(layout.panelSize.height, 0)
    }

    /// DIAG-2026-07-31: user-reported bug. A wide-but-short image
    /// (1313×226, the typical 16:9 landscape screenshot) on a
    /// portrait-rotated main display (1216×2277 cap) used to fall into
    /// the scrollable branch and produce a 1216×2277 panel with a
    /// 1313×226 imageView crammed into a 226-px-tall top strip and
    /// ~2050 px of white below. The fix: if the image fits the cap
    /// height, size the panel to the image — no dead space.
    func testWideShortImageOnPortraitScreenFitsImageSize() {
        // portrait screen: 1344 wide × 2528 tall visible (rotated)
        let portraitScreen = NSSize(width: 1344, height: 2528)
        let wideShort = NSSize(width: 1313.3, height: 225.7)
        let layout = ImagePreviewPanel.layout(imageSize: wideShort, screenSize: portraitScreen)
        XCTAssertFalse(layout.scrollable, "wide-short image that fits cap.height must NOT scroll")
        XCTAssertEqual(layout.panelSize, wideShort, "panel must match the image size so no white strip appears")
        XCTAssertEqual(layout.imageSize, wideShort)
    }

    /// User-reported bug (2026-07-31): a window screenshot whose height
    /// fills the screen (e.g. a near-fullscreen app window, 700×958 on a
    /// 1512×982 display) falls into the scrollable branch and gets a
    /// cap-sized panel (1360×883) while the imageView is only 700 wide —
    /// the ~660 px to the right of the document renders as blank panel
    /// background. The panel must hug the image width and only scroll
    /// vertically.
    func testFullHeightWindowScreenshotPanelHugsImageWidth() {
        let fullHeight = NSSize(width: 700, height: 958) // height ≈ visible frame height
        let layout = ImagePreviewPanel.layout(imageSize: fullHeight, screenSize: screen)
        XCTAssertTrue(layout.scrollable, "taller than 90% of screen: must scroll vertically")
        XCTAssertEqual(layout.imageSize, fullHeight, "image keeps native resolution")
        XCTAssertEqual(layout.panelSize.width, fullHeight.width,
                       "panel must not be wider than the image — dead space renders as blank on the right")
        XCTAssertEqual(layout.panelSize.height, floor(screen.height * 0.9),
                       "panel height is capped at 90% of the screen")
    }

    // MARK: - DIAG-2026-07-31: wide-image long-press produces a white screen

    /// Render a wide screenshot (6020×2400, iPhone 6K landscape capture)
    /// and inspect the view tree that `show(image:)` builds. The
    /// `scrollable` branch must wrap a non-empty NSImageView (so the
    /// scroll view draws real pixels, not windowBackgroundColor white).
    /// This is the reproduction of the user-reported "long-press on wide
    /// image shows white screen" bug.
    @MainActor
    func testWideImageShowProducesNonEmptyContentView() {
        defer { ImagePreviewPanel.hide() }
        let wide = makeImage(width: 6020, height: 2400, color: .red)
        ImagePreviewPanel.show(image: wide, screen: nil)
        // After show(), the panel should be non-nil and have a content view.
        let panel = ImagePreviewPanel.testPanel
        XCTAssertNotNil(panel, "show() must create a panel")
        guard let panel = panel else { return }
        let content = panel.contentView
        XCTAssertNotNil(content, "panel must have a content view")
        // The content view is an NSScrollView (scrollable branch) — find
        // the NSImageView inside it and verify it has a non-zero frame
        // AND a non-nil image.
        guard let scroll = content as? NSScrollView else {
            XCTFail("Expected content view to be NSScrollView for a wide image, got \(String(describing: type(of: content)))")
            return
        }
        guard let imageView = scroll.documentView as? NSImageView else {
            XCTFail("NSScrollView documentView must be NSImageView, got \(String(describing: type(of: scroll.documentView)))")
            return
        }
        XCTAssertGreaterThan(imageView.frame.width, 0,
                           "ImageView's frame must be non-zero (otherwise documentView collapses and background shows white)")
        XCTAssertGreaterThan(imageView.frame.height, 0)
        XCTAssertNotNil(imageView.image, "ImageView must have the source image set")
        XCTAssertEqual(imageView.image?.size, wide.size, "ImageView's image must be the wide source image, not a placeholder")
    }

    /// Same setup but for a wide image whose NSImage has size 0×0 (the
    /// case I'm hedging against — NSImage(data:) for some HEIC variants
    /// returns 0×0 until first draw). The fallback must NOT produce a
    /// zero-sized imageView.
    @MainActor
    func testZeroSizeImageShowProducesNonEmptyContentView() {
        defer { ImagePreviewPanel.hide() }
        // NSImage(size: .zero) is a valid 0×0 NSImage — simulates the
        // NSImage(data:) lazy-decode case.
        let zeroImage = NSImage(size: NSSize(width: 0, height: 0))
        ImagePreviewPanel.show(image: zeroImage, screen: nil)
        let panel = ImagePreviewPanel.testPanel
        XCTAssertNotNil(panel)
        guard let panel = panel else { return }
        // Either path — the panel must NOT show a zero-sized imageView
        // (which would draw nothing over the white panel background).
        func findImageView(_ view: NSView) -> NSImageView? {
            if let iv = view as? NSImageView { return iv }
            for sub in view.subviews {
                if let found = findImageView(sub) { return found }
            }
            return nil
        }
        if let cv = panel.contentView, let iv = findImageView(cv) {
            XCTAssertGreaterThan(iv.frame.width, 0,
                           "even for a 0×0 source image, the imageView frame must be non-zero (otherwise the panel draws white)")
            XCTAssertGreaterThan(iv.frame.height, 0)
        }
    }

    // MARK: - Monitor lifecycle (ID-VIEW-0047 follow-up coverage)

    /// ID-CRASH-0050 (replaces ID-VIEW-0047): verify show() installs the
    /// single Escape monitor via DI. The previous `testShowInstallsAllThreeMonitors`
    /// asserted 3 monitors (Escape + scrollWheel + leftMouseUp) — but the
    /// scrollWheel + leftMouseUp monitors were the USER-FEEDBACK-2026-09-26
    /// racy suppression fix for synthesized mouseUp events. ID-CRASH-0050
    /// removed both monitors (race-prone; the natural
    /// `NSPressGestureRecognizer.ended` path + `Escape` fallback are the
    /// final design per ID-VIEW-0047). Without DI, the install branch
    /// would be trusted but unverified — exactly the failure mode that
    /// caused the original bug. This test pins the Escape install pairing.
    @MainActor
    func testShowInstallsEscapeMonitor() throws {
        // Backup and restore the DI hook.
        let saved = (
            ImagePreviewPanel.keyDownInstaller, ImagePreviewPanel.keyDownUninstaller
        )
        defer {
            (ImagePreviewPanel.keyDownInstaller, ImagePreviewPanel.keyDownUninstaller) = saved
        }

        nonisolated(unsafe) var installs = 0
        nonisolated(unsafe) var uninstalls = 0
        let fakeToken = "fake" as NSString
        let inc: () -> Any? = { installs += 1; return fakeToken }
        let dec: (Any) -> Void = { _ in uninstalls += 1 }
        ImagePreviewPanel.keyDownInstaller = inc
        ImagePreviewPanel.keyDownUninstaller = dec

        let tiny = makeImage(width: 16, height: 16, color: .red)
        ImagePreviewPanel.show(image: tiny, screen: nil)
        XCTAssertEqual(installs, 1, "show() must install exactly the Escape monitor (scrollWheel + leftMouseUp removed by ID-CRASH-0050)")
        // Hide to clean up before assertion
        ImagePreviewPanel.hide()
        XCTAssertEqual(uninstalls, 1, "hide() must uninstall exactly the Escape monitor")
    }

    /// ID-VIEW-0048 (2026-09-27): USER-FEEDBACK on portrait display —
    /// `NSMouseInRect` was called with `flipped: false`, which assumes
    /// the rect is in y-up (Cocoa view) coordinates. NSScreen.visibleFrame
    /// is in y-down (Quartz screen) coordinates; the y-axis mismatch
    /// caused NSMouseInRect to return false for the portrait display
    /// where the mouse sat, so the fallback path sized for the
    /// 1440×900 default and positioned the preview at (0, 0) — the
    /// bottom-left of the actual portrait display. The user saw the
    /// preview far from the cursor.
    ///
    /// This test pins the helper's input vs output for a portrait
    /// geometry so a regression is caught. The fix (flipped: true)
    /// means the screen detection in `show()` accepts the mouse
    /// position; the helper's own math is unchanged.
    func testPortraitDisplayOriginStaysCenteredOnCursor() {
        // Portrait display: 1080 wide × 1920 tall, origin top-left
        // (Quartz/screen coordinates). User's mouse near the top of
        // the display — e.g. mid-Touch Bar area.
        let frame = NSRect(x: 0, y: 0, width: 1080, height: 1920)
        let mouse = NSPoint(x: 540, y: 1700)
        let panel = NSSize(width: 400, height: 300)
        let result = ImagePreviewPanel.origin(panelSize: panel, mouse: mouse, frame: frame)
        // Panel center on mouse (540, 1700). Center is at the top
        // third of the display in y-down coords.
        XCTAssertEqual(result.x, 340, accuracy: 1, "panel.x centers on mouse.x on portrait")
        // In y-down coords, larger y = higher on screen. Center
        // 1700 - 150 = 1550. The panel's top edge (1550 + 150) at
        // y=1700 sits just below the menubar (y<1920); the bottom
        // edge at y=1400 is well within the visible frame.
        XCTAssertEqual(result.y, 1550, accuracy: 1, "panel.y centers on mouse.y on portrait (y-down coords)")
    }

    // MARK: - Origin math (cursor-anchored panel placement)

    /// ID-VIEW-0047 (2026-09-26): pure helper for cursor-anchored
    /// origin. The previous `panel.center()`-only path meant a
    /// large-image preview's scrollbar was unreachable because the
    /// panel sat far from the user's mouse cursor; macOS routes
    /// wheel events to the window under the cursor. The fix
    /// anchors the panel to the cursor with a clamp so the
    /// scrollbar can't be off-screen.
    func testOriginCentersPanelOnCursor() {
        let frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let mouse = NSPoint(x: 500, y: 500)
        let result = ImagePreviewPanel.origin(panelSize: NSSize(width: 200, height: 100), mouse: mouse, frame: frame)
        XCTAssertEqual(result.x, 400, accuracy: 0.5, "panel.x = mouse.x - panel.width/2")
        XCTAssertEqual(result.y, 450, accuracy: 0.5, "panel.y = mouse.y - panel.height/2")
    }

    /// ID-VIEW-0047: when the panel is bigger than the visible frame
    /// (e.g. on a small screen with a giant image), the origin math
    /// must clamp to the frame's minX/minY, not produce a negative
    /// origin that puts the scrollbar off-screen — which was
    /// exactly the "scrollbar unreachable" bug the user reported.
    func testOriginClampsToFrameWhenPanelExceedsFrame() {
        let frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        let mouse = NSPoint(x: 250, y: 200)
        let result = ImagePreviewPanel.origin(panelSize: NSSize(width: 800, height: 600), mouse: mouse, frame: frame)
        XCTAssertEqual(result.x, 0, "panel clamped to frame.minX")
        XCTAssertEqual(result.y, 0, "panel clamped to frame.minY")
    }

    /// ID-VIEW-0047: sizing screen must == positioning screen
    /// (same call to `origin(panelSize:mouse:frame:)` with the same
    /// `frame` for both layout sizing and origin clamping). Otherwise
    /// the panel could be sized against one screen and clamped to
    /// another, producing an off-screen position.
    func testOriginClampHonorsSameScreenUsedForSizing() {
        // Two adjacent screens: primary (1366x768) + secondary (1920x1080)
        // aligned right-of-left. Frame for layout == frame for clamp.
        let primary = NSRect(x: 0, y: 0, width: 1366, height: 768)
        let mouse = NSPoint(x: 800, y: 600)  // within primary
        let result = ImagePreviewPanel.origin(panelSize: NSSize(width: 400, height: 300), mouse: mouse, frame: primary)
        // Panel would be centered at (600, 450); clamp to primary's frame.
        XCTAssertGreaterThanOrEqual(result.x, primary.minX)
        XCTAssertLessThanOrEqual(result.x, primary.maxX - 400)
        XCTAssertGreaterThanOrEqual(result.y, primary.minY)
        XCTAssertLessThanOrEqual(result.y, primary.maxY - 300)
    }

    // MARK: - dispatchScroll (ID-CRASH-0056 follow-up)

    /// ID-CRASH-0056 (USER-FEEDBACK-2026-09-26 round 7): verify that
    /// `dispatchScroll` actually scrolls the document inside the
    /// NSScrollView when called with a scrollWheel event. Previously
    /// the scrollView frame was `.zero` (created with `frame: .zero`
    /// then only the panel was repositioned via `setFrameOrigin`), so
    /// `NSScrollView.scroll(_:)` was a no-op internally. The fix:
    /// set content.frame = panelSize in makePanel AND use direct
    /// `clipView.bounds.origin.y = clampedY` in dispatchScroll
    /// (scroll(_:) and scrollToVisible were both no-ops in NSPanel).
    @MainActor
    func testDispatchScrollActuallyMovesDocument() {
        defer { ImagePreviewPanel.hide() }
        // Image is 800×4000 — definitely taller than any reasonable screen
        // cap, so this will always be in the scrollable branch.
        let tall = makeImage(width: 800, height: 4000, color: .blue)
        ImagePreviewPanel.show(image: tall, screen: nil)
        let panel = ImagePreviewPanel.testPanel
        XCTAssertNotNil(panel)
        guard let panel = panel else { return }
        guard let scrollView = panel.contentView as? NSScrollView else {
            XCTFail("Expected NSScrollView for tall image, got \(String(describing: panel.contentView))")
            return
        }
        guard let documentView = scrollView.documentView else {
            XCTFail("scrollView.documentView is nil")
            return
        }

        // Document view should be full image size (native resolution)
        XCTAssertEqual(documentView.bounds.width, 800, accuracy: 1)
        XCTAssertEqual(documentView.bounds.height, 4000, accuracy: 1)

        // Initial offset should be 0 (top of document)
        let initialOffset = scrollView.documentVisibleRect.origin
        XCTAssertEqual(initialOffset.y, 0, accuracy: 0.5)

        // Send scrollWheel: wheelDeltaY=100 means scroll up → content down
        let scrollEvent = makeScrollWheelEvent(wheelDeltaY: 100)
        ImagePreviewPanel.dispatchScroll(scrollEvent)
        let afterOffset = scrollView.documentVisibleRect.origin
        XCTAssertGreaterThan(afterOffset.y, initialOffset.y,
                             "visible rect origin.y must increase after scrolling down")
        XCTAssertTrue(scrollView.hasVerticalScroller, "scrollView must have a vertical scroller")
    }

    /// Non-scrollable small image — contentView is plain NSImageView,
    /// dispatchScroll guard fails silently (no crash, no effect).
    @MainActor
    func testDispatchScrollOnNonScrollablePanelIsNoOp() {
        defer { ImagePreviewPanel.hide() }
        let small = makeImage(width: 100, height: 100, color: .green)
        ImagePreviewPanel.show(image: small, screen: nil)
        let panel = ImagePreviewPanel.testPanel
        XCTAssertNotNil(panel)
        guard let panel = panel else { return }
        XCTAssertFalse(panel.contentView is NSScrollView,
                       "small image should use plain NSImageView, not NSScrollView")
        let scrollEvent = makeScrollWheelEvent(wheelDeltaY: 100)
        ImagePreviewPanel.dispatchScroll(scrollEvent)  // must not throw
    }

    private func makeScrollWheelEvent(wheelDeltaY: Int32) -> NSEvent {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: Int32(wheelDeltaY), wheel2: 0, wheel3: 0)!
        return NSEvent(cgEvent: event)!
    }

    // MARK: - Test helpers

    private func makeImage(width: Int, height: Int, color: NSColor) -> NSImage {
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }
}
