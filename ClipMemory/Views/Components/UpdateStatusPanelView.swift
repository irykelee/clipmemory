import SwiftUI

struct UpdateStatusPanelView: View {
    @EnvironmentObject var status: UpdateStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.string("settings.updateSource.statusPanel",
                            Self.sourceLabel(status.currentSource),
                            formatted(status.lastCheck),
                            Self.reasonLabel(status.lastSwitchReason)))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // UPD-3 (2026-07-24 review): the panel used to interpolate the raw
    // channel id and ProbeReason rawValue straight into user-visible text
    // ("Source: github-release · ... · Last switch: automaticReachable").
    // Map both through L10n; fall back to the raw value only for ids the
    // channel table doesn't know (future channels, stale persisted state).
    static func sourceLabel(_ channelID: String) -> String {
        guard let channel = UpdateFeedPolicies.knownChannels.first(where: { $0.id == channelID }) else {
            return channelID
        }
        return L10n.string(channel.labelKey)
    }

    static func reasonLabel(_ rawValue: String?) -> String {
        guard let rawValue, let reason = ProbeReason(rawValue: rawValue) else { return "—" }
        return L10n.string(reason.labelKey)
    }

    // F-25 (2026-07-23 audit): DateFormatter is expensive to construct
    // (locale + calendar + format pattern lookups). The previous
    // implementation allocated a new one on every body re-render, and
    // `body` re-runs on every @Published change in `UpdateStatus`. Cache
    // a single static instance — safe because SwiftUI body always runs
    // on the main thread, and this is only ever called from body.
    // ID-L10N-0017 (2026-07-30 audit): the static formatter was created
    // with `.current` system locale, not the user's in-app `LanguageManager`
    // selection. Surrounding L10n.string text switches when the user
    // changes language, but the date stays in the system locale → mixed-
    // language status line. Re-create the formatter on each call using
    // `LanguageManager.shared.selectedLanguage` so language changes take
    // effect (the F-25 cache concern was per-body, and a single
    // DateFormatter is cheap once the locale is set).
    private static func dateFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        f.locale = Locale(identifier: LanguageManager.shared.selectedLanguage)
        return f
    }

    private func formatted(_ date: Date?) -> String {
        guard let date else { return "—" }
        return Self.dateFormatter().string(from: date)
    }
}