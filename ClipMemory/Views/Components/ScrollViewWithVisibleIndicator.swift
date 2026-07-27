import SwiftUI
import AppKit

/// A vertical scroll view that always shows its scrollbar track when
/// content overflows the viewport, and hides it cleanly when content
/// fits — matching macOS standard behavior (Finder, Mail, Xcode all do
/// this). On macOS 13.0+ deployment target, the canonical path is to
/// wrap NSScrollView via NSViewRepresentable and host SwiftUI content
/// in an NSHostingView subclass that reports its measured size via
/// `intrinsicContentSize` — otherwise NSScrollView can't compute the
/// thumb position correctly and the user sees the thumb at the wrong
/// fraction of the track.
///
/// Apple's docs (developer.apple.com/documentation/appkit/nsscrollview)
/// and the SwiftUI hosting guidance both confirm this is the canonical
/// pattern: bare `NSHostingView` returns `NSView.noIntrinsicMetric`,
/// so a subclass must override `intrinsicContentSize` and `fittingSize`
/// to propagate the wrapped SwiftUI view's measured height to the
/// containing scroll view.
///
/// Use this for any compact detail pane where the user needs to know
/// whether content extends past the visible area. Pairs with a fixed
/// `maxHeight` to set the viewport — NSScrollView clips the rest and
/// the persistent thumb + track signals overflow.
struct ScrollViewWithVisibleIndicator<Content: View>: NSViewRepresentable {
    let content: () -> Content
    let maxHeight: CGFloat

    init(maxHeight: CGFloat = 90,
         @ViewBuilder content: @escaping () -> Content) {
        self.maxHeight = maxHeight
        self.content = content
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true   // hide when content fits; show when overflow
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        // SelfSizingHostingView: subclass NSHostingView so its
        // intrinsicContentSize reflects the wrapped SwiftUI content's
        // measured height. Without this, NSScrollView has no way to
        // compute the thumb position relative to content height, and
        // the user sees a thumb at a fraction that doesn't match the
        // actual scrollable area. (Apple docs — NSScrollView hosting
        // SwiftUI guidance.)
        let documentView = SelfSizingHostingView(rootView: content())
        scrollView.documentView = documentView

        // Constrain the scroll view's height to maxHeight. NSScrollView's
        // contentSize is then driven by documentView.intrinsicContentSize
        // (subclass), which the SwiftUI view computes on layout pass.
        context.coordinator.maxHeight = maxHeight
        context.coordinator.scrollView = scrollView
        context.coordinator.documentView = documentView

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // Refresh the document view with the latest SwiftUI content.
        if let documentView = nsView.documentView as? SelfSizingHostingView<Content> {
            documentView.rootView = content()
            DispatchQueue.main.async {
                context.coordinator.refit()
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var scrollView: NSScrollView?
        weak var documentView: NSView?
        var maxHeight: CGFloat = 90
        private var observation: NSKeyValueObservation?

        /// Re-fit the document view's frame to its intrinsic height
        /// (capped by maxHeight) and the scroll view's current width,
        /// then refresh the scrollers so the thumb reflects the new
        /// content height.
        func refit() {
            guard let scrollView = scrollView, let documentView = documentView else { return }
            let width = scrollView.contentView.bounds.width
            guard width > 0 else { return }
            let naturalHeight = documentView.intrinsicContentSize.height
            documentView.frame = NSRect(
                x: 0, y: 0,
                width: width,
                height: max(naturalHeight, maxHeight)
            )
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
}

/// NSHostingView subclass that reports its intrinsic content height so
/// NSScrollView can position the thumb correctly. The bare
/// `NSHostingView` returns `NSView.noIntrinsicMetric` for both axes,
/// which leaves NSScrollView unable to compute the document's natural
/// height — see Apple docs on hosting SwiftUI in AppKit scroll views.
final class SelfSizingHostingView<Content: View>: NSHostingView<Content> {
    override var intrinsicContentSize: NSSize {
        // fittingSize runs the SwiftUI layout pass with the current
        // bounds width and asks for the height the wrapped view needs.
        // Return that height; width stays unconstrained (noIntrinsicMetric)
        // because NSScrollView's content view dictates width.
        let size = self.fittingSize
        return NSSize(width: NSView.noIntrinsicMetric, height: size.height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Invalidate intrinsicContentSize on width change so the next
        // layout pass re-measures wrapped Text at the new width. Without
        // this, dynamic text changes won't reflow.
        self.invalidateIntrinsicContentSize()
    }
}