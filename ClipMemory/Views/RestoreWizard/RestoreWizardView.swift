import SwiftUI

struct RestoreWizardView: View {
    @ObservedObject var vm: RestoreWizardViewModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
            Divider()
            footer
        }
        .frame(width: 480, height: 600)
    }

    private var header: some View {
        HStack {
            Text(L10n.restoreWizardTitle)
                .font(.headline)
            Spacer()
            Text("\(vm.step.rawValue + 1) / \(WizardStep.allCases.count)")
                .foregroundColor(.secondary)
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        switch vm.step {
        case .selectSource: selectSourceStep
        case .validate: validateStep
        case .preview: previewStep
        case .confirmApply: confirmApplyStep
        case .result: resultStep
        }
    }

    @ViewBuilder
    private var selectSourceStep: some View {
        VStack(spacing: 16) {
            // Local backups section (empty fallback OR list).
            if vm.backups.isEmpty {
                emptyLocalList
            } else {
                localBackupList
            }
            // External file section (always shown — independent entry point).
            externalFileSection
        }
    }

    private var emptyLocalList: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text(L10n.restoreSourceLocalEmpty).font(.headline)
            Text(L10n.restoreSourceLocalEmptyHint)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
        }
    }

    private var localBackupList: some View {
        List(selection: Binding<LocalBackup?>(
            get: { nil },
            set: { if let b = $0 { vm.selectLocalBackup(b) } }
        )) {
            Section(L10n.restoreSourceLocal) {
                ForEach(vm.backups) { backup in
                    VStack(alignment: .leading) {
                        Text(backup.directoryName)
                        if backup.isIncomplete {
                            Text(L10n.restoreSourceLocalIncompleteTooltip)
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                    .disabled(backup.isIncomplete)
                    .help(backup.isIncomplete ? L10n.restoreSourceLocalIncompleteTooltip : "")
                    .tag(backup)
                }
            }
        }
        .frame(height: 280)
    }

    private var externalFileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text(L10n.restoreSourceExternal).font(.subheadline).foregroundColor(.secondary)
            Button(L10n.restoreSourceExternalPick) { openExternalFilePicker() }
                .buttonStyle(.bordered)
        }
    }

    private func openExternalFilePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "clipmemory")].compactMap { $0 }
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        vm.beginExternalValidation(url: url)
    }

    private var validateStep: some View {
        Group {
            switch vm.validation {
            case .pending:
                // External file picked, awaiting passphrase entry.
                externalPassphraseEntry
            case .validating:
                ProgressView()
            case .wrongPassword:
                // Wrong password — re-entry with same URL.
                VStack(spacing: 12) {
                    Text(L10n.restoreSourceExternalPasswordWrong).foregroundColor(.red)
                    externalPassphraseEntry
                }
            case .corrupted(let reason):
                Text(reason).foregroundColor(.red)
            case .valid, .incomplete:
                EmptyView()  // shouldn't reach here
            }
        }
    }

    /// Shared by `.pending` (first attempt) and `.wrongPassword` (retry).
    private var externalPassphraseEntry: some View {
        VStack(spacing: 12) {
            SecureField(L10n.restoreSourceExternalPassword, text: $vm.passphrase)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit(submitPassphrase)
            Button(L10n.buttonConfirm, action: submitPassphrase)
                .buttonStyle(.borderedProminent)
                .disabled(vm.passphrase.isEmpty)
        }
    }

    private func submitPassphrase() {
        guard case .externalFile(let url) = vm.source else { return }
        Task { await vm.validateExternal(url: url, passphrase: vm.passphrase) }
    }

    private var previewStep: some View {
        Group {
            if case .valid(let preview) = vm.validation {
                VStack(alignment: .leading, spacing: 8) {
                    Label("\(preview.itemsCount)", systemImage: "doc.on.doc")
                    Label("\(preview.tagsCount)", systemImage: "tag")
                    Label("\(preview.imagesCount)", systemImage: "photo")
                    Label(preview.createdAt.formatted(), systemImage: "clock")
                    if let v = preview.appVersion {
                        Label(v, systemImage: "app.badge")
                    }
                    ForEach(preview.warnings, id: \.self) { w in
                        Text(warningText(w)).foregroundColor(.orange)
                    }
                }
            } else {
                ProgressView()
            }
        }
    }

    private var confirmApplyStep: some View {
        VStack(spacing: 12) {
            switch vm.progress {
            case .idle:
                Text(L10n.restoreConfirmBody).multilineTextAlignment(.center)
            case .snapshotting:
                ProgressView(L10n.restoreProgressSnapshot)
            case .importing:
                ProgressView(L10n.restoreProgressImport)
            case .finished(let r):
                Text("\(r.itemsImported)").font(.largeTitle)
                Text(L10n.restoreResultTitle)
            case .failed(let err):
                Text(err.localizedDescription).foregroundColor(.red)
            }
        }
    }

    private var resultStep: some View {
        VStack(spacing: 12) {
            if let r = vm.result {
                Text(L10n.restoreResultBody)
                    .multilineTextAlignment(.center)
                if r.imageImportFailed {
                    Text(L10n.restoreResultImageFailed)
                        .foregroundColor(.orange)
                }
            }
            Button(L10n.restoreResultClose) { onClose() }
                .buttonStyle(.borderedProminent)
        }
    }

    private var footer: some View {
        HStack {
            Button(L10n.buttonCancel, role: .cancel) { vm.cancel(); onClose() }
                .keyboardShortcut(.escape)
            Spacer()
            if vm.step == .preview {
                Button(L10n.restoreConfirmApply) { vm.apply(); vm.step = .confirmApply }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }

    private func warningText(_ w: RestoreWarning) -> String {
        switch w {
        case .incompleteMarker: return L10n.restorePreviewWarningIncomplete
        case .missingEncryptionKey: return L10n.restoreErrorKeychain
        case .emptyContent: return L10n.restoreSourceLocalEmpty
        }
    }
}
