import Foundation
import os.log

/// Local automatic backup of the store's persisted data.
///
/// What gets backed up (everything is already encrypted at rest, so backups
/// stay encrypted too — no key material is ever included):
/// - `ClipboardItems`, `ClipMemoryTags`, `ClipboardTrashedItems` (raw UserDefaults blobs)
/// - `Images/` (encrypted image files)
///
/// Trigger: once per day on app launch (throttled by `lastBackupDate`), plus a
/// manual "Backup Now" from Settings. Old backups are pruned to `backupKeepCount`.
/// All paths are injectable so tests never touch the real Application Support.

/// Failures thrown by `backupNow()`. Created M-2 (2026-07-23) when the
/// signature was promoted from `URL?` to `throws -> URL`. Each case names
/// the failed filesystem step so callers (and tests) can disambiguate
/// without parsing `localizedDescription`.
enum BackupError: LocalizedError {
    case directoryCreationFailed(underlying: Error)
    case writeFailed(filename: String, underlying: Error)
    case imageCopyFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .directoryCreationFailed(let e):
            return "Backup directory creation failed: \(e.localizedDescription)"
        case .writeFailed(let name, let e):
            return "Backup write to \(name) failed: \(e.localizedDescription)"
        case .imageCopyFailed(let e):
            return "Backup image copy failed: \(e.localizedDescription)"
        }
    }
}

final class BackupService {
    static let shared = BackupService()

    private static let enabledKey = "backupEnabled"
    private static let keepCountKey = "backupKeepCount"
    private static let lastBackupDateKey = "lastBackupDate"
    private static let minimumInterval: TimeInterval = 24 * 60 * 60
    /// H-6 (2026-07-24 audit): marker file dropped at the start of every
    /// backup and removed on success. An orphan timestamped dir carrying
    /// `.incomplete` is a half-written backup — the host app crashed or was
    /// killed mid-write — and is unsafe to restore from. `pruneOldBackups()`
    /// removes these unconditionally so the count-based keep logic doesn't
    /// mistake them for valid backups and prune recent good ones to keep
    /// them (the audit's "complete backups got pruned, incomplete kept"
    /// failure scenario).
    static let incompleteMarkerName = ".incomplete"

    /// L-13 (2026-07-24 audit): single source of truth for the backup
    /// directory timestamp format. Used by `performBackupUnlocked` to format
    /// the new dir name and by `isBackupDirName` to recognize its own prior
    /// timestamps. `yyyy-MM-dd_HHmmss.SSS` is 21 chars — bumping to
    /// millisecond precision (BUG-021, 2026-07-21) raised it from 17 chars;
    /// the previous second-precision stamp produced name collisions on rapid
    /// "Backup Now" clicks.
    private static let backupDirTimestampFormat = "yyyy-MM-dd_HHmmss.SSS"

    private let logger = Logger(subsystem: "com.clipmemory.app", category: "BackupService")
    private let fileManager = FileManager.default
    private let defaults: UserDefaults
    private let backupsDirectory: URL
    private let imagesDirectory: URL

    init(backupsDirectory: URL? = nil, imagesDirectory: URL? = nil, defaults: UserDefaults = .standard) {
        let appSupport = AppDirectories.applicationSupport
        self.backupsDirectory = backupsDirectory
            ?? appSupport.appendingPathComponent("ClipMemory/Backups", isDirectory: true)
        self.imagesDirectory = imagesDirectory
            ?? appSupport.appendingPathComponent("ClipMemory/Images", isDirectory: true)
        self.defaults = defaults
    }

    var backupsDirectoryURL: URL { backupsDirectory }

    var isEnabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    var keepCount: Int {
        get {
            let value = defaults.integer(forKey: Self.keepCountKey)
            return [3, 7, 14, 30].contains(value) ? value : 7
        }
        set { defaults.set(newValue, forKey: Self.keepCountKey) }
    }

    var lastBackupDate: Date? {
        defaults.object(forKey: Self.lastBackupDateKey) as? Date
    }

    /// Daily trigger from app launch. Runs on a utility queue; no-op when
    /// disabled or when the last backup is younger than 24h.
    func performBackupIfNeeded() {
        guard isEnabled else { return }
        if let last = lastBackupDate, Date().timeIntervalSince(last) < Self.minimumInterval {
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // M-2 (2026-07-23): backupNow now throws. Auto-backup path is
            // best-effort — log + skip on failure. Real user-visible failures
            // surface from the manual UI button path and the import path
            // (both of which inspect the thrown error directly).
            _ = try? self?.backupNow()
        }
    }

