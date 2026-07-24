import SwiftUI

/// Renders up to `maxChipsVisible` chips for an item's attached tag ids,
/// defensively dropping any orphan UUIDs (tag id without a matching
/// `ClipboardStore.tags` entry — possible if a tag was deleted out-of-band).
///
/// Uses the project's existing `FlowLayout` so chips wrap naturally inside
/// the row. Caps at 4 to keep list row height stable; full list is always
/// available via the tag picker sheet.
struct TagChipStack: View {
    let tagIds: Set<UUID>
    let store: ClipboardStore

    /// Pinned to 4 so the list row stays a single visual line in most cases.
    /// Changing this number changes visible density — covered by a unit test.
    static let maxChipsVisible = 4

    /// Pure helper exposed for testing. Drops orphans and sorts by tag name
    /// so the visible chips are deterministic across launches and rows.
    static func visibleTags(from tagIds: Set<UUID>, store: ClipboardStore) -> [Tag] {
        tagIds
            .compactMap { store.tags[$0] }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .prefix(maxChipsVisible)
            .map { $0 }
    }

    // M-15 (2026-07-24 audit): cache the computed chips so the
    // compactMap + sorted + prefix chain doesn't re-run on every nested
    // state change in the parent row (hover, isCopied, isSelected,
    // selection changes inside Section headers, etc). The cache key
    // fingerprints tagIds + the resolved tag names, so a rename also
    // invalidates correctly.
    @State private var cachedChips: [Tag] = []

    private var cacheKey: Int {
        var h = Hasher()
        h.combine(tagIds)
        // Sorted-by-uuidString gives a stable order for the hash so the
        // same set always produces the same fingerprint.
        for id in tagIds.sorted(by: { $0.uuidString < $1.uuidString }) {
            h.combine(store.tags[id]?.name ?? "")
        }
        return h.finalize()
    }

    var body: some View {
        Group {
            if cachedChips.isEmpty {
                EmptyView()
            } else {
                FlowLayout(spacing: 4) {
                    ForEach(cachedChips, id: \.id) { tag in
                        TagChip(tag: tag)
                    }
                }
            }
        }
        // Fires on first appearance and whenever the cache key changes,
        // recomputing the chip list exactly once per invalidation.
        .task(id: cacheKey) {
            cachedChips = Self.visibleTags(from: tagIds, store: store)
        }
    }
}
