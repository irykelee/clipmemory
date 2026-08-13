import Foundation

/// Metadata for one local auto-backup directory. Listed by
/// `BackupService.listAvailableBackups()` and rendered by the restore
/// wizard (step 1). Sendable so it can cross the
/// background-dispatch boundary in `RestoreWizardViewModel`.
struct LocalBackup: Identifiable, Hashable, Sendable {
    let id: URL
    let directoryName: String
    let date: Date
    let sizeBytes: Int64
    let itemsCount: Int?
    let tagsCount: Int?
    let imagesCount: Int?
    let isIncomplete: Bool
}
