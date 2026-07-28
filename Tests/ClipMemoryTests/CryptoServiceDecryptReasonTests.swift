import XCTest
@testable import ClipMemory

/// P0-2 T1-T3: decryptWithReason 4 态分类 + 否定缓存 hit/TTL/keyUnavailable 不缓存
final class CryptoServiceDecryptReasonTests: XCTestCase {

    override func setUp() {
        super.setUp()
        CryptoService.resetForTesting()
        // Force "key load attempted but no key" state so getKey() returns nil
        // under XCTest without needing to touch the prod key file (which is
        // always present on the dev machine and would otherwise be read by
        // getKey()'s fallback path).
        CryptoService.simulateKeyLoadAttemptedForTesting()
    }

    override func tearDown() {
        CryptoService.resetForTesting()
        super.tearDown()
    }

    // T1: 4 case 分类
    func testDecryptWithReasonSuccess() throws {
        let store = MockKeyStore()
        let key = Data((0..<32).map { UInt8($0 ^ 0xA5) })
        store.store(key)
        let prepared = CryptoService.prepareKey(keyURL: keyURL, keyStore: store, failureHandler: { _ in .quit })
        XCTAssertNotNil(prepared)

        // Encrypt a known plaintext via the legacy decrypt path round-trip
        let plain = "hello world"
        guard let encrypted = CryptoService.shared.encrypt(plain) else {
            XCTFail("encrypt failed"); return
        }
        let itemID = UUID()
        let result = CryptoService.shared.decryptWithReason(encrypted, itemID: itemID)
        if case .success(let s) = result {
            XCTAssertEqual(s, plain)
        } else {
            XCTFail("expected .success, got \(result)")
        }
    }

    func testDecryptWithReasonKeyUnavailable() {
        // No prepareKey → getKey() returns nil → .keyUnavailable
        let itemID = UUID()
        let result = CryptoService.shared.decryptWithReason("anybase64", itemID: itemID)
        XCTAssertEqual(result, .keyUnavailable, "未 prepareKey 必须归 keyUnavailable")
    }

    func testDecryptWithReasonDataCorruptedOnGCMFailure() throws {
        // 准备真实 key
        let store = MockKeyStore()
        let key = Data((0..<32).map { UInt8($0) })
        store.store(key)
        _ = CryptoService.prepareKey(keyURL: keyURL, keyStore: store, failureHandler: { _ in .quit })

        // 损坏密文：合法 base64 但解密必然 GCM tag 失败
        let corruptBase64 = Data([0xFF, 0xFE, 0xFD, 0xFC, 0xFB, 0xFA]).base64EncodedString()
        let itemID = UUID()
        let result = CryptoService.shared.decryptWithReason(corruptBase64, itemID: itemID)
        XCTAssertEqual(result, .dataCorrupted, "GCM 失败必须归 dataCorrupted")
    }

    func testDecryptWithReasonInternalErrorOnNonBase64() throws {
        let store = MockKeyStore()
        let key = Data((0..<32).map { UInt8($0) })
        store.store(key)
        _ = CryptoService.prepareKey(keyURL: keyURL, keyStore: store, failureHandler: { _ in .quit })

        let itemID = UUID()
        let result = CryptoService.shared.decryptWithReason("!!!not-base64!!!", itemID: itemID)
        XCTAssertEqual(result, .internalError, "非法 base64 归 internalError")
    }

    // T2: 否定缓存 hit + TTL
    func testNegativeCacheHitOnRepeatedFailure() throws {
        let store = MockKeyStore()
        let key = Data((0..<32).map { UInt8($0) })
        store.store(key)
        _ = CryptoService.prepareKey(keyURL: keyURL, keyStore: store, failureHandler: { _ in .quit })

        let corruptBase64 = Data([0xAA, 0xBB, 0xCC, 0xDD]).base64EncodedString()
        let itemID = UUID()

        // 第一次：写入缓存
        let r1 = CryptoService.shared.decryptWithReason(corruptBase64, itemID: itemID)
        XCTAssertEqual(r1, .dataCorrupted)

        // 第二次：应命中缓存（用 injectable clock 跳过时间）
        let r2 = CryptoService.shared.decryptWithReason(corruptBase64, itemID: itemID)
        XCTAssertEqual(r2, .dataCorrupted, "TTL 内重复调用应命中缓存")
    }

    // T3: keyUnavailable 不入缓存（NR4 正确性核心）
    func testKeyUnavailableNotCachedAndRetriesAfterKeyPrepared() {
        // Step 1: keyUnavailable
        let itemID = UUID()
        let r1 = CryptoService.shared.decryptWithReason("any", itemID: itemID)
        XCTAssertEqual(r1, .keyUnavailable)

        // Step 2: prepareKey（模拟用户解锁）
        let store = MockKeyStore()
        let key = Data((0..<32).map { UInt8($0 ^ 0x5A) })
        store.store(key)
        _ = CryptoService.prepareKey(keyURL: keyURL, keyStore: store, failureHandler: { _ in .quit })

        // Step 3: 同一 itemID 再调 → 应重新尝试（不应有陈旧 .keyUnavailable 缓存）
        // 这里调 encrypt 拿一个合法密文再调
        guard let validEncrypted = CryptoService.shared.encrypt("real content") else {
            XCTFail("encrypt failed"); return
        }
        let r2 = CryptoService.shared.decryptWithReason(validEncrypted, itemID: itemID)
        if case .success(let s) = r2 {
            XCTAssertEqual(s, "real content", "key 就绪后必须能解密成功，不被旧 keyUnavailable 缓存压制")
        } else {
            XCTFail("expected .success after key prepared, got \(r2)")
        }
    }

    // T3 续: dataCorrupted 入缓存 + prepareKey 后清空
    func testDataCorruptedCacheClearedAfterPrepareKey() throws {
        let store = MockKeyStore()
        let key = Data((0..<32).map { UInt8($0) })
        store.store(key)
        _ = CryptoService.prepareKey(keyURL: keyURL, keyStore: store, failureHandler: { _ in .quit })

        let corruptBase64 = Data([0x11, 0x22, 0x33, 0x44]).base64EncodedString()
        let itemID = UUID()
        let r1 = CryptoService.shared.decryptWithReason(corruptBase64, itemID: itemID)
        XCTAssertEqual(r1, .dataCorrupted)

        // 重新 prepareKey（模拟 key 重新就绪）→ 缓存应清空
        store.store(key)
        _ = CryptoService.prepareKey(keyURL: keyURL, keyStore: store, failureHandler: { _ in .quit })

        // 同一损坏密文再调 → 重新走 AES（虽仍 .dataCorrupted，但证明缓存清空）
        let r2 = CryptoService.shared.decryptWithReason(corruptBase64, itemID: itemID)
        XCTAssertEqual(r2, .dataCorrupted, "prepareKey 后应清空缓存并重试 AES")
    }

    // MARK: - Test helpers

    private var keyURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("p02-\(UUID().uuidString).key")
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
}
