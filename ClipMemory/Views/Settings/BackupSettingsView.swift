import SwiftUI
import AppKit

/// Backup settings tab: auto-backup toggle, retention, manual backup,
/// open folder, and encrypted export/import.
///
/// Self-contained — export/import/passphrase logic moved here verbatim from
/// ContentView (lines 841-960 before the settings-window refactor) so the
/// settings window doesn't depend on ContentView callbacks.
struct BackupSettingsView: View {
    let backupService: BackupService

    @State private var backupRefresh = false

    var body: some View {
        Form {
            Section {
                Toggle(L10n.settingsBackupAuto, isOn: Binding(
                    get: { backupService.isEnabled },
                    set: { backupService.isEnabled = $0 }
                ))
                Picker(L10n.settingsBackupKeep, selection: Binding(
                    get: { backupService.keepCount },
                    set: { backupService.keepCount = $0 }
                )) {
                    // ID-L10N-0009 (2026-07-30 audit): use L10n plural for unit
                    // context (e.g. "3 backups" / "3 個備份" instead of bare "3").
                    ForEach([3, 7, 14, 30], id: \.self) { Text(L10n.settingsBackupKeepCount($0)).tag($0) }
                }
                Button(L10n.settingsBackupNow) {
                    // BUG-020 (2026-07-21): backupNow() does synchronous file
                    // IO — hop to a background queue and toggle the refresh
                    // signal on the main queue when done.
                    DispatchQueue.global(qos: .userInitiated).async {
                        // F-4 (2026-07-23 audit): surface failures via a real
                        // alert instead of a silent "Back Up Now" that did
                        // nothing.
                        do {
                            _ = try backupService.backupNow()
                            DispatchQueue.main.async { backupRefresh.toggle() }
                        } catch {
                            DispatchQueue.main.async { showBackupInfo(L10n.settingsBackupError) }
                        }
                    }
                }.buttonStyle(.link)
                Button(L10n.settingsBackupOpen) {
                    NSWorkspace.shared.open(backupService.backupsDirectoryURL)
                }.buttonStyle(.link)
                Button(L10n.settingsBackupExport) { exportBackup() }.buttonStyle(.link)
                Button(L10n.settingsBackupImport) { importBackup() }.buttonStyle(.link)
            } header: { Text(L10n.settingsSectionBackup) } footer: {
                // N-3 (2026-07-27): when the most recent attempt failed more
                // recently than the most recent success, surface the failure
                // in the footer. Otherwise show the last successful backup
                // time. A success clears the failure record, so manual "Back
                // Up Now" makes the footer flip back without an app restart.
                if let errorDate = backupService.lastBackupErrorDate,
                   (backupService.lastBackupDate ?? .distantPast) < errorDate,
                   let message = backupService.lastBackupErrorMessage {
                    Text(L10n.settingsBackupErrorLast(message))
                        .foregroundColor(.red)
                        .id(backupRefresh)
                } else if let last = backupService.lastBackupDate {
                    Text(L10n.settingsBackupLast(last.formatted(date: .abbreviated, time: .shortened)))
                        .foregroundColor(.secondary)
                        .id(backupRefresh)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Alerts

    private func showBackupInfo(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        alert.addButton(withTitle: L10n.buttonConfirm)
        alert.runModal()
    }

    /// Prompts for the backup passphrase (min 6 chars). Returns nil on cancel,
    /// or a valid passphrase on confirm. Loops with a warning if the user
    /// tries to confirm a too-short input (3.1, 2026-07-23 audit).
    private func promptBackupPassphrase() -> String? {
        while true {
            let alert = NSAlert()
            alert.messageText = L10n.settingsBackupPassphrase
            // H-2 (2026-07-23): explains the round-trip requirement so users
            // save the password somewhere recoverable.
            alert.informativeText = L10n.settingsBackupPassphraseInfo
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            alert.accessoryView = field
            alert.addButton(withTitle: L10n.buttonConfirm)
            alert.addButton(withTitle: L10n.buttonCancel)

            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            let value = field.stringValue
            if value.count >= 6 { return value }

            // 3.1 (2026-07-23 audit): short input re-prompts with an explicit
            // "Passphrase too short" warning instead of silently swallowing it.
            let warning = NSAlert()
            warning.messageText = L10n.passphraseTooShortTitle
            warning.informativeText = L10n.passphraseTooShortMessage
            warning.alertStyle = .warning
            warning.addButton(withTitle: L10n.buttonConfirm)
            warning.runModal()
        }
    }

    // MARK: - Export / Import

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "clipmemory")].compactMap { $0 }
        // ID-L10N-0008 (2026-07-30 audit): compose with L10n.appName so non-English
        // locales see "剪忆-backup.clipmemory" / "ClipMemory バックアップ" etc.
        panel.nameFieldStringValue = "\(L10n.appName)-backup.clipmemory"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let passphrase = promptBackupPassphrase() else { return }
        // H-3 (2026-07-23): a missing root encryption key gets a dedicated
        // message (reset encryption from Settings) rather than the generic
        // "operation failed".
        guard let keyData = CryptoService.loadKeyData() else {
            showBackupInfo(L10n.settingsBackupErrorMissingEncryptionKey)
            return
        }
        // Flush the 500ms debounce so the package includes the very latest items.
        ClipboardStore.shared.flushPendingSaves()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try BackupPackage.exportPackage(
                    to: url,
                    passphrase: passphrase,
                    imagesDirectory: ImageStorage.shared.imagesDirectoryURL,
                    keyData: keyData
                )
                DispatchQueue.main.async { showBackupInfo(L10n.settingsBackupExportDone) }
            } catch {
                DispatchQueue.main.async { showBackupInfo(L10n.settingsBackupError) }
            }
        }
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "clipmemory")].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let passphrase = promptBackupPassphrase() else { return }
        // Flush + safety snapshot of current data before mutating.
        ClipboardStore.shared.flushPendingSaves()
        // Heavy work (unzip, re-keying, image copies) off the main thread;
        // BackupPackage hops to main for the @Published merges itself.
        DispatchQueue.global(qos: .userInitiated).async {
            // M-2 (2026-07-23): pre-import safety snapshot is REQUIRED before
            // mutating user data. If it fails we must NOT proceed — silently
            // overwriting history with no rollback point is a data-loss bug.
            do {
                _ = try backupService.backupNow()
            } catch {
                DispatchQueue.main.async { showBackupInfo(L10n.settingsBackupError) }
                return
            }
            do {
                let result = try BackupPackage.importPackage(
                    from: url,
                    passphrase: passphrase,
                    store: ClipboardStore.shared,
                    localCrypto: ServiceContainer.crypto,
                    imagesDirectory: ImageStorage.shared.imagesDirectoryURL
                )
                DispatchQueue.main.async {
                    showBackupInfo(L10n.settingsBackupImportResult(
                        result.itemsImported,
                        result.itemsSkipped,
                        result.itemsSkippedCorrupt,
                        result.imagesImported
                    ))
                }
            } catch BackupPackageError.wrongPassword {
                DispatchQueue.main.async { showBackupInfo(L10n.settingsBackupPassphraseWrong) }
            } catch BackupPackageError.corruptedData {
                // Route corrupted-package errors to the generic 'operation
                // failed' notice so users recognize "file problem, not
                // password problem".
                DispatchQueue.main.async { showBackupInfo(L10n.settingsBackupError) }
            } catch {
                DispatchQueue.main.async { showBackupInfo(L10n.settingsBackupError) }
            }
        }
    }
}
