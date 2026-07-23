import SwiftUI

struct WelcomeView: View {
    let hotKeyManager: HotKeyManager
    let onComplete: () -> Void

    @ObservedObject private var languageManager = LanguageManager.shared
    @State private var hotKeyConflictDetected = false
    @State private var hotKeyStatus: HotKeyStatus = .checking

    enum HotKeyStatus {
        case checking
        case success
        case conflict
    }

    @ViewBuilder
    private var getStartedButton: some View {
        let base = Button(action: {
            FirstLaunchManager.markLaunched()
            onComplete()
        }, label: {
            Text(L10n.welcomeGetStarted)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
        })
        .buttonStyle(.borderedProminent)
        // F-10 (2026-07-23 audit): Enter on the Welcome sheet did nothing
        // because the button had no keyboard shortcut. SwiftUI's
        // `.keyboardShortcut(.defaultAction)` binds Enter globally to the
        // view (no focus required), which is the macOS-standard behavior
        // for a primary action button in a modal sheet.
        .keyboardShortcut(.defaultAction)
        if #available(macOS 14.0, *) {
            base.buttonBorderShape(.capsule)
        } else {
            base
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    Spacer(minLength: 16)

                    Image(systemName: "doc.on.clipboard.fill")
                        .font(.system(size: sz(64)))
                        .foregroundColor(.accentColor)

                    Text(L10n.welcomeTitle)
                        .font(.title)
                        .fontWeight(.bold)

                    Text(L10n.welcomeSubtitle)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    VStack(alignment: .leading, spacing: 16) {
                        InstructionRow(number: "1", icon: "menubar.rectangle", title: L10n.welcomeStep1Title, description: L10n.welcomeStep1Desc)
                        InstructionRow(number: "2", icon: "keyboard", title: L10n.welcomeStep2Title, description: L10n.welcomeStep2Desc(hotKeyManager.config.displayString))
                        InstructionRow(number: "3", icon: "star", title: L10n.welcomeStep3Title, description: L10n.welcomeStep3Desc)
                        InstructionRow(number: "4", icon: "cursorarrow.click.2", title: L10n.welcomeStep4Title, description: L10n.welcomeStep4Desc)
                        InstructionRow(number: "5", icon: "hand.tap", title: L10n.welcomeStep5Title, description: L10n.welcomeStep5Desc)
                        InstructionRow(number: "6", icon: "trash", title: L10n.welcomeStep6Title, description: L10n.welcomeStep6Desc)
                    }
                    .padding()
                    .background(Color(.textBackgroundColor))
                    .cornerRadius(appCornerRadius)

                    if hotKeyConflictDetected {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text(L10n.welcomeHotkeyConflict)
                                .font(.callout)
                                .foregroundColor(.orange)
                        }
                        .padding()
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(appCornerRadius)
                    }

                    Spacer(minLength: 16)
                }
                .padding()
            }

            Divider()

            getStartedButton
                .padding()
        }
        .frame(width: 420)
        .onAppear { checkHotKeyConflict() }
    }

    private func checkHotKeyConflict() {
        hotKeyStatus = .checking
        // Read-only status check: AppDelegate already attempted registration at
        // launch. Calling register() here re-registered (and logged an error)
        // on every onAppear — that was the -9878 log spam.
        if hotKeyManager.hotKeyRef != nil {
            hotKeyConflictDetected = false
            hotKeyStatus = .success
        } else if hotKeyManager.registerAttempted {
            hotKeyConflictDetected = true
            hotKeyStatus = .conflict
        } else {
            // No attempt yet (shouldn't happen in practice) — treat as checking.
            hotKeyConflictDetected = false
        }
    }
}

struct InstructionRow: View {
    let number: String
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 28, height: 28)
                Text(number)
                    .font(.callout)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.callout)
                        .foregroundColor(.accentColor)
                    Text(title)
                        .font(.callout)
                        .fontWeight(.semibold)
                }
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

/// Manages first launch state
class FirstLaunchManager {
    static let hasLaunchedKey = "hasLaunchedBefore"

    static var isFirstLaunch: Bool {
        !UserDefaults.standard.bool(forKey: hasLaunchedKey)
    }

    static func markLaunched() {
        UserDefaults.standard.set(true, forKey: hasLaunchedKey)
    }
}
