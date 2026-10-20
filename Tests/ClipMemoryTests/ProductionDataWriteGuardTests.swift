import XCTest
@testable import ClipMemory

/// ID-CRASH-0031 (2026-10-20) — guards for the production data blobs.
///
/// Background: on 2026-10-20 a test run replaced the user's 106 trashed
/// entries with an empty array. Two independent defects were involved:
///
/// 1. `xcodebuild test` launches the app binary through LaunchServices.
///    A plain app launch has no `XCTestConfigurationFilePath`, so the
///    per-service `xcTestDefaults` guard fell through to the PRODUCTION
///    path and the launched app read / wrote the real
///    `com.clipmemory.app` domain.
/// 2. The suite-level pollution canary compared key PRESENCE for the two
///    data keys (they sat in `appLifecycleKeys`), so a whole-array
///    overwrite was invisible to it.
///
/// The guard under test here is the write gate inside
/// `FileStorageBackend`: while the process runs tests, the production
/// data keys must never be written into `UserDefaults.standard`.
///
/// These tests deliberately touch `.standard` — that IS the condition
/// being verified. Every test snapshots the affected blob first and
/// restores it in a `defer` (via `UserDefaults.standard.set`, which
/// bypasses the backend gate), so a regression cannot leave the user's
/// data modified.
final class ProductionDataWriteGuardTests: XCTestCase {

    /// Restores a production blob exactly as it was before the test ran.
    ///
    /// The restore deliberately goes through `UserDefaults.standard.set`
    /// instead of the backend: the backend refuses production writes
    /// under XCTest, so a restore through it would be blocked.
    private func snapshotProductionBlob(_ key: String) -> Data? {
        UserDefaults.standard.data(forKey: key)
    }