    /// Creates a timestamped backup directory with the three store blobs and a
    /// copy of Images/, then prunes old backups. Returns the new directory.
    /// Throws `BackupError` on any filesystem failure. Callers should either:
    /// - Log + skip (e.g., `performBackupIfNeeded`, the "Backup Now" UI button)
    /// - Abort the calling operation (e.g., the pre-import safety snapshot —
    ///   failing here means we have no rollback point, so the import must NOT
    ///   proceed; see `ContentView.swift` importBackup flow for the contract).
    ///
    /// M-2 (2026-07-23): previously returned `URL?` and silently coerced every
    /// failure to `nil`. `ContentView.importBackup` had no way to detect the
    /// pre-import snapshot failing and proceeded to overwrite user data
    /// anyway. Now the failure is observable at the type level.
    ///
    /// E-2 (2026-07-23 audit): a second concurrent invocation (e.g. a
    /// double-clicked manual "Backup Now" landing in the same window as
    /// the daily auto-backup fired from `performBackupIfNeeded`) used to
    /// race — both calls would race on the timestamped directory creation
    /// and the Images/ copy. Serialize via `backupLock` so the second
    /// caller blocks until the first completes, then runs sequentially
    /// after it (duplicate work but never corruption).
    private let backupLock = NSLock()

    @discardableResult
    func backupNow() throws -> URL {
        backupLock.lock()
        defer { backupLock.unlock() }
        return try performBackupUnlocked()
    }

