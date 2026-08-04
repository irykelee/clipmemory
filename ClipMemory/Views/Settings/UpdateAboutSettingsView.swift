import SwiftUI
import AppKit

/// Update & About settings tab: auto-update, update-source policy, and the
/// about section (version, feedback, welcome guide, tips).
///
/// No injected dependencies — reads/writes through the shared singletons
/// (`UpdateService.shared`, `AppDelegate`).
struct UpdateAboutSettingsView: View {
    @State private var showingTips = false

    var body: some View {
        Form {
            // Auto update
            Section {
                Toggle(L10n.settingsUpdateAuto, isOn: Binding(
                    get: { UpdateService.shared.automaticallyChecksForUpdates },
                    set: { UpdateService.shared.automaticallyChecksForUpdates = $0 }
                ))
                Button(L10n.settingsUpdateCheckNow) { UpdateService.shared.checkNow() }.buttonStyle(.link)
            } header: { Text(L10n.settingsSectionUpdate) } footer: {
                if let lastCheck = UpdateService.shared.lastUpdateCheckDate {
                    Text(L10n.settingsUpdateLastCheck(lastCheck.formatted(date: .abbreviated, time: .shortened)))
                        .foregroundColor(.secondary)
                }
            }

            // Update source
            Section {
                Picker(L10n.settingsUpdateSourceTitle, selection: Binding(
                    get: { UpdateService.feedPolicy },
                    set: { newPolicy in UpdateService.shared.setPolicy(newPolicy) }
                )) {
                    ForEach(UpdateFeedPolicy.allCases, id: \.self) { policy in
                        switch policy {
                        case .automatic: Text(L10n.settingsUpdateSourceOptionAutomatic).tag(policy)
                        case .primary:   Text(L10n.settingsUpdateSourceOptionPrimary).tag(policy)
                        case .fallback:  Text(L10n.settingsUpdateSourceOptionFallback).tag(policy)
                        }
                    }
                }.pickerStyle(.segmented)
                UpdateStatusPanelView().environmentObject(UpdateService.shared.status)
            } header: { Text(L10n.settingsUpdateSourceTitle) }
            footer: { Text(L10n.settingsUpdateSourceFooter).foregroundColor(.secondary) }

            // About
            Section {
                Text(L10n.aboutVersion(AppVersion.current)).foregroundColor(.secondary)
                Text(L10n.aboutFreeEdition).foregroundColor(.secondary)
                Button(L10n.sendFeedback) {
                    // NEW-4 (2026-07-21): `if let` keeps the codebase free of `!`.
                    if let url = URL(string: "https://github.com/irykelee/clipmemory/issues/new") {
                        NSWorkspace.shared.open(url)
                    }
                }.buttonStyle(.link)
                Button(L10n.viewWelcomeGuide) {
                    (NSApp.delegate as? AppDelegate)?.showWelcomeView()
                }.buttonStyle(.link)
                Button(L10n.tipsTitle) { showingTips = true }.buttonStyle(.link)
            } header: { Text(L10n.settingsSectionAbout) }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingTips) {
            TipsView(onClose: { showingTips = false })
        }
    }
}
