import SwiftUI

/// Tab identifiers for the independent settings window.
enum SettingsTab: String, CaseIterable {
    case general, history, backup, update
    var label: String {
        switch self {
        case .general: L10n.settingsTabGeneral
        case .history: L10n.settingsTabHistory
        case .backup:  L10n.settingsTabBackup
        case .update:  L10n.settingsTabUpdate
        }
    }
}

/// Root view for the independent settings window (2026-07-25 plan).
///
/// Presents a segmented tab bar at the top and swaps the content below.
/// Each tab is a self-contained subview that reads/writes through the
/// shared services (`ClipboardStore`, `BackupService`, `HotKeyManager`)
/// rather than going through ContentView callbacks.
struct SettingsRootView: View {
    let hotKeyManager: HotKeyManager?
    @ObservedObject var store: ClipboardStore
    let backupService: BackupService

    @State private var selectedTab: SettingsTab = .general
    @ObservedObject private var languageManager = LanguageManager.shared

    var body: some View {
        VStack(spacing: 0) {
            // Segmented tab bar
            Picker(selection: $selectedTab, label: EmptyView()) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Text(tab.label).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            // Tab content
            Group {
                switch selectedTab {
                case .general:
                    GeneralSettingsView(hotKeyManager: hotKeyManager)
                case .history:
                    HistoryCaptureSettingsView(store: store)
                case .backup:
                    BackupSettingsView(backupService: backupService)
                case .update:
                    UpdateAboutSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Re-render when language changes so all labels update.
        .id(languageManager.selectedLanguage)
    }
}
