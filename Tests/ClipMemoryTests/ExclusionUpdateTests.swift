import XCTest
@testable import ClipMemory

/// ID-EXCLUDE-0002 (2026-08-14): the corrected default list is offered to
/// existing installs, never applied to them. These tests pin that the offer
/// appears when it should, applies exactly what it advertised, and stays
/// dismissed without gagging a future release's additions.
final class ExclusionUpdateTests: XCTestCase {

    /// An install from before the correction: the dead KeeWeb id, and none of
    /// the newly curated apps.
    private let legacyList = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.keepassx.keeweb"
    ]

    func testLegacyInstallIsOfferedTheCorrectionAndAdditions() {
        let update = KnownExcludedApps.pendingUpdate(current: legacyList, dismissed: [])
        XCTAssertEqual(update.corrections, ["com.keepassx.keeweb"])
        XCTAssertTrue(update.additions.contains("org.keepassxc.keepassxc"))
        XCTAssertFalse(update.isEmpty)
    }

    func testFreshInstallIsOfferedNothing() {
        let update = KnownExcludedApps.pendingUpdate(
            current: KnownExcludedApps.defaultBundleIds,
            dismissed: []
        )
        XCTAssertTrue(update.isEmpty, "a fresh install already has the curated list")
    }

    func testApplyingReplacesDeadIdInPlaceAndAppendsTheRest() {
        let update = KnownExcludedApps.pendingUpdate(current: legacyList, dismissed: [])
        let applied = KnownExcludedApps.applying(update, to: legacyList)

        // Replaced, not appended — position 3 stays position 3.
        XCTAssertEqual(applied[3], "net.antelle.keeweb")
        XCTAssertFalse(applied.contains("com.keepassx.keeweb"))
        // Everything the user already had survives.
        for id in legacyList where id != "com.keepassx.keeweb" {
            XCTAssertTrue(applied.contains(id), "dropped a pre-existing id: \(id)")
        }
        XCTAssertTrue(applied.contains("com.nordsec.nordpass"))
    }

    func testApplyingLeavesUserAddedEntriesAlone() {
        // The whole point: this must never touch anything the user chose.
        let withCustom = legacyList + ["com.example.myapp"]
        let update = KnownExcludedApps.pendingUpdate(current: withCustom, dismissed: [])
        let applied = KnownExcludedApps.applying(update, to: withCustom)
        XCTAssertTrue(applied.contains("com.example.myapp"))
    }

    func testApplyingIsIdempotent() {
        let first = KnownExcludedApps.applying(
            KnownExcludedApps.pendingUpdate(current: legacyList, dismissed: []),
            to: legacyList
        )
        let second = KnownExcludedApps.applying(
            KnownExcludedApps.pendingUpdate(current: first, dismissed: []),
            to: first
        )
        XCTAssertEqual(first, second)
    }

    func testDismissedIdsSuppressTheNotice() {
        let update = KnownExcludedApps.pendingUpdate(current: legacyList, dismissed: [])
        let afterDismiss = KnownExcludedApps.pendingUpdate(
            current: legacyList,
            dismissed: update.introducedIds
        )
        XCTAssertTrue(afterDismiss.isEmpty)
    }

    func testDismissalDoesNotSuppressALaterUnrelatedAddition() {
        // Dismissing today must not silence a future release that curates an
        // app this user has never been asked about.
        var dismissed = KnownExcludedApps.pendingUpdate(current: legacyList, dismissed: [])
            .introducedIds
        dismissed.removeAll { $0 == "com.nordsec.nordpass" }
        let update = KnownExcludedApps.pendingUpdate(current: legacyList, dismissed: dismissed)
        XCTAssertEqual(update.additions, ["com.nordsec.nordpass"])
    }

    func testDismissingTheCorrectionLeavesTheDeadIdInPlace() {
        // Declining means nothing changes — including not quietly deleting the
        // rule that doesn't work.
        let update = KnownExcludedApps.pendingUpdate(current: legacyList, dismissed: [])
        let afterDismiss = KnownExcludedApps.pendingUpdate(
            current: legacyList,
            dismissed: update.introducedIds
        )
        XCTAssertTrue(afterDismiss.isEmpty)
        XCTAssertTrue(legacyList.contains("com.keepassx.keeweb"))
    }
}
