import XCTest
@testable import ClipMemory

/// ID-REVIEW-1043：测试进程不得触碰**生产钥匙串项**
/// （`com.clipmemory.app` / `root-encryption-key`）—— 那是**用户的全局资源**。
///
/// ⑬ = 测试往生产域写，⑭ = 测试往用户磁盘写垃圾，⑮ = 测试毁用户剪贴板，
/// ⑯ = 测试把夹具文本写进用户剪贴板 ⇒ 本条是**同族第 5 例**：
/// 测试进程**读**用户的真实根密钥，并**删掉**测试自己的 key 文件。
///
/// ## 判据为什么是「哨兵文件还在不在」
///
/// 生产分支一旦进入，`attemptKeychainLoad` 的 `.published` 分支会调用
/// `secureRemoveKeyFile(at: keyURL)` 把 XCTest 的 key 文件
/// （`ClipMemory/Keys-Tests/.encryption_key`）**删掉**
/// ⇒ **哨兵是否还在** = 「生产钥匙串有没有被查」的**可证伪**判据。
///
/// 实测（2026-10-27，修之前）：直接调用 `retryPrepareKeyIfLocked()` 和
/// 发 `NSWorkspace.sessionDidBecomeActiveNotification` **两条路径都把哨兵删了**
/// ⇒ 测试进程确实查了生产钥匙串（只读：生产项 mtime 与密钥字节均未变）。
///
/// ## 修法（两处，缺一不可）
///
/// 1. `CryptoService.prepareKey` —— **唯一的收敛点**：XCTest 下若拿到的
///    是**生产身份**的 `KeychainKeyStore`（service == `defaultService`）
///    就**拒绝对外服务**。注入的 mock / 测试专用 service **不受影响**
///    （迁移分支的测试正依赖它们）。
/// 2. `AppDelegate.setupKeychainUnlockObserver` —— 测试宿主里**根本不注册**
///    唤醒 / 解锁 observer（它带着 `prewarmIfNeeded` 的副作用，本来也不该在
///    测试里跑）。
final class Review1043RegressionTests: XCTestCase {

    // MARK: - 哨兵（key 文件）

    /// XCTest 下的 root key 文件（`ClipMemory/Keys-Tests/.encryption_key`）。
    private var keyURL: URL { CryptoService.keyFileURL }

    private var fm: FileManager { FileManager.default }

    /// 装一个 32 字节哨兵 key 文件，并返回恢复现场的闭包。
    ///
    /// ⚠️ 必须**先备份**原文件：测试跑完之后要把现场还原回去，
    /// 否则这一条测试就会污染后面所有依赖 key 文件的测试。
    private func withSentinelKeyFile(_ body: () -> Void) {
        let existed = fm.fileExists(atPath: keyURL.path)
        let backup = existed ? try? Data(contentsOf: keyURL) : nil
        defer {
            try? fm.removeItem(at: keyURL)
            if let backup {
                try? backup.write(to: keyURL)
                // 还原权限：key 文件必须是 0o600（`prepareLegacyFileKeyForTests`
                // 就是这么写的）—— 还原时漏掉会把用户的 key 文件降成 0o644。
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
            }
            CryptoService.shared.clearInMemoryKey()
        }
        let sentinel = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        try? sentinel.write(to: keyURL)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        // 清掉内存里的 key —— 否则 `retryPrepareKeyIfLocked` 的幂等检查会
        // 直接返回，**根本不会**走到钥匙串 ⇒ 断言会变成空绿。
        CryptoService.shared.clearInMemoryKey()
        body()
    }

    private func sentinelAlive() -> Bool {
        fm.fileExists(atPath: keyURL.path)
    }

    // MARK: - 行为守卫

    /// ① `retryPrepareKeyIfLocked()`（默认参数 = 生产 `KeychainKeyStore`）
    ///    不得查生产钥匙串。
    func testRetryPrepareKeyIfLockedDoesNotQueryProductionKeychain() {
        withSentinelKeyFile {
            _ = CryptoService.retryPrepareKeyIfLocked()
            XCTAssertTrue(
                sentinelAlive(),
                "retryPrepareKeyIfLocked 不得进入生产钥匙串路径（哨兵被删 ⇒ 生产项被查了）"
            )
        }
    }

