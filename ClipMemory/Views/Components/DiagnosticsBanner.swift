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
        // ID-CRASH-0008 (2026-09-28 code-review P1-3): the user's
        // tag sidebar can empty silently when `loadTags()` fails.
        // Surface it on the same banner UI as keyUnavailable /
        // dataCorruptedCount so a failed tags-load gets the same
        // visibility as other persistence failures.
        // ID-REVIEW-1027 (2026-11-12): the local SQLite store. It sits
        // ABOVE the tags-load failure because it is the more structural
        // problem: the store is the substrate the next release switches
        // to, and a user who never learns it is broken learns it at the
        // worst possible moment.
        //
        // (ID-REVIEW-1027 round 2, P3-1: the comment above used to say
        // "ABOVE" while the code checked the tags failure FIRST - the
        // banner the user saw was the tags one, and the storage one was
        // never shown. The ORDER now matches the comment.)
        if let issue = diagnostics.storageMirrorIssue {
            switch issue {
            case .fromNewerBuild: return L10n.bannerStorageNewerBuild
            case .diverged: return L10n.bannerStorageDiverged
            case .unavailable: return L10n.bannerStorageUnavailable
            }
        }
        if diagnostics.tagsLoadFailed { return L10n.bannerTagsLoadFailed }
        if diagnostics.totalCorruptedCount > 0 {
            return L10n.bannerDataCorruptedCount(diagnostics.totalCorruptedCount)
        }
        return nil
    }

    private var icon: String {
        diagnostics.keyUnavailable ? "lock.fill" : "exclamationmark.triangle.fill"
    }
}
