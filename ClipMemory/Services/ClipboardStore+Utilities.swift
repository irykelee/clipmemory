//
//  ClipboardStore+Utilities.swift
//  ClipMemory
//
//  P1-AUDIT-2026-09-22 (P2-8, Task 2 split): miscellaneous small helpers
//  extracted from ClipboardStore.swift into a pure extension. Zero logic
//  change — methods are copied verbatim.
//
//  Methods moved verbatim:
//   - quarantineCorruptBlob(key:error:)
//   - parseExcludedBundleIds() -> Set<String>
//   - static let iso8601Formatter (the only static let on the extension,
//     supported because Swift extensions CAN declare static stored
//     properties — only instance stored properties are forbidden).
//
//  State stays in the main class body where the methods are referenced by
//  loadItems (also still in main file) — loadTags (now in
//  ClipboardStore+Tag.swift) calls this through the same extension bridge.
//
//  `iso8601Formatter` was a private static stored property on the main
//  class; now lives on the extension as an internal static let. Static
//  stored properties in extensions are legal in Swift (only instance
//  stored properties are forbidden by the extension restrictions).
//
//  Swift access-level caveat: `private` on a class member restricts access
//  to the SAME source file (including extensions in the same file). When
//  the extension moves to a different file, the cross-file access requires
//  loosening `private` → `internal` (default) on the state members.
//
//  Version bump: none (internal refactor; per user spec "version bump = patch
//  — non minor/major"). Ship via rebase-merge to main, do not single-release.

import Foundation

extension ClipboardStore {

    /// Quarantine a corrupt UserDefaults blob: copy it under
    /// `<key>.corrupt-<ISO8601-ts>` then remove the original. Without this,
    /// the next `saveItems` / `saveTags` / `saveTrashedItems` would
    /// overwrite the corrupt blob with `[]`, permanently destroying the
    /// user's history. Quarantining lets recovery tooling (or a future
    /// "restore from backup" affordance) attempt repair.
    /// Post-audit-scan fix: previously `loadItems()` / `loadTrashedItems()`
    /// / `loadTags()` silently swallowed the error and continued with an
    /// empty in-memory collection — the very next save wiped the persist
    /// layer permanently.
    func quarantineCorruptBlob(key: String, error: Error) {
        let defaults = UserDefaults.standard
        guard let blob = defaults.data(forKey: key) else { return }
        let timestamp = Self.iso8601Formatter.string(from: Date())
        let quarantineKey = "\(key).corrupt-\(timestamp)"
        defaults.set(blob, forKey: quarantineKey)
        defaults.removeObject(forKey: key)
        logger.error("Corrupt blob \(key) quarantined to \(quarantineKey). First-decoder error: \(error.localizedDescription). The next save will overwrite the original key with the current (empty) in-memory collection; recover from the quarantined copy or a backup before saving.")
    }

    // ID-PERF-0009 (2026-07-30 audit): ISO8601DateFormatter init is ~1 ms
    // (locale + dateFormat + calendar setup). `quarantineCorruptBlob` is
    // called from `loadItems` / `loadTags` error paths. Hoist to a
    // `static let` so all calls share one instance (same pattern as
    // the date-formatter cache in DateHelpers.swift).
    //
    // Swift extensions CAN declare static stored properties (only instance
    // stored properties are forbidden by the extension restrictions), so
    // this `static let` lives here in the Utilities extension rather than
    // back on the main class body.
    static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Parses `excludedBundleIdsString` (comma-separated) into a clean
    /// `Set<String>` of bundle IDs. Whitespace-trimmed, lowercased, and
    /// empty entries filtered out. Called from
    /// `excludedBundleIdsString.didSet` to push the change into the
    /// monitor's exclusion set.
    func parseExcludedBundleIds() -> Set<String> {
        Set(excludedBundleIdsString
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty })
    }
}