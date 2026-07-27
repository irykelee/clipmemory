import SwiftUI
import AppKit

/// A vertical scroll view that always shows its scroll indicator, even
/// when the content fits the visible area. SwiftUI's built-in `ScrollView`
/// (macOS) only shows the indicator as a transient overlay while the user
/// is actively scrolling, which makes it invisible at rest — a user looking
/// for the scrollbar to discover hidden content can't find one.
///
/// This wrapper wraps an `NSScrollView` via `NSViewRepresentable`, sets
/// `hasVerticalScroller = true`, and forces the scroller style to
/// `.legacy` (the always-visible bar). The view fits its content's natural
/// height up to `maxHeight`, then clips and lets NSScrollView handle the
/// overflow with a persistent track + thumb on the right edge.
///
/// Use this in any place where the user needs a visible affordance that
/// content extends past the visible area — most useful in compact detail
/// panes where a hidden ScrollView is worse than a clipped one (because
/// the user can't tell there's more to read).
struct ScrollViewWithVisibleIndicator<Content: View>: NSViewRepresentable {
    let content: () -> Content
    let maxHeight: CGFloat

    init(maxHeight: CGFloat = 140,
         @ViewBuilder content: @escaping () -> Content) {
        self.maxHeight = maxHeight
        self.content = content
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .legacy  // always-visible track + thumb
        scrollView.verticalScrollElasticity = .none

        let documentView = NSHostingView<Content>(rootView: content())
        documentView.translatesAutoresizingMaskIntoConstraints = true
        documentView.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
        scrollView.documentView = documentView

        // Listen for content size changes so we can re-clamp the document
        // view height to the natural intrinsic height (capped by maxHeight).
        context.coordinator.setupObservation(documentView: documentView, scrollView: scrollView, maxHeight: maxHeight)

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // Refresh the document view with the latest SwiftUI content and
        // re-fit its frame.
        if let documentView = nsView.documentView as? NSHostingView<Content> {
            documentView.rootView = content()
            DispatchQueue.main.async {
                Coordinator.fitDocumentView(documentView: documentView, in: nsView, maxHeight: maxHeight)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var observation: NSKeyValueObservation?

        func setupObservation(documentView: NSView, scrollView: NSScrollView, maxHeight: CGFloat) {
            observation = documentView.observe(\.intrinsicContentSize, options: [.initial, .new]) { _, _ in
                DispatchQueue.main.async {
                    Self.fitDocumentView(documentView: documentView, in: scrollView, maxHeight: maxHeight)
                }
            }
        }

        deinit {
            observation?.invalidate()
        }

        /// Fit the document view's frame to its natural intrinsic content
        /// height (clamped to maxHeight) and the scroll view's current
        /// width, then re-position so the document is anchored at top-left.
        static func fitDocumentView(documentView: NSView, in scrollView: NSScrollView, maxHeight: CGFloat) {
            let width = scrollView.contentView.bounds.width
            guard width > 0 else { return }
            let naturalHeight = documentView.intrinsicContentSize.height
            let height = max(0, min(naturalHeight, maxHeight))
            documentView.frame = NSRect(x: 0, y: 0, width: width, height: max(naturalHeight, height))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
}