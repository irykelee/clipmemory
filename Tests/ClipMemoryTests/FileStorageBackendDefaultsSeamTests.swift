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
    private var standardSnapshot: [String: Any]!

    override func setUp() {
        super.setUp()
        let uid = UUID().uuidString
        suite1 = UserDefaults(suiteName: "FSB-seam-1-\(uid)")!
        suite2 = UserDefaults(suiteName: "FSB-seam-2-\(uid)")!
        suite1.removePersistentDomain(forName: "FSB-seam-1-\(uid)")
        suite2.removePersistentDomain(forName: "FSB-seam-2-\(uid)")
        // Snapshot production so a forgotten .standard access doesn't
        // pollute the host's user plist.
        standardSnapshot = UserDefaults.standard.dictionaryRepresentation()
    }

    override func tearDown() {
        // Belt-and-suspenders: even though seam tests don't touch
        // .standard, sweep any leaked keys so a future regression gets
        // caught by ZZZ canary on the next full run.
        for key in UserDefaults.standard.dictionaryRepresentation().keys
        where !standardSnapshot.keys.contains(key) {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

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
        // Plant data in .standard under the same storageKey the instance
        // will use, then prove the instance ignores it.
        UserDefaults.standard.set(
            Data("decoy".utf8),
            forKey: "test.items"
        )
        defer { UserDefaults.standard.removeObject(forKey: "test.items") }

        let backend = FileStorageBackend(storageKey: "test.items", defaults: suite1)
        let items = try backend.load()

        XCTAssertTrue(items.isEmpty,
                      "load must return [] when injected suite is empty (ignoring .standard decoy)")
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
        // Create with the default 0-arg init — must still hit .standard.
        let backend = FileStorageBackend(storageKey: "prod.default.items")
        let items = [ClipboardItem(content: "prod", type: .text,
                                   isEncrypted: false, contentHash: "p")]
        try backend.save(items)

        XCTAssertNotNil(UserDefaults.standard.data(forKey: "prod.default.items"),
                        "default init must write to .standard for production callers")
        defer { UserDefaults.standard.removeObject(forKey: "prod.default.items") }
    }
}