import SwiftUI

// MARK: - Brand Logo
struct LogoView: View {
    @ObservedObject private var languageManager = LanguageManager.shared

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
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(chineseName)
                    // ID-A11Y-0003 (2026-07-30 audit): route through `sz()`
                    // so Settings → Font Size (small/medium/large) actually
                    // applies to the brand logo in the welcome window.
                    .font(.system(size: sz(20), weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                Text("ClipMemory")
                    .font(.system(size: sz(11), weight: .medium))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .accessibilityLabel(L10n.appName)
        } else {
            // Single name (English, Japanese, Korean, etc.)
            Text(L10n.appName)
                .font(.system(size: sz(16), weight: .bold, design: .rounded))
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .accessibilityLabel(L10n.appName)
        }
    }
}