    /// The actual backup work, factored out so `backupNow()` can wrap it
    /// with the concurrency lock without mixing lock and logic.
    private func performBackupUnlocked() throws -> URL {
        let formatter = DateFormatter()
        // POSIX locale keeps `yyyy` Gregorian regardless of the user's calendar
        // (Buddhist/Japanese eras would otherwise break name-sort = time-sort).
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // BUG-021 (2026-07-21): `yyyy-MM-dd_HHmmss` has second precision —
        // a manual "Backup Now" landing in the same second as the daily
        // auto-backup, or two rapid manual triggers, would produce the
        // same directory name and `copyItem` would fail because the
        // destination already exists. Append `.SSS` for millisecond
        // precision — still human-sortable, still unique within a year.
        // L-13 (2026-07-24 audit): the format literal now lives in
        // `backupDirTimestampFormat` so the formatter and the dir-name
        // recognizer (`isBackupDirName`) share one source of truth.
        formatter.dateFormat = Self.backupDirTimestampFormat
        let destination = backupsDirectory.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)

        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            logger.error("Backup failed (directory): \(error.localizedDescription)")
            throw BackupError.directoryCreationFailed(underlying: error)
        }

        // H-6 (2026-07-24 audit): drop an `.incomplete` marker the moment the
        // dir exists. If the process crashes or is killed before we reach the
        // matching `removeItem` at the bottom of this function, the marker
        // tells `pruneOldBackups` to delete this dir instead of treating it
        // as a valid backup. Best-effort write — failure to mark means the
        // crash-consistency safety net is lost, but doesn't break the backup
        // itself (the existing partial-dir cleanup defer still fires).
        do {
            try Data().write(to: destination.appendingPathComponent(Self.incompleteMarkerName))
        } catch {
            logger.warning("Backup: failed to write .incomplete marker (crash-consistency degraded): \(error.localizedDescription)")
        }

        // 1.2 (2026-07-23 audit): partial-failure cleanup. Once we've
        // created the timestamped dir, any subsequent throw leaves an
        // empty or partial dir on disk. `lastBackupDate` correctly does
        // NOT advance (so the next backup retries), but the orphan dir
        // would accumulate forever — combined with the now-fixed 1.1
        // prune filter bug, this would amplify disk growth.
        //
        // `succeeded` flips to `true` only right before the final `return`
        // — every other path throws and trips the defer's removeItem.
        var succeeded = false
        defer {
            if !succeeded {
                try? fileManager.removeItem(at: destination)
            }
        }

        let blobs: [(String, String)] = [
            ("items.json", "ClipboardItems"),
            ("tags.json", "ClipMemoryTags"),
            ("trash.json", "ClipboardTrashedItems")
        ]
        for (filename, key) in blobs {
            guard let data = defaults.data(forKey: key) else { continue }
            do {
                try data.write(to: destination.appendingPathComponent(filename), options: .atomic)
            } catch {
                logger.error("Backup failed (write \(filename)): \(error.localizedDescription)")
                throw BackupError.writeFailed(filename: filename, underlying: error)
            }
        }

        if fileManager.fileExists(atPath: imagesDirectory.path) {
            let imagesDestination = destination.appendingPathComponent("Images", isDirectory: true)
            do {
                try fileManager.copyItem(at: imagesDirectory, to: imagesDestination)
            } catch {
                logger.error("Backup failed (copy Images): \(error.localizedDescription)")
                throw BackupError.imageCopyFailed(underlying: error)
            }
        }

        // H-6 (2026-07-24 audit): all data has been written successfully —
        // remove the `.incomplete` marker so the dir is treated as a valid
        // backup by future prune calls. Removal happens BEFORE `succeeded`
        // flips so any post-write exception (the only realistic one today is
        // the `pruneOldBackups` log-but-don't-throw path) still leaves the
        // dir in a consistent state: either marked incomplete (defer cleanup
        // will remove it) or marker-free (it stays as a valid backup).
        try? fileManager.removeItem(at: destination.appendingPathComponent(Self.incompleteMarkerName))

        defaults.set(Date(), forKey: Self.lastBackupDateKey)
        pruneOldBackups()
        logger.info("Backup completed at \(destination.path)")
        succeeded = true
        return destination
    }

    /// Keeps the newest `keepCount` timestamped backup directories.
    ///
    /// H-6 (2026-07-24 audit): before the count-based prune, any timestamped
    /// dir carrying the `.incomplete` marker is removed unconditionally.
    /// These are half-written backups left over from a crashed `backupNow()`
    /// call — unusable for restore, so they must not count toward `keepCount`
    /// (otherwise a partial dir is kept while a recent valid backup is
    /// pruned, the audit's failure scenario).
    func pruneOldBackups() {
        // L-12 (2026-07-24 audit): every `try?` here was silently coerced to
        // a no-op return, hiding FS-level errors (permissions, disk gone,
        // sandboxes). Surface them via logger.error so an operator can
        // diagnose "Backups/ grows unboundedly" instead of guessing.
        //
        // Capture `backupsDirectory.path` outside the `do/catch` so the
        // catch closures don't implicitly capture `self.backupsDirectory`.
        // Swift 6 strict concurrency flags the implicit capture in the
        // interpolation even when the property is `let`; hoisting the
        // String sidesteps the diagnostic without a `self.` qualifier.
        let backupsPath = backupsDirectory.path
        let entries: [String]
        do {
            entries = try fileManager.contentsOfDirectory(atPath: backupsPath)
        } catch {
            logger.error("pruneOldBackups: failed to list \(backupsPath): \(error.localizedDescription)")
            return
        }
        // Only prune our own timestamped backup dirs — stray files (.DS_Store,
        // anything the user placed here) are left alone.
        let backupNames = entries.filter(Self.isBackupDirName)
        pruneIncompleteBackups(among: backupNames)
        // Re-read the surviving names after the incomplete sweep so
        // count-based prune uses the right set.
        let surviving: [String]
        do {
            surviving = try fileManager.contentsOfDirectory(atPath: backupsPath)
        } catch {
            logger.error("pruneOldBackups: failed to re-list \(backupsPath) after incomplete sweep: \(error.localizedDescription)")
            return
        }
        let validNames = surviving.filter(Self.isBackupDirName)
        // Timestamped names sort chronologically as plain strings.
        let sorted = validNames.sorted()
        let excess = sorted.count - keepCount
        guard excess > 0 else { return }
        for name in sorted.prefix(excess) {
            do {
                try fileManager.removeItem(at: backupsDirectory.appendingPathComponent(name))
            } catch {
                logger.error("pruneOldBackups: failed to remove \(name): \(error.localizedDescription)")
            }
        }
        logger.info("Pruned \(excess) old backup(s), keeping \(self.keepCount)")
    }

    /// H-6 (2026-07-24 audit): remove every timestamped backup dir whose
    /// directory listing still contains the `.incomplete` marker. Called
    /// from `pruneOldBackups` before the count-based logic runs.
    private func pruneIncompleteBackups(among backupNames: [String]) {
        var removed = 0
        var failures = 0
        for name in backupNames {
            let dir = backupsDirectory.appendingPathComponent(name)
            let markerURL = dir.appendingPathComponent(Self.incompleteMarkerName)
            if fileManager.fileExists(atPath: markerURL.path) {
                do {
                    try fileManager.removeItem(at: dir)
                    removed += 1
                } catch {
                    // L-12 (2026-07-24 audit): previously `try?` here too —
                    // an FS failure on the incomplete sweep left the half-
                    // written dir on disk, the very thing the sweep exists
                    // to clean up. Log + skip, continue with the rest.
                    failures += 1
                    logger.error("pruneIncompleteBackups: failed to remove \(dir.path): \(error.localizedDescription)")
                }
            }
        }
        if removed > 0 {
            logger.info("H-6: pruned \(removed) incomplete backup(s) (crash leftovers)")
        }
        if failures > 0 {
            logger.error("H-6: \(failures) incomplete backup(s) could not be removed")
        }
    }

    /// Matches the `yyyy-MM-dd_HHmmss.SSS` backup directory format (21 chars).
    /// The length MUST match the live `dateFormat` in `backupNow()` — when
    /// BUG-021 (2026-07-21) promoted the stamp from second precision (17 chars)
    /// to millisecond precision (21 chars), this filter was overlooked, so
    /// `pruneOldBackups` matched 0 production dirs and the `Backups/` tree
    /// grew unboundedly. Cross-check the two sites together when changing
    /// either.
    ///
    /// L-13 (2026-07-24 audit): both the format literal and the char-position
    /// validation now derive from `backupDirTimestampFormat`; the length `21`
    /// is still a magic literal here because `Character.count` matches the
    /// visible char count of the format string — keep both in sync if either
    /// changes.
    private static func isBackupDirName(_ name: String) -> Bool {
        let chars = Array(name)
        guard chars.count == 21 else { return false }
        for (index, char) in chars.enumerated() {
            switch index {
            case 4, 7: guard char == "-" else { return false }
            case 10: guard char == "_" else { return false }
            case 17: guard char == "." else { return false }
            default: guard char.isNumber else { return false }
            }
        }
        return true
    }
}