    /// ② `prepareKey()` 的**默认** store 就是生产 `KeychainKeyStore`
    ///    —— 这是所有生产路径的收敛点，必须在这里就被拒。
    func testPrepareKeyWithDefaultStoreDoesNotQueryProductionKeychain() {
        withSentinelKeyFile {
            _ = CryptoService.prepareKey(failureHandler: { _ in .quit })
            XCTAssertTrue(
                sentinelAlive(),
                "prepareKey 不得查询生产钥匙串（哨兵被删 ⇒ 生产项被查了）"
            )
        }
    }

    /// ③ 真实通知路径：发 `NSWorkspace.sessionDidBecomeActiveNotification`
    ///    （AppDelegate 的 observer 就挂在它上面）⇒ 走完整链路。
    func testSessionBecomesActiveNotificationDoesNotQueryProductionKeychain() {
        withSentinelKeyFile {
            NSWorkspace.shared.notificationCenter.post(
                name: NSWorkspace.sessionDidBecomeActiveNotification,
                object: nil
            )
            // observer 的 queue 是 .main ⇒ 要转主 run loop 才会执行
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            XCTAssertTrue(
                sentinelAlive(),
                "唤醒 / 解锁通知路径不得查生产钥匙串（哨兵被删 ⇒ 生产项被查了）"
            )
        }
    }

    /// ④ 测试宿主里**不得**注册唤醒 / 解锁 observer。
    ///
    /// 用 `Mirror` 读 `AppDelegate` 的三个 observer token 属性 —— 判据是
    /// **结果**（token 为 nil = 没注册），不是「源码里有没有某句话」。
    func testKeychainUnlockObserverIsNotRegisteredInTestHost() throws {
        let delegate = try XCTUnwrap(
            NSApp.delegate as? AppDelegate,
            "测试宿主里 AppDelegate 应已启动（TEST_HOST = 真 app）"
        )
        let children = Mirror(reflecting: delegate).children
        var values: [String: Any] = [:]
        for child in children {
            if let label = child.label { values[label] = child.value }
        }
        for name in ["keychainUnlockObserver", "sessionBecomeActiveObserver", "didBecomeActiveObserver"] {
            let value = try XCTUnwrap(
                values[name],
                "AppDelegate 应保有 \(name) 属性（否则这条守卫在空跑）"
            )
            XCTAssertTrue(
                Self.isNilOptional(value),
                "测试宿主里 \(name) 不应是已注册的 observer token"
            )
        }
    }

    // MARK: - 控制组（证明守卫不是「一刀切拒绝」）

    /// ⑤ 注入的 mock store **仍然要被 consulted** —— 守卫必须精确到
    ///    「生产身份」，不能把测试专用 store 也一起拒掉。
    func testInjectedStoreIsStillConsulted() {
        let spy = RecordingKeyStore()
        _ = CryptoService.prepareKey(
            keyURL: Self.missingKeyURL,
            keyStore: spy,
            failureHandler: { _ in .quit }
        )
        XCTAssertTrue(
            spy.loadStatusCalls > 0,
            "注入的 store 必须仍被查询（守卫只该拒生产身份，不该一刀切）"
        )
        CryptoService.shared.clearInMemoryKey()
    }

    /// ⑥ **非生产 service** 的 `KeychainKeyStore` 也要被 consulted ——
    ///    守卫的判据是 **service**，不是「类型是不是 KeychainKeyStore」。
    func testNonProductionKeychainServiceIsStillConsulted() throws {
        let service = "com.clipmemory.tests-\(UUID().uuidString)"
        let store = KeychainKeyStore(service: service, account: "probe")
        defer { store.delete() }
        _ = CryptoService.prepareKey(
            keyURL: Self.missingKeyURL,
            keyStore: store,
            failureHandler: { _ in .quit }
        )
        XCTAssertNotNil(
            store.load(),
            "非生产 service 的 KeychainKeyStore 必须仍被写入（守卫按 service 判定，不是按类型）"
        )
        CryptoService.shared.clearInMemoryKey()
    }

