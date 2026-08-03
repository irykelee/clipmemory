import SwiftUI

// MARK: - Brand Logo
struct LogoView: View {
    @ObservedObject private var languageManager = LanguageManager.shared

    // ID-VIEW-0017 (2026-08-03, user-driven): the logo moved from the
    // sidebar header into the window toolbar. In the sidebar it should
    // span the column width (`.frame(maxWidth: .infinity)`); inside a
    // ToolbarItem it must NOT — it should hug its content and sit on the
    // leading edge. `expandWidth` selects the behavior at the call site.
    var expandWidth: Bool = true

    /// True when appName contains both Chinese and English (zh-Hans / zh-Hant)
    private var isBilingual: Bool {
        let name = L10n.appName
        return name.contains(" ClipMemory") && !name.hasPrefix("ClipMemory")
    }

    /// Chinese name extracted from appName (e.g. "剪忆" from "剪忆 ClipMemory")
    private var chineseName: String {
        let full = L10n.appName
        if let range = full.range(of: " ClipMemory") {
            return String(full[..<range.lowerBound])
        }
        return full
    }

    var body: some View {
        if isBilingual {
            // Chinese + English on one line: "剪忆 ClipMemory"
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(chineseName)
                    // ID-A11Y-0003 (2026-07-30 audit): route through `sz()`
                    // so Settings → Font Size (small/medium/large) actually
                    // applies to the brand logo in the welcome window.
                    .font(.system(size: sz(20), weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                Text("ClipMemory")
                    // ID-VIEW-0021 (2026-08-03, user-driven): English part
                    // bumped sz(11) → sz(14) — it read too small next to the
                    // sz(20) Chinese name.
                    .font(.system(size: sz(14), weight: .medium))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: expandWidth ? .infinity : nil)
            .padding(.vertical, 4)
            .accessibilityLabel(L10n.appName)
        } else {
            // Single name (English, Japanese, Korean, etc.)
            Text(L10n.appName)
                .font(.system(size: sz(16), weight: .bold, design: .rounded))
                .foregroundColor(.primary)
                .frame(maxWidth: expandWidth ? .infinity : nil)
                .padding(.vertical, 4)
                .accessibilityLabel(L10n.appName)
        }
    }
}
