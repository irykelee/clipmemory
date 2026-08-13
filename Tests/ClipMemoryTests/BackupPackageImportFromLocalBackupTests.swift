import XCTest
@testable import ClipMemory

@MainActor final class BackupPackageImportFromLocalBackupTests: XCTestCase {
    var tmpDir: URL!
    var backupDir: URL!
    var imagesDir: URL!
    var defaults: UserDefaults!
    var store: ClipboardStore!

    override func setUp() {
        super.setUp()
        let uid = UUID().uuidString
        tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("clip-import-\(uid)", isDirectory: true)
        backupDir = tmpDir.appendingPathComponent("backup", isDirectory: true)
        imagesDir = tmpDir.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "test-import-\(uid)")!
        defaults.removePersistentDomain(forName: "test-import-\(uid)")
        store = ClipboardStore(backend: MemoryStorageBackend(), defaults: defaults)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    private func writeBlob(_ name: String, _ data: Data) throws {
        try data.write(to: backupDir.appendingPathComponent(name))
    }

    func testEmptyBackupReturnsZeroResult() throws {
        let r = try BackupPackage.importFromLocalBackup(backupDir, store: store, imagesDirectory: imagesDir, defaults: defaults)
        XCTAssertEqual(r.itemsImported, 0)
        XCTAssertEqual(r.tagsImported, 0)
        XCTAssertEqual(r.imagesImported, 0)
        XCTAssertFalse(r.imageImportFailed)
    }

    func testItemsMergedIntoStore() throws {
        let itemJSON = """
        [{"id":"00000000-0000-0000-0000-000000000001","type":"text","content":"hello","contentHash":"abc","isEncrypted":false,"isPinned":false,"isSensitive":false,"appBundleID":null,"createdAt":0}]
        """.data(using: .utf8)!
        try writeBlob("items.json", itemJSON)
        let r = try BackupPackage.importFromLocalBackup(backupDir, store: store, imagesDirectory: imagesDir, defaults: defaults)
        XCTAssertEqual(r.itemsImported, 1)
        XCTAssertEqual(r.itemsSkipped, 0)
    }

    func testTrashMergedIntoStore() throws {
        let trashJSON = """
        [{"id":"00000000-0000-0000-0000-000000000002","type":"text","content":"deleted","contentHash":"def","isEncrypted":false,"isPinned":false,"isSensitive":false,"appBundleID":null,"createdAt":0,"trashedAt":100}]
        """.data(using: .utf8)!
        try writeBlob("trash.json", trashJSON)
        let r = try BackupPackage.importFromLocalBackup(backupDir, store: store, imagesDirectory: imagesDir, defaults: defaults)
        // Trash items go to trashedItems, not itemsImported (itemsImported is only from items.json)
        XCTAssertEqual(r.itemsImported, 0)
    }

    func testTagsMergedIntoStore() throws {
        let tagsJSON = """
        [{"id":"00000000-0000-0000-0000-000000000003","name":"myTag","colorHex":"#ff0000","isAutoSuggested":false,"createdAt":0}]
        """.data(using: .utf8)!
        try writeBlob("tags.json", tagsJSON)
        let r = try BackupPackage.importFromLocalBackup(backupDir, store: store, imagesDirectory: imagesDir, defaults: defaults)
        XCTAssertEqual(r.tagsImported, 1)
    }

    func testImagesCopiedWithZeroSixPermissions() throws {
        let imagesBackup = backupDir.appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesBackup, withIntermediateDirectories: true)
        let png = Data(repeating: 0, count: 100)  // placeholder bytes
        try png.write(to: imagesBackup.appendingPathComponent("00000000-0000-0000-0000-000000000010.png"))
        let r = try BackupPackage.importFromLocalBackup(backupDir, store: store, imagesDirectory: imagesDir, defaults: defaults)
        XCTAssertEqual(r.imagesImported, 1)
        XCTAssertFalse(r.imageImportFailed)
        let copied = imagesDir.appendingPathComponent("00000000-0000-0000-0000-000000000010.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: copied.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value
        XCTAssertEqual(perms, 0o600)
    }

    func testExistingImageSkipped() throws {
        let imagesBackup = backupDir.appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesBackup, withIntermediateDirectories: true)
        let name = "00000000-0000-0000-0000-000000000011.png"
        try Data(repeating: 1, count: 50).write(to: imagesBackup.appendingPathComponent(name))
        // Pre-place at destination with different bytes — must NOT be overwritten.
        let existing = Data(repeating: 2, count: 50)
        try existing.write(to: imagesDir.appendingPathComponent(name))
        let r = try BackupPackage.importFromLocalBackup(backupDir, store: store, imagesDirectory: imagesDir, defaults: defaults)
        XCTAssertEqual(r.imagesImported, 0)
        let bytes = try Data(contentsOf: imagesDir.appendingPathComponent(name))
        XCTAssertEqual(bytes, existing, "Existing image must be preserved")
    }

    func testCorruptedItemsThrows() throws {
        try writeBlob("items.json", Data("not-json".utf8))
        XCTAssertThrowsError(try BackupPackage.importFromLocalBackup(backupDir, store: store, imagesDirectory: imagesDir, defaults: defaults)) { err in
            guard case BackupPackageError.corruptedData(_, .items) = err else {
                XCTFail("expected corruptedData(_, .items), got \(err)"); return
            }
        }
    }

    func testMissingFilesTreatedAsEmpty() throws {
        // items.json / trash.json / tags.json / Images/ all absent.
        let r = try BackupPackage.importFromLocalBackup(backupDir, store: store, imagesDirectory: imagesDir, defaults: defaults)
        XCTAssertEqual(r.itemsImported, 0)
        XCTAssertEqual(r.tagsImported, 0)
    }
}
