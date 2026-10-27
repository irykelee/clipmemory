import XCTest
@testable import ClipMemory

/// ID-STORE-0015 (2026-08-14, L26 live drill path C):
/// FileStorageBackend now accepts an injected `defaults: UserDefaults`
/// suite instead of hardcoding `UserDefaults.standard`. This is the
/// seam that lets `TrashStore.init(backend:defaults:)` route its
/// injected `defaults` through to the underlying backend.
///
/// What this fixes (audit C-1, 2026-08-14):
/// - TrashStore had `defaults:` injection (line 70) but FileStorageBackend
///   read .standard unconditionally, so tests could not exercise the
///   trash-blob-load failure path without polluting production keys.
/// - Same pattern blocked any future multi-suite isolation work for
///   items / tags persistence (currently routed through MemoryStorageBackend
///   in tests, but the production code path was untestable).
final class FileStorageBackendDefaultsSeamTests: XCTestCase {

    private var suite1: UserDefaults!
    private var suite2: UserDefaults!

    override func setUp() {
        super.setUp()
        let uid = UUID().uuidString
        suite1 = TestSuiteCleanup.makeSuite(named: "FSB-seam-1-\(uid)")
        suite2 = TestSuiteCleanup.makeSuite(named: "FSB-seam-2-\(uid)")
        // ID-REVIEW-1040 follow-up: both clears were NO-OPs (a fresh-UUID
        // suite cannot have a domain yet) and each queued a **pending
        // write** in cfprefsd — the very mechanism that writes an empty
        // shell back to disk (measured 5/40).
    }

    // ID-REVIEW-1038 (2026-10-26): the `tearDown` sweep is GONE.
    //
    // It removed every key that appeared in `UserDefaults.standard` since
    // `setUp` — INCLUDING keys the RUNNING app wrote in that window. The
    // user's real settings could be deleted by a test. The suite now
    // writes nothing to the production domain at all, so there is nothing
    // to sweep, and a future regression is caught by
    // `ProductionDomainWriteGuardTests` (which NAMES the offender) and by
    // the ZZZ production-domain canary.

    /// save() writes to the injected suite, NOT UserDefaults.standard.
    func testSaveWritesToInjectedDefaultsNotStandard() throws {
        let backend = FileStorageBackend(storageKey: "test.items", defaults: suite1)
        let items = [ClipboardItem(
            content: "hello",
            type: .text,
            isEncrypted: false,
            contentHash: "h1"
        )]
        try backend.save(items)

        XCTAssertNotNil(suite1.data(forKey: "test.items"),
                        "save must land in injected suite")
        XCTAssertNil(UserDefaults.standard.data(forKey: "test.items"),
                     "save must NOT leak into production .standard")
    }

    /// load() reads from the injected suite. A .standard write to the same
    /// key must be invisible to an instance that was given suite1.
    func testLoadReadsFromInjectedDefaultsIgnoringStandard() throws {
        // Plant a decoy under the SAME key name in ANOTHER domain, then
        // prove the instance ignores it.
        //
        // ID-REVIEW-1038 (2026-10-26): the decoy used to be planted in
        // `UserDefaults.standard` — the PRODUCTION domain, because the
        // test host runs inside the app process. A decoy in a DIFFERENT
        // per-test suite proves the same property (a same-key value in
        // another domain must be invisible) without touching the user's
        // real settings, and without a restore that a host abort would
        // skip.
        let decoySuiteName = "FSB-seam-decoy-\(UUID().uuidString)"
        let decoySuite = TestSuiteCleanup.makeSuite(named: decoySuiteName)
        defer { TestSuiteCleanup.destroy(decoySuite) }
        decoySuite.set(Data("decoy".utf8), forKey: "test.items")

        let backend = FileStorageBackend(storageKey: "test.items", defaults: suite1)
        let items = try backend.load()

        XCTAssertTrue(items.isEmpty,
                      "load must return [] when injected suite is empty (ignoring the decoy domain)")
    }

    /// saveTags / loadTags also go through the injected seam.
    func testTagsPathAlsoUsesInjectedDefaults() throws {
        let backend = FileStorageBackend(storageKey: "test.tags", defaults: suite1)
        let tags = [Tag(id: UUID(), name: "work", colorHex: "#FF0000")]
        try backend.saveTags(tags)

        XCTAssertNotNil(suite1.data(forKey: "test.tags"))
        XCTAssertNil(UserDefaults.standard.data(forKey: "test.tags"))

        let loaded = try backend.loadTags()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "work")
    }

    /// saveBlob (the CLIP-2 hot path) also routes through the seam.
    func testSaveBlobUsesInjectedDefaults() throws {
        let backend = FileStorageBackend(storageKey: "test.blob", defaults: suite1)
        let payload = Data("pre-encoded".utf8)
        try backend.saveBlob(payload)

        XCTAssertEqual(suite1.data(forKey: "test.blob"), payload)
        XCTAssertNil(UserDefaults.standard.data(forKey: "test.blob"))
    }

    /// Two backends with different suites must NOT see each other's data —
    /// proves the seam is per-instance, not a static.
    func testTwoInstancesWithDifferentSuitesAreIsolated() throws {
        let backendA = FileStorageBackend(storageKey: "shared.key", defaults: suite1)
        let backendB = FileStorageBackend(storageKey: "shared.key", defaults: suite2)

        let itemsA = [ClipboardItem(content: "fromA", type: .text,
                                     isEncrypted: false, contentHash: "a")]
        try backendA.save(itemsA)

        let loadedFromB = try backendB.load()
        XCTAssertTrue(loadedFromB.isEmpty,
                      "backendB with suite2 must NOT see backendA's write to suite1")
    }

    /// Production path: defaults defaults to .standard so the 0-arg init
    /// keeps existing callers working (no call-site change in the convenience
    /// init paths).
    func testDefaultsParameterDefaultsToStandard() throws {
        // Create with the default 0-arg init — must still be bound to
        // .standard.
        //
        // ID-REVIEW-1038 (2026-10-26): this used to SAVE through the
        // 0-arg init and then assert that `.standard` had received the
        // bytes — i.e. it wrote the user's production domain to prove
        // where the backend points. The binding is now asserted by
        // IDENTITY, which is the same contract without the write.
        let backend = FileStorageBackend(storageKey: "prod.default.items")
        XCTAssertTrue(
            backend.testDefaults === UserDefaults.standard,
            "default init must stay bound to .standard for production callers"
        )
    }
}
