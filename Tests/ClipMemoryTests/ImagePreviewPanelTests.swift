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
        XCTAssertGreaterThan(imageView.frame.width, 0, "ImageView's frame must be non-zero (otherwise documentView collapses and background shows white)")
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
            XCTAssertGreaterThan(iv.frame.width, 0, "even for a 0×0 source image, the imageView frame must be non-zero (otherwise the panel draws white)")
            XCTAssertGreaterThan(iv.frame.height, 0)
        }
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
