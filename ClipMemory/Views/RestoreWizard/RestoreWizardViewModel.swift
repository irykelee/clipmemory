import Foundation
import SwiftUI
// Note: no `import CryptoKit` — F9 fix pushed password validation into
// `BackupPackage.validateExternalPackage` so the VM is a pure state mapper.

@MainActor
final class RestoreWizardViewModel: ObservableObject {
    let backupService: BackupService
    let imagesDirectory: URL
    let defaults: UserDefaults

    @Published var step: WizardStep = .selectSource
    @Published var backups: [LocalBackup] = []
    @Published var source: RestoreSource?
    @Published var validation: RestoreValidation = .pending
    @Published var progress: RestoreProgress = .idle
    @Published var passphrase: String = ""
    @Published var lastError: BackupPackageError?
    @Published var result: BackupImportResult?

    /// Cancellation token for in-flight loads.
    private var loadTask: Task<Void, Never>?

    init(backupService: BackupService, imagesDirectory: URL, defaults: UserDefaults) {
        self.backupService = backupService
        self.imagesDirectory = imagesDirectory
        self.defaults = defaults
    }

    deinit {
        loadTask?.cancel()
    }

    /// Step 1: Load local backups in the background; [weak self] prevents
    /// writes to deallocated VM if user dismisses wizard mid-load.
    /// CRITICAL: uses injected `self.backupService`, NOT `BackupService.shared` —
    /// tests inject a temp-dir service and would read real backups otherwise.
    func loadList() async {
        loadTask?.cancel()
        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            let list = self?.backupService.listAvailableBackups() ?? []
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.backups = list }
        }
        await loadTask?.value
    }

    /// Step 1 → 2: user picked an external `.clipmemory` file (URL).
    /// Sets source, clears passphrase, transitions to step 2 awaiting input.
    /// `validateExternal(url:passphrase:)` does the actual key derivation.
    func beginExternalValidation(url: URL) {
        source = .externalFile(url)
        passphrase = ""
        validation = .pending
        step = .validate
    }

    /// Step 1 → 2/3: user picked a local backup.
    func selectLocalBackup(_ backup: LocalBackup) {
        source = .localBackup(backup)
        step = .validate
        // Local validation is sync (read items/tags JSON); transition immediately.
        Task { @MainActor in
            validateLocal(backup)
        }
    }

    private func validateLocal(_ backup: LocalBackup) {
        // Build preview from already-counted fields; re-decode items.json for size.
        do {
            let itemsData = try Data(contentsOf: backup.id.appendingPathComponent("items.json"))
            let items = try JSONDecoder().decode([ClipboardItem].self, from: itemsData)
            let tagsData = try Data(contentsOf: backup.id.appendingPathComponent("tags.json"))
            let tags = try JSONDecoder().decode([Tag].self, from: tagsData)
            let imagesDir = backup.id.appendingPathComponent("Images", isDirectory: true)
            let imagesCount = FileManager.default.fileExists(atPath: imagesDir.path)
                ? (try? FileManager.default.contentsOfDirectory(atPath: imagesDir.path).filter { $0.hasSuffix(".png") }.count) ?? 0
                : 0

            var warnings: [RestoreWarning] = []
            if backup.isIncomplete { warnings.append(.incompleteMarker) }
            if items.isEmpty && tags.isEmpty { warnings.append(.emptyContent) }

            let preview = RestorePreview(
                source: .localBackup(backup),
                itemsCount: items.count,
                tagsCount: tags.count,
                imagesCount: imagesCount,
                createdAt: backup.date,
                appVersion: nil,
                warnings: warnings
            )
            validation = .valid(preview: preview)
            step = .preview
        } catch {
            validation = .corrupted(reason: error.localizedDescription)
        }
    }

    /// Step 2: user picked external file (URL) AND entered passphrase.
    func validateExternal(url: URL, passphrase: String) async {
        self.passphrase = passphrase
        source = .externalFile(url)
        step = .validate
        validation = .validating
        // Background: delegate to BackupPackage.validateExternalPackage (F9 fix
        // moved all crypto + size guards + canonical error mapping into the
        // service). VM is now a pure state mapper — no CryptoKit needed.
        do {
            let manifestData = try await Task.detached(priority: .userInitiated) {
                try BackupPackage.validateExternalPackage(at: url, passphrase: passphrase)
            }.value

            let preview = RestorePreview(
                source: .externalFile(url),
                itemsCount: manifestData.itemCount,
                tagsCount: manifestData.tagCount,
                imagesCount: manifestData.imageCount,
                createdAt: manifestData.createdAt,
                appVersion: manifestData.appVersion,
                warnings: []
            )
            validation = .valid(preview: preview)
            step = .preview
        } catch BackupPackageError.wrongPassword {
            validation = .wrongPassword
        } catch {
            validation = .corrupted(reason: error.localizedDescription)
        }
    }

    /// Step 4: Apply. Flush → snapshot → import. Background; updates `progress` on main.
    ///
    /// `mode` is a forward-declared parameter for the future `RestoreMode.replace`
    /// branch (phase 2). Today only `.merge` is implemented — `clearAll` for `.replace`
    /// does not exist. If a future caller passes `.replace`, this `precondition` traps
    /// with a developer-facing message; otherwise `apply()` silently no-ops. The view
    /// layer (Task 6) calls `apply()` with no argument, picking up the default `.merge`.
    func apply(mode: RestoreMode = .merge) {
        precondition(mode == .merge, "RestoreMode.replace requires clearAll() implementation (phase 2). Today only .merge is supported.")
        guard case .valid(let preview) = validation, let source = source else { return }
        // Capture main-actor values before entering detached task.
        let imagesDir = imagesDirectory
        let userDefaults = defaults
        let passphraseValue = passphrase
        let store = ClipboardStore.shared
        let svc = backupService
        progress = .snapshotting
        Task.detached(priority: .userInitiated) { [weak self] in
            // Step 0: flush pending saves (sync, ~ms).
            await MainActor.run { ClipboardStore.shared.flushPendingSaves() }

            // Step 1: safety snapshot (background).
            let snapshotURL: URL
            do {
                snapshotURL = try await Task.detached(priority: .userInitiated) {
                    try svc.backupNow()
                }.value
                _ = snapshotURL
            } catch {
                await MainActor.run {
                    self?.progress = .failed(.snapshotFailed("Snapshot failed: \(error.localizedDescription)"))
                    self?.lastError = .snapshotFailed(error.localizedDescription)
                }
                return
            }

            await MainActor.run { self?.progress = .importing }

            // Step 2: import (background; hops to main internally).
            do {
                let result: BackupImportResult
                switch source {
                case .localBackup(let backup):
                    if backup.isIncomplete {
                        await MainActor.run { self?.progress = .failed(.corruptedData("incomplete", .manifest)) }
                        return
                    }
                    result = try BackupPackage.importFromLocalBackup(
                        backup.id, store: store,
                        imagesDirectory: imagesDir,
                        defaults: userDefaults
                    )
                case .externalFile(let url):
                    result = try BackupPackage.importPackage(
                        from: url,
                        passphrase: passphraseValue,
                        store: store,
                        localCrypto: ServiceContainer.crypto,
                        imagesDirectory: imagesDir,
                        defaults: userDefaults
                    )
                }
                await MainActor.run {
                    self?.result = result
                    self?.progress = .finished(result)
                    self?.step = .result
                }
            } catch BackupPackageError.wrongPassword {
                // Defensive TOCTOU: validateExternal should have caught this
                // first (F8 fix). If it reaches here (e.g., key changed
                // mid-session), route back to step 2 for password re-entry.
                await MainActor.run {
                    self?.progress = .idle
                    self?.validation = .wrongPassword
                    self?.step = .validate
                }
            } catch let err as BackupPackageError {
                await MainActor.run { self?.progress = .failed(err) }
            } catch {
                await MainActor.run { self?.progress = .failed(.corruptedData(error.localizedDescription, .manifest)) }
            }
        }
    }

    func cancel() {
        loadTask?.cancel()
    }
}
