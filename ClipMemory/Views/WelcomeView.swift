import SwiftUI

struct WelcomeView: View {
    let hotKeyManager: HotKeyManager
    let onComplete: () -> Void

    @State private var hotKeyConflictDetected = false
    @State private var hotKeyStatus: HotKeyStatus = .checking

    enum HotKeyStatus {
        case checking
        case success
        case conflict
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: 64))
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
                InstructionRow(
                    number: "1",
                    icon: "menubar.rectangle",
                    title: L10n.welcomeStep1Title,
                    description: L10n.welcomeStep1Desc
                )

                InstructionRow(
                    number: "2",
                    icon: "keyboard",
                    title: L10n.welcomeStep2Title,
                    description: L10n.welcomeStep2Desc(hotKeyManager.config.displayString)
                )

                InstructionRow(
                    number: "3",
                    icon: "star",
                    title: L10n.welcomeStep3Title,
                    description: L10n.welcomeStep3Desc
                )
            }
            .padding()
            .background(Color(.textBackgroundColor))
            .cornerRadius(12)

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
                .cornerRadius(8)
            }

            Spacer()

            VStack(spacing: 12) {
                Button(action: {
                    FirstLaunchManager.markLaunched()
                    onComplete()
                }) {
                    Text(L10n.welcomeGetStarted)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
        }
        .padding()
        .frame(width: 420, height: 560)
        .onAppear {
            checkHotKeyConflict()
        }
    }

    private func checkHotKeyConflict() {
        hotKeyStatus = .checking
        // Register hotkey and check if it succeeded
        hotKeyManager.register()
        if hotKeyManager.hotKeyRef == nil {
            hotKeyConflictDetected = true
            hotKeyStatus = .conflict
        } else {
            hotKeyConflictDetected = false
            hotKeyStatus = .success
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
