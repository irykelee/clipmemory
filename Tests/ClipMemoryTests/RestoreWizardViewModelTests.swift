import XCTest
@testable import ClipMemory

@MainActor
final class RestoreWizardViewModelTests: XCTestCase {
    var tmpDir: URL!
    var backupDir: URL!
    var imagesDir: URL!
    var vm: RestoreWizardViewModel!

    override func setUp() async throws {
        try await super.setUp()
        let uid = UUID().uuidString
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("clip-vm-\(uid)", isDirectory: true)
        backupDir = tmpDir.appendingPathComponent("backups", isDirectory: true)
        imagesDir = tmpDir.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        // Make one valid backup.
        let dir = backupDir.appendingPathComponent("2026-08-01_120000.000", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: dir.appendingPathComponent("items.json"))
        try Data("[]".utf8).write(to: dir.appendingPathComponent("tags.json"))

        let service = BackupService(backupsDirectory: backupDir, imagesDirectory: imagesDir,
                                    defaults: UserDefaults(suiteName: "test-vm-\(uid)")!,
                                    fileManager: FileManager.default)
        vm = RestoreWizardViewModel(backupService: service, imagesDirectory: imagesDir, defaults: .init(suiteName: "test-vm-defaults-\(uid)")!)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        try await super.tearDown()
    }

    func testInitialStateIsSelectSource() {
        XCTAssertEqual(vm.step, .selectSource)
        XCTAssertNil(vm.source)
        XCTAssertEqual(vm.validation, .pending)
    }

    func testLoadListPopulatesBackups() async throws {
        await vm.loadList()
        XCTAssertEqual(vm.backups.count, 1)
        XCTAssertEqual(vm.backups.first?.directoryName, "2026-08-01_120000.000")
    }

    func testLoadListEmptyBackupsLeavesBackupsEmpty() async throws {
        try? FileManager.default.removeItem(at: backupDir.appendingPathComponent("2026-08-01_120000.000"))
        await vm.loadList()
        XCTAssertEqual(vm.backups.count, 0)
        // Wizard shows fallback view based on `backups.isEmpty && source == nil`.
    }

    func testSelectLocalBackupMovesToValidate() async throws {
        await vm.loadList()
        guard let backup = vm.backups.first else { XCTFail("no backup"); return }
        vm.selectLocalBackup(backup)
        // Wait for validation to complete (synchronous for local).
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNotNil(vm.source)
        XCTAssertEqual(vm.step, .preview)
        if case .valid(let preview) = vm.validation {
            XCTAssertEqual(preview.itemsCount, 0)
        } else {
            XCTFail("expected .valid, got \(vm.validation)")
        }
    }

    func testIncompleteBackupStillListedButUIHandlesDisable() async throws {
        let incompleteDir = backupDir.appendingPathComponent("2026-08-02_120000.000", isDirectory: true)
        try FileManager.default.createDirectory(at: incompleteDir, withIntermediateDirectories: true)
        try Data().write(to: incompleteDir.appendingPathComponent(BackupService.incompleteMarkerName))
        await vm.loadList()
        XCTAssertEqual(vm.backups.count, 2)
        XCTAssertNotNil(vm.backups.first(where: { $0.isIncomplete }))
    }

    // MARK: - External file validation tests
    //
    // The canonical wrongPassword / corrupted / archiveFailed / oversized
    // tests live in `BackupPackageValidateExternalPackageTests` (Task 2.5) —
    // the error mapping is service-owned, so the canonical regression test
    // belongs there. These two tests cover the VM's pure state-mapping layer.

    func testBeginExternalValidationSetsSourceAndAdvancesToValidate() throws {
        // Use a non-existent URL — validation won't fire until passphrase submit.
        let url = URL(fileURLWithPath: "/tmp/doesnt-exist.clipmemory")
        vm.beginExternalValidation(url: url)
        XCTAssertEqual(vm.step, .validate)
        if case .externalFile(let u) = vm.source { XCTAssertEqual(u, url) } else { XCTFail("expected .externalFile") }
        XCTAssertEqual(vm.validation, .pending)
        XCTAssertEqual(vm.passphrase, "")
    }

    func testValidateExternalCorruptedFileSetsCorruptedState() async {
        // Non-existent file → archiveFailed or similar in the ditto step.
        let url = URL(fileURLWithPath: "/tmp/doesnt-exist-\(UUID().uuidString).clipmemory")
        vm.beginExternalValidation(url: url)
        await vm.validateExternal(url: url, passphrase: "anything")
        if case .corrupted = vm.validation { } else {
            XCTFail("expected .corrupted, got \(vm.validation)")
        }
    }

    // NOTE: wrongPassword reachability is covered by
    // `BackupPackageValidateExternalPackageTests.testWrongPassphraseThrowsWrongPassword`
    // (Task 2.5) — the canonical error mapping lives in the service, so
    // the canonical regression test belongs there too.
}
