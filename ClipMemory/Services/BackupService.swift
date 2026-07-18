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
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
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
            self?.backupNow()
        }
    }

    /// Creates a timestamped backup directory with the three store blobs and a
    /// copy of Images/, then prunes old backups. Returns the new directory.
    @discardableResult
    func backupNow() -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let destination = backupsDirectory.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)

        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

            let blobs: [(String, String)] = [
                ("items.json", "ClipboardItems"),
                ("tags.json", "ClipMemoryTags"),
                ("trash.json", "ClipboardTrashedItems")
            ]
            for (filename, key) in blobs {
                guard let data = defaults.data(forKey: key) else { continue }
                try data.write(to: destination.appendingPathComponent(filename), options: .atomic)
            }

            if fileManager.fileExists(atPath: imagesDirectory.path) {
                let imagesDestination = destination.appendingPathComponent("Images", isDirectory: true)
                try fileManager.copyItem(at: imagesDirectory, to: imagesDestination)
            }

            defaults.set(Date(), forKey: Self.lastBackupDateKey)
            pruneOldBackups()
            logger.info("Backup completed at \(destination.path)")
            return destination
        } catch {
            logger.error("Backup failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Keeps the newest `keepCount` timestamped backup directories.
    func pruneOldBackups() {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: backupsDirectory.path) else { return }
        // Timestamped names sort chronologically as plain strings.
        let sorted = entries.sorted()
        let excess = sorted.count - keepCount
        guard excess > 0 else { return }
        for name in sorted.prefix(excess) {
            try? fileManager.removeItem(at: backupsDirectory.appendingPathComponent(name))
        }
        logger.info("Pruned \(excess) old backup(s), keeping \(self.keepCount)")
    }
}
