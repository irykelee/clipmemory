import Foundation

/// P1-AUDIT-2026-09-22 (P2-9): central registry of UserDefaults keys.
///
/// Before this enum, key strings were scattered as raw literals across 9+ files
/// (`ClipboardStore`, `TrashStore`, `BackupService`, `BackupPackage`,
/// `StorageBackend`, `LanguageManager`, `UpdateService`, `FirstLaunchService`,
/// `HotKeyManager`, `SafeModeService`, `StartupHealth`, `ImageStorage`,
/// `FontScaling`). Renaming a key silently orphaned the user's existing data
/// because the new read path hit a missing key and returned the default;
/// collisions between accidentally-matching literals were impossible to detect
/// statically.
///
/// Every case below preserves the historical rawValue byte-for-byte. Existing
/// UserDefaults entries (`~/Library/Preferences/com.clipmemory.app.plist`) keep
/// working — switching `forKey: "maxClipboardItems"` to `forKey:
/// UserDefaultsKey.maxClipboardItems.rawValue` is a transparent rename at the
/// call site, never a data migration.
///
/// Adding a new key:
/// 1. Pick the case name from the existing service pattern (`xxxKey` / `xxx`).
/// 2. Use the historical rawValue verbatim — never invent a new one.
/// 3. Replace all `defaults.X(forKey: "literal")` with
///    `defaults.X(forKey: UserDefaultsKey.X.rawValue)`.
/// 4. If the literal was a derived concatenation (e.g. `"X" + ".y"`), promote
///    it to its own case so it's discoverable via `allCases`.
enum UserDefaultsKey: String, CaseIterable {
    // MARK: - ClipboardStore (items + settings)

    /// Persisted clipboard items JSON blob. Production alias for items.
    /// Clipped-2/P2-9: this key is shared with `StorageBackend.init`'s default
    /// and the backup blobs tuple — centralizing here is the single source.
    case clipboardItems = "ClipboardItems"

    /// Persisted tag dictionary JSON blob. Shared between ClipboardStore and
    /// BackupService's backup manifest.
    case clipboardTags = "ClipMemoryTags"

    /// Persisted recycle-bin items JSON blob. TrashStore is the canonical
    /// owner; BackupService reads it during backup.
    case trashedItems = "ClipboardTrashedItems"

    /// Persistent sentinel that survives across launches (ID-STORE-0013).
    /// Cleared on the next successful `loadTrashedItems()`. Lives alongside
    /// the trash blob key as `<key>.loadFailed`.
    case trashedItemsLoadFailedSentinel = "ClipboardTrashedItems.loadFailed"

    /// Trash retention window (days). Derived from `trashedItems` in legacy
    /// code (`trashedItemsStorageKey + ".retentionDays"`); promoted here so
    /// the concat string isn't reconstructed at every call site.
    case trashedItemsRetentionDays = "ClipboardTrashedItems.retentionDays"

    /// User-configurable max item count. Picker in HistoryCaptureSettingsView;
    /// P2-9 audit found the literal at ClipboardStore.swift:305 + 4 call sites.
    case maxClipboardItems = "maxClipboardItems"

    /// Sensitive-content auto-clear window (hours). ClipboardStore.swift:306.
    case sensitiveClearHours = "sensitiveClearHours"

    /// Whether to capture rich-text pastes. ClipboardStore.swift:307.
    case captureRichText = "captureRichText"

    /// Comma-separated bundle IDs excluded from clipboard monitoring.
    /// ClipboardStore.swift:308.
    case excludedBundleIds = "excludedBundleIds"

    /// Bundle IDs the user has declined to add to the exclusion list
    /// (ID-EXCLUDE-0002). ClipboardStore.swift:309.
    case excludedUpdateDismissedIds = "excludedUpdateDismissedIds"

    // MARK: - OCR (ClipboardStore+OCR)

    /// Whether on-device OCR runs for newly captured images.
    /// ClipboardStore+OCR.swift:7.
    case ocrEnabled = "ocrEnabled"

    /// Whether image search results show OCR text snippet.
    /// ClipboardStore+OCR.swift:9.
    case ocrPreviewEnabled = "ocrPreviewEnabled"

    // MARK: - ImageStorage migration

    /// One-shot migration completion flag for legacy ClipPaste/Images/.
    /// ImageStorage.swift:78.
    case imageStorageMigrationComplete = "ImageStorageMigrationComplete"

