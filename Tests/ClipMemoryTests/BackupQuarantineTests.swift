import XCTest
import CryptoKit
@testable import ClipMemory

/// ID-BACKUP-0006 (2026-10-23) — 隔离副本（`.corrupt-*`）必须进备份 / 导出包，
/// 并且能在导入后还原回原来的 key。
///
/// 背景：blob 解码失败时 `quarantineCorruptBlob`
/// （`ClipboardStore+Utilities.swift` / `TrashStore.swift`）把原始字节复制到
/// `<key>.corrupt-<ISO8601 时间戳>` 并**移除原 key**。那份副本是用户原始
/// 字节的唯一留存 —— 改动前它不在备份白名单里，blob 损坏后备份不会带走
/// 它，用户的原始数据可能永久丢失。
///
/// 验收（对应任务书）：
/// 1. 损坏的 items blob 被隔离后，备份目录里出现 `Quarantine/`，其中字节
///    与隔离副本**逐字节相同**。
/// 2. 导出包里有隔离副本；导入一个**不含**隔离节的旧包不报错。
/// 3. 导入含隔离节的包后，defaults 里 `.corrupt-*` key 恢复且字节相同，
///    **主 key 未被污染**。
/// 4. 没有隔离副本时，备份 / 导出行为与改动前完全一致（不产生空的
///    `Quarantine/` 目录）。
///
/// 全程沙箱化：临时目录 + 一次性 CryptoService 密钥 + 独立 UserDefaults
/// suite；生产 `com.clipmemory.app` 域与真实 Application Support 不被触碰
/// （唯一刻意触碰 `.standard` 的用例是生产数据保护门本身，且断言「没写进去」）。
@MainActor final class BackupQuarantineTests: XCTestCase {

    private var tempRoot: URL!
    private var backupsDir: URL!
    private var imagesDir: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var localCrypto: CryptoService!
    private var store: ClipboardStore!
    private var originalCrypto: CryptoServiceProtocol?

    private let passphrase = "quarantine-secret"
    private let rootKeyBytes: Data = Data((0..<32).map { UInt8($0 & 0xFF) })

