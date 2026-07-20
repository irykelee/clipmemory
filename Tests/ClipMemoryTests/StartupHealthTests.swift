import XCTest
import os.log
@testable import ClipMemory

/// A.2 observability: one-time startup health snapshot.
/// Tests exercise the pure Snapshot description + side-effect-free
/// `snapshot(keyStore:imagesDirectory:fileManager:defaults:)` and the
/// `logSnapshot` UserDefaults write. They never touch the real ClipboardStore
/// or Keychain so live history stays untouched (per C1 test-never-touch-prod-data).
final class StartupHealthTests: XCTestCase {

    private var defaults: UserDefaults!
    private var fakeKeyStore: FakeKeyStore!
    private var tempImagesDir: URL!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "test-startup-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        fakeKeyStore = FakeKeyStore(hasKey: true)
        tempImagesDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("startup-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempImagesDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tempImagesDir)
        super.tearDown()
    }

    // MARK: - Snapshot description formatting (pure)

    func testSnapshotDescriptionContainsAllFields() {
        let snapshot = StartupHealth.Snapshot(
            version: "2.5.6",
            macosVersion: "macOS 14.5",
            keychainKeyExists: true,
            itemsCount: 42,
            trashedCount: 3,
            tagsCount: 5,
            imagesCount: 10,
            lastLaunchTime: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let desc = snapshot.description
        XCTAssertTrue(desc.contains("version=2.5.6"), desc)
        XCTAssertTrue(desc.contains("macos=macOS 14.5"), desc)
        XCTAssertTrue(desc.contains("keychain=true"), desc)
        XCTAssertTrue(desc.contains("items=42"), desc)
        XCTAssertTrue(desc.contains("trashed=3"), desc)
        XCTAssertTrue(desc.contains("tags=5"), desc)
        XCTAssertTrue(desc.contains("images=10"), desc)
        XCTAssertTrue(desc.contains("lastLaunch="), desc)
    }

    func testSnapshotDescriptionNilLastLaunch() {
        let snapshot = StartupHealth.Snapshot(
            version: "2.5.6",
            macosVersion: "macOS 14.5",
            keychainKeyExists: false,
            itemsCount: 0,
            trashedCount: 0,
            tagsCount: 0,
            imagesCount: 0,
            lastLaunchTime: nil
        )
        XCTAssertTrue(snapshot.description.contains("lastLaunch=never"))
    }

    // MARK: - snapshot() field reads via injected deps

    func testSnapshotKeychainTrueWhenKeyPresent() {
        fakeKeyStore = FakeKeyStore(hasKey: true)
        let snap = StartupHealth.snapshot(
            keyStore: fakeKeyStore,
            imagesDirectory: tempImagesDir,
            defaults: defaults
        )
        XCTAssertTrue(snap.keychainKeyExists)
    }

    func testSnapshotKeychainFalseWhenKeyAbsent() {
        fakeKeyStore = FakeKeyStore(hasKey: false)
        let snap = StartupHealth.snapshot(
            keyStore: fakeKeyStore,
            imagesDirectory: tempImagesDir,
            defaults: defaults
        )
        XCTAssertFalse(snap.keychainKeyExists)
    }

    func testSnapshotImagesCount() throws {
        for i in 0..<3 {
            let url = tempImagesDir.appendingPathComponent("img\(i).jpg")
            try Data().write(to: url)
        }
        let snap = StartupHealth.snapshot(
            keyStore: fakeKeyStore,
            imagesDirectory: tempImagesDir,
            defaults: defaults
        )
        XCTAssertEqual(snap.imagesCount, 3)
    }

    func testSnapshotImagesCountZeroForEmptyDir() {
        let snap = StartupHealth.snapshot(
            keyStore: fakeKeyStore,
            imagesDirectory: tempImagesDir,
            defaults: defaults
        )
        XCTAssertEqual(snap.imagesCount, 0)
    }

    func testSnapshotImagesCountReturnsZeroForMissingDir() {
        let missingDir = tempImagesDir.appendingPathComponent("nonexistent")
        let snap = StartupHealth.snapshot(
            keyStore: fakeKeyStore,
            imagesDirectory: missingDir,
            defaults: defaults
        )
        XCTAssertEqual(snap.imagesCount, 0)
    }

    func testSnapshotReadsLastLaunchTimeFromDefaults() {
        let stored = Date(timeIntervalSince1970: 1_650_000_000)
        defaults.set(stored, forKey: "lastLaunchTime")
        let snap = StartupHealth.snapshot(
            keyStore: fakeKeyStore,
            imagesDirectory: tempImagesDir,
            defaults: defaults
        )
        XCTAssertEqual(snap.lastLaunchTime, stored)
    }

    func testSnapshotLastLaunchNilWhenAbsent() {
        let snap = StartupHealth.snapshot(
            keyStore: fakeKeyStore,
            imagesDirectory: tempImagesDir,
            defaults: defaults
        )
        XCTAssertNil(snap.lastLaunchTime)
    }

    func testSnapshotReadsAppVersion() {
        let snap = StartupHealth.snapshot(
            keyStore: fakeKeyStore,
            imagesDirectory: tempImagesDir,
            defaults: defaults
        )
        XCTAssertFalse(snap.version.isEmpty)
    }

    func testSnapshotReadsMacOSVersion() {
        let snap = StartupHealth.snapshot(
            keyStore: fakeKeyStore,
            imagesDirectory: tempImagesDir,
            defaults: defaults
        )
        XCTAssertFalse(snap.macosVersion.isEmpty)
    }

    // MARK: - logSnapshot side effects

    func testLogSnapshotWritesLastLaunchTime() {
        StartupHealth.logSnapshot(
            keyStore: fakeKeyStore,
            imagesDirectory: tempImagesDir,
            defaults: defaults
        )
        let stored = defaults.object(forKey: "lastLaunchTime") as? Date
        XCTAssertNotNil(stored)
        XCTAssertLessThan(abs(stored!.timeIntervalSinceNow), 5)
    }

    func testLogSnapshotDoesNotOverwriteBeforeReading() {
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        defaults.set(old, forKey: "lastLaunchTime")

        StartupHealth.logSnapshot(
            keyStore: fakeKeyStore,
            imagesDirectory: tempImagesDir,
            defaults: defaults
        )

        let stored = defaults.object(forKey: "lastLaunchTime") as? Date
        XCTAssertNotNil(stored)
        XCTAssertNotEqual(stored!.timeIntervalSince1970, 1_600_000_000, accuracy: 1.0)
        XCTAssertLessThan(abs(stored!.timeIntervalSinceNow), 5)
    }

    // MARK: - Fake KeyStoring

    private final class FakeKeyStore: KeyStoring {
        let hasKey: Bool
        init(hasKey: Bool) { self.hasKey = hasKey }
        func load() -> Data? { hasKey ? Data([1, 2, 3, 4]) : nil }
        func store(_ keyData: Data) -> OSStatus { errSecSuccess }
        func delete() {}
    }
}
