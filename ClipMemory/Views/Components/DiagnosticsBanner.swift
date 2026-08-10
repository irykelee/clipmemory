import SwiftUI

/// P0-2: search-path decryption failure banner. Shows one of two states:
/// - keyUnavailable: "Try again after unlock" (transient, self-healing)
/// - dataCorrupted: "N items corrupted" (permanent, dismissible)
struct DiagnosticsBanner: View {
    let diagnostics: DecryptionDiagnostics
    let onDismiss: () -> Void

    var body: some View {
        if let text = displayText, !diagnostics.dismissed {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(diagnostics.keyUnavailable ? .orange : .red)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.primary)
                Spacer()
                CloseButton(action: onDismiss)
                    // ID-L10N-0019 (2026-07-31 audit): tooltip was bound to the
                    // "Confirm" key — this button dismisses the banner, so it
                    // must read "Close" in every language.
                    .help(L10n.buttonClose)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 8)
        }
    }

    private var displayText: String? {
        if diagnostics.keyUnavailable { return L10n.bannerKeyUnavailable }
        if diagnostics.totalCorruptedCount > 0 {
            return L10n.bannerDataCorruptedCount(diagnostics.totalCorruptedCount)
        }
        return nil
    }

    private var icon: String {
        diagnostics.keyUnavailable ? "lock.fill" : "exclamationmark.triangle.fill"
    }
}
