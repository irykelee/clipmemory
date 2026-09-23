//
//  ClipboardStore+Tag.swift
//  ClipMemory
//
//  P1-AUDIT-2026-09-22 (P2-8, Task 2 split): tag operations extracted from
//  ClipboardStore.swift into a pure extension. Zero logic change — methods
//  are copied verbatim. State (`tagSaveTimer` / `tagNeedsSave` /
//  `tagSaveTimerQueue` / `tagBackend` / `tagStorageKey` / `tags`) stays in
//  the main class body because Swift extensions can't have stored instance
//  properties.
//
//  Methods moved verbatim:
//   - addTag(_:)
//   - addTag(to:tagId:)
//   - removeTag(from:tagId:)
//   - deleteTag(id:)
//   - deleteTag(id:includeItems:)
//   - tags(matchingPrefix:limit:)
//   - loadTags()
//   - saveTags()
//   - scheduleTagSave() (private)
//   - flushTagSave()
//   - importBackupTags(_:)
//
//  Swift access-level caveat: `private` on a class member restricts access
//  to the SAME source file (including extensions in the same file). When
//  the extension moves to a different file, the cross-file access requires
//  loosening `private` → `internal` (default) on the state members.
//  Each loosening in the main file carries a comment explaining the
//  cross-extension caller.
//
//  Version bump: none (internal refactor; per user spec "version bump = patch
//  — non minor/major"). Ship via rebase-merge to main, do not single-release.

import Foundation

extension ClipboardStore {

    /// Insert or replace a tag by its UUID. Tags with the same id overwrite
    /// (idempotent rename/recolor). Triggers a debounced tag save.
    func addTag(_ tag: Tag) {
        // E-6 (2026-07-23 audit): trim leading/trailing whitespace +
        // newlines from the user-supplied tag name before storing.
        // Without this, a tag named "  Work  " persists as-is and the
        // sidebar / search / suggestions all see it as a distinct tag
        // from "Work". Trimming here is defensive — it protects all
        // callers (NewTagSheet, TagPickerSheet bulk-add, future entry
        // points) without each needing to remember to trim.
        let trimmedName = tag.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName != tag.name {
            tags[tag.id] = Tag(
                id: tag.id,
                name: trimmedName,
                colorHex: tag.colorHex,
                isAutoSuggested: tag.isAutoSuggested,
                createdAt: tag.createdAt
            )
        } else {
            tags[tag.id] = tag
        }
        scheduleTagSave()
    }

    /// Attach an existing tag (by id) to an item. Idempotent — adding the same
    /// tag twice is a no-op since tagIds is a Set. Schedules both item and tag
    /// persistence so the attachment survives app restarts.
    func addTag(to itemId: UUID, tagId: UUID) {
        // ID-PERF-0015 (2026-07-30 audit): use the maintained UUID→index
        // map for O(1) lookup instead of `firstIndex(where:)` (O(n) per
        // call). The map is rebuilt by `rebuildItemIndexIfStale()` (inside
        // `resolvedIndex(for:)`) after every items mutation, so it's
        // correct under the O(1) read. PR54-H (v2.8.4): route through
        // `resolvedIndex(for:)` for the bounds-check guard.
        guard let index = resolvedIndex(for: itemId) else { return }
        items[index].tagIds.insert(tagId)
        scheduleSave()
    }

    /// Detach a tag from an item. Does not delete the tag itself; for that use
    /// deleteTag(id:). Safe to call when the tag isn't attached (no-op).
    func removeTag(from itemId: UUID, tagId: UUID) {
        // ID-PERF-0015 + PR54-H (v2.8.4): see addTag above.
        guard let index = resolvedIndex(for: itemId) else { return }
        items[index].tagIds.remove(tagId)
        scheduleSave()
    }

    /// Delete a tag definition AND strip its id from every item's tagIds set.
    /// This prevents dangling UUIDs (tag references that no longer resolve).
    /// Safe to call with an unknown id — no-op in that case. Triggers a
    /// debounced save for both tags and items.
    func deleteTag(id tagId: UUID) {
        deleteTag(id: tagId, includeItems: false)
    }

