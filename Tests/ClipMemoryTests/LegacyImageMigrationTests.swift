import XCTest
@testable import ClipMemory

/// STOR-3 (2026-07-24) regression tests: the legacy ClipPaste→ClipMemory
/// image migration runs on a utility queue instead of blocking the main
/// thread at startup (AppDelegate.setupClipboardMonitor first-touches the
/// ImageStorage singleton), while the observable contract — per-file resume
/// tracking, global completion flag, plaintext cleanup — is unchanged.
///
/// STOR-4 (2026-07-24) regression tests: permanently ineligible legacy
/// files (empty / over the size cap) are recorded in a skip list — never
/// retried, never blocking the global completion flag — while transient
/// failures still leave the flag false so the next launch retries.
final class LegacyImageMigrationTests: XCTestCase {

    private let migrationKey = "ImageStorageMigrationComplete"
    private let migratedFilenamesKey = "ImageStorageMigratedFilenames"
    private let skippedFilenamesKey = "ImageStorageSkippedLegacyFilenames"

    private var storage: ImageStorage!
    private var legacyDir: URL!
    private var suiteName: String!
    private var suite: UserDefaults!
    private var originalCrypto: CryptoServiceProtocol?
    private var migratedUUIDs: [UUID] = []

    override func setUp() {
        super.setUp()
        originalCrypto = ServiceContainer.crypto
        ServiceContainer.crypto = CryptoService(customKeyData: Data((0..<32).map { UInt8($0) }))

        storage = ImageStorage.shared
        legacyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("STOR3-Legacy-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)

        suiteName = "STOR3Tests.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        for uuid in migratedUUIDs {
            storage.deleteImage(filename: "\(uuid.uuidString).png")
        }
        migratedUUIDs.removeAll()
        if let suiteName { suite?.removePersistentDomain(forName: suiteName) }
        suite = nil
        suiteName = nil
        try? FileManager.default.removeItem(at: legacyDir)
        legacyDir = nil
        if let originalCrypto { ServiceContainer.crypto = originalCrypto }
        originalCrypto = nil
        super.tearDown()
    }

    private func newMigratedUUID() -> UUID {
        let uuid = UUID()
        migratedUUIDs.append(uuid)
        return uuid
    }

    /// Minimal bytes satisfying the migration's unencrypted-PNG sniff
    /// (magic 89 50 4E 47) — the migrator checks the signature only.
    private func makeLegacyPNGBytes() -> Data {
        Data([0x89, 0x50, 0x4E, 0x47]) + Data((0..<64).map { UInt8($0 & 0xFF) })
    }

    @discardableResult
    private func writeLegacyFile(_ data: Data, uuid: UUID) -> String {
        let filename = "\(uuid.uuidString).png"
        try? data.write(to: legacyDir.appendingPathComponent(filename))
        return filename
    }

    // MARK: - STOR-3: async scheduling

