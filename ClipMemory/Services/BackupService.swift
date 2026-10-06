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

    // P1-AUDIT-2026-09-22 (P2-9): the static let `xxxKey` constants used to
    // hold raw string literals. Replaced with the central `UserDefaultsKey`
    // enum to make renames static-checkable and prevent collision. The
    // legacy `Self.enabledKey` / `Self.keepCountKey` / `Self.lastBackupDateKey`
    // etc. references below now resolve through the enum's rawValue.
    private static var enabledKey: String { UserDefaultsKey.backupEnabled.rawValue }
    private static var keepCountKey: String { UserDefaultsKey.backupKeepCount.rawValue }
    private static var lastBackupDateKey: String { UserDefaultsKey.lastBackupDate.rawValue }
    // N-3 (2026-07-27): pair with `lastBackupDateKey` to surface failures
    // from the auto-backup path. `performBackupIfNeeded` used to swallow
    // every `BackupError` via `try?` — users had no signal that the daily
    // backup had stopped succeeding (disk full, permissions revoked, Keychain
    // locked). The settings page now shows "Last backup failed: <reason>"
    // when the most recent failure is newer than the most recent success.
    private static var lastBackupErrorDateKey: String { UserDefaultsKey.lastBackupErrorDate.rawValue }
    private static var lastBackupErrorMessageKey: String { UserDefaultsKey.lastBackupErrorMessage.rawValue }
    // ID-STORE-0016 (2026-08-15, L26 Path E): pruneOldBackups' contentsOfDirectory
    // failure was a silent no-op (line 374-376 catch + return), so a perm-revoked
    // or deleted Backups/ directory meant prune ran but kept nothing, and
    // Backups/ grew unbounded with no UI signal. Mirror N-3's UserDefaults pair
    // so the settings page can show "Last prune failed: <reason>". Distinct from
    // lastBackupErrorDate because prune failures don't prevent the next
    // backup (the user can still trigger backupNow manually) — collapsing them
    // would hide the prune signal under a recent backup success.
    private static var lastPruneErrorDateKey: String { UserDefaultsKey.lastPruneErrorDate.rawValue }
    private static var lastPruneErrorMessageKey: String { UserDefaultsKey.lastPruneErrorMessage.rawValue }
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

    // ID-STORE-0016: see lastPruneErrorDateKey above.
    var lastPruneErrorDate: Date? {
        defaults.object(forKey: Self.lastPruneErrorDateKey) as? Date
    }
    var lastPruneErrorMessage: String? {
        defaults.string(forKey: Self.lastPruneErrorMessageKey)
    }

    // ID-STORE-0016: shared writer used by both pruneOldBackups catch
    // branches (initial listing + post-incomplete-sweep re-listing). Mirror
    // of the N-3 pattern in performBackupIfNeeded (line 189-191).
    private func recordPruneError(message: String) {
        defaults.set(Date(), forKey: Self.lastPruneErrorDateKey)
        defaults.set(message, forKey: Self.lastPruneErrorMessageKey)
    }

    /// Daily trigger from app launch. Runs on a utility queue; no-op when
    /// disabled or when the last backup is younger than 24h.
    func performBackupIfNeeded() {
        guard isEnabled else { return }
        // ID-STORE-0017 (2026-08-15, L26 Path E): a non-Date value at
        // lastBackupDateKey (e.g., a bad migration or accidental
        // `defaults.set(Int, ...)`) makes `as? Date` return nil, which
        // silently skips the throttle block. The backup fires anyway
        // — fail-open toward backing up — but the operator has no signal
        // that the throttle is no longer in effect. Log a warning so the
        // corruption is visible in Console.app without changing the
        // fail-open behavior (more backups is safer than fewer).
        if let raw = defaults.object(forKey: Self.lastBackupDateKey),
           !(raw is Date) {
            logger.warning("lastBackupDate corrupted (type=\(type(of: raw))), treating as nil so throttle is skipped — backup will fire this launch")
        }
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
        try prepareBackupDirectory(at: destination)
        writeIncompleteMarker(at: destination)

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
            if !succeeded { removePartialBackup(at: destination) }
        }

        try writeBackupBlobs(to: destination)
        try copyImagesIfPresent(to: destination)

        // H-6 (2026-07-24 audit): all data has been written successfully —
        // remove the `.incomplete` marker so the dir is treated as a valid
        // backup by future prune calls. Removal happens BEFORE `succeeded`
        // flips so any post-write exception (the only realistic one today is
        // the `pruneOldBackups` log-but-don't-throw path) still leaves the
        // dir in a consistent state: either marked incomplete (defer cleanup
        // will remove it) or marker-free (it stays as a valid backup).
        try removeIncompleteMarker(in: destination)
        finalizeBackupSuccess(at: destination)
        succeeded = true
        return destination
    }

    /// Creates the parent `Backups/` directory (chmod 0o700 if it exists)
    /// and the timestamped leaf directory for this run (also 0o700).
    /// ID-SECURITY-0004 (2026-07-31): the 0o700 perm closes the
    /// backup-metadata leak to other local users on shared hosts.
    /// ID-REVIEW-1007 (code-review-2026-10-01 P2 0-7): also chmod the
    /// parent — `createDirectory(withIntermediateDirectories:)` only sets
    /// the leaf perm; the parent inherits the umask-derived default
    /// (typically 0o755).
    private func prepareBackupDirectory(at destination: URL) throws {
        do {
            try fileManager.createDirectory(
                at: backupsDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // Already exists from a prior run — make sure the perm is
            // current. setAttributes is a no-op if the path is missing
            // (handled below by createDirectory on the leaf), and
            // silent on perm-already-correct.
            _ = try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backupsDirectory.path)
            try fileManager.createDirectory(
                at: destination,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            logger.error("Backup failed (directory): \(error.localizedDescription)")
            throw BackupError.directoryCreationFailed(underlying: error)
        }
    }

    /// H-6 (2026-07-24 audit): drop an `.incomplete` marker the moment the
    /// dir exists. If the process crashes or is killed before we reach the
    /// matching `removeItem` at the bottom of this function, the marker
    /// tells `pruneOldBackups` to delete this dir instead of treating it
    /// as a valid backup. Best-effort write — failure to mark means the
    /// crash-consistency safety net is lost, but doesn't break the backup
    /// itself (the existing partial-dir cleanup defer still fires).
    private func writeIncompleteMarker(at destination: URL) {
        do {
            try Data().write(to: destination.appendingPathComponent(Self.incompleteMarkerName))
        } catch {
            logger.warning("Backup: failed to write .incomplete marker (crash-consistency degraded): \(error.localizedDescription)")
        }
    }

    /// ID-10 (2026-07-30 audit): partial backup dir leak on backup
    /// failure. pruneOldBackups eventually picks it up if it lacks the
    /// .incomplete marker, but a write failure before the marker is
    /// written leaves a fully-formed-looking orphan that survives until
    /// the next prune.
    private func removePartialBackup(at destination: URL) {
        do {
            try fileManager.removeItem(at: destination)
        } catch {
            // swiftlint:disable:next line_length
            logger.error("Failed to clean partial backup directory: \(error.localizedDescription, privacy: .public) path=\(destination.path, privacy: .public)")
        }
    }

    /// P1-AUDIT-2026-09-22 (P2-10): the (filename, key) pairs come from
    /// the central `BackupBlobRegistry` enum. BackupPackage.swift iterates
    /// the same registry, so adding a new blob type = one enum case; both
    /// backup paths get it automatically. Each blob is chmod 0o600
    /// (ID-REVIEW-1007) to close the per-backup metadata leak.
    private func writeBackupBlobs(to destination: URL) throws {
        for blob in BackupBlobRegistry.allBlobKeys {
            let filename = blob.filename
            let key = blob.userDefaultsKey
            guard let data = defaults.data(forKey: key) else { continue }
            do {
                let blobURL = destination.appendingPathComponent(filename)
                try data.write(to: blobURL, options: .atomic)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: blobURL.path)
            } catch {
                logger.error("Backup failed (write \(filename)): \(error.localizedDescription)")
                throw BackupError.writeFailed(filename: filename, underlying: error)
            }
        }
    }

    /// Hard-links the `Images/` directory into the backup if present;
    /// no-op otherwise.
    ///
    /// ID-REVIEW-1018 (2026-10-06, code-review-2026-10-01 §六 P2-7):
    /// previously used `fileManager.copyItem(at:to:)` which recursively
    /// duplicates every image. With `keepCount` at 30 and a sizable
    /// image library, a daily backup was multiplying disk usage by up
    /// to 30x. ImageStorage saves content-immutable encrypted blobs
    /// (UUID-named, never modified after write), so hard links to the
    /// source files are safe — N backups share the same inodes.
    ///
    /// Pre-research (commit-time): on this MacBook (macOS 27.0.1,
    /// `/dev/disk3s1` APFS volume), 10MB test file + `cp` + Swift
    /// `copyfile(COPYFILE_CLONE)` all produced independent inodes
    /// with full 10MB block allocation. APFS CoW clone is not
    /// activated on this volume for `copyfile(2)`. Hard link is the
    /// only path that achieves zero incremental disk usage without
    /// changing the ImageStorage storage layout (per task discipline).
    ///
    /// Restore path (`importImages` in BackupPackage.swift) reads
    /// bytes regardless of whether the path is a hard link, so no
    /// restore-side change is needed.
    private func copyImagesIfPresent(to destination: URL) throws {
        guard fileManager.fileExists(atPath: imagesDirectory.path) else { return }
        let imagesDestination = destination.appendingPathComponent("Images", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: imagesDestination, withIntermediateDirectories: true
            )
        } catch {
            logger.error("Backup failed (create Images dir): \(error.localizedDescription)")
            throw BackupError.imageCopyFailed(underlying: error)
        }

        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey]
        guard let enumerator = fileManager.enumerator(
            at: imagesDirectory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return
        }

        // Hard link every regular file in `Images/`. Failures abort the
        // backup with `imageCopyFailed` (same as the old `copyItem` path)
        // so a broken source file doesn't produce a half-formed backup.
        // The partial backup dir is cleaned up by `removePartialBackup`
        // via the `.incomplete` marker pattern in the caller.
        for case let fileURL as URL in enumerator {
            do {
                let values = try fileURL.resourceValues(forKeys: resourceKeys)
                guard values.isRegularFile == true else { continue }
                let dst = imagesDestination.appendingPathComponent(fileURL.lastPathComponent)
                try fileManager.linkItem(at: fileURL, to: dst)
            } catch {
                logger.error("Backup failed (link Images): \(error.localizedDescription) source=\(fileURL.lastPathComponent)")
                throw BackupError.imageCopyFailed(underlying: error)
            }
        }
    }

    /// ID-REVIEW-1018 (2026-10-06): sum of `URLResourceKey.fileAllocatedSizeKey`
    /// across every file in every backup directory. Because images are
    /// hard-linked, the SAME inode appears N times in the enumeration
    /// (once per backup), and `fileAllocatedSize` reports the full
    /// allocation per path (not deduplicated). Naive summation would
    /// report `count × image_size` even though the disk only stores
    /// one copy. We dedupe by `fileResourceIdentifierKey` (an
    /// `NSURL`-internal id that uniquely identifies the underlying
    /// inode for hard-linked files) — each unique inode is counted
    /// exactly once.
    ///
    /// Read off the main actor — walks `Backups/<ts>/` recursively;
    /// cost is acceptable because the section only refreshes on
    /// settings tab open.
    func totalBackupDiskUsage() -> (bytes: Int64, count: Int) {
        let keys: Set<URLResourceKey> = [.fileAllocatedSizeKey, .fileResourceIdentifierKey]
        var total: Int64 = 0
        var count = 0
        // `fileResourceIdentifier` is typed `Any?` (URLResourceKey
        // expects URLResourceKey, but the identifier itself conforms
        // to NSCopying & NSSecureCoding & NSObjectProtocol — i.e. it's
        // an NSObject). Wrap in AnyHashable so we can use it as a Set
        // key directly.
        var seenInodes: Set<AnyHashable> = []
        let entries = (try? fileManager.contentsOfDirectory(
            at: backupsDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []
        for entry in entries {
            // Use the same `isBackupDirName` predicate as `pruneOldBackups`
            // so the two stay in lock-step. (The earlier version of this
            // method used a hard-coded `Backup-` prefix + 28-char length
            // check that matched a long-deprecated convention; real
            // backup dir names are just `yyyy-MM-dd_HHmmss.SSS` from
            // `backupDirTimestampFormat`.)
            guard Self.isBackupDirName(entry.lastPathComponent) else { continue }
            count += 1
            guard let enumerator = fileManager.enumerator(
                at: entry,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let fileURL as URL in enumerator {
                guard let values = try? fileURL.resourceValues(forKeys: keys),
                      let size = values.fileAllocatedSize,
                      let identifier = values.fileResourceIdentifier else { continue }
                // First sighting of this inode → count it; subsequent
                // hard links to the same inode → skip. Cast through NSObject
                // since `fileResourceIdentifier` is typed `Any?` (the
                // Foundation API returns NSObjectProtocol-conforming values
                // but the Swift signature is loose) and AnyHashable needs
                // a concrete Hashable type.
                let key = AnyHashable(identifier as! NSObject)
                if seenInodes.insert(key).inserted {
                    total += Int64(size)
                }
            }
        }
        return (total, count)
    }

    /// Updates UserDefaults bookkeeping (lastBackupDate, clear any prior
    /// error record), runs the retention prune, and logs success. Caller
    /// has already removed the `.incomplete` marker.
    private func finalizeBackupSuccess(at destination: URL) {
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
            // ID-STORE-0016 (2026-08-15, L26 Path E): record the failure so the
            // settings page surfaces "Last prune failed: <reason>". Mirror of
            // N-3's lastBackupErrorDate/Message pair; separated because a prune
            // failure is distinct from a backup failure (the next backupNow
            // can still succeed; collapsing them would hide the prune signal).
            recordPruneError(message: error.localizedDescription)
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
            recordPruneError(message: error.localizedDescription)
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
    /// the UI.
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

    /// Preview counts payload for `previewCounts(for:)`. Named struct
    /// (vs a 3-tuple) keeps the call site readable (`.items` / `.tags`
    /// / `.images` vs `.0` / `.1` / `.2`) and matches the established
    /// struct-return pattern at `LocalBackup` / `RestorePreview`.
    struct PreviewCounts: Equatable {
        let items: Int
        let tags: Int
        let images: Int
    }

    /// ID-CRASH-0026 (2026-09-28 code-review P2-24): single source of
    /// truth for the local-backup preview payload (items / tags / image
    /// counts). Previously `RestoreWizardViewModel.validateLocal(_:)`
    /// reimplemented these three reads inline — duplicating the backup
    /// directory layout knowledge that already lives here. Returns
    /// `.failure` with the original error so the VM can surface the
    /// user-visible reason in `RestoreValidation.corrupted`.
    ///
    /// **Callers MUST dispatch off `@MainActor` before invoking** (this
    /// method does `Data(contentsOf:)` + `JSONDecoder().decode(...)` on
    /// the calling thread, blocking for up to several hundred ms on
    /// real backups). The matching pattern is `Task.detached` (see
    /// `RestoreWizardViewModel.validateLocal(_:)` before this commit
    /// was sync; documented here for any future caller).
    func previewCounts(for backup: LocalBackup) -> Result<PreviewCounts, Error> {
        let itemsURL = backup.id.appendingPathComponent("items.json")
        let tagsURL = backup.id.appendingPathComponent("tags.json")
        let imagesURL = backup.id.appendingPathComponent("Images", isDirectory: true)

        do {
            let itemsData = try Data(contentsOf: itemsURL)
            let items = try JSONDecoder().decode([ClipboardItem].self, from: itemsData)
            // tags.json / Images/ are best-effort: missing tags
            // shouldn't fail the preview (legitimate empty-tag backups
            // exist; matches `decodeTags` (BackupPackage.swift:1073-1077)
            // returning `[]` for missing), missing Images dir just
            // means zero images. Corrupted tags.json is also degraded
            // to 0 — a degraded preview that surfaces the error in the
            // apply step (the real validation site) is better than a
            // hard-fail preview that hides the data behind a banner.
            let tagsCount = (try? Data(contentsOf: tagsURL))
                .flatMap { try? JSONDecoder().decode([Tag].self, from: $0) }
                .map { $0.count } ?? 0
            let imagesCount = countPNGs(in: imagesURL) ?? 0
            return .success(PreviewCounts(items: items.count, tags: tagsCount, images: imagesCount))
        } catch {
            return .failure(error)
        }
    }
}
