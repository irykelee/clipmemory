import SwiftUI
import AppKit
import ServiceManagement

/// Settings page extracted from ContentView (NEW-7 Phase 2).
///
/// Originally lived as `ContentView.settingsDetail` (lines 893-1039 of
/// ContentView.swift before this refactor). Extracted into a standalone
/// view to reduce ContentView's 1336-line file size; the surrounding
/// ContentView passes bindings and callbacks to keep behavior identical.
///
/// State ownership:
/// - **Local `@State`**: `hotkeyRefresh`, `backupRefresh` — only used
///   inside this view to force SwiftUI re-render after hotkey reset or
///   backup completion. Moved out of ContentView.
/// - **Local `@AppStorage`**: `fontScale` — only this view's font-size
///   picker writes it. Moved out of ContentView.
/// - **Injected `@Binding`**: state that other parts of ContentView also
///   touch (`themeAppearance`, `isRecordingHotKey`, `showingAppPicker`,
///   `showingTips`, `pendingMaxItemsReduction`).
/// - **Injected callbacks**: actions that need ContentView's
///   helper-function context (e.g. `startRecording` uses
///   `keyEventMonitor`, `exportBackup`/`importBackup` prompt for a
///   passphrase and toggle sheets, etc.).
struct SettingsView: View {
    @ObservedObject var languageManager: LanguageManager
    @Binding var themeAppearance: String
    @Binding var isRecordingHotKey: Bool
    @Binding var showingAppPicker: Bool
    @Binding var showingTips: Bool
    @Binding var pendingMaxItemsReduction: (old: Int, new: Int)?

    @AppStorage("fontScale") private var fontScale: Double = 1.0
    @State private var hotkeyRefresh = false
    @State private var backupRefresh = false

    let hotKeyManager: HotKeyManager?
    @ObservedObject var store: ClipboardStore
    let backupService: BackupService

    let onApplyAppearance: () -> Void
    let onExportBackup: () -> Void
    let onImportBackup: () -> Void
    let onShowLaunchAtLoginError: () -> Void
    let onShowWelcomeGuide: () -> Void
    let onStartHotKeyRecording: () -> Void

