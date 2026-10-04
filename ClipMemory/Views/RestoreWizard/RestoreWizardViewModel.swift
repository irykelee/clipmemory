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
        // ID-CRASH-0026 (2026-09-28 code-review P2-24): delegate the
        // items.json / tags.json / Images/ enumeration to
        // `BackupService.previewCounts(for:)` so the backup directory
        // layout is owned in exactly one place (P1-AUDIT-2026-09-22
        // P1-5 had this as a residual — the rest of the four call sites
        // were already moved in earlier batches; this was the last).
        //
        // Sync FS call on @MainActor — pre-existing behaviour (the
        // previous inline implementation was also sync). ID-CRASH-0026
        // preserves the dispatch contract; moving the call off-main
        // is a separate concern (tracked under P2 perf backlog).
        switch backupService.previewCounts(for: backup) {
        case .success(let counts):
            var warnings: [RestoreWarning] = []
            if backup.isIncomplete { warnings.append(.incompleteMarker) }
            if counts.items == 0 && counts.tags == 0 { warnings.append(.emptyContent) }
            let preview = RestorePreview(
                source: .localBackup(backup),
                itemsCount: counts.items,
                tagsCount: counts.tags,
                imagesCount: counts.images,
                createdAt: backup.date,
                appVersion: nil,
                warnings: warnings
            )
            validation = .valid(preview: preview)
            step = .preview
        case .failure(let error):
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
        guard case .valid = validation, let source = source else { return }
        // Capture main-actor values before entering detached task.
        let context = RestoreContext(
            source: source,
            imagesDirectory: imagesDirectory,
            defaults: defaults,
            passphrase: passphrase,
            store: ClipboardStore.shared,
            backupService: backupService
        )
        progress = .snapshotting
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.performRestoreTask(context: context)
        }
    }

    /// Bundle of @MainActor values that the detached restore task needs.
    /// Captured synchronously in `apply()` before the task hop so the
    /// background task can pass them by value (no MainActor reads inside
    /// the detached closure except where SwiftUI bindings require them).
    private struct RestoreContext: Sendable {
        let source: RestoreSource
        let imagesDirectory: URL
        let defaults: UserDefaults
        let passphrase: String
        let store: ClipboardStore
        let backupService: BackupService
    }

    /// The actual restore flow, run on a detached userInitiated task.
    /// Split out from `apply()` so the orchestration is readable and
    /// each step's error branch lives next to its corresponding success
    /// branch instead of nesting three layers deep.
    private func performRestoreTask(context: RestoreContext) async {
        // Step 0: flush pending saves (sync, ~ms).
        await MainActor.run { ClipboardStore.shared.flushPendingSaves() }
        // Step 1: safety snapshot (background).
        guard await runSafetySnapshot(backupService: context.backupService) else { return }
        await MainActor.run { self.progress = .importing }
        // Step 2: import (background; hops to main internally).
        await performImportAndReport(context: context)
    }

    /// Runs the safety snapshot before any restore. Returns true on
    /// success, false if the snapshot failed (in which case the caller
    /// should NOT advance to the import phase).
    private func runSafetySnapshot(backupService: BackupService) async -> Bool {
        do {
            _ = try await Task.detached(priority: .userInitiated) {
                try backupService.backupNow()
            }.value
            return true
        } catch {
            await MainActor.run {
                self.progress = .failed(.snapshotFailed("Snapshot failed: \(error.localizedDescription)"))
            }
            return false
        }
    }

    /// Step 2: import the backup (local or external file) and translate
    /// the outcome into the view's progress / step. `wrongPassword`
    /// routes back to the password-entry step (F8 fix); other
    /// `BackupPackageError`s surface as `.failed`; unknown errors get
    /// wrapped as `corruptedData` for triage.
    private func performImportAndReport(context: RestoreContext) async {
        do {
            let result: BackupImportResult
            switch context.source {
            case .localBackup(let backup):
                if backup.isIncomplete {
                    await MainActor.run { self.progress = .failed(.corruptedData("incomplete", .manifest)) }
                    return
                }
                result = try BackupPackage.importFromLocalBackup(
                    backup.id, store: context.store,
                    imagesDirectory: context.imagesDirectory,
                    defaults: context.defaults
                )
            case .externalFile(let url):
                result = try BackupPackage.importPackage(
                    from: url,
                    passphrase: context.passphrase,
                    store: context.store,
                    localCrypto: ServiceContainer.crypto,
                    imagesDirectory: context.imagesDirectory,
                    defaults: context.defaults
                )
            }
            await MainActor.run {
                self.result = result
                self.progress = .finished(result)
                self.step = .result
            }
        } catch BackupPackageError.wrongPassword {
            // Defensive TOCTOU: validateExternal should have caught this
            // first (F8 fix). If it reaches here (e.g., key changed
            // mid-session), route back to step 2 for password re-entry.
            await MainActor.run {
                self.progress = .idle
                self.validation = .wrongPassword
                self.step = .validate
            }
        } catch let err as BackupPackageError {
            await MainActor.run { self.progress = .failed(err) }
        } catch {
            await MainActor.run { self.progress = .failed(.corruptedData(error.localizedDescription, .manifest)) }
        }
    }

    func cancel() {
        loadTask?.cancel()
    }
}
