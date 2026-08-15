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
                // C2 (v2.7.9): "current vs latest" version line so the user
                // can tell at a glance whether they're on the latest release.
                // nil `latestAvailableVersion` → neutral state (only the
                // current version is shown, never a green "up to date"
                // claim without evidence from a real appcast fetch).
                VersionStatusLine(current: AppVersion.current, latest: UpdateService.shared.status.latestAvailableVersion)
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
                        case .gitee:     Text(L10n.settingsUpdateSourceOptionGitee).tag(policy)
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
            footer: { Text(L10n.settingsPrivacyNoTelemetry).foregroundColor(.secondary) }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingTips) {
            TipsView(onClose: { showingTips = false })
        }
    }
}

/// C2 (v2.7.9): three-state version line for the Update tab.
///
/// - `latest == nil`: never been probed yet (or the parse returned empty).
///   Shows ONLY the current version — no "up to date" claim, because we
///   have no evidence backing it. Prevents "false green" before the first
///   appcast fetch lands.
/// - `latest == current`: Sparkle convention says newest item is first in
///   the appcast; equality is sufficient because `AppVersion.current`
///   (CFBundleShortVersionString) and `<sparkle:shortVersionString>` use
///   the same format (no `v` prefix, dotted numbers).
/// - `latest != current`: an update is available.
private struct VersionStatusLine: View {
    let current: String
    let latest: String?

    var body: some View {
        if let latest {
            Text(L10n.settingsUpdateStatusLine(
                current,
                latest,
                latest == current
                    ? L10n.settingsUpdateStatusUpToDate
                    : L10n.settingsUpdateStatusOutOfDate
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            // Neutral state: only the current version, no status phrase.
            // AppVersion.current already includes the leading "v" via the
            // localized format string convention used elsewhere ("About"
            // section renders "v2.7.8" through L10n.aboutVersion).
            Text("v\(current)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
