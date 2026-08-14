import Foundation

/// Curated knowledge about credential-handling apps that should not have their
/// clipboard writes recorded.
///
/// Three separate concerns share this table, which is why it lives in Models
/// rather than inside any one of them:
///   1. `ClipboardStore` seeds `excludedBundleIdsString` for fresh installs.
///   2. `HistoryCaptureSettingsView` renders friendly chip labels for ids that
///      resolve nowhere (the app simply isn't installed on this Mac).
///   3. The same view offers an opt-in "update your exclusion list" notice.
///
/// ID-EXCLUDE-0001 (2026-08-14): every id below was verified verbatim against
/// the app's Homebrew cask definition (`formulae.brew.sh/api/cask/<name>.json`,
/// zap/uninstall stanzas), because the previously shipped default list carried
/// `com.keepassx.keeweb` — an id that belongs to no app at all, so that
/// exclusion had never once fired. Do not add an entry here from memory; look
/// up the cask (or the installed bundle) first.
enum KnownExcludedApps {

    /// Bundle ids seeded on a fresh install.
    ///
    /// Existing installs are deliberately NOT migrated to this list — their
    /// stored value is a user-owned setting. `staleReplacements` +
    /// `recommendedAdditions(for:)` drive an opt-in notice instead.
    static let defaultBundleIds: [String] = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "net.antelle.keeweb",
        "org.keepassxc.keepassxc",
        "org.keepassx.keepassxc",
        "com.nordsec.nordpass",
        "me.proton.pass.electron",
        "com.keepersecurity.passwordmanager",
        "com.lastpass.lastpass",
        "com.lastpass.lastpassmacdesktop",
        "in.sinew.enpass-desktop",
        "com.hicknhacksoftware.macpass",
        "com.maxgoedjen.secretive"
    ]

    /// Ids we shipped that turned out to be wrong, mapped to the real id.
    ///
    /// Used only to *offer* a correction — never applied silently.
    static let staleReplacements: [String: String] = [
        "com.keepassx.keeweb": "net.antelle.keeweb"
    ]

    /// Human-readable names, so a chip for an app that isn't installed reads
    /// "1Password 7" instead of "com.agilebits.onepassword7".
    ///
    /// Names only — deliberately no bundled logo artwork. Redistributing these
    /// vendors' marks inside an MIT-licensed app is a trademark risk that four
    /// prettier chips do not justify; naming a product is nominative use.
    private static let displayNames: [String: String] = [
        "com.1password.1password": "1Password",
        "com.agilebits.onepassword7": "1Password 7",
        "com.bitwarden.desktop": "Bitwarden",
        "net.antelle.keeweb": "KeeWeb",
        "com.keepassx.keeweb": "KeeWeb",
        "org.keepassxc.keepassxc": "KeePassXC",
        "org.keepassx.keepassxc": "KeePassXC",
        "com.nordsec.nordpass": "NordPass",
        "me.proton.pass.electron": "Proton Pass",
        "com.keepersecurity.passwordmanager": "Keeper",
        "com.lastpass.lastpass": "LastPass",
        "com.lastpass.lastpassmacdesktop": "LastPass",
        "in.sinew.enpass-desktop": "Enpass",
        "com.hicknhacksoftware.macpass": "MacPass",
        "com.maxgoedjen.secretive": "Secretive"
    ]

    /// Friendly name for a bundle id, or nil when we have no curated name and
    /// the caller should fall back to showing the raw id.
    ///
    /// Case-insensitive: `excludedBundleIdsString` preserves whatever case the
    /// picker or a drag supplied, while `parseExcludedBundleIds()` lowercases
    /// for matching. Lookups here must tolerate both.
    static func displayName(for bundleId: String) -> String? {
        displayNames[bundleId.lowercased()]
    }

    /// Stale ids present in `current` that we have a known correction for.
    static func staleCorrections(for current: [String]) -> [(old: String, new: String)] {
        let present = Set(current.map { $0.lowercased() })
        return staleReplacements
            .filter { present.contains($0.key) && !present.contains($0.value) }
            .map { (old: $0.key, new: $0.value) }
            .sorted { $0.old < $1.old }
    }

    /// Curated ids missing from `current`.
    static func recommendedAdditions(for current: [String]) -> [String] {
        let present = Set(current.map { $0.lowercased() })
        return defaultBundleIds.filter { !present.contains($0) }
    }

    // MARK: - Opt-in update (ID-EXCLUDE-0002)

    /// What an existing install could gain, if the user chooses to take it.
    struct PendingUpdate: Equatable {
        /// Ids in the user's list that we know are dead, with their real id.
        var corrections: [String] = []
        /// Curated ids the user doesn't have yet.
        var additions: [String] = []

        var isEmpty: Bool { corrections.isEmpty && additions.isEmpty }

        /// Ids this update would introduce — what gets recorded when the user
        /// dismisses it, so a later version adding new entries can ask again
        /// instead of being silenced forever by one dismissal.
        var introducedIds: [String] {
            corrections.compactMap { staleReplacements[$0] } + additions
        }
    }

    /// Never applied automatically. A shipped default that turns out to be
    /// wrong is our bug, but the list it lives in is the user's setting — the
    /// fix is offered, not performed.
    static func pendingUpdate(current: [String], dismissed: [String]) -> PendingUpdate {
        let dismissedSet = Set(dismissed.map { $0.lowercased() })
        let corrections = staleCorrections(for: current)
            .filter { !dismissedSet.contains($0.new) }
            .map(\.old)
        let additions = recommendedAdditions(for: current)
            .filter { !dismissedSet.contains($0) }
        return PendingUpdate(corrections: corrections, additions: additions)
    }

    /// Apply an update to a list: dead ids are replaced in place (keeping their
    /// position), new ids are appended. Anything the user added themselves is
    /// untouched.
    static func applying(_ update: PendingUpdate, to current: [String]) -> [String] {
        let corrections = Set(update.corrections.map { $0.lowercased() })
        var result = current.map { id -> String in
            guard corrections.contains(id.lowercased()),
                  let replacement = staleReplacements[id.lowercased()] else { return id }
            return replacement
        }
        var present = Set(result.map { $0.lowercased() })
        for id in update.additions where present.insert(id.lowercased()).inserted {
            result.append(id)
        }
        return result
    }
}