    private func restoreProductionBlob(_ key: String, _ original: Data?) {
        if let original {
            UserDefaults.standard.set(original, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// The gate must recognise that this process runs tests.
    func testTestProcessIsDetected() {
        XCTAssertTrue(
            TestIsolation.isRunningTests,
            "ID-CRASH-0031: the test process must be detectable — otherwise every "
            + "production-write guard in the app is inert"
        )
    }

    /// A write to a production data key from a test process must be
    /// refused, and must not touch the stored bytes.
    func testTestProcessCannotWriteProductionItemsBlob() throws {
        let key = UserDefaultsKey.clipboardItems.rawValue
        let original = snapshotProductionBlob(key)
        defer { restoreProductionBlob(key, original) }

        let backend = FileStorageBackend(storageKey: key, defaults: .standard)
        let probe = ClipboardItem(content: "id-crash-0031-guard-probe", type: .text)

        XCTAssertThrowsError(try backend.save([probe])) { error in
            guard case StorageBackendError.productionWriteBlocked(let blockedKey) = error else {
                return XCTFail("expected productionWriteBlocked, got \(error)")
            }
            XCTAssertEqual(blockedKey, key)
        }

        XCTAssertEqual(
            UserDefaults.standard.data(forKey: key), original,
            "ID-CRASH-0031: the refused write must not have modified the production blob"
        )
    }

    /// The same gate applies to the pre-encoded blob path (`saveBlob`) —
    /// that is the path `ClipboardStore.saveItems()` actually uses.
    func testTestProcessCannotWriteProductionItemsBlobViaSaveBlob() throws {
        let key = UserDefaultsKey.clipboardItems.rawValue
        let original = snapshotProductionBlob(key)
        defer { restoreProductionBlob(key, original) }

        let backend = FileStorageBackend(storageKey: key, defaults: .standard)
        let payload = try JSONEncoder().encode([ClipboardItem(content: "blob-probe", type: .text)])

        XCTAssertThrowsError(try backend.saveBlob(payload)) { error in
            guard case StorageBackendError.productionWriteBlocked = error else {
                return XCTFail("expected productionWriteBlocked, got \(error)")
            }
        }

        XCTAssertEqual(UserDefaults.standard.data(forKey: key), original)
    }

    /// The gate must NOT be a blanket ban: a test-owned storage key in an
    /// isolated suite is a fixture, not the user's data.
    func testIsolatedSuiteWithOwnKeyIsNotBlocked() throws {
        let suiteName = "ProductionDataWriteGuardTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let backend = FileStorageBackend(storageKey: "test.guard.probe", defaults: defaults)
        let probe = ClipboardItem(content: "allowed", type: .text)

        XCTAssertNoThrow(try backend.save([probe]))
        XCTAssertEqual(try backend.load().map(\.content), ["allowed"])
    }

    /// An isolated suite that reuses a production key NAME is also a
    /// fixture — the gate keys on the production domain, not the name.
    func testIsolatedSuiteWithProductionKeyNameIsNotBlocked() throws {
        let suiteName = "ProductionDataWriteGuardTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let backend = FileStorageBackend(
            storageKey: UserDefaultsKey.clipboardItems.rawValue,
            defaults: defaults
        )
        let probe = ClipboardItem(content: "fixture", type: .text)

        XCTAssertNoThrow(try backend.save([probe]))
        XCTAssertEqual(try backend.load().map(\.content), ["fixture"])
    }

    /// The three production data keys must be exactly the ones the gate
    /// protects — a typo here would silently unprotect the user's data.
    func testProductionDataKeysCoverHistoryTrashAndTags() {
        XCTAssertEqual(
            TestIsolation.productionDataKeys,
            ["ClipboardItems", "ClipboardTrashedItems", "ClipMemoryTags"]
        )
    }

    /// ID-CRASH-0031: the quarantine path MOVES the blob — it writes a
    /// `.corrupt-*` copy and REMOVES the original key. The removal is
    /// more destructive than a write, so it must be guarded too.
    func testQuarantineGuardRefusesProductionDomainMutation() {
        XCTAssertTrue(
            TestIsolation.mustRefuseProductionDataMutation(.standard),
            "a test process must not mutate the production domain"
        )

        let suiteName = "ProductionDataWriteGuardTests-\(UUID().uuidString)"
        let isolated = UserDefaults(suiteName: suiteName)!
        defer { isolated.removePersistentDomain(forName: suiteName) }
        XCTAssertFalse(
            TestIsolation.mustRefuseProductionDataMutation(isolated),
            "an isolated suite is a fixture, not the user's data"
        )
    }

    /// ID-CRASH-0031: the per-service guards must use the shared
    /// multi-signal probe. A guard that only reads
    /// `XCTestConfigurationFilePath` silently degrades to the production
    /// path when that variable is absent — which is exactly what the
    /// 2026-10-20 forensics hit.
    func testPerServiceGuardsUseTheSharedProbe() {
        XCTAssertFalse(
            HotKeyManager.xcTestDefaults === UserDefaults.standard,
            "HotKeyManager must not persist to the production domain under XCTest"
        )
        XCTAssertFalse(
            SafeModeService.xcTestDefaults === UserDefaults.standard,
            "SafeModeService must not persist to the production domain under XCTest"
        )
        XCTAssertFalse(
            ClipboardStore.xcTestDefaults === UserDefaults.standard,
            "ClipboardStore must not persist to the production domain under XCTest"
        )
    }

    /// ID-CRASH-0031: `BackupService.shared` must not write into the
    /// production `Backups/` directory from a test process — a test run
    /// would otherwise create a backup dir in the user's real folder and
    /// prune it, rotating the user's own backups out.
    func testBackupServiceSharedInstanceIsIsolatedUnderXCTest() {
        let productionBackups = AppDirectories.applicationSupport
            .appendingPathComponent("ClipMemory/Backups", isDirectory: true)
            .standardizedFileURL.path
        XCTAssertNotEqual(
            BackupService.shared.backupsDirectoryURL.standardizedFileURL.path,
            productionBackups,
            "BackupService.shared must not use the production Backups directory under XCTest"
        )
    }
}
