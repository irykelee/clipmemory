import XCTest
@testable import ClipMemory

/// H6: key preparation must never fatalError. Every failure path routes
/// through the injectable failure handler; a corrupt key file is only
/// destroyed when the handler explicitly chooses to regenerate.
final class CryptoKeyPreparationTests: XCTestCase {

    /// Records failures and replays scripted actions; never alerts and
    /// never terminates. Actions cycle by index, clamped to the last one.
    private final class FailureRecorder {
        private(set) var failures: [CryptoKeyFailure] = []
        private let actions: [KeyFailureAction]

        init(actions: [KeyFailureAction]) {
            self.actions = actions
        }

        var handler: (CryptoKeyFailure) -> KeyFailureAction {
            { failure in
                self.failures.append(failure)
                let index = min(self.failures.count - 1, self.actions.count - 1)
                return self.actions[index]
            }
        }
    }

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CryptoKeyPreparationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Restore writability in case a test made the directory read-only.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempDir.path)
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var keyURL: URL {
        tempDir.appendingPathComponent(".encryption_key")
    }

    func testPrepareKeyGeneratesKeyFileWithSecurePerms() {
        let recorder = FailureRecorder(actions: [.quit])
        let key = CryptoService.prepareKey(keyURL: keyURL, failureHandler: recorder.handler)

        XCTAssertNotNil(key)
        XCTAssertEqual(recorder.failures, [], "fresh key generation must not invoke the failure handler")

        let data = try? Data(contentsOf: keyURL)
        XCTAssertEqual(data?.count, 32)
        let attrs = try? FileManager.default.attributesOfItem(atPath: keyURL.path)
        XCTAssertEqual(attrs?[.posixPermissions] as? Int, 0o600, "key file must be owner-only")
    }

    func testPrepareKeyLoadsExistingValidKeyWithoutHandler() {
        let existing = Data((0..<32).map { UInt8($0) })
        XCTAssertNoThrow(try existing.write(to: keyURL))

        let recorder = FailureRecorder(actions: [.quit])
        let key = CryptoService.prepareKey(keyURL: keyURL, failureHandler: recorder.handler)

        XCTAssertNotNil(key)
        XCTAssertEqual(recorder.failures, [], "a valid existing key needs no failure handler")
        // File content untouched
        XCTAssertEqual(try? Data(contentsOf: keyURL), existing)
    }

    func testPrepareKeyCorruptFileQuitLeavesFileUntouched() {
        let corrupt = Data(repeating: 0xAB, count: 10) // wrong length = corrupt
        XCTAssertNoThrow(try corrupt.write(to: keyURL))

        let recorder = FailureRecorder(actions: [.quit])
        let key = CryptoService.prepareKey(keyURL: keyURL, failureHandler: recorder.handler)

        XCTAssertNil(key, "declining regeneration leaves no key")
        XCTAssertEqual(recorder.failures, [.corruptExistingKey])
        XCTAssertEqual(try? Data(contentsOf: keyURL), corrupt, "corrupt file must survive when the user quits")
    }

    func testPrepareKeyCorruptFileRegenerateReplacesKey() {
        let corrupt = Data(repeating: 0xAB, count: 10)
        XCTAssertNoThrow(try corrupt.write(to: keyURL))

        let recorder = FailureRecorder(actions: [.regenerate])
        let key = CryptoService.prepareKey(keyURL: keyURL, failureHandler: recorder.handler)

        XCTAssertNotNil(key)
        XCTAssertEqual(recorder.failures, [.corruptExistingKey])
        XCTAssertEqual((try? Data(contentsOf: keyURL))?.count, 32, "regeneration writes a fresh 32-byte key")
    }

    func testPrepareKeyStorageFailureReturnsNilWhenQuit() throws {
        // Read-only directory makes the temp-file write fail.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: tempDir.path)

        let recorder = FailureRecorder(actions: [.quit])
        let key = CryptoService.prepareKey(keyURL: keyURL, failureHandler: recorder.handler)

        XCTAssertNil(key)
        XCTAssertEqual(recorder.failures, [.keyStorageFailed])
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyURL.path))
    }

    func testPrepareKeyStorageFailureRegenerateRetries() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: tempDir.path)

        // First failure: regenerate (retry). Still read-only → fails again;
        // second failure: quit. Bounded recursion, no crash.
        let recorder = FailureRecorder(actions: [.regenerate, .quit])
        let key = CryptoService.prepareKey(keyURL: keyURL, failureHandler: recorder.handler)

        XCTAssertNil(key)
        XCTAssertEqual(recorder.failures, [.keyStorageFailed, .keyStorageFailed],
                       "regenerate must retry the write once more")
    }
}