    /// Regression: scheduling the migration must not block the caller, the
    /// migration must still run to completion, and the completion handler
    /// must fire after the state is observable (flag set, file moved).
    /// Pre-fix the whole pass ran synchronously on the main thread at
    /// startup; this test would have been impossible to write because there
    /// was no async entry point at all.
    func testScheduleLegacyMigrationRunsAsyncAndCompletes() throws {
        let uuid = newMigratedUUID()
        let plaintext = makeLegacyPNGBytes()
        let filename = writeLegacyFile(plaintext, uuid: uuid)

        let exp = expectation(description: "legacy migration completes on utility queue")
        var callerThreadWasBlocked = true
        storage.scheduleLegacyMigration(
            legacyDirectory: legacyDir,
            defaults: suite
        ) {
            callerThreadWasBlocked = false
            exp.fulfill()
        }
        // If scheduling were synchronous (the pre-STOR-3 behavior), the
        // completion would already have run before this line; with the async
        // dispatch the flag is still true at this point in all non-pathological
        // scheduler interleavings — but we don't assert on it (racy). The
        // contract assertion happens after the wait.
        _ = callerThreadWasBlocked

        wait(for: [exp], timeout: 10.0)

        XCTAssertTrue(suite.bool(forKey: migrationKey),
                      "STOR-3: async pass must still set the global completion flag")
        XCTAssertEqual(suite.stringArray(forKey: migratedFilenamesKey), [filename],
                       "STOR-3: per-file resume tracking must record the migrated file")

        // File migrated to the (test-sandboxed) ClipMemory images dir,
        // encrypted in v2 format, and the legacy plaintext is gone.
        let migratedURL = storage.imagesDirectoryURL.appendingPathComponent(filename)
        let onDisk = try Data(contentsOf: migratedURL)
        XCTAssertTrue(onDisk.starts(with: Data("v2".utf8)),
                      "Migrated file must be v2-encrypted, not plaintext")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: legacyDir.appendingPathComponent(filename).path),
            "Successfully migrated plaintext must be cleaned up")
    }

    /// Contract: the completion-notification path is unchanged — observers
    /// (ClipboardStore.handleImageMigrationCompleted) still receive the
    /// migrated filenames on the main queue after an async pass.
    func testScheduleLegacyMigrationStillPostsCompletionNotificationOnMain() {
        let uuid = newMigratedUUID()
        let filename = writeLegacyFile(makeLegacyPNGBytes(), uuid: uuid)

        let noteExp = expectation(description: "ImageStorageMigrationCompleted posted")
        var observedOnMain = false
        var observedFilenames: [String] = []
        let observer = NotificationCenter.default.addObserver(
            forName: Notification.Name("ImageStorageMigrationCompleted"),
            object: nil,
            queue: nil
        ) { note in
            // Notifications from an earlier test's migration pass can be
            // delivered late (main-queue async post draining during THIS
            // test's wait). Ignore any notification that isn't ours.
            let filenames = note.userInfo?["migratedFilenames"] as? [String] ?? []
            guard filenames.contains(filename) else { return }
            observedOnMain = Thread.isMainThread
            observedFilenames = filenames
            noteExp.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let doneExp = expectation(description: "migration pass finished")
        storage.scheduleLegacyMigration(legacyDirectory: legacyDir, defaults: suite) {
            doneExp.fulfill()
        }
        wait(for: [doneExp, noteExp], timeout: 10.0)

        XCTAssertTrue(observedOnMain,
                      "Completion notification must be delivered on the main queue")
        XCTAssertEqual(observedFilenames, [filename])
    }

    /// Contract: a missing legacy directory is still a successful no-op that
    /// marks the migration complete (fresh installs must not retry forever).
    func testMigrationWithMissingLegacyDirectoryMarksComplete() {
        let missing = legacyDir.appendingPathComponent("does-not-exist", isDirectory: true)
        storage.migrateFromLegacyIfNeeded(legacyDirectory: missing, defaults: suite)
        XCTAssertTrue(suite.bool(forKey: migrationKey))
    }

    // MARK: - STOR-4: permanently ineligible files vs transient failures

    /// Regression: an oversized legacy file must NOT block the whole
    /// migration. Pre-fix, an over-cap file set hadFailure = true on every
    /// launch, so the global completion flag stayed false forever and the
    /// plaintext of SUCCESSFULLY migrated files was never cleaned up.
    /// Post-fix the file lands in the skip list and the pass completes.
    func testOversizedLegacyFileIsSkippedAndDoesNotBlockCompletion() {
        let smallCap = 128 // bytes — keeps fixtures tiny; the cap is injectable
        let goodUUID = newMigratedUUID()
        let goodFilename = writeLegacyFile(makeLegacyPNGBytes(), uuid: goodUUID)
        let oversizedUUID = UUID()
        let oversizedFilename = "\(oversizedUUID.uuidString).png"
        try? Data(repeating: 0xAB, count: smallCap + 100)
            .write(to: legacyDir.appendingPathComponent(oversizedFilename))

        storage.migrateFromLegacyIfNeeded(
            legacyDirectory: legacyDir, defaults: suite, maxFileSize: smallCap
        )

        XCTAssertTrue(suite.bool(forKey: migrationKey),
                      "STOR-4: an over-cap file must not block the global completion flag")
        XCTAssertEqual(suite.stringArray(forKey: skippedFilenamesKey), [oversizedFilename],
                       "STOR-4: over-cap file must be recorded in the permanent skip list")
        XCTAssertEqual(suite.stringArray(forKey: migratedFilenamesKey), [goodFilename],
                       "STOR-4: the eligible file must still migrate in the same pass")

        // The skipped file stays in the legacy dir (we never delete files we
        // didn't migrate); the migrated file's plaintext is cleaned up.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: legacyDir.appendingPathComponent(oversizedFilename).path),
            "Skipped file must remain in the legacy dir — not our file to delete")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: legacyDir.appendingPathComponent(goodFilename).path),
            "STOR-4: plaintext of migrated files must be cleaned up once the pass completes")
    }

    /// Regression: empty (0-byte) legacy files are also permanently
    /// ineligible and take the skip-list path, not the failure path.
    func testZeroByteLegacyFileIsSkippedAndDoesNotBlockCompletion() {
        let emptyUUID = UUID()
        let emptyFilename = "\(emptyUUID.uuidString).png"
        try? Data().write(to: legacyDir.appendingPathComponent(emptyFilename))

        storage.migrateFromLegacyIfNeeded(
            legacyDirectory: legacyDir, defaults: suite, maxFileSize: 128
        )

        XCTAssertTrue(suite.bool(forKey: migrationKey))
        XCTAssertEqual(suite.stringArray(forKey: skippedFilenamesKey), [emptyFilename])
    }

    /// Contract: once a filename is in the skip list it is never retried —
    /// even if the on-disk file later becomes eligible-sized. This is what
    /// stops the migrator from re-examining the same poison file on every
    /// launch.
    func testSkippedFileIsNotRetriedOnLaterPasses() {
        let uuid = UUID()
        let filename = "\(uuid.uuidString).png"
        let fileURL = legacyDir.appendingPathComponent(filename)
        try? Data(repeating: 0xAB, count: 256).write(to: fileURL)

        // First pass: file over the injected cap → skip-listed, pass completes.
        storage.migrateFromLegacyIfNeeded(
            legacyDirectory: legacyDir, defaults: suite, maxFileSize: 128
        )
        XCTAssertEqual(suite.stringArray(forKey: skippedFilenamesKey), [filename])

        // Shrink the file to an eligible size; second pass must NOT migrate it.
        try? makeLegacyPNGBytes().write(to: fileURL)
        storage.migrateFromLegacyIfNeeded(
            legacyDirectory: legacyDir, defaults: suite, maxFileSize: 128
        )

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: storage.imagesDirectoryURL.appendingPathComponent(filename).path),
            "STOR-4: skip-listed file must never be retried, even after it becomes eligible-sized")
        XCTAssertNil(suite.stringArray(forKey: migratedFilenamesKey),
                     "No file should have been migrated across either pass")
    }

    /// Contract: a TRANSIENT failure (file unreadable mid-pass) is not
    /// skip-listed and keeps the completion flag false so the next launch
    /// retries. Simulated with a directory named like a legacy PNG —
    /// attributes succeed (passes the size gate) but Data(contentsOf:) throws.
    func testTransientReadFailureLeavesMigrationIncompleteAndNotSkipped() {
        let uuid = UUID()
        let filename = "\(uuid.uuidString).png"
        try? FileManager.default.createDirectory(
            at: legacyDir.appendingPathComponent(filename),
            withIntermediateDirectories: false
        )

        storage.migrateFromLegacyIfNeeded(legacyDirectory: legacyDir, defaults: suite)

        XCTAssertFalse(suite.bool(forKey: migrationKey),
                       "STOR-4: transient failures must keep the completion flag false for retry")
        XCTAssertNil(suite.stringArray(forKey: skippedFilenamesKey),
                     "STOR-4: transient failures must NOT enter the permanent skip list")
    }
}
