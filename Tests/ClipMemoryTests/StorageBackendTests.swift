import XCTest
@testable import ClipMemory

/// P1-AUDIT-2026-09-22 (P2-2): FileStorageBackend.saveBlob previously
/// did `defaults.set(blob, forKey: key)` without verifying the write
/// succeeded. macOS sandbox-blocking / disk-full / permission-denied
/// return failure from `set()` WITHOUT throwing — write failure was
/// silent. These tests exercise the read-back verify that closes
/// the in-memory failure path.
///
/// **Honest scope** (post OpenCode auto-review amendment):
/// This test exercises the IN-MEMORY `set()` failure path — the
/// `FailingUserDefaults` shim drops the value at `set()` time so
/// `defaults.data(forKey:)` returns nil immediately. It validates the
/// ONE class of failure that the read-back can catch.
///
/// The audit's headline scenarios (disk-full / permission-denied at
/// the cfprefsd daemon's async flush) are NOT caught by this
/// mechanism: by the time the daemon flush fails, `set()` has
/// already accepted the value into the in-memory cache, and any
/// subsequent `synchronize()` / read-back from the same process
/// returns the cached bytes. Such failures manifest as silent
/// data loss on the NEXT process restart — closing that requires
/// periodic integrity verification or a different storage backend,
/// both out of scope for this fix.
final class StorageBackendTests: XCTestCase {

    private var suite: UserDefaults!
    private var standardSnapshot: [String: Any]!

    override func setUp() {
        super.setUp()
        let uid = UUID().uuidString
        suite = UserDefaults(suiteName: "StorageBackendTests-\(uid)")!
        suite.removePersistentDomain(forName: "StorageBackendTests-\(uid)")
        // Snapshot production UserDefaults so a forgotten .standard
        // access doesn't pollute the host plist (ZZZ canary guard).
        standardSnapshot = UserDefaults.standard.dictionaryRepresentation()
    }

    override func tearDown() {
        for key in UserDefaults.standard.dictionaryRepresentation().keys
        where !standardSnapshot.keys.contains(key) {
            UserDefaults.standard.removeObject(forKey: key)
        }
        suite = nil
        standardSnapshot = nil
        super.tearDown()
    }

    /// P1-AUDIT-2026-09-22 (P2-2): saveBlob must detect in-memory
    /// write failures via read-back verification. The
    /// FailingUserDefaults shim silently drops writes — without
    /// read-back, saveBlob would silently report success (no throw,
    /// no error).
    ///
    /// NOTE: this covers the IN-MEMORY failure path (cfprefsd
    /// unreachable at process init, etc.) only. Disk-flush failures
    /// at the daemon's async persist point are not catchable here —
    /// see the file-level docstring.
    func testSaveBlobDetectsWriteFailure() throws {
        // P1-AUDIT-2026-09-22 (P2-2): inject a UserDefaults shim whose
        // set() silently drops writes — simulates in-memory set()
        // failure (sandbox-blocked cfprefsd at process init).
        // saveBlob must throw on read-back mismatch, not silently
        // report success.
        let failingSuite = FailingUserDefaults(suiteName: "p2-2-fail-\(UUID().uuidString)")!
        let failingBackend = FileStorageBackend(
            storageKey: "p2-2-fail-key",
            defaults: failingSuite
        )

        XCTAssertThrowsError(
            try failingBackend.saveBlob(Data([0x01, 0x02])),
            "P1-AUDIT-2026-09-22 P2-2: saveBlob must detect in-memory write failure via read-back"
        )
    }

    /// P1-AUDIT-2026-09-22 (P2-2): normal UserDefaults writes must
    /// still succeed — guards against an over-eager read-back that
    /// would always throw.
    func testSaveBlobSuccessOnNormalUserDefaults() throws {
        let backend = FileStorageBackend(
            storageKey: "p2-2-success-key",
            defaults: suite
        )

        XCTAssertNoThrow(
            try backend.saveBlob(Data([0xAA, 0xBB, 0xCC])),
            "P1-AUDIT-2026-09-22 P2-2: saveBlob must succeed for normal writes"
        )
        // Sanity: the bytes actually landed in the suite.
        XCTAssertEqual(suite.data(forKey: "p2-2-success-key"),
                       Data([0xAA, 0xBB, 0xCC]))
    }
}

/// P1-AUDIT-2026-09-22 (P2-2): UserDefaults shim that silently drops
/// all writes. Simulates disk-full / sandbox-blocked / permission-
/// denied scenarios without real FS manipulation.
private final class FailingUserDefaults: UserDefaults, @unchecked Sendable {
    override func set(_ value: Any?, forKey defaultName: String) {
        // Silent drop. Do not call super — simulate write failure.
    }
    override func data(forKey defaultName: String) -> Data? {
        // Always return nil to simulate "no data was written".
        return nil
    }
}