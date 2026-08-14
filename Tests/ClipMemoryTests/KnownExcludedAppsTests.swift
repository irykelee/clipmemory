import XCTest
@testable import ClipMemory

/// ID-EXCLUDE-0001 (2026-08-14): the shipped default exclusion list contained
/// `com.keepassx.keeweb`, a bundle id belonging to no app — that exclusion had
/// never fired. These tests pin the corrected data and the opt-in correction
/// helpers that offer it to existing installs.
final class KnownExcludedAppsTests: XCTestCase {

    func testDefaultsDoNotContainTheStaleKeeWebId() {
        XCTAssertFalse(
            KnownExcludedApps.defaultBundleIds.contains("com.keepassx.keeweb"),
            "com.keepassx.keeweb matches no installed app; KeeWeb ships as net.antelle.keeweb"
        )
        XCTAssertTrue(KnownExcludedApps.defaultBundleIds.contains("net.antelle.keeweb"))
    }

    func testDefaultsAreLowercasedAndUnique() {
        // parseExcludedBundleIds() lowercases both sides when matching, so a
        // mixed-case default would still work — but storing them lowercased
        // keeps the chip labels and the recommendation diff consistent.
        for id in KnownExcludedApps.defaultBundleIds {
            XCTAssertEqual(id, id.lowercased(), "default id not lowercased: \(id)")
        }
        XCTAssertEqual(
            Set(KnownExcludedApps.defaultBundleIds).count,
            KnownExcludedApps.defaultBundleIds.count,
            "duplicate id in defaults"
        )
    }

    func testEveryDefaultHasAFriendlyName() {
        // The whole point of the table: an excluded app that isn't installed
        // must still render as a readable name, never as a raw bundle id.
        for id in KnownExcludedApps.defaultBundleIds {
            XCTAssertNotNil(KnownExcludedApps.displayName(for: id), "no display name for \(id)")
        }
    }

    func testDisplayNameLookupIsCaseInsensitive() {
        // The picker inserts whatever case the bundle reports, so the stored
        // string can hold "com.LastPass.LastPass" while the table is lowercased.
        XCTAssertEqual(KnownExcludedApps.displayName(for: "com.LastPass.LastPass"), "LastPass")
        XCTAssertEqual(KnownExcludedApps.displayName(for: "com.lastpass.lastpass"), "LastPass")
    }

    func testDisplayNameReturnsNilForUnknownId() {
        XCTAssertNil(KnownExcludedApps.displayName(for: "com.example.unknown"))
    }

    func testStaleCorrectionOfferedWhenOldIdPresent() {
        let corrections = KnownExcludedApps.staleCorrections(for: ["com.keepassx.keeweb", "com.bitwarden.desktop"])
        XCTAssertEqual(corrections.count, 1)
        XCTAssertEqual(corrections.first?.old, "com.keepassx.keeweb")
        XCTAssertEqual(corrections.first?.new, "net.antelle.keeweb")
    }

    func testStaleCorrectionSuppressedWhenReplacementAlreadyPresent() {
        // Someone who already added the real id shouldn't be nagged; the old
        // dead id is harmless on its own and stays until they remove it.
        let corrections = KnownExcludedApps.staleCorrections(
            for: ["com.keepassx.keeweb", "net.antelle.keeweb"]
        )
        XCTAssertTrue(corrections.isEmpty)
    }

    func testStaleCorrectionIsCaseInsensitive() {
        let corrections = KnownExcludedApps.staleCorrections(for: ["COM.KeePassX.KeeWeb"])
        XCTAssertEqual(corrections.first?.new, "net.antelle.keeweb")
    }

    func testRecommendedAdditionsExcludeWhatIsAlreadyThere() {
        let additions = KnownExcludedApps.recommendedAdditions(for: ["com.bitwarden.desktop"])
        XCTAssertFalse(additions.contains("com.bitwarden.desktop"))
        XCTAssertTrue(additions.contains("net.antelle.keeweb"))
    }

    func testRecommendedAdditionsEmptyForAFreshInstall() {
        // A fresh install is seeded from defaultBundleIds, so the notice must
        // not appear for it.
        let additions = KnownExcludedApps.recommendedAdditions(for: KnownExcludedApps.defaultBundleIds)
        XCTAssertTrue(additions.isEmpty)
    }
}