    var body: some View {
        Form {
            if let hk = hotKeyManager {
                Section {
                    HStack {
                        if isRecordingHotKey {
                            Text(L10n.settingsHotkeyRecording).foregroundColor(.orange)
                            Spacer()
                            Button(L10n.buttonCancel) { isRecordingHotKey = false }.buttonStyle(.link)
                        } else {
                            Text(hk.config.displayString).fontDesign(.monospaced).id(hotkeyRefresh)
                            Spacer()
                            Button(L10n.settingsHotkeyChange) { onStartHotKeyRecording() }.buttonStyle(.link)
                        }
                    }
                    Button(L10n.settingsHotkeyReset) {
                        hk.updateHotKey(keyCode: HotKeyConfig.defaultConfig.keyCode, modifiers: HotKeyConfig.defaultConfig.modifiers)
                        hotkeyRefresh.toggle()
                    }.buttonStyle(.link)
                } header: { Text(L10n.settingsSectionHotkey) }
            }
            Section {
                Picker(L10n.themeAppearance, selection: Binding(get: { themeAppearance }, set: { themeAppearance = $0; onApplyAppearance() })) {
                    Text(L10n.themeAppearanceSystem).tag("system"); Text(L10n.themeAppearanceLight).tag("light"); Text(L10n.themeAppearanceDark).tag("dark")
                }
            } header: { Text(L10n.settingsSectionTheme) }
            Section {
                Picker(L10n.settingsSectionLanguage, selection: $languageManager.selectedLanguage) { ForEach(languageManager.availableLanguages, id: \.code) { Text($0.name).tag($0.code) } }
            } header: { Text(L10n.settingsSectionLanguage) }
            Section {
                Picker(L10n.string("settings.font.picker"), selection: $fontScale) { Text(L10n.fontSizeSmall).tag(1.0); Text(L10n.fontSizeMedium).tag(1.2); Text(L10n.fontSizeLarge).tag(1.4) }
            } header: { Text(L10n.settingsFontSize) }
            Section {
                Picker(L10n.settingsAutoClear, selection: $store.sensitiveClearHours) { ForEach(SensitiveClearOption.options) { Text($0.label).tag($0.hours) } }.id(languageManager.selectedLanguage)
            } header: { Text(L10n.settingsSectionSensitive) } footer: { Text(L10n.settingsSensitiveHint).foregroundColor(.secondary) }
            Section {
                Picker(L10n.settingsMaxItems, selection: Binding(get: { store.maxItems }, set: { newValue in
                    if newValue < store.maxItems, store.items.count > newValue {
                        pendingMaxItemsReduction = (old: store.maxItems, new: newValue)
                    } else {
                        store.maxItems = newValue
                    }
                })) { ForEach([50, 100, 200, 500], id: \.self) { Text(L10n.settingsMaxItemsCount($0)).tag($0) } }.id(languageManager.selectedLanguage)
            } header: { Text(L10n.settingsSectionHistory) }
            Section {
                Picker(L10n.trashRetentionDays, selection: $store.trashRetentionDays) { ForEach([3, 7, 14, 30], id: \.self) { Text("\($0)").tag($0) } }
            }
            Section {
                Toggle(L10n.settingsCaptureRichText, isOn: $store.captureRichText)
            } footer: { Text(L10n.settingsCaptureRichTextHint).foregroundColor(.secondary) }
            Section {
                Toggle(L10n.settingsOcrEnabled, isOn: Binding(
                    get: { store.ocrEnabled },
                    set: { store.ocrEnabled = $0 }
                ))
            } footer: { Text(L10n.settingsOcrHint).foregroundColor(.secondary) }
            Section {
                excludedAppsTags
                Button(action: { showingAppPicker = true }, label: { Label(L10n.settingsAddExcludedApp, systemImage: "plus.circle") }).buttonStyle(.link)
            } header: { Text(L10n.settingsSectionExcludedApps) }
            Section {
                Toggle(L10n.launchAtLogin, isOn: Binding(get: { SMAppService.mainApp.status == .enabled }, set: { v in
                    do { if v { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { onShowLaunchAtLoginError() }
                }))
            }
            Section {
                Toggle(L10n.settingsBackupAuto, isOn: Binding(
                    get: { backupService.isEnabled },
                    set: { backupService.isEnabled = $0 }
                ))
                Picker(L10n.settingsBackupKeep, selection: Binding(
                    get: { backupService.keepCount },
                    set: { backupService.keepCount = $0 }
                )) { ForEach([3, 7, 14, 30], id: \.self) { Text("\($0)").tag($0) } }
                Button(L10n.settingsBackupNow) {
                    // BUG-020 (2026-07-21 partial): backupNow() does
                    // synchronous file IO. The auto-backup path already wraps
                    // the call in DispatchQueue.global — only this UI button
                    // was missing it. Hop to a background queue and toggle
                    // the refresh signal on the main queue when done.
                    DispatchQueue.global(qos: .userInitiated).async {
                        _ = backupService.backupNow()
                        DispatchQueue.main.async {
                            backupRefresh.toggle()
                        }
                    }
                }.buttonStyle(.link)
                Button(L10n.settingsBackupOpen) {
                    NSWorkspace.shared.open(backupService.backupsDirectoryURL)
                }.buttonStyle(.link)
                Button(L10n.settingsBackupExport) { onExportBackup() }.buttonStyle(.link)
                Button(L10n.settingsBackupImport) { onImportBackup() }.buttonStyle(.link)
            } header: { Text(L10n.settingsSectionBackup) } footer: {
                if let last = backupService.lastBackupDate {
                    Text(L10n.settingsBackupLast(last.formatted(date: .abbreviated, time: .shortened))).foregroundColor(.secondary)
                        .id(backupRefresh)
                }
            }
            Section {
                Toggle(L10n.settingsUpdateAuto, isOn: Binding(
                    get: { UpdateService.shared.automaticallyChecksForUpdates },
                    set: { UpdateService.shared.automaticallyChecksForUpdates = $0 }
                ))
                Button(L10n.settingsUpdateCheckNow) { UpdateService.shared.checkNow() }.buttonStyle(.link)
            } header: { Text(L10n.settingsSectionUpdate) } footer: {
                if let lastCheck = UpdateService.shared.lastUpdateCheckDate {
                    Text(L10n.settingsUpdateLastCheck(lastCheck.formatted(date: .abbreviated, time: .shortened))).foregroundColor(.secondary)
                }
            }
            Section(L10n.settingsUpdateSourceTitle) {
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
            }
            Section {
                Text(L10n.aboutVersion(AppVersion.current)).foregroundColor(.secondary)
                Text(L10n.aboutFreeEdition).foregroundColor(.secondary)
                Button(L10n.sendFeedback) {
                    // NEW-4 (2026-07-21): the literal URL is safe to force-unwrap,
                    // but `if let` keeps the codebase free of `!` and signals
                    // intent to future readers.
                    if let url = URL(string: "https://github.com/irykelee/clipmemory/issues/new") {
                        NSWorkspace.shared.open(url)
                    }
                }.buttonStyle(.link)
                Button(L10n.viewWelcomeGuide) { onShowWelcomeGuide() }.buttonStyle(.link)
                Button(L10n.tipsTitle) { showingTips = true }.buttonStyle(.link)
            } header: { Text(L10n.settingsSectionAbout) }
        }
        .formStyle(.grouped)
    }

    /// Local copy of `ContentView.excludedAppsTags` (lines 1132-1173 before
    /// this refactor). Reads `store.excludedBundleIdsString` and renders
    /// one chip per excluded app with an `x` to remove.
    private var excludedAppsTags: some View {
        let rawIds = store.excludedBundleIdsString
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        let excludedIds = rawIds.filter { seen.insert($0).inserted }
        if excludedIds.isEmpty {
            return AnyView(EmptyView())
        }
        let apps: [(name: String, bundleId: String)] = excludedIds.compactMap { bundleId in
            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }) {
                return (app.localizedName ?? bundleId, bundleId)
            }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                return (url.deletingPathExtension().lastPathComponent, bundleId)
            }
            return nil
        }
        return AnyView(
            FlowLayout(spacing: 6) {
                ForEach(apps, id: \.bundleId) { app in
                    HStack(spacing: 4) {
                        Text(app.name).font(.system(size: sz(11)))
                        Button(action: {
                            let newIds = excludedIds.filter { $0 != app.bundleId }
                            store.excludedBundleIdsString = newIds.joined(separator: ",")
                        }, label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: sz(10)))
                                .foregroundColor(.secondary)
                        })
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(6)
                }
            }
        )
    }
}