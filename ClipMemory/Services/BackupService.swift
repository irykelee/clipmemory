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
    @discardableResult
    func backupNow() throws -> URL {
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
        formatter.dateFormat = "yyyy-MM-dd_HHmmss.SSS"
        let destination = backupsDirectory.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)

        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            logger.error("Backup failed (directory): \(error.localizedDescription)")
            throw BackupError.directoryCreationFailed(underlying: error)
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

        defaults.set(Date(), forKey: Self.lastBackupDateKey)
        pruneOldBackups()
        logger.info("Backup completed at \(destination.path)")
        return destination
    }

    /// Keeps the newest `keepCount` timestamped backup directories.
    func pruneOldBackups() {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: backupsDirectory.path) else { return }
        // Only prune our own timestamped backup dirs — stray files (.DS_Store,
        // anything the user placed here) are left alone.
        let backupNames = entries.filter(Self.isBackupDirName)
        // Timestamped names sort chronologically as plain strings.
        let sorted = backupNames.sorted()
        let excess = sorted.count - keepCount
        guard excess > 0 else { return }
        for name in sorted.prefix(excess) {
            try? fileManager.removeItem(at: backupsDirectory.appendingPathComponent(name))
        }
        logger.info("Pruned \(excess) old backup(s), keeping \(self.keepCount)")
    }

    /// Matches the `yyyy-MM-dd_HHmmss` backup directory format (17 chars).
    private static func isBackupDirName(_ name: String) -> Bool {
        let chars = Array(name)
        guard chars.count == 17 else { return false }
        for (index, char) in chars.enumerated() {
            switch index {
            case 4, 7: guard char == "-" else { return false }
            case 10: guard char == "_" else { return false }
            default: guard char.isNumber else { return false }
            }
        }
        return true
    }
}
