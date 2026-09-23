//
//  ClipboardStore+History.swift
//  ClipMemory
//
//  P1-AUDIT-2026-09-22 (P2-8, Task 1 split): date-group history extensions
//  extracted from ClipboardStore.swift into a pure extension. Zero logic
//  change — methods are copied verbatim. State (`items`, `pinnedItems`)
//  stays in the main class body because Swift extensions can't have
//  stored properties.
//
//  Scope:
//  - Date-group counts (todayCount / yesterdayCount / olderCount +
//    groupCounts private computed property + GroupCounts private struct)
//  - Date-range unpin (unpinAll / unpinToday / unpinYesterday /
//    unpinOlder + unpinItems private helper)
//  - Date-range clear (clearToday / clearYesterday / clearOlder)
//  - Type × date-range conditional clear (ClearRange enum + isDate
//    helper + clearItems(type:range:))
//
//  Swift access-level caveat: `private` on a class member restricts access
//  to the SAME source file (including extensions in the same file). When
//  the extension moves to a different file, the cross-file access requires
//  loosening `private` → `internal` (default) on the state members. This
//  is a visibility change, not a logic change — call sites and semantics
//  are untouched. Within this extension file, `groupCounts` and
//  `unpinItems(where:)` stay `private` because `todayCount` /
//  `yesterdayCount` / `olderCount` / `unpinToday` / `unpinYesterday` /
//  `unpinOlder` (which call them) are co-located in this same file.
//
//  Deviation from plan: the originating plan brief referenced fictional
//  `searchItems` / `clipboardSearch` / `searchDebounce` / `historyCounts`
//  / `clipboardHistoryCounts` methods. None of those exist in the
//  codebase — search logic lives in ContentView/QuickBarView, not
//  ClipboardStore. This extension covers the only date-related cluster
//  that actually exists in ClipboardStore.swift. A separate
//  `ClipboardStore+Search.swift` is not created.
//
//  Version bump: none (internal refactor; per user spec "version bump =
//  patch — non minor/major"). Ship via rebase-merge to main, do not
//  single-release.

import Foundation

extension ClipboardStore {

    // MARK: - Date-group counts

    /// 各日期分组未读（未固定）项目计数 — computed once per call from a single O(n) filter pass
    var todayCount: Int { groupCounts.today }
    var yesterdayCount: Int { groupCounts.yesterday }
    var olderCount: Int { groupCounts.older }

    private struct GroupCounts {
        var today: Int
        var yesterday: Int
        var older: Int
    }

    private var groupCounts: GroupCounts {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        // CLIP-8 (2026-07-24 review): removed the dead
        // `startOfDayBeforeYesterday` binding — nothing in this function
        // consumed it (the old BUG-016 comment claimed unpinOlder did, but
        // unpinOlder computes its own date at ~L1272).
        guard let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) else {
            return GroupCounts(today: 0, yesterday: 0, older: 0)
        }
        var today = 0, yesterday = 0, older = 0
        for item in items where !item.isPinned {
            if item.createdAt >= startOfToday {
                today += 1
            } else if item.createdAt >= startOfYesterday {
                yesterday += 1
            } else {
                older += 1
            }
        }
        return GroupCounts(today: today, yesterday: yesterday, older: older)
    }

    // MARK: - Date-range unpin

    func unpinAll() {
        for i in items.indices {
            items[i].isPinned = false
        }
        updatePinnedItems()
        scheduleSave()
    }

    func unpinToday() {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? Date()
        unpinItems { $0.createdAt >= startOfToday && $0.createdAt < endOfToday }
    }

    func unpinYesterday() {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        guard let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) else { return }
        unpinItems { $0.createdAt >= startOfYesterday && $0.createdAt < startOfToday }
    }

    func unpinOlder() {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        guard let startOfDayBeforeYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) else { return }
        unpinItems { $0.createdAt < startOfDayBeforeYesterday }
    }

    private func unpinItems(where predicate: (ClipboardItem) -> Bool) {
        for i in items.indices where predicate(items[i]) && items[i].isPinned {
            items[i].isPinned = false
        }
        updatePinnedItems()
        scheduleSave()
    }

    // MARK: - Date-range clear

    /// 清除今日的所有非置顶项目
    func clearToday() {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? Date()
        deleteItems { item in
            !item.isPinned && item.createdAt >= startOfToday && item.createdAt < endOfToday
        }
    }

    /// 清除昨天的所有非置顶项目
    func clearYesterday() {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        guard let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) else { return }
        deleteItems { item in
            !item.isPinned && item.createdAt >= startOfYesterday && item.createdAt < startOfToday
        }
    }

    /// 清除更早（昨天之前）的所有非置顶项目
    func clearOlder() {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        guard let startOfDayBeforeYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) else { return }
        deleteItems { item in
            !item.isPinned && item.createdAt < startOfDayBeforeYesterday
        }
    }

    // MARK: - Conditional clear (type × time range)

    enum ClearRange: CaseIterable {
        case all, today, yesterday, older
    }

    /// Returns whether `date` falls inside the given range, using the same
    /// day boundaries as clearToday/clearYesterday/clearOlder.
    func isDate(_ date: Date, inClearRange range: ClearRange, calendar: Calendar = .current) -> Bool {
        let startOfToday = calendar.startOfDay(for: Date())
        switch range {
        case .all:
            return true
        case .today:
            let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? Date.distantFuture
            return date >= startOfToday && date < endOfToday
        case .yesterday:
            guard let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) else { return false }
            return date >= startOfYesterday && date < startOfToday
        case .older:
            guard let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) else { return false }
            return date < startOfYesterday
        }
    }

    /// Clears items matching an optional type and a time range, skipping
    /// pinned items (same protection rule as the other clear* paths).
    /// Returns the number of items moved to trash.
    @discardableResult
    func clearItems(type: ClipboardItemType?, range: ClearRange) -> Int {
        let targets = items.filter { item in
            !item.isPinned
                && (type == nil || item.type == type)
                && isDate(item.createdAt, inClearRange: range)
        }
        guard !targets.isEmpty else { return 0 }
        moveToTrash(targets)
        return targets.count
    }
}