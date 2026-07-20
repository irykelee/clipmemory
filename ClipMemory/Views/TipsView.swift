import SwiftUI
import AppKit

struct TipsView: View {
    let onClose: () -> Void
    @ObservedObject private var languageManager = LanguageManager.shared

    /// Reads the live hotkey from AppDelegate's HotKeyManager so the tip
    /// stays in sync if the user rebinds it in settings. Falls back to the
    /// static default if AppDelegate isn't ready yet (e.g. on first launch).
    private var liveHotkeyDisplay: String {
        // H-1: hotKeyManager on AppDelegate is now optional — extra level of
        // optional chaining so a missing manager falls back to defaults instead
        // of crashing the view that triggered recomputation.
        (NSApp.delegate as? AppDelegate)?.hotKeyManager?.config.displayString
            ?? HotKeyConfig.defaultConfig.displayString
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.tipsTitle).font(.title2).fontWeight(.semibold)
                Spacer()
                Button(L10n.buttonClose) { onClose() }.buttonStyle(.plain).foregroundColor(.accentColor)
            }.padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Group {
                        // Quick Access
                        section(L10n.welcomeStep2Title) {
                            row(L10n.welcomeStep2Desc(liveHotkeyDisplay))
                            row("🖱 \(L10n.welcomeStep1Desc)")
                        }
                        // Item Operations
                        section(L10n.tipsActions) {
                            row("• \(L10n.welcomeStep4Desc)")
                            row("• \(L10n.welcomeStep5Desc)")
                        }
                        // Step 6: Manage History
                        section(L10n.settingsSectionHistory) {
                            row("• \(L10n.welcomeStep6Desc)")
                        }
                        // Keyboard
                        section(L10n.tipsKeyboard) {
                            row("↑↓ — \(L10n.quickbarRecent(8))")
                            row("⏎ — \(L10n.actionCopy)")
                            row("⎋ — \(L10n.buttonClose)")
                        }
                        // Unpin short
                        section(L10n.unpinAll) {
                            row("• \(L10n.unpinToday)")
                            row("• \(L10n.unpinYesterday)")
                            row("• \(L10n.unpinOlder)")
                            row("• \(L10n.unpinAll)")
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical)
            }
        }
        .frame(width: 460, height: 520)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline).foregroundColor(.accentColor).padding(.bottom, 2)
            content().font(.subheadline)
            Divider()
        }
    }

    private func row(_ text: String) -> some View {
        Text(text).foregroundColor(.secondary).padding(.leading, 8)
    }
}