    /// ⑦ `Mirror` 判据自身的控制组：探测器必须能分辨「nil」与「非 nil」，
    ///    否则守卫 ④ 会空绿。
    func testNilOptionalDetectorDiscriminates() throws {
        let none: NSObjectProtocol? = nil
        let some: NSObjectProtocol? = NSObject()
        XCTAssertTrue(Self.isNilOptional(none), "nil 必须被识别为 nil")
        XCTAssertFalse(Self.isNilOptional(some), "非 nil 必须被识别为非 nil")
    }

    // MARK: - 判定函数（纯函数 ⇒ 两侧都可测）

    /// ⑧ XCTest ⇒ **拒**生产身份。
    func testDecisionFunctionRefusesProductionIdentityUnderXCTest() {
        XCTAssertTrue(
            CryptoService.shouldRefuseKeychainStore(
                isRunningTests: true,
                keyStore: KeychainKeyStore()
            ),
            "XCTest 下必须拒绝生产身份的 KeychainStore"
        )
    }

    /// ⑨ 生产 ⇒ **绝不拒**。
    ///
    /// ⚠️ 这一条是「把 `isRunningTests` 条件去掉」那条变异**唯一**能抓住的
    /// 地方 —— 那个变异在真机上会让**整个 app 失去根密钥**
    /// （`prepareKey` 永远返回 nil ⇒ 历史全解不开）。
    func testDecisionFunctionNeverRefusesInProduction() {
        XCTAssertFalse(
            CryptoService.shouldRefuseKeychainStore(
                isRunningTests: false,
                keyStore: KeychainKeyStore()
            ),
            "生产环境绝不能拒绝生产钥匙串（否则 app 永远拿不到根密钥）"
        )
    }

    /// ⑩ 非生产 service ⇒ **不拒**（守卫按 service 判定，不是按类型）。
    func testDecisionFunctionDoesNotRefuseTestScopedService() {
        XCTAssertFalse(
            CryptoService.shouldRefuseKeychainStore(
                isRunningTests: true,
                keyStore: KeychainKeyStore(service: "com.clipmemory.tests-x", account: "probe")
            ),
            "测试专用 service 不该被拒"
        )
    }

    /// ⑪ 注入的 mock ⇒ **不拒**（守卫不是一刀切）。
    func testDecisionFunctionDoesNotRefuseInjectedFake() {
        XCTAssertFalse(
            CryptoService.shouldRefuseKeychainStore(
                isRunningTests: true,
                keyStore: RecordingKeyStore()
            ),
            "注入的 fake 不该被拒"
        )
    }

    /// ⑫ **生产 service 下的任何 account 一律拒**（保守语义：拒掉整个 app 命名空间）。
    ///
    /// 这条把「判据是 **service**」这件事**钉住**：若有人把判据改成按
    /// `account` 比（`root-encryption-key`），本条会变红。
    func testDecisionFunctionRefusesWholeProductionServiceNamespace() {
        XCTAssertTrue(
            CryptoService.shouldRefuseKeychainStore(
                isRunningTests: true,
                keyStore: KeychainKeyStore(
                    service: KeychainKeyStore.defaultService,
                    account: "some-other-account"
                )
            ),
            "生产 service 命名空间下的任何 store 都该被拒（保守语义）"
        )
    }

    // MARK: - Helper

    /// 一个**不存在**的 key 文件路径 —— 让 `prepareKey` 走「没有旧文件 ⇒
    /// 直接生成」分支（不碰真实 key 文件）。
    private static var missingKeyURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("clipmemory-review1043-missing-\(UUID().uuidString)")
    }

    /// `Optional.none` ⇒ true；`Optional.some(x)` ⇒ false。
    ///
    /// `Mirror` 对 Optional 的表示：`.none` 没有 child，`.some(x)` 有一个 child。
    private static func isNilOptional(_ value: Any) -> Bool {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else { return false }
        return mirror.children.isEmpty
    }

    /// 记录调用次数的 `KeyStoring` 实现。
    private final class RecordingKeyStore: KeyStoring {
        private(set) var loadStatusCalls = 0
        private var stored: Data?

        func loadStatus() -> KeychainLoadStatus {
            loadStatusCalls += 1
            return stored.map { .found($0) } ?? .notFound
        }

        func load() -> Data? { stored }

        func store(_ data: Data) throws { stored = data }

        func delete() { stored = nil }
    }
}
