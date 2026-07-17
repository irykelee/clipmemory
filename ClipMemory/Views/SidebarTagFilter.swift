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
///   item must have at least one matching tag id (段内 OR).
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

            // Dimension 2: tag section (段内 OR — empty selection = no filter).
            if !selectedTagIds.isEmpty {
                let hit = selectedTagIds.contains { item.tagIds.contains($0) }
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
