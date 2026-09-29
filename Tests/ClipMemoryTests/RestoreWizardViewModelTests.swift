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

    // MARK: - ID-CRASH-0026 (2026-09-28 code-review P2-24): direct
    // coverage of `BackupService.previewCounts(for:)`. Without these
    // the only behavioural change vs the prior inline implementation
    // (missing tags.json degraded to 0 instead of throwing) is
    // unverified, and the auto-reviewer in this batch rightly called
    // out the prior commit body as making test-coverage claims that
    // weren't true of the existing setUp-based fixtures.

    /// Resolves the single fixture backup created in `setUp`.
    private func fixtureBackup() async throws -> LocalBackup {
        await vm.loadList()
        guard let b = vm.backups.first else {
            XCTFail("setUp did not produce a backup"); throw NSError(domain: "test", code: -1)
        }
        return b
    }

    func testPreviewCountsHappyPath() async throws {
        let b = try await fixtureBackup()
        let result = vm.backupService.previewCounts(for: b)
        XCTAssertEqual(try? result.get(),
                       BackupService.PreviewCounts(items: 0, tags: 0, images: 0))
    }

    /// ID-CRASH-0026 v2: missing tags.json is degraded to tags=0
    /// (matches `decodeTags` returning [] for missing — `BackupPackage
    /// .swift:1073-1077`). Previously this threw → wizard showed
    /// `.corrupted`; now `.valid` with a warning the empty-content
    /// banner surfaces. Behaviour change, explicitly tested.
    func testPreviewCountsMissingTagsDegradesToZero() async throws {
        let b = try await fixtureBackup()
        try FileManager.default.removeItem(
            at: b.id.appendingPathComponent("tags.json"))
        let result = vm.backupService.previewCounts(for: b)
        XCTAssertEqual(try? result.get(),
                       BackupService.PreviewCounts(items: 0, tags: 0, images: 0))
    }

    /// ID-CRASH-0026 v2: missing Images/ directory is degraded to
    /// images=0 (legitimate pre-image-feature backups exist).
    func testPreviewCountsMissingImagesDirectoryDegradesToZero() async throws {
        let b = try await fixtureBackup()
        // setUp does not create Images/ — verify the default-fall-through
        // path returns success-with-zero. (Sanity check that the
        // missing-dir case is hit by every test that uses the fixture.)
        let result = vm.backupService.previewCounts(for: b)
        XCTAssertEqual(try? result.get(),
                       BackupService.PreviewCounts(items: 0, tags: 0, images: 0))
    }

    /// ID-CRASH-0026 v2: corrupt tags.json (present but un-decodable)
    /// is ALSO degraded to 0 — design choice: degraded preview that
    /// surfaces the real error in the apply step is preferred to a
    /// hard-fail preview that hides the data behind a banner. This test
    /// pins the choice so a future "be stricter" refactor is forced
    /// to update the test and the doc comment in lockstep.
    func testPreviewCountsCorruptTagsDegradesToZero() async throws {
        let b = try await fixtureBackup()
        try Data("not valid json {[}".utf8).write(
            to: b.id.appendingPathComponent("tags.json"))
        let result = vm.backupService.previewCounts(for: b)
        XCTAssertEqual(try? result.get(),
                       BackupService.PreviewCounts(items: 0, tags: 0, images: 0))
    }

    /// ID-CRASH-0026: items.json failure is the one path that still
    /// returns `.failure` (preserves the prior behaviour — preview is
    /// not usable without an items.json). Pins this contract.
    func testPreviewCountsMissingItemsReturnsFailure() async throws {
        let b = try await fixtureBackup()
        try FileManager.default.removeItem(
            at: b.id.appendingPathComponent("items.json"))
        let result = vm.backupService.previewCounts(for: b)
        switch result {
        case .failure: break
        case .success(let counts):
            XCTFail("expected .failure for missing items.json, got success(\(counts))")
        }
    }

    /// ID-CRASH-0026: items.json that successfully decodes but
    /// contains an empty array exercises the decode path end-to-end
    /// (vs. the missing-file case above). itemsCount must be 0 from
    /// the *array length*, not from a wrongly-skipped read. The
    /// decode-with-non-trivial-items variant is covered indirectly by
    /// the live integration test (the user's existing backups);
    /// constructing a faithful ClipboardItem fixture here would just
    /// duplicate the field-by-field Codable mirror that
    /// `ClipboardItem` tests already own.
    func testPreviewCountsEmptyItemsArrayDecodesToZero() async throws {
        let b = try await fixtureBackup()
        // setUp already writes "[]" to items.json; this test just
        // pins that "[]" is a SUCCESS path with itemsCount == 0.
        let result = vm.backupService.previewCounts(for: b)
        XCTAssertEqual((try? result.get())?.items, 0)
    }

    /// ID-CRASH-0026 v3 — falsifiable coverage: encodes a real
    /// `ClipboardItem` and a real `Tag` via the same Codable
    /// infrastructure that production uses, writes them to the
    /// fixture backup, drops a `.png` into Images/, then asserts
    /// **non-zero** counts. A constant-zero implementation of
    /// `previewCounts` would FAIL this test, which is what makes
    /// the test set as a whole non-trivial (the previous 5 tests all
    /// asserted 0 and could be passed by `return PreviewCounts(0,0,0)`).
    func testPreviewCountsNonZeroCountsAreReported() async throws {
        let b = try await fixtureBackup()

        // Build a real items.json: 3 ClipboardItem records.
        let items = (0..<3).map { i in
            ClipboardItem(
                id: UUID(),
                content: "row-\(i)",
                type: .text,
                createdAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + i)),
                isPinned: false,
                isSensitive: false,
                expiresAt: nil,
                isEncrypted: false,
                contentHash: nil
            )
        }
        // Use default JSONEncoder/JSONDecoder strategies (matches production:
// `BackupService.decodeCount` / `previewCounts` / `BackupPackage.decodeItems`
// all use `JSONDecoder()` with no date-strategy override, i.e.
// `.deferredToDate` — Date encoded as TimeInterval Double).
        let encoder = JSONEncoder()
        let itemsData = try encoder.encode(items)
        try itemsData.write(to: b.id.appendingPathComponent("items.json"))

        // Build a real tags.json: 2 Tag records.
        let tags = (0..<2).map { i in
            Tag(id: UUID(), name: "tag-\(i)", colorHex: "#fbbc04", createdAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + i)))
        }
        let tagsData = try encoder.encode(tags)
        try tagsData.write(to: b.id.appendingPathComponent("tags.json"))

        // Drop 4 PNGs in Images/.
        let imagesDir = b.id.appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        for i in 0..<4 {
            let png = Data(repeating: UInt8(i), count: 8) // not a real PNG but extension check is `hasSuffix`
            try png.write(to: imagesDir.appendingPathComponent("img-\(i).png"))
        }
        // Plus one non-PNG file to verify the suffix filter.
        try Data([0]).write(to: imagesDir.appendingPathComponent("not-counted.txt"))

        let result = vm.backupService.previewCounts(for: b)
        let counts = try result.get()
        XCTAssertEqual(counts.items, 3, "items.json with 3 records must report items=3")
        XCTAssertEqual(counts.tags, 2, "tags.json with 2 records must report tags=2")
        XCTAssertEqual(counts.images, 4, "Images/ with 4 .png + 1 .txt must report images=4 (not 5)")
    }
}
