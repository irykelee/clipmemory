import Foundation

/// Pure helper backing ContentView's sidebar filter. Handles the two
/// sidebar-driven dimensions — type/pinned and selected tags — so they
/// can be unit-tested without rendering SwiftUI. Date + search filters
/// remain in ContentView's filterItems; this helper only owns the part
/// the sidebar introduces.
///
/// **Semantics**:
/// - `pinnedOnly` (caller passes true for `.pinned` tab) — item must be pinned.
/// - `typeFilter` (caller passes the tab's `typeFilter` for non-`.all` /
///   non-`.pinned` tabs) — item's type must match.
/// - `selectedTagIds` (any UUID set, possibly empty) — if non-empty,
///   item must contain **every** selected tag id (intersection / AND).
/// - All three are AND-combined: type/pinned AND tags.
enum SidebarTagFilter {

    /// Apply sidebar-driven filtering. Items failing any dimension are dropped.
    static func apply(items: [ClipboardItem],
                      typeFilter: ClipboardItemType?,
                      pinnedOnly: Bool,
                      selectedTagIds: Set<UUID>) -> [ClipboardItem] {
        items.filter { item in
            // Dimension 1: type / pinned (callers pick one or neither).
            if pinnedOnly {
                if !item.isPinned { return false }
            } else if let typeFilter {
                if item.type != typeFilter { return false }
            }

            // Dimension 2: tag section (AND — empty selection = no filter).
            // 2026-07-27 (user-requested): changed from OR to AND.
            // Rationale: OR turned "中国大陆" + "2026" into "any tag matches
            // either" — the 2026 tag alone matched every 2026 item worldwide,
            // making the 中国大陆 selection meaningless. AND treats tag
            // selection as an intersection (must carry every selected tag),
            // matching how users actually compose filters in tools like
            // Finder smart folders and Gmail multi-label search.
            if !selectedTagIds.isEmpty {
                // ID-PERF-0010 (2026-07-30 audit): drop `Set(item.tagIds)`
                // wrap. `Set.isSubset(of:)` accepts any `Sequence` whose
                // element matches `Set.Element`; passing `[UUID]` directly
                // skips the per-item Set allocation that was burning ~50K
                // heap allocs on 10K-item × 5-tag histories (every search
                // keystroke + tag click). Comparison cost is O(m·n) per
                // item where m = selectedTagIds.count, n = tagIds.count —
                // small constants in practice (typical n ≤ 5), well below
                // the allocation savings.
                let hit = selectedTagIds.isSubset(of: item.tagIds)
                if !hit { return false }
            }

            return true
        }
    }

    /// Filter items whose `TimeGroup` is not in `collapsedGroups`. Used by
    /// keyboard navigation in ContentView so ↑/↓ walk only what the user
    /// actually sees — without this, the selection index would advance
    /// through hidden rows and the visual highlight would appear to skip.
    ///
    /// Caller passes `today` and `yesterday` (typically the view's cached
    /// startOfToday / startOfYesterday) so the grouping is deterministic
    /// and testable without a live `Date()`.
    static func visibleItems(items: [ClipboardItem],
                             collapsedGroups: Set<TimeGroup>,
                             today: Date,
                             yesterday: Date) -> [ClipboardItem] {
        items.filter { item in
            !collapsedGroups.contains(group(for: item, today: today, yesterday: yesterday))
        }
    }

    /// Map an item to its `TimeGroup` given the same date anchors used by
    /// ContentView.updateDisplayedItemsCache. Extracted so the visible-items
    /// filter and the cache stay in lockstep.
    static func group(for item: ClipboardItem, today: Date, yesterday: Date) -> TimeGroup {
        if item.createdAt >= today { return .today }
        if item.createdAt >= yesterday { return .yesterday }
        return .older
    }
}
