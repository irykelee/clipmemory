import SwiftUI

// MARK: - Flow Layout for wrapping tags
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    // L-18 (2026-07-24 audit): SwiftUI Layout calls `sizeThatFits` and
    // `placeSubviews` in sequence during a single layout pass. Both were
    // independently calling `subview.sizeThatFits(.unspecified)` for every
    // child, so each chip's sizing ran twice per layout pass. Cache the
    // sizes in the Layout's `cache` argument so the second call reuses
    // what the first computed.
    typealias Cache = [CGSize]

    func makeCache(subviews: Subviews) -> Cache { [] }

    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache.removeAll(keepingCapacity: true) }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let sizes = cachedSizes(subviews: subviews, cache: &cache)
        return layoutSize(sizes: sizes, proposal: proposal)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let sizes = cachedSizes(subviews: subviews, cache: &cache)
        var point = CGPoint(x: bounds.minX, y: bounds.minY)
        var lineHeight: CGFloat = 0

        for (index, subview) in subviews.enumerated() {
            let size = sizes[index]
            if point.x + size.width > bounds.maxX && lineHeight > 0 {
                point.x = bounds.minX
                point.y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: point, proposal: .unspecified)
            point.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }

    /// Lazily populate the per-pass size cache so both `sizeThatFits` and
    /// `placeSubviews` share a single `sizeThatFits(.unspecified)` call
    /// per child.
    private func cachedSizes(subviews: Subviews, cache: inout Cache) -> [CGSize] {
        if cache.count == subviews.count { return cache }
        let computed = subviews.map { $0.sizeThatFits(.unspecified) }
        cache = computed
        return computed
    }

    private func layoutSize(sizes: [CGSize], proposal: ProposedViewSize) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var width: CGFloat = 0
        var height: CGFloat = 0
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0

        for size in sizes {
            if lineWidth + size.width > maxWidth && lineWidth > 0 {
                width = max(width, lineWidth - spacing)
                height += lineHeight + spacing
                lineWidth = 0
                lineHeight = 0
            }
            lineWidth += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        width = max(width, lineWidth - spacing)
        height += lineHeight
        return CGSize(width: width, height: height)
    }
}