    /// 一份「损坏的 blob」字节 —— 故意不是合法 JSON，模拟解码失败的 blob。
    private let corruptBytes = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x7F])

    override func setUp() {
        super.setUp()
        let uid = UUID().uuidString
        suiteName = "BackupQuarantineTests-\(uid)"
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupQuarantineTests-\(uid)", isDirectory: true)
        backupsDir = tempRoot.appendingPathComponent("Backups", isDirectory: true)
        imagesDir = tempRoot.appendingPathComponent("Images", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        defaults = TestSuiteCleanup.makeSuite(named: suiteName)
        // ID-REVIEW-1040 follow-up: this clear was a NO-OP — a suite whose
        // name carries a fresh UUID cannot have a domain yet — and it queued
        // a **pending write** in cfprefsd, which is exactly the mechanism
        // that writes an empty shell back to disk (measured 5/40).
        localCrypto = CryptoService(customKeyData: Data((32..<64).map { UInt8($0 & 0xFF) }))
        originalCrypto = ServiceContainer.crypto
        ServiceContainer.setCryptoForTesting(localCrypto)
        store = ClipboardStore(backend: MemoryStorageBackend(), defaults: defaults)
    }

    override func tearDown() {
        if let originalCrypto { ServiceContainer.setCryptoForTesting(originalCrypto) }
        originalCrypto = nil
        if let defaults { TestSuiteCleanup.destroy(defaults) }
        defaults = nil
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        backupsDir = nil
        imagesDir = nil
        localCrypto = nil
        store = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// 走**真实**的隔离路径：把损坏 blob 放进主 key，再调用 store 的
    /// `quarantineCorruptBlob` —— 它会复制到 `<key>.corrupt-<时间戳>` 并
    /// 移除主 key。返回生成的隔离副本 key。
    ///
    /// 时间戳由运行时生成，测试**不猜**它 —— key 是从 defaults 里扫出来的。
    @discardableResult
    private func quarantineItemsBlob() throws -> String {
        defaults.set(corruptBytes, forKey: UserDefaultsKey.clipboardItems.rawValue)
        store.quarantineCorruptBlob(
            key: UserDefaultsKey.clipboardItems.rawValue,
            error: NSError(domain: "BackupQuarantineTests", code: 1)
        )
        XCTAssertNil(
            defaults.data(forKey: UserDefaultsKey.clipboardItems.rawValue),
            "quarantine must remove the original key — otherwise the corrupt blob is still live"
        )
        let quarantineKey = try XCTUnwrap(
            BackupBlobRegistry.quarantineKeys(in: defaults).first {
                $0.hasPrefix(UserDefaultsKey.clipboardItems.rawValue + BackupBlobRegistry.quarantineKeyInfix)
            },
            "quarantine must have produced a `.corrupt-*` copy"
        )
        XCTAssertEqual(defaults.data(forKey: quarantineKey), corruptBytes)
        return quarantineKey
    }

    private func makeBackupService() -> BackupService {
        BackupService(backupsDirectory: backupsDir, imagesDirectory: imagesDir, defaults: defaults)
    }

    private func runDittoZip(_ staging: URL, to packageURL: URL) throws {
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--sequesterRsrc", staging.path, packageURL.path]
        try ditto.run()
        ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0, "ditto zip failed")
    }

    /// 解开一个 `.clipmemory` 包到临时目录，返回该目录（调用方负责清理）。
    private func extractPackage(_ packageURL: URL) throws -> URL {
        let staging = tempRoot.appendingPathComponent("inspect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", packageURL.path, staging.path]
        try ditto.run()
        ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0, "ditto unzip failed")
        return staging
    }

    private func manifestJSON(in packageURL: URL) throws -> [String: Any] {
        let staging = try extractPackage(packageURL)
        defer { try? FileManager.default.removeItem(at: staging) }
        let data = try Data(contentsOf: staging.appendingPathComponent("manifest.json"))
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    /// 造一个**老版本**导出格式的包：没有 `Quarantine/` 目录，manifest 里
    /// 也没有 `quarantineCount` 字段（`BackupManifest` 的可选字段 → nil）。
    private func buildLegacyPackage() throws -> URL {
        let packageCrypto = CryptoService(customKeyData: Data((64..<96).map { UInt8($0 & 0xFF) }))
        let staging = tempRoot.appendingPathComponent("legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try Data("[]".utf8).write(to: staging.appendingPathComponent("items.json"))
        try Data("[]".utf8).write(to: staging.appendingPathComponent("trash.json"))
        try Data("[]".utf8).write(to: staging.appendingPathComponent("tags.json"))
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let derivedKey = try BackupPackage.deriveKey(passphrase: passphrase, salt: salt, version: 1)
        let sealed = try AES.GCM.seal(packageCrypto.exportKeyDataForTesting(), using: derivedKey)
        try XCTUnwrap(sealed.combined).write(to: staging.appendingPathComponent("key.enc"))
        let manifest = BackupManifest(
            formatVersion: 1,
            createdAt: Date(),
            appVersion: "test",
            keySalt: salt.base64EncodedString(),
            itemCount: 0,
            tagCount: 0,
            imageCount: 0,
            keyDerivationVersion: 1
        )
        try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent("manifest.json"))
        let packageURL = tempRoot.appendingPathComponent("legacy-\(UUID().uuidString).clipmemory")
        try runDittoZip(staging, to: packageURL)
        return packageURL
    }

    private func posixPermissions(of url: URL) -> Int? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.posixPermissions] as? NSNumber)?.intValue
    }

    // MARK: - 1. 每日备份：隔离副本进备份目录，字节逐字节相同

    /// 验收 #1：损坏的 items blob 被隔离后，备份目录里出现 `Quarantine/`，
    /// 其中字节与隔离副本**逐字节相同**。
    func testDailyBackupCarriesQuarantineCopyByteIdentical() throws {
        let quarantineKey = try quarantineItemsBlob()
        let service = makeBackupService()

        let dir = try service.backupNow()
        let quarantineDirectory = dir.appendingPathComponent(BackupBlobRegistry.quarantineDirectoryName)
        let fileURL = quarantineDirectory.appendingPathComponent(quarantineKey)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fileURL.path),
            "the backup must carry the quarantine copy at Quarantine/<full UserDefaults key>"
        )
        XCTAssertEqual(
            try Data(contentsOf: fileURL),
            corruptBytes,
            "the backed-up quarantine copy must be byte-identical to the isolated copy"
        )
        XCTAssertEqual(
            posixPermissions(of: fileURL),
            0o600,
            "the quarantine copy holds user data — file mode must stay 0o600"
        )
        XCTAssertEqual(
            posixPermissions(of: quarantineDirectory),
            0o700,
            "the Quarantine/ directory must stay 0o700"
        )
    }

    /// 回收站侧的隔离副本同样要进备份（两套源 key 都要覆盖）。
    func testDailyBackupCarriesTrashQuarantineCopy() throws {
        let trashKey = UserDefaultsKey.trashedItems.rawValue
        let trashQuarantineKey = trashKey + BackupBlobRegistry.quarantineKeyInfix + "2026-10-20T12:35:00.123Z"
        defaults.set(corruptBytes, forKey: trashQuarantineKey)

        let dir = try makeBackupService().backupNow()
        let fileURL = dir
            .appendingPathComponent(BackupBlobRegistry.quarantineDirectoryName)
            .appendingPathComponent(trashQuarantineKey)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(try Data(contentsOf: fileURL), corruptBytes)
    }

    // MARK: - 2. 导出包：隔离副本进包 / 旧包仍可导入

    /// 验收 #2a：导出的 `.clipmemory` 包里有隔离副本。
    ///
    /// 包内的字节用**包密钥整体封装**过（隔离副本在 JSON 层面已经损坏，
    /// 走不了逐条重加密），所以包内字节 ≠ 原始字节，但导入后能还原回
    /// 原始字节（见验收 #3）。
    func testExportPackageCarriesQuarantineCopy() throws {
        let quarantineKey = try quarantineItemsBlob()
        let packageURL = tempRoot.appendingPathComponent("quarantine-\(UUID().uuidString).clipmemory")

        try BackupPackage.exportPackage(
            to: packageURL,
            passphrase: passphrase,
            defaults: defaults,
            imagesDirectory: imagesDir,
            keyData: rootKeyBytes
        )

        let staging = try extractPackage(packageURL)
        defer { try? FileManager.default.removeItem(at: staging) }
        let fileURL = staging
            .appendingPathComponent(BackupBlobRegistry.quarantineDirectoryName)
            .appendingPathComponent(quarantineKey)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fileURL.path),
            "the exported package must carry the quarantine copy"
        )
        XCTAssertNotEqual(
            try Data(contentsOf: fileURL),
            corruptBytes,
            "the packaged copy must be sealed with the package key (no plaintext in the package)"
        )
        let manifest = try JSONDecoder().decode(
            BackupManifest.self,
            from: try Data(contentsOf: staging.appendingPathComponent("manifest.json"))
        )
        XCTAssertEqual(manifest.quarantineCount, 1, "the manifest must declare the quarantine copy count")
    }

    /// 验收 #2b：导入一个**不含隔离节**的旧包不报错（向后兼容）。
    func testImportOfLegacyPackageWithoutQuarantineSectionSucceeds() throws {
        let legacyPackage = try buildLegacyPackage()

        XCTAssertNoThrow(
            try BackupPackage.importPackage(
                from: legacyPackage,
                passphrase: passphrase,
                store: store,
                localCrypto: localCrypto,
                imagesDirectory: imagesDir,
                defaults: defaults
            ),
            "a package without a quarantine section must import cleanly"
        )
        XCTAssertTrue(
            BackupBlobRegistry.quarantineKeys(in: defaults).isEmpty,
            "a legacy package must not conjure quarantine copies"
        )
    }

    /// 旧包的 manifest 里根本没有 `quarantineCount` 字段 —— 解码后必须是
    /// nil（而不是 0 / 抛错），这是「按空处理」的实现基础。
    func testLegacyManifestDecodesWithoutQuarantineCount() throws {
        let legacyPackage = try buildLegacyPackage()
        let json = try manifestJSON(in: legacyPackage)
        XCTAssertNil(json["quarantineCount"], "a legacy manifest must not carry the field")
    }

    // MARK: - 3. 导入：还原回原 key，主 key 不被污染

    /// 验收 #3：导入含隔离节的包后，defaults 里 `.corrupt-*` key 恢复且字节
    /// 相同，**主 key 未被污染**。
    func testImportRestoresQuarantineCopyWithoutPollutingMainKey() throws {
        let quarantineKey = try quarantineItemsBlob()
        // 主 key 放一份「好数据」—— 导入绝不能拿损坏数据覆盖它。
        let goodMainBytes = try JSONEncoder().encode([ClipboardItem(content: "good", type: .text)])
        defaults.set(goodMainBytes, forKey: UserDefaultsKey.clipboardItems.rawValue)

        let packageURL = tempRoot.appendingPathComponent("restore-\(UUID().uuidString).clipmemory")
        try BackupPackage.exportPackage(
            to: packageURL,
            passphrase: passphrase,
            defaults: defaults,
            imagesDirectory: imagesDir,
            keyData: rootKeyBytes
        )

        // 模拟「用户已经丢了那份隔离副本」→ 导入后应恢复。
        defaults.removeObject(forKey: quarantineKey)
        XCTAssertNil(defaults.data(forKey: quarantineKey))

        _ = try BackupPackage.importPackage(
            from: packageURL,
            passphrase: passphrase,
            store: store,
            localCrypto: localCrypto,
            imagesDirectory: imagesDir,
            defaults: defaults
        )

        XCTAssertEqual(
            defaults.data(forKey: quarantineKey),
            corruptBytes,
            "the imported package must restore the quarantine copy byte-identically"
        )
        XCTAssertEqual(
            defaults.data(forKey: UserDefaultsKey.clipboardItems.rawValue),
            goodMainBytes,
            "the main key must NOT be overwritten with the quarantined (corrupt) bytes"
        )
    }

    /// 隔离副本必须写回**它自己的** key，不能被还原成主 key。
    func testImportNeverWritesQuarantineBytesToTheMainKey() throws {
        let quarantineKey = try quarantineItemsBlob()
        let packageURL = tempRoot.appendingPathComponent("nomain-\(UUID().uuidString).clipmemory")
        try BackupPackage.exportPackage(
            to: packageURL,
            passphrase: passphrase,
            defaults: defaults,
            imagesDirectory: imagesDir,
            keyData: rootKeyBytes
        )
        defaults.removeObject(forKey: quarantineKey)
        defaults.removeObject(forKey: UserDefaultsKey.clipboardItems.rawValue)

        _ = try BackupPackage.importPackage(
            from: packageURL,
            passphrase: passphrase,
            store: store,
            localCrypto: localCrypto,
            imagesDirectory: imagesDir,
            defaults: defaults
        )

        XCTAssertNil(
            defaults.data(forKey: UserDefaultsKey.clipboardItems.rawValue),
            "the main key must stay absent — a corrupt blob must never be revived as live data"
        )
        XCTAssertEqual(defaults.data(forKey: quarantineKey), corruptBytes)
    }

    /// 本地自动备份的还原路径同样要还原隔离副本 —— 否则每日备份里的那份
    /// 副本是死字节。
    func testLocalBackupRestoreCarriesQuarantineCopyBack() throws {
        let quarantineKey = try quarantineItemsBlob()
        let dir = try makeBackupService().backupNow()

        defaults.removeObject(forKey: quarantineKey)
        XCTAssertNil(defaults.data(forKey: quarantineKey))

        _ = try BackupPackage.importFromLocalBackup(
            dir,
            store: store,
            imagesDirectory: imagesDir,
            defaults: defaults
        )

        XCTAssertEqual(
            defaults.data(forKey: quarantineKey),
            corruptBytes,
            "restoring a local backup must bring the quarantine copy back"
        )
    }

    // MARK: - 4. 没有隔离副本时，行为与改动前完全一致

    /// 验收 #4a：没有隔离副本时，每日备份**不产生**空的 `Quarantine/` 目录。
    func testBackupWithoutQuarantineCreatesNoQuarantineDirectory() throws {
        // 放一份正常的 items blob —— 备份本身要有内容，「没有隔离副本」才是
        // 唯一的差异。
        defaults.set(
            try JSONEncoder().encode([ClipboardItem(content: "good", type: .text)]),
            forKey: UserDefaultsKey.clipboardItems.rawValue
        )
        let dir = try makeBackupService().backupNow()
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: dir.appendingPathComponent(BackupBlobRegistry.quarantineDirectoryName).path
            ),
            "no quarantine copies → no Quarantine/ directory at all"
        )
        // 常规 blob 仍在（备份本身没坏）。
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("items.json").path))
    }

    /// 验收 #4b：没有隔离副本时，导出包里没有 `Quarantine/`，且 manifest 里
    /// `quarantineCount` 字段整个不出现。
    ///
    /// 断言的是「**字段缺席**」，不是「字节与改动前一致」：实测同一个
    /// manifest 连续编码会得到不同的字节序列（JSON 键序不稳定，跨进程更是
    /// 完全不同），字节从来不是这里的契约 —— 字段在不在才是。下面读的是
    /// JSON 对象（按 key 查），不是原始字节。
    func testExportWithoutQuarantineProducesNoQuarantineSection() throws {
        defaults.set(
            try JSONEncoder().encode([ClipboardItem(content: "good", type: .text)]),
            forKey: UserDefaultsKey.clipboardItems.rawValue
        )
        let packageURL = tempRoot.appendingPathComponent("plain-\(UUID().uuidString).clipmemory")
        try BackupPackage.exportPackage(
            to: packageURL,
            passphrase: passphrase,
            defaults: defaults,
            imagesDirectory: imagesDir,
            keyData: rootKeyBytes
        )

        let staging = try extractPackage(packageURL)
        defer { try? FileManager.default.removeItem(at: staging) }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: staging.appendingPathComponent(BackupBlobRegistry.quarantineDirectoryName).path
            ),
            "no quarantine copies → the package must not carry an empty Quarantine/ section"
        )
        let json = try manifestJSON(in: packageURL)
        XCTAssertNil(
            json["quarantineCount"],
            "no quarantine copies → the manifest must not carry the field at all"
        )
    }

    // MARK: - 5. 生产数据保护门

    /// 写回前必须过 TestIsolation 的生产数据保护：测试进程不许把隔离副本
    /// 写进生产的 `com.clipmemory.app` 域。
    func testRestoreRefusesProductionDomainMutation() throws {
        let quarantineKey = try quarantineItemsBlob()
        let packageURL = tempRoot.appendingPathComponent("guarded-\(UUID().uuidString).clipmemory")
        try BackupPackage.exportPackage(
            to: packageURL,
            passphrase: passphrase,
            defaults: defaults,
            imagesDirectory: imagesDir,
            keyData: rootKeyBytes
        )

        XCTAssertThrowsError(
            try BackupPackage.importPackage(
                from: packageURL,
                passphrase: passphrase,
                store: store,
                localCrypto: localCrypto,
                imagesDirectory: imagesDir,
                // ALLOW-PRODUCTION-WRITE: deliberate — the restore must be aimed at the
                // production domain, because the thing under test is the guard that
                // refuses production mutations in a test process.
                defaults: .standard
            ),
            "the production-data guard must refuse the restore in a test process"
        ) { error in
            guard case BackupPackageError.quarantineRestoreRefused = error else {
                XCTFail("expected quarantineRestoreRefused, got \(error)")
                return
            }
        }
        XCTAssertNil(
            UserDefaults.standard.data(forKey: quarantineKey),
            "the guard must prevent writing into the production domain"
        )
    }

    // MARK: - 6. key 形态与收集规则

    /// 隔离副本的 key 形态必须与 `quarantineCorruptBlob` 的构造一致 ——
    /// `<源 key>.corrupt-<ISO8601 时间戳>`。
    func testQuarantineKeyShapeMatchesQuarantineConstruction() {
        for sourceKey in BackupBlobRegistry.quarantineSourceKeys {
            XCTAssertTrue(
                BackupBlobRegistry.isQuarantineKey("\(sourceKey).corrupt-2026-10-20T12:34:56.789Z"),
                "\(sourceKey) quarantine key must be recognized"
            )
            XCTAssertFalse(
                BackupBlobRegistry.isQuarantineKey(sourceKey),
                "the plain source key is not a quarantine key"
            )
            XCTAssertFalse(
                BackupBlobRegistry.isQuarantineKey("\(sourceKey).loadFailed"),
                "the load-failed sentinel must not be mistaken for a quarantine copy"
            )
        }
    }

    /// 收集路径要覆盖 items / tags / trash 三个源 key —— 三处
    /// `quarantineCorruptBlob` 调用点都产生这种 key。
    func testQuarantineKeysCoverEveryQuarantinableSourceKey() {
        XCTAssertEqual(
            Set(BackupBlobRegistry.quarantineSourceKeys),
            [
                UserDefaultsKey.clipboardItems.rawValue,
                UserDefaultsKey.clipboardTags.rawValue,
                UserDefaultsKey.trashedItems.rawValue
            ],
            "every blob whose load can quarantine must be covered"
        )
    }

    /// 收集规则：只收 `.corrupt-*` 且值是 Data 的 key。
    func testQuarantineKeysCollectsOnlyDataValuedQuarantineKeys() throws {
        let itemsKey = UserDefaultsKey.clipboardItems.rawValue
        let trashKey = UserDefaultsKey.trashedItems.rawValue
        defaults.set(Data([1, 2, 3]), forKey: itemsKey + ".corrupt-2026-10-20T12:34:56.789Z")
        defaults.set(Data([4, 5, 6]), forKey: trashKey + ".corrupt-2026-10-20T12:35:00.123Z")
        // 干扰项：不是隔离副本 / 值不是 Data。
        defaults.set(Data([7]), forKey: itemsKey)
        defaults.set("not-a-blob", forKey: trashKey + ".corrupt-2026-10-20T12:36:00.000Z")
        defaults.set("noise", forKey: "SomeOtherSetting")

        let keys = BackupBlobRegistry.quarantineKeys(in: defaults)
        XCTAssertEqual(
            keys,
            [
                itemsKey + ".corrupt-2026-10-20T12:34:56.789Z",
                trashKey + ".corrupt-2026-10-20T12:35:00.123Z"
            ],
            "only Data-valued `.corrupt-*` keys are collected, sorted"
        )
    }

    /// 隔离副本的 key 会**原样**当文件名用 —— 路径穿越必须被挡住。
    func testQuarantineKeyRejectsPathTraversal() {
        XCTAssertFalse(
            BackupBlobRegistry.isQuarantineKey("ClipboardItems.corrupt-../../../../etc/passwd"),
            "a traversal-shaped key must never be accepted as a backup filename"
        )
        XCTAssertFalse(
            BackupBlobRegistry.isQuarantineKey("ClipboardItems.corrupt-"),
            "an empty timestamp suffix is not a quarantine key"
        )
    }
}
