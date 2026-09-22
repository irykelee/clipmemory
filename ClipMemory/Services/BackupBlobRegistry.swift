import Foundation

/// P1-AUDIT-2026-09-22 (P2-10): centralized registry of backup blob
/// types. Pre-fix: `BackupService.swift` + `BackupPackage.swift` each
/// maintained a private blobs table — adding a new blob type required
/// changes in 2 places (and drifted). Centralized here.
///
/// The actual backup flow serializes 3 blobs (items / tags / trash); the
/// earlier audit brief listed 5 candidate cases (`settings`, `ocrCache`)
/// that aren't part of the current backup contract — not added (would
/// fabricate data the backup pipeline doesn't actually produce).
///
/// Each case carries all the info the call sites need:
/// 1. `filename` — name used inside the backup archive / staging dir.
/// 2. `userDefaultsKey` — `UserDefaults` key whose `data(forKey:)` value
///    gets serialized. Comes from the central `UserDefaultsKey` registry
///    (P2-9), so the UserDefaults key string itself is also centralized.
/// 3. `decodeType` — `any Decodable.Type` used by `BackupPackage` to
///    build the manifest count without string-dispatching on
///    `UserDefaultsKey.rawValue`. P1-AUDIT-2026-09-22 (P2-10) Round-2.
///
/// Adding a new blob type = add one `case` here + the three `switch` arms
/// in the `filename` / `userDefaultsKey` / `decodeType` properties.
/// Iteration is registry-driven; `BackupPackage`'s decode dispatch is
/// also registry-driven (via `BlobKey.decodeType`). Both backup paths
/// (timestamped `BackupService` directory + `.clipmemory` `BackupPackage`
/// zip) iterate `allBlobKeys` and pick up the new blob automatically.
enum BackupBlobRegistry {
    /// All known backup blob types. Adding a new blob type = add one
    /// case here; both backup paths read from this enum.
    enum BlobKey: CaseIterable {
        case items
        case tags
        case trash

        /// Filename used inside the backup archive / staging directory.
        var filename: String {
            switch self {
            case .items: return "items.json"
            case .tags: return "tags.json"
            case .trash: return "trash.json"
            }
        }

        /// UserDefaults key whose `data(forKey:)` value gets serialized.
        /// Sourced from the central `UserDefaultsKey` registry (P2-9) so
        /// this stays the single source of truth end-to-end.
        var userDefaultsKey: String {
            switch self {
            case .items: return UserDefaultsKey.clipboardItems.rawValue
            case .tags: return UserDefaultsKey.clipboardTags.rawValue
            case .trash: return UserDefaultsKey.trashedItems.rawValue
            }
        }

        /// Type to feed `JSONDecoder.decode(_:from:)` when computing the
        /// manifest count for this blob. P1-AUDIT-2026-09-22 (P2-10)
        /// Round-2: replaces the inner `switch key` string-dispatch in
        /// `BackupPackage.exportPackage` — adding a new blob type now
        /// requires only adding the decode arm here, not editing
        /// `BackupPackage`.
        var decodeType: any Decodable.Type {
            switch self {
            case .items: return [ClipboardItem].self
            case .tags: return [Tag].self
            case .trash: return [ClipboardItem].self
            }
        }
    }

    /// Returns the keys a backup must serialize. Used by both
    /// `BackupService.exportBackup` and `BackupPackage.exportPackage`.
    static var allBlobKeys: [BlobKey] {
        BlobKey.allCases
    }
}