    /// Filenames already migrated (resume state for partially-failed runs).
    /// ImageStorage.swift:81.
    case imageStorageMigratedFilenames = "ImageStorageMigratedFilenames"

    /// Filenames permanently ineligible for migration (empty / over size cap).
    /// ImageStorage.swift:87.
    case imageStorageSkippedLegacyFilenames = "ImageStorageSkippedLegacyFilenames"

    /// Test-only flag that gates the first launch's `cleanupOrphanedImages`.
    /// ImageStorage.swift:910 (inline literal in `cleanupOrphanedImagesForTesting`).
    case imageStorageStartupCleanupRan = "ImageStorageStartupCleanupRan"

    // MARK: - BackupService

    /// User toggle: auto-backup enabled.
    case backupEnabled = "backupEnabled"

    /// Number of daily backups to retain (3 / 7 / 14 / 30).
    case backupKeepCount = "backupKeepCount"

    /// Timestamp of the last successful backup. Drives the 24h throttle.
    case lastBackupDate = "lastBackupDate"

    /// Timestamp of the last backup failure (N-3, 2026-07-27). Surfaced as
    /// "Last backup failed: <reason>" in Settings.
    case lastBackupErrorDate = "lastBackupErrorDate"

    /// Error message paired with `lastBackupErrorDate` for the Settings UI.
    case lastBackupErrorMessage = "lastBackupErrorMessage"

    // MARK: - BackupService (2026-08-15, L26 Path E)

    /// Error message paired with `lastPruneErrorDate`.
    case lastPruneErrorMessage = "lastPruneErrorMessage"

    /// Timestamp of the last prune failure (ID-STORE-0016). Distinct from
    /// `lastBackupErrorDate` because prune failures don't block the next
    /// backup; collapsing them would hide the prune signal.
    case lastPruneErrorDate = "lastPruneErrorDate"

    // MARK: - UpdateService (Sparkle fallback feed)

    /// User consent to use the jsDelivr fallback feed (legacy single-Bool).
    /// UpdateService.swift:174. Migrated to `UpdateFeedPolicy` (enum) in v2.5.
    case updateFallbackFeedConsent = "UpdateFallbackFeedConsent"

    /// Timestamp of the last successfully-parsed primary appcast item.
    /// UpdateService.swift:175.
    case lastPrimaryAppcastItemDate = "LastPrimaryAppcastItemDate"

    /// Update-source policy enum (`.automatic` / `.primary` / `.fallback`).
    /// UpdateService.swift:176.
    case updateFeedPolicy = "UpdateFeedPolicy"

    // MARK: - LanguageManager

    /// User-selected app language code (zh-Hans / en / ja / ko / es / pt).
    case appLanguage = "appLanguage"

    /// System `AppleLanguages` chain (prepended with the selected language
    /// instead of replaced). Apple system convention — case-sensitive.
    case appleLanguages = "AppleLanguages"

    // MARK: - FirstLaunch

    /// Has the user completed the welcome flow at least once.
    /// FirstLaunchService.swift:14 / WelcomeView.swift:181 (the canary
    /// whitelist `appLifecycleKeys` references this exact string).
    case hasLaunchedBefore = "hasLaunchedBefore"

    // MARK: - HotKey

    /// Carbon `keyCode` for the global show-window hotkey.
    case hotKeyKeyCode = "HotKeyKeyCode"

    /// Carbon `modifiers` mask for the global show-window hotkey.
    case hotKeyModifiers = "HotKeyModifiers"

    // MARK: - Startup health

    /// Last successful launch timestamp. Drives "previous launch was N seconds
    /// ago" in the startup health log line.
    case lastLaunchTime = "lastLaunchTime"

    // MARK: - SafeMode (ID-CRASH-0003, 2026-08-16)

    /// Consecutive-launch crash counter. Resets on successful launch.
    case safeModeCrashCount = "safeMode.crashCount"

    /// Whether the current launch is in safe mode (sticky until user exits).
    case safeModeActive = "safeMode.active"

    /// Whether the sentinel writer is functional. false after 3 consecutive
    /// write failures; drives the degraded banner.
    case safeModeSentinelHealthy = "safeMode.sentinelHealthy"

    // MARK: - Font

    /// Font scale factor (1.0 / 1.2 / 1.4 by Picker, defensive clamp < 4).
    /// Utils/FontScaling.swift:15.
    case fontScale = "fontScale"
}