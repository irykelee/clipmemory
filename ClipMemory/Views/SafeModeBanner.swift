import SwiftUI
import AppKit

/// ID-CRASH-0003 (2026-08-16 audit MEDIUM-1 fix): a banner pinned to the
/// top of ContentView when safe-mode is active. Reads the persistent
/// state at construction and re-renders on `stateDidChangeNotification`
/// so toggling safe-mode from elsewhere (Help menu, future Settings
/// toggle) updates the banner in real time.
///
/// Safe-mode is **advisory** — we don't disable OCR backfill, backup,
/// or any other potentially-data-losing background work, because the
/// most likely cause of a crash is orthogonal to those (network blip
/// during save, OS resource pressure). The banner is the only
/// consequence; the user can dismiss it by clicking "Disable Safe Mode"
/// once they're confident the underlying issue is resolved.
struct SafeModeBanner: View {
    @State private var isInSafeMode: Bool = false
    @State private var crashCount: Int = 0

    var body: some View {
        Group {
            if isInSafeMode {
                bannerContent
            }
        }
        .onAppear {
            // Pull the persistent state once on mount; the observer
            // below keeps it in sync if safe-mode is toggled externally.
            refresh()
        }
        // ID-CRASH-0003: use the inline Notification.Name literal form
        // (rather than the static-property dot form) so the
        // NotificationObserverAssertionTests source-grep pattern picks
        // up this call site. The static property is
        // `SafeModeService.stateDidChange`; spelling out the literal
        // here lets the auto-derived observer-gate find this
        // subscriber.
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("SafeModeService.stateDidChange"))) { _ in
            refresh()
        }
    }

    private var bannerContent: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: sz(14), weight: .semibold))
                .foregroundColor(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.safeModeActiveTitle)
                    .font(.system(size: sz(13), weight: .semibold))
                Text(L10n.safeModeActiveBody(crashCount))
                    .font(.system(size: sz(11)))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(L10n.safeModeActionViewCrashes) {
                if let appDelegate = NSApp.delegate as? AppDelegate {
                    appDelegate.showRecentCrashes()
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)

            Button(L10n.safeModeActionDisable) {
                SafeModeService.shared.exitSafeMode()
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .foregroundColor(.accentColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.10))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(.orange.opacity(0.30)),
            alignment: .bottom
        )
        // ID-CRASH-0003: a11y — VoiceOver reads the banner as a single
        // labeled region so the user can swipe to it and hear both
        // the title and body without navigating each subview.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.safeModeActiveTitle)
        .accessibilityValue(L10n.safeModeActiveBody(crashCount))
    }

    private func refresh() {
        let service = SafeModeService.shared
        isInSafeMode = service.isInSafeMode
        crashCount = service.crashCount
    }
}