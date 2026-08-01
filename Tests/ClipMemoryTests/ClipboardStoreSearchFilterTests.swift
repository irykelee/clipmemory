import XCTest
@testable import ClipMemory

/// P0-2 T4: 加密条目解密失败 → 排除出搜索结果 + banner 显示（不再测"不外泄密文"，F1 误诊修正）
@MainActor
final class ClipboardStoreSearchFilterTests: XCTestCase {

    private var appStore: ClipboardStore!

    override func setUp() {
        super.setUp()
        CryptoService.resetForTesting()
        CryptoService.simulateKeyLoadAttemptedForTesting()
        // M12 (2026-08-01): per-test injected store — fresh instance starts
        // empty, so prior tests' items can't contaminate the filter
        // assertions (previously ClipboardStore.shared.items.removeAll()).
        appStore = ClipboardStore(backend: MemoryStorageBackend())
    }

    override func tearDown() {
        CryptoService.resetForTesting()
        super.tearDown()
    }

    func testKeyUnavailableItemExcludedFromSearchResults() throws {
        // 准备 key
        let store = MockKeyStore()
        let key = Data((0..<32).map { UInt8($0 ^ 0xCC) })
        store.store(key)
        _ = CryptoService.prepareKey(keyURL: keyURL, keyStore: store, failureHandler: { _ in .quit })

        // 注入 mock（real encrypt for addItem, simulated keyUnavailable for decrypt）
        let crypto = ToggleableKeyCrypto()
        let original = ServiceContainer.crypto
        ServiceContainer.setCryptoForTesting(crypto)
        defer { ServiceContainer.setCryptoForTesting(original) }

        // 添加 1 个明文 item（addItem 会用 crypto.encrypt 单次加密存储为 v2）
        appStore.addItem(ClipboardItem(content: "apple pie recipe", type: .text, isEncrypted: false))

        // 切换 mock 到 keyUnavailable 模式 — 之后 filter 调 getDecryptedContent 会得 nil
        crypto.simulateKeyUnavailable = true

        // 搜索"apple"应返回 0 条（keyUnavailable 时 getDecryptedContent 返回 nil → 不匹配）
        let items = appStore.items
        let filtered = items.filter { item in
            guard item.isEncrypted else { return item.content.contains("apple") }
            return appStore.getDecryptedContent(item)?.localizedCaseInsensitiveContains("apple") ?? false
        }
        XCTAssertEqual(filtered.count, 0, "keyUnavailable item should not match search (decrypt returns nil)")
    }

    func testSuccessfullyDecryptedItemMatchesSearch() throws {
        // 准备 key
        let store = MockKeyStore()
        let key = Data((0..<32).map { UInt8($0 ^ 0xCC) })
        store.store(key)
        _ = CryptoService.prepareKey(keyURL: keyURL, keyStore: store, failureHandler: { _ in .quit })

        // real crypto（不替换为 mock）
        appStore.addItem(ClipboardItem(content: "apple pie recipe", type: .text, isEncrypted: false))

        let items = appStore.items
        let filtered = items.filter { item in
            guard item.isEncrypted else { return item.content.contains("apple") }
            return appStore.getDecryptedContent(item)?.localizedCaseInsensitiveContains("apple") ?? false
        }
        XCTAssertEqual(filtered.count, 1, "successfully decrypted item should match search")
    }

    // MARK: - Test helpers

    private var keyURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("p02-t4-\(UUID().uuidString).key")
    }

    private final class MockKeyStore: KeyStoring {
        private(set) var stored: Data?
        func load() -> Data? { stored }
        func loadStatus() -> KeychainLoadStatus {
            if let s = stored { return .found(s) }
            return .notFound
        }
        @discardableResult
        func store(_ keyData: Data) -> OSStatus {
            stored = keyData
            return errSecSuccess
        }
        func delete() { stored = nil }
    }

    private final class ToggleableKeyCrypto: CryptoServiceProtocol {
        var simulateKeyUnavailable = false
        func encrypt(_ string: String) -> String? {
            simulateKeyUnavailable ? nil : CryptoService.shared.encrypt(string)
        }
        func decrypt(_ base64String: String) -> String? {
            simulateKeyUnavailable ? nil : CryptoService.shared.decrypt(base64String)
        }
        func decryptWithReason(_ base64String: String, itemID: UUID) -> DecryptResult {
            simulateKeyUnavailable ? .keyUnavailable : CryptoService.shared.decryptWithReason(base64String, itemID: itemID)
        }
        func encryptData(_ data: Data) -> Data? { simulateKeyUnavailable ? nil : CryptoService.shared.encryptData(data) }
        func decryptData(_ combined: Data) -> Data? { simulateKeyUnavailable ? nil : CryptoService.shared.decryptData(combined) }
        func isOldFormat(_ base64String: String) -> Bool { CryptoService.shared.isOldFormat(base64String) }
        func migrateToV2(_ base64String: String) -> String? { CryptoService.shared.migrateToV2(base64String) }
        func hmacHex(for string: String) -> String? { CryptoService.shared.hmacHex(for: string) }
    }
}
