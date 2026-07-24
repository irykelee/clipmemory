import XCTest
@testable import ClipMemory

/// STOR-3 (2026-07-24) regression tests: the legacy ClipPaste→ClipMemory
/// image migration runs on a utility queue instead of blocking the main
/// thread at startup (AppDelegate.setupClipboardMonitor first-touches the
/// ImageStorage singleton), while the observable contract — per-file resume
/// tracking, global completion flag, plaintext cleanup — is unchanged.
final class LegacyImageMigrationTests: XCTestCase {

    private let migrationKey = "ImageStorageMigrationComplete"
    private let migratedFilenamesKey = "ImageStorageMigratedFilenames"

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
}
