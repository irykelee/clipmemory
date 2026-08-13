import Foundation

/// Restore mode for the wizard.
///
/// - `merge`: SHIPS in this PR. Adds imported items/tags to current store
///   (deduped by id and contentHash per `ClipboardStore.importBackupItems`).
/// - `replace`: PHASE 2 — `clearAll` then import. Enum case exists for
///   forward compatibility; UI does NOT expose this option in this PR
///   (YAGNI per CLAUDE.md — no `clearAll` implementation).
enum RestoreMode: String, CaseIterable {
    case merge
    case replace
}
