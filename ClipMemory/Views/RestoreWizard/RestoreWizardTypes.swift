import Foundation

/// State machine for the restore wizard.
enum WizardStep: Int, CaseIterable {
    case selectSource    // 1: pick local backup OR external file
    case validate        // 2: read + verify (password for external; identity for local)
    case preview         // 3: counts / version / warnings
    case confirmApply    // 4: safety snapshot → apply → progress
    case result          // 5: imported / skipped / corrupt / image failed summary
}

/// Source selected in step 1.
enum RestoreSource: Equatable {
    case localBackup(LocalBackup)
    case externalFile(URL)
}

/// Validation result for step 2.
enum RestoreValidation: Equatable {
    case pending
    case validating
    case valid(preview: RestorePreview)
    case wrongPassword              // external file only
    case corrupted(reason: String)  // terminal
    case incomplete                 // defensive; UI prevents reaching here
}

/// Pre-import preview shown in step 3.
struct RestorePreview: Equatable {
    let source: RestoreSource
    let itemsCount: Int
    let tagsCount: Int
    let imagesCount: Int
    let createdAt: Date
    let appVersion: String?
    let warnings: [RestoreWarning]
}

/// Non-fatal warnings surfaced in preview.
enum RestoreWarning: Equatable {
    case incompleteMarker
    case missingEncryptionKey
    case emptyContent
}

/// Apply progress for step 4.
enum RestoreProgress: Equatable {
    case idle
    case snapshotting
    case importing
    case finished(BackupImportResult)
    case failed(BackupPackageError)
}
