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
    case markerRemovalFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .directoryCreationFailed(let e):
            return "Backup directory creation failed: \(e.localizedDescription)"
        case .writeFailed(let name, let e):
            return "Backup write to \(name) failed: \(e.localizedDescription)"
        case .imageCopyFailed(let e):
            return "Backup image copy failed: \(e.localizedDescription)"
        case .markerRemovalFailed(let e):
            return "Backup .incomplete marker removal failed: \(e.localizedDescription)"
        }
    }
}

final class BackupService {
    static let shared = BackupService()

    private static let enabledKey = "backupEnabled"
    private static let keepCountKey = "backupKeepCount"
    private static let lastBackupDateKey = "lastBackupDate"
    // N-3 (2026-07-27): pair with `lastBackupDateKey` to surface failures
    // from the auto-backup path. `performBackupIfNeeded` used to swallow
    // every `BackupError` via `try?` — users had no signal that the daily
    // backup had stopped succeeding (disk full, permissions revoked, Keychain
    // locked). The settings page now shows "Last backup failed: <reason>"
    // when the most recent failure is newer than the most recent success.
    private static let lastBackupErrorDateKey = "lastBackupErrorDate"
    private static let lastBackupErrorMessageKey = "lastBackupErrorMessage"
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

    /// L-9 (2026-07-25 audit): DateFormatter creation is ~1–2 ms. Backup runs
    /// are serialized by `backupLock`, so a static formatter is safe and avoids
    /// allocating one per backup / prune operation.
    private static let backupFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = backupDirTimestampFormat
        return formatter
    }()

    private let logger = Logger(subsystem: "com.clipmemory.app", category: "BackupService")
    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let backupsDirectory: URL
    private let imagesDirectory: URL

    init(backupsDirectory: URL? = nil, imagesDirectory: URL? = nil, defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        let appSupport = AppDirectories.applicationSupport
        self.backupsDirectory = backupsDirectory
            ?? appSupport.appendingPathComponent("ClipMemory/Backups", isDirectory: true)
        self.imagesDirectory = imagesDirectory
            ?? appSupport.appendingPathComponent("ClipMemory/Images", isDirectory: true)
        self.defaults = defaults
        // BKP-1 (2026-07-24): injectable so tests can deterministically fail
        // the .incomplete marker removal without chmod tricks on real dirs.
        self.fileManager = fileManager
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
        set {
            // ID-BACKUP-0003 (2026-07-31 audit): lowering the retention count
            // used to leave the now-over-limit old backups on disk until the
            // next backup triggered pruning — disk usage diverged from the
            // user's expectation for up to 24h. Prune immediately when the
            // value drops. Async so the settings UI never blocks on the
            // removeItem cost of Images/-carrying backup dirs; BackupService
            // is a singleton, so `self` capture is effectively immortal anyway.
            let oldValue = keepCount
            defaults.set(newValue, forKey: Self.keepCountKey)
            if newValue < oldValue {
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    // ID-BACKUP-0005 (2026-08-01 audit): this fire-and-forget
                    // prune ran outside `backupLock`, so it could overlap a
                    // concurrent `backupNow()` (which holds the lock and also
                    // calls pruneOldBackups) — duplicate directory listings,
                    // double removeItem attempts, and spurious failure logs.
                    // Take the same lock here; `pruneOldBackups` stays the
                    // unlocked body because `performBackupUnlocked` calls it
                    // while already holding the lock (NSLock is not
                    // recursive — wrapping both paths would deadlock).
                    guard let self else { return }
                    self.backupLock.lock()
                    defer { self.backupLock.unlock() }
                    self.pruneOldBackups()
                }
            }
        }
    }

    var lastBackupDate: Date? {
        defaults.object(forKey: Self.lastBackupDateKey) as? Date
    }

    // N-3 (2026-07-27): see lastBackupErrorDateKey. Set by the auto-backup
    // path when `backupNow()` throws; cleared on the next success. Paired
    // with `lastBackupErrorMessage` for the UI.
    var lastBackupErrorDate: Date? {
        defaults.object(forKey: Self.lastBackupErrorDateKey) as? Date
    }

    var lastBackupErrorMessage: String? {
        defaults.string(forKey: Self.lastBackupErrorMessageKey)
    }

    /// Daily trigger from app launch. Runs on a utility queue; no-op when
    /// disabled or when the last backup is younger than 24h.
    func performBackupIfNeeded() {
        guard isEnabled else { return }
        if let last = lastBackupDate {
            let elapsed = Date().timeIntervalSince(last)
            // ID-BACKUP-0002 (2026-07-31 audit): the throttle is wall-clock
            // based. A system clock rollback (NTP correction, manual change)
            // after the last backup yields a NEGATIVE delta, which is always
            // < minimumInterval — the daily backup silently stalled until the
            // wall clock caught back up. Treat a negative delta as "due now"
            // (fail-open towards backing up) instead of extending the window.
            if elapsed >= 0, elapsed < Self.minimumInterval {
                return
            }
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // M-2 (2026-07-23): backupNow now throws. Auto-backup path is
            // best-effort — log + skip on failure. Real user-visible failures
            // surface from the manual UI button path and the import path
            // (both of which inspect the thrown error directly).
            // N-3 (2026-07-27): record the failure in UserDefaults so the
            // settings page can surface "Last backup failed: <reason>" to
            // the user. Previously `try?` meant the only signal was a log
            // line in Console.app, invisible to the user.
            guard let self else { return }
            do {
                _ = try self.backupNow()
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                self.defaults.set(Date(), forKey: Self.lastBackupErrorDateKey)
                self.defaults.set(message, forKey: Self.lastBackupErrorMessageKey)
                self.logger.error("Auto-backup failed: \(message)")
            }
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
        // L-9 (2026-07-25 audit): use the cached static formatter instead of
        // creating a new DateFormatter on every backup.
        let destination = backupsDirectory.appendingPathComponent(Self.backupFormatter.string(from: Date()), isDirectory: true)

        do {
            // ID-SECURITY-0004 (2026-07-31 audit): backup dirs were created
            // with default 0o755, exposing backup metadata (timestamp, item
            // count via items.json size, image count) to other local users on
            // shared hosts. Align with ImageStorage's ID-SECURITY-0002 fix —
            // 0o700. The blobs themselves are encrypted at rest either way.
            try fileManager.createDirectory(
                at: destination,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
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
                // ID-10 (2026-07-30 audit): partial backup dir leak on
                // backup failure. pruneOldBackups eventually picks it up
                // if it lacks the .incomplete marker, but a write failure
                // before the marker is written leaves a fully-formed-
                // looking orphan that survives until the next prune.
                do {
                    try fileManager.removeItem(at: destination)
                } catch {
                    logger.error("Failed to clean partial backup directory: \(error.localizedDescription, privacy: .public) path=\(destination.path, privacy: .public)")
                }
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
        try removeIncompleteMarker(in: destination)

        defaults.set(Date(), forKey: Self.lastBackupDateKey)
        // N-3 (2026-07-27): a successful backup clears the previous failure
        // record. The settings page only shows "Last backup failed" when
        // lastBackupErrorDate is strictly later than lastBackupDate, so this
        // clear makes the footer flip back to "Last backup: ..." immediately
        // after a manual "Back Up Now" succeeds.
        defaults.removeObject(forKey: Self.lastBackupErrorDateKey)
        defaults.removeObject(forKey: Self.lastBackupErrorMessageKey)
        pruneOldBackups()
        logger.info("Backup completed at \(destination.path)")
        succeeded = true
        return destination
    }

    /// BKP-1 (2026-07-24): this used to be `try?` inside
    /// `performBackupUnlocked`. A swallowed removal failure left a
    /// fully-written backup carrying `.incomplete`, and the NEXT
    /// `pruneOldBackups()` would then delete that good backup as a crash
    /// leftover — the exact data-loss scenario H-6 was protecting against.
    /// Treat removal failure like any other backup step failure: log +
    /// throw, the caller's defer cleans up the timestamped dir, and
    /// `lastBackupDate` stays put so the next launch retries.
    private func removeIncompleteMarker(in destination: URL) throws {
        do {
            try fileManager.removeItem(at: destination.appendingPathComponent(Self.incompleteMarkerName))
        } catch {
            logger.error("Backup failed (remove .incomplete marker): \(error.localizedDescription)")
            throw BackupError.markerRemovalFailed(underlying: error)
        }
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
            // L-12 (2026-07-25 audit): a regular file that happens to match the
            // timestamp format must not be deleted. Only act on directories.
            guard Self.isBackupDirectory(at: dir, fileManager: fileManager) else { continue }
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

    /// L-12 (2026-07-25 audit): a regular file that happens to match the
    /// backup timestamp format must not be treated as a backup directory.
    /// Only directories are valid targets for pruning.
    private static func isBackupDirectory(at url: URL, fileManager: FileManager) -> Bool {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        return isDir.boolValue
    }

    /// Matches the `yyyy-MM-dd_HHmmss.SSS` backup directory format (21 chars).
    /// The length MUST match the live `dateFormat` in `backupNow()` — when
    /// BUG-021 (2026-07-21) promoted the stamp from second precision (17 chars)
    /// to millisecond precision (21 chars), this filter was overlooked, so
    /// `pruneOldBackups` matched 0 production dirs and the `Backups/` tree
    /// grew unboundedly. Cross-check the two sites together when changing
    /// either.
    ///
    /// L-13 (2026-07-24 review): the recognizer now parses the name with a
    /// DateFormatter built from the shared `backupDirTimestampFormat`
    /// constant (plus a re-format round-trip equality check to stay strict),
    /// replacing the hand-maintained 21-char / char-position validation that
    /// had to be kept in sync with the format string by hand.
    private static let backupDirNameFormatter: DateFormatter = {
        let f = DateFormatter()
        // POSIX locale matches performBackupUnlocked: keeps `yyyy` Gregorian
        // regardless of the user's calendar so name-sort = time-sort.
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = backupDirTimestampFormat
        return f
    }()

    private static func isBackupDirName(_ name: String) -> Bool {
        guard let date = backupDirNameFormatter.date(from: name) else { return false }
        // Round-trip: DateFormatter parsing is lenient about digit counts and
        // out-of-range components (e.g. month 13 rolls over); requiring the
        // parsed date to format back to the exact input keeps recognition as
        // strict as the previous per-character check.
        return backupDirNameFormatter.string(from: date) == name
    }

    /// Lists auto-backups available for restore. Synchronous and
    /// non-isolated (`BackupService` is `final class` with no
    /// `@MainActor`). Callers MUST dispatch to a background queue —
    /// on `@MainActor` the recursive directory walk + JSON reads stall
    /// the UI. (Same pattern as `BackupSettingsView.importBackup():164`
    /// which dispatches to `.userInitiated`.)
    func listAvailableBackups() -> [LocalBackup] {
        let fm = fileManager
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: backupsDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            logger.error("listAvailableBackups: failed to list \(self.backupsDirectory.path): \(error.localizedDescription)")
            return []
        }

        var backups: [LocalBackup] = []
        for url in entries {
            // Skip non-directories (defensive — backups dir should only contain dirs).
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }

            let name = url.lastPathComponent
            // Skip non-timestamped names.
            guard Self.isBackupDirName(name) else { continue }

            let date = Self.backupDirNameFormatter.date(from: name) ?? Date.distantPast

            // Incomplete detection — KEEP in list (UI disables selection per §4.4).
            let markerPath = url.appendingPathComponent(Self.incompleteMarkerName).path
            let isIncomplete = fm.fileExists(atPath: markerPath)

            let itemsCount = decodeCount(url: url.appendingPathComponent("items.json"))
            let tagsCount = decodeCount(url: url.appendingPathComponent("tags.json"))
            let imagesCount = countPNGs(in: url.appendingPathComponent("Images", isDirectory: true))
            let sizeBytes = Self.directoryTotalSize(at: url)

            backups.append(LocalBackup(
                id: url,
                directoryName: name,
                date: date,
                sizeBytes: sizeBytes,
                itemsCount: itemsCount,
                tagsCount: tagsCount,
                imagesCount: imagesCount,
                isIncomplete: isIncomplete
            ))
        }
        // Newest first; incomplete sink to the bottom.
        return backups.sorted { lhs, rhs in
            if lhs.isIncomplete != rhs.isIncomplete { return !lhs.isIncomplete }
            return lhs.date > rhs.date
        }
    }

    /// Recursive size of a directory tree. Best-effort: returns 0 on any
    /// FS error (permissions, broken symlink). Used only for UI display.
    private static func directoryTotalSize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let entry as URL in enumerator {
            let values = try? entry.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    /// Decode JSON array and return its count. Nil on read failure or
    /// missing file.
    private func decodeCount(url: URL) -> Int? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        // Try [ClipboardItem] first (items.json, trash.json), then [Tag] (tags.json).
        if let items = try? JSONDecoder().decode([ClipboardItem].self, from: data) { return items.count }
        if let tags = try? JSONDecoder().decode([Tag].self, from: data) { return tags.count }
        return nil
    }

    /// Count .png files in a directory. Nil if directory missing.
    private func countPNGs(in dir: URL) -> Int? {
        guard fileManager.fileExists(atPath: dir.path) else { return nil }
        guard let entries = try? fileManager.contentsOfDirectory(atPath: dir.path) else { return nil }
        return entries.filter { $0.hasSuffix(".png") }.count
    }
}
