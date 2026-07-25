import SwiftUI
import AppKit
import ServiceManagement
import Carbon.HIToolbox

/// General settings tab: hotkey, launch-at-login, language, appearance.
///
/// Self-contained — hotkey recording uses its own NSEvent monitor rather
/// than going through ContentView's keyEventMonitor.
struct GeneralSettingsView: View {
    let hotKeyManager: HotKeyManager?

    @AppStorage("themeAppearance") private var themeAppearance = "system"
    @AppStorage("fontScale") private var fontScale: Double = 1.0
    @ObservedObject private var languageManager = LanguageManager.shared

    @State private var hotkeyRefresh = false
    @State private var isRecordingHotKey = false
    @State private var keyEventMonitor: Any?
    @State private var launchAtLoginEnabled: Bool = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            // Hotkey
            if let hk = hotKeyManager {
                Section {
                    HStack {
                        if isRecordingHotKey {
                            Text(L10n.settingsHotkeyRecording).foregroundColor(.orange)
                            Spacer()
                            Button(L10n.buttonCancel) {
                                isRecordingHotKey = false
                                stopKeyEventMonitor()
                            }.buttonStyle(.link)
                        } else {
                            Text(hk.config.displayString).fontDesign(.monospaced).id(hotkeyRefresh)
                            Spacer()
                            Button(L10n.settingsHotkeyChange) { startRecording() }.buttonStyle(.link)
                        }
                    }
                    Button(L10n.settingsHotkeyReset) {
                        hk.updateHotKey(keyCode: HotKeyConfig.defaultConfig.keyCode, modifiers: HotKeyConfig.defaultConfig.modifiers)
                        hotkeyRefresh.toggle()
                    }.buttonStyle(.link)
                } header: { Text(L10n.settingsSectionHotkey) }
            }

            // Launch at login
            Section {
                Toggle(L10n.launchAtLogin, isOn: Binding(
                    get: { launchAtLoginEnabled },
                    set: { v in
                        do {
                            if v { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                            launchAtLoginEnabled = v
                        } catch {
                            showLaunchAtLoginError()
                        }
                    }
                ))
            }

            // Language
            Section {
                Picker(L10n.settingsSectionLanguage, selection: $languageManager.selectedLanguage) {
                    ForEach(languageManager.availableLanguages, id: \.code) { Text($0.name).tag($0.code) }
                }
            } header: { Text(L10n.settingsSectionLanguage) }

            // Appearance
            Section {
                Picker(L10n.themeAppearance, selection: $themeAppearance) {
                    Text(L10n.themeAppearanceSystem).tag("system")
                    Text(L10n.themeAppearanceLight).tag("light")
                    Text(L10n.themeAppearanceDark).tag("dark")
                }
                .onChange(of: themeAppearance) { _ in applyAppearance() }
                Picker(L10n.string("settings.font.picker"), selection: $fontScale) {
                    Text(L10n.fontSizeSmall).tag(1.0)
                    Text(L10n.fontSizeMedium).tag(1.2)
                    Text(L10n.fontSizeLarge).tag(1.4)
                }
            } header: { Text(L10n.settingsSectionTheme) }
        }
        .formStyle(.grouped)
        .onAppear { refreshLaunchAtLogin() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLaunchAtLogin()
        }
        .onDisappear { stopKeyEventMonitor() }
    }

    // MARK: - Hotkey Recording

    private func startRecording() {
        isRecordingHotKey = true
        stopKeyEventMonitor()
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isRecordingHotKey else { return event }
            if event.keyCode == 53 { // Esc
                isRecordingHotKey = false
                stopKeyEventMonitor()
                return event
            }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !mods.isEmpty else { return nil }
            let keyCode = UInt32(event.keyCode)
            var modifiers: UInt32 = 0
            if mods.contains(.command) { modifiers |= UInt32(cmdKey) }
            if mods.contains(.control) { modifiers |= UInt32(controlKey) }
            if mods.contains(.option) { modifiers |= UInt32(optionKey) }
            if mods.contains(.shift) { modifiers |= UInt32(shiftKey) }
            isRecordingHotKey = false
            stopKeyEventMonitor()
            hotKeyManager?.updateHotKey(keyCode: keyCode, modifiers: modifiers)
            return nil
        }
    }

    private func stopKeyEventMonitor() {
        if let m = keyEventMonitor { NSEvent.removeMonitor(m); keyEventMonitor = nil }
    }

    // MARK: - Launch at Login

    private func refreshLaunchAtLogin() {
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    private func showLaunchAtLoginError() {
        let alert = NSAlert()
        alert.messageText = L10n.error
        alert.informativeText = L10n.settingsLaunchAtLoginErrorBody
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.buttonConfirm)
        alert.runModal()
    }

    // MARK: - Appearance

    private func applyAppearance() {
        switch themeAppearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}