    /// When `includeItems` is true, items carrying this tag are first moved to
    /// the recycle bin (recoverable), then the tag definition is deleted and
    /// its id stripped from any remaining items.
    func deleteTag(id tagId: UUID, includeItems: Bool) {
        if includeItems {
            deleteItems { $0.tagIds.contains(tagId) }
        }
        guard tags.removeValue(forKey: tagId) != nil else { return }
        for index in items.indices where items[index].tagIds.contains(tagId) {
            items[index].tagIds.remove(tagId)
        }
        scheduleTagSave()
        scheduleSave()
    }

    /// Case-insensitive prefix search over tag names. Returns up to `limit`
    /// tags ordered by `createdAt` descending (most recent first), so the
    /// caller's autocomplete surfaces the user's own latest tag first.
    /// Empty prefix → empty result (autocomplete is opt-in).
    func tags(matchingPrefix prefix: String, limit: Int = 8) -> [Tag] {
        guard !prefix.isEmpty, limit > 0 else { return [] }
        let needle = prefix.lowercased()
        return tags.values
            .filter { $0.name.lowercased().hasPrefix(needle) }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Tag persistence

    /// Load the tag dictionary from the tag backend. Called once during init.
    /// Corrupted data is logged and treated as empty — better to lose tag defs
    /// than to crash on startup.
    func loadTags() {
        do {
            let loaded = decryptTagNames(try tagBackend.loadTags())
            tags = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        } catch {
            quarantineCorruptBlob(key: Self.tagStorageKey, error: error)
            logger.error("Failed to load tags: \(error.localizedDescription)")
            // 2026-07-24 audit: the previous path was silent beyond an os_log
            // entry — the user saw an empty tag sidebar with no explanation.
            // Surface the failure via .tagBackendCorrupted.
            // 2026-07-24 review: nothing observes this yet — the post is the
            // deliberate hook for a future Settings diagnostics banner /
            // "restore from backup" affordance.
            NotificationCenter.default.post(name: .tagBackendCorrupted, object: nil)
            tags = [:]
        }
    }

    /// Synchronously write the current tag dictionary to the tag backend.
    /// Names are encrypted at the persistence boundary while the in-memory
    /// `tags` dictionary stays plaintext for UI use.
    func saveTags() {
        do {
            try tagBackend.saveTags(encryptTagNames(Array(tags.values)))
        } catch {
            logger.error("Failed to save tags: \(error.localizedDescription)")
        }
    }

    /// Debounced tag save — coalesces rapid mutations (addTag/deleteTag) into
    /// one write, mirroring the existing scheduleSave() pattern for items.
    private func scheduleTagSave() {
        tagNeedsSave = true
        // 2026-07-26 review: lazily create the timer once and reuse it via
        // schedule(deadline:), matching the existing single-serial-queue
        // save-timer pattern in scheduleSave().
        if tagSaveTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: tagSaveTimerQueue)
            timer.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in
                    self?.flushTagSave()
                }
            }
            timer.resume()
            tagSaveTimer = timer
        }
        tagSaveTimer?.schedule(deadline: .now() + saveDebounceInterval)
    }

    // ID-ARCH-0002 PR #1 (2026-08-11): visibility loosened `private` → `internal`
    // so extension's flushPendingSaves() can call it.
    func flushTagSave() {
        guard tagNeedsSave else { return }
        tagNeedsSave = false
        // ID-LIFE-0023 (2026-07-31): no cancel() here — see flushSave().
        // A cancelled source silently ignores later schedule() calls,
        // which used to kill every debounced tag save after the first flush.
        saveTags()
    }

    /// Merges imported backup tags by id (existing ids win). Returns count added.
    @discardableResult
    func importBackupTags(_ newTags: [Tag]) -> Int {
        let existingIds = Set(tags.keys)
        var added = 0
        for tag in newTags where !existingIds.contains(tag.id) {
            tags[tag.id] = tag
            added += 1
        }
        if added > 0 { scheduleTagSave() }
        return added
    }
}