import XCTest
@testable import ClipMemory

/// ID-REVIEW-1048 (2026-10-28): `StartupHealth` 的两个**默认参数**都是
/// **生产身份**，而且**那道闸门没覆盖它** —— 「测试基础设施污染用户真实环境」
/// 这一族的**第 13 例**。
///
/// ## 这一族到本条为止的形状
///
/// | 轮次 | 被污染的用户资源 |
/// |---|---|
/// | 1042 | 系统通用剪贴板 |
/// | 1043 | 生产钥匙串项 |
/// | 1044 | 全局热键 ⌘⇧V + 菜单栏状态项 |
/// | 1045 | 崩溃哨兵文件 |
/// | 1046 | 崩溃计数共享 suite |
/// | 1047 | 首次启动标志 + 恢复向导 / 备份的默认参数 + 窗口位置 + 登录项 |
/// | **1048（本条）** | **启动健康快照的默认钥匙串 + 默认偏好域** |
///
/// ## 本条挖到的两个东西
///
/// **① `keyStore: any KeyStoring = KeychainKeyStore()`**
/// —— **默认参数就是生产钥匙串身份**（与 ID-REVIEW-1047 的 `defaults: .standard`
/// **逐字同型**，只是资源换了：钥匙串 vs 偏好域）。
///
/// ⇒ ID-REVIEW-1043 造了一道**按身份判定**的闸门
/// （`CryptoService.shouldRefuseKeychainStore`），但它挂在
/// `CryptoService.prepareKey` 这**一个收敛点**上。
/// ⇒ 而 `StartupHealth.snapshot` / `logSnapshot` 走的是**兄弟读路径** ——
/// 它们**直接** `keyStore.load()`，**根本到不了**那个收敛点
/// ⇒ **闸门的覆盖面比台账暗示的窄**。
///
/// ⚠️ 后果不是「读坏了数据」，而是**读会挂**：生产钥匙串项是由**另一个签名**
/// 的进程建的（正规签名 vs 测试宿主的 ad-hoc）⇒ macOS 弹**钥匙串 ACL 授权框**
/// ⇒ 测试宿主**阻塞**在上面（ID-REVIEW-1043 实测几十秒），并且留下一个
/// `SecurityAgent` 进程 ⇒ 后续的钥匙串操作**全被堵死**。
/// ⇒ ⇒ 「我只想读一下」和「我只想验证一下」这两个前缀，
/// 经常是**引入用户可见故障**的最短路径。
///
/// **② `defaults: UserDefaults = .standard`**
/// —— `logSnapshot` 会 `defaults.set(Date(), forKey: lastLaunchTime)`
/// ⇒ 一个**写**进用户真实域的默认参数。
/// ⇒ 而 `lastLaunchTime` 在 ZZZ canary 的**白名单**里
/// ⇒ 这个写入**本来就看不见**（与 ID-REVIEW-1038 把 `ClipboardItems` 移出
/// 白名单是**同一种盲区**：*能容忍变化 ⇒ 看不见破坏*）。
///
/// **③ 还有第三条**：这个文件的**头部注释**写着
/// 「Tests inject every dependency via parameters so live history stays
/// untouched」⇒ 一条**写在注释里的、没有被强制**的不变量
/// —— 与 ID-REVIEW-1043 / ID-REVIEW-1047 **逐字同型**。
///
/// ## 本文件锁住的不变量
///
/// ① 测试进程里，`StartupHealth` **不得**读一个报出**生产 service** 的钥匙串
/// ② 同上，`logSnapshot` 也不得
/// ③ 测试进程里，`snapshot` 的**默认**域**必须**是隔离 suite（**只读**证明）
/// ③b `snapshot` 与 `logSnapshot` 的默认参数**必须**是**同一个**表达式
/// ④ `mayReadKeyStore` 的**两半**：生产 ⇒ 允许；测试 + 生产身份 ⇒ 拒绝
/// ⑤ `defaultsFor` 的**两半**：生产 ⇒ **同一个** `.standard`；测试 ⇒ 不是生产域
/// ⑥ app 树里 `KeychainKeyStore()` 的**库存**必须恰好是 6 处（棘轮）
/// ⑦ `StartupHealth.swift` 里**不得**再出现 `= .standard`
/// ⑦b 隔离 suite 名**必须**与 bootstrap 清理列表一致（单一真相）
final class Review1048RegressionTests: XCTestCase {

    // MARK: - ①② 测试进程不得读生产身份的钥匙串

    /// ① **行为**守卫：`snapshot(...)` **不得**读一个报出**生产 service** 的
    /// 钥匙串。
    ///
    /// ⚠️ 用一个**记录用**的 conformer：它报出生产 service（于是**按身份**
    /// 判定会拒绝它），并记录 `load()` 是否被调用。
    /// ⇒ 断言的是「**这个进程有没有去读**」，**不是**「读到了什么」。
    ///
    /// ⚠️ 这个守卫**绝不**碰真实钥匙串 —— 它不调用 `KeychainKeyStore`，
    /// 用的是测试里的 conformer（ID-REVIEW-1042 的教训：*验证工具本身不能
    /// 成为它要消灭的那种伤害源*）。
    func testSnapshotNeverReadsAProductionIdentityKeyStoreInATestProcess() {
        let recorder = RecordingKeyStore(reportsProductionService: true)
        let snapshot = StartupHealth.snapshot(
            keyStore: recorder,
            imagesDirectory: Self.temporaryImagesDirectory(),
            defaults: Self.isolatedDefaults()
        )
        XCTAssertEqual(
            recorder.loadCallCount, 0,
            "测试进程里的 `StartupHealth.snapshot` **不得**读一个报出生产 service "
            + "的钥匙串 —— 那会把 macOS 的钥匙串 ACL 授权框弹到用户屏幕上，"
            + "并把测试宿主**阻塞**在上面"
        )
        XCTAssertFalse(
            snapshot.keychainKeyExists,
            "被拒绝的生产身份必须报告「没有密钥」，而不是去问系统"
        )
    }

    /// ② **行为**守卫：`logSnapshot(...)` 同样不得读生产身份的钥匙串。
    ///
    /// ⚠️ 守卫 ① 只覆盖 `snapshot` —— 而 `logSnapshot` 是**另一个**读点
    /// ⇒ 「一条守卫只覆盖两个并列机制中的一个，它对另一个就是零覆盖」
    /// （ID-REVIEW-1047 §48.1 的形状）⇒ **两个读点各钉一条**。
    func testLogSnapshotNeverReadsAProductionIdentityKeyStoreInATestProcess() {
        let recorder = RecordingKeyStore(reportsProductionService: true)
        StartupHealth.logSnapshot(
            keyStore: recorder,
            imagesDirectory: Self.temporaryImagesDirectory(),
            defaults: Self.isolatedDefaults()
        )
        XCTAssertEqual(
            recorder.loadCallCount, 0,
            "测试进程里的 `StartupHealth.logSnapshot` **不得**读一个报出生产 "
            + "service 的钥匙串（同守卫 ① 的理由）"
        )
    }

    // MARK: - ③ 默认域不得是生产域

    /// ③ **行为**守卫：测试进程里，`snapshot(...)` 的**默认** `defaults`
    /// **不得**是生产域。
    ///
    /// ⚠️ 这一条覆盖的是**默认参数**那条路径 —— 守卫 ④/⑤ 断言的是**纯函数**，
    /// 而**纯函数被断言**并不等于**调用点真的用了它** ⇒ 必须有一条**走真实
    /// 默认参数**的行为守卫。
    ///
    /// ⚠️⚠️ **为什么用 `snapshot` 而不是 `logSnapshot`** —— 这条守卫的设计
    /// 本身就是本族教训的应用：
    /// * `logSnapshot` 会 `defaults.set(...)` ⇒ 如果 seam 被改坏（默认域又变回
    ///   `.standard`），**这个守卫自己**就会把 `lastLaunchTime` 写进**用户的
    ///   真实域** ⇒ *验证工具本身成了它要消灭的那种伤害源*
    ///   （ID-REVIEW-1042 的教训）；
    /// * `snapshot` **只读** ⇒ 即使 seam 被改坏，它最多读一次生产域
    ///   （**读**不写 ⇒ 无污染），守卫本身永远是安全的。
    /// ⇒ 写路径由守卫 ③b（**两个**默认参数表达式**必须相同**）+ 守卫 ⑦
    /// （该文件里**不得**再有 `= .standard`）**传递覆盖**。
    ///
    /// ⚠️ `lastLaunchTime` 在 ZZZ canary 的白名单里 ⇒ 如果主 canary 能看见
    /// 这个回归，它早就该响 ⇒ 正因如此才需要这条守卫自己钉住。
    func testSnapshotWithoutInjectedDefaultsReadsTheIsolatedSuite() {
        let key = UserDefaultsKey.lastLaunchTime.rawValue
        let seeded = Date(timeIntervalSince1970: 1_650_000_000)
        // ⚠️ ID-REVIEW-1040: a suite must be created through
        // `TestSuiteCleanup.makeSuite(named:)` — a suite created directly is
        // invisible to the process-end sweep and its plist file leaks.
        let isolated = TestSuiteCleanup.makeSuite(named: StartupHealth.xcTestIsolationSuiteName)
        isolated.set(seeded, forKey: key)
        defer { isolated.removeObject(forKey: key) }

        let snapshot = StartupHealth.snapshot(
            keyStore: RecordingKeyStore(reportsProductionService: false),
            imagesDirectory: Self.temporaryImagesDirectory()
            // ⚠️ `defaults:` deliberately OMITTED ⇒ the default parameter
            // resolves ⇒ this is the path under test.
        )

        XCTAssertEqual(
            snapshot.lastLaunchTime,
            seeded,
            "测试进程里 `snapshot` 的**默认**域**必须**是隔离 suite "
            + "`\(StartupHealth.xcTestIsolationSuiteName)` —— "
            + "它刚才在那里被种了一个已知日期；读不到 ⇒ 默认参数没走 seam"
        )
        XCTAssertFalse(
            TestIsolation.addressesProductionDomain(isolated),
            "隔离 suite **不得**是生产域（否则上面那条断言是自欺）"
        )
    }

    /// ③b **静态**守卫：`snapshot` 与 `logSnapshot` 的 `defaults` 默认参数
    /// **必须**是**同一个**表达式。
    ///
    /// ⇒ 守卫 ③ 用**只读**的 `snapshot` 证明了默认参数解析到隔离 suite；
    /// ⇒ 而 `logSnapshot` 会**写** ⇒ 它的默认参数**必须**是同一个表达式
    /// ⇒ 这样写路径就被**传递覆盖**，而**不需要**一个会写生产域的守卫。
    func testBothSnapshotOverloadsShareTheSameDefaultsDefaultParameter() throws {
        let url = Self.repoRoot
            .appendingPathComponent("ClipMemory/Services/StartupHealth.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let blanked = TestSourceScanner.blankingCommentsAndStrings(source)
        let expression = "defaults: UserDefaults = StartupHealth.defaultsFor(isTestProcess: TestIsolation.isRunningTests)"
        XCTAssertEqual(
            TestSourceScanner.occurrenceCount(of: expression, in: blanked), 2,
            "`snapshot` 与 `logSnapshot` 的 `defaults` 默认参数**必须**是"
            + "**同一个**表达式（`\(expression)`）—— "
            + "否则**写**的那条路径（`logSnapshot`）没有被守卫 ③ 覆盖到"
        )
    }

    // MARK: - ④⑤ 两半的纯函数

    /// ④ `mayReadKeyStore` 的**两半**。
    func testTheKeyStoreReadJudgementHasBothHalves() {
        let productionIdentity = RecordingKeyStore(reportsProductionService: true)
        let other = RecordingKeyStore(reportsProductionService: false)

        XCTAssertTrue(
            StartupHealth.mayReadKeyStore(isRunningTests: false, keyStore: productionIdentity),
            "生产进程**必须**照旧读生产钥匙串（生产行为零变化）"
        )
        XCTAssertFalse(
            StartupHealth.mayReadKeyStore(isRunningTests: true, keyStore: productionIdentity),
            "测试进程**不得**读报出生产 service 的钥匙串"
        )
        XCTAssertTrue(
            StartupHealth.mayReadKeyStore(isRunningTests: true, keyStore: other),
            "注入的 fake / 非生产 service 的 store 在测试进程里**照常可读**"
            + "（否则依赖注入的测试全挂）"
        )
    }

    /// ⑤ `defaultsFor` 的**两半**。
    func testTheDefaultsResolverHasBothHalves() {
        XCTAssertTrue(
            StartupHealth.defaultsFor(isTestProcess: false) === UserDefaults.standard,
            "生产分支**必须**就是 `UserDefaults.standard`（生产零变化）"
        )
        XCTAssertFalse(
            TestIsolation.addressesProductionDomain(
                StartupHealth.defaultsFor(isTestProcess: true)
            ),
            "测试分支**不得**是生产域"
        )
    }

    // MARK: - ⑥⑦ 库存棘轮

    /// ⑥ **棘轮**：app 树里 `KeychainKeyStore()` 的**库存**必须恰好是 6 处。
    ///
    /// ⚠️ 它盯的是**「构造生产钥匙串身份」这个动作**，不是某个写法
    /// ⇒ 新增一处构造点（哪怕是为了「读一下」）⇒ 立刻红 ⇒ 必须先在台账里
    /// 判定它是否已被闸门挡住。
    ///
    /// ⚠️ 它**不能**取代行为守卫 ①②：库存只数「有没有构造」，不数
    /// 「**读**的时候有没有被闸门挡住」⇒ 两个方向都要钉。
    func testTheProductionKeychainConstructionInventoryIsPinned() throws {
        var inventory: [String: Int] = [:]
        for url in try TestSourceScanner.appSourceFiles() {
            let source = try String(contentsOf: url, encoding: .utf8)
            let count = TestSourceScanner.occurrenceCount(
                of: "KeychainKeyStore()",
                in: TestSourceScanner.blankingCommentsAndStrings(source)
            )
            guard count > 0 else { continue }
            inventory[TestSourceScanner.appRelativePath(of: url)] = count
        }
        XCTAssertEqual(
            inventory,
            [
                "Services/CryptoService.swift": 4,
                "Services/StartupHealth.swift": 2
            ],
            "「构造生产钥匙串身份」的库存变了 —— 新增一处构造点，"
            + "都必须先在台账里判定它是否已被闸门挡住"
        )
        XCTAssertEqual(
            inventory.values.reduce(0, +), 6,
            "库存总数必须仍是 6（台账 §49 的逐条判定就是按这 6 条写的）"
        )
    }

    /// ⑦ **静态**守卫：`StartupHealth.swift` 里**不得**再出现 `= .standard`。
    ///
    /// ⇒ 它的两个 `defaults` 默认参数现在**必须**走 `defaultsFor(isTestProcess:)`。
    /// ⇒ 这条与守卫 ⑲（`Review1047RegressionTests` 的逐文件库存棘轮）**互相
    /// 独立**：⑲ 盯**总库存**，⑦ 盯**这个文件**。
    func testStartupHealthHasNoProductionIdentityDefaultParameterLeft() throws {
        let url = Self.repoRoot
            .appendingPathComponent("ClipMemory/Services/StartupHealth.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let blanked = TestSourceScanner.blankingCommentsAndStrings(source)
        XCTAssertEqual(
            TestSourceScanner.occurrenceCount(of: "= .standard", in: blanked), 0,
            "`StartupHealth.swift` 里**不得**再有 `= .standard` 的默认参数"
            + "（它就是**内联的生产身份**：默认参数 = 生产域）"
        )
        XCTAssertTrue(
            blanked.contains("defaultsFor(isTestProcess:"),
            "`StartupHealth` 的默认域**必须**走 `defaultsFor(isTestProcess:)`"
        )
        XCTAssertTrue(
            blanked.contains("mayReadKeyStore("),
            "`StartupHealth` 的钥匙串读**必须**走 `mayReadKeyStore(...)`"
            + "（那才是**按身份判定**、且与 CryptoService 共用同一道判据的闸门）"
        )
    }

    /// ⑦b **单一真相**：`StartupHealth` 的 suite 名与 bootstrap 清理列表里的
    /// 那个**必须**是同一个字符串。
    ///
    /// ⚠️ ID-REVIEW-1037 的形状：两个副本一旦漂移，清理器就会**清理错误的
    /// suite** ⇒ 跨测试泄漏**静默**发生 ⇒ 必须钉一条。
    func testTheStartupHealthSuiteNameIsASingleSourceOfTruth() {
        XCTAssertEqual(
            StartupHealth.xcTestIsolationSuiteName,
            XCTestIsolationSuiteBootstrap.startupHealthSuiteName,
            "两个 suite 名副本**必须**一致 —— 否则清理器会清理错的 suite，"
            + "跨测试泄漏**静默**发生"
        )
        XCTAssertTrue(
            XCTestIsolationSuiteBootstrap.sharedSuiteNames.contains(
                StartupHealth.xcTestIsolationSuiteName
            ),
            "该 suite **必须**在每个测试前被清理（否则 `lastLaunchTime` 会漏给下一个测试）"
        )
    }

    // MARK: - Helpers

    /// Repository root, computed from this file's own location.
    private static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ClipMemoryTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
            .resolvingSymlinksInPath()
    }()

    /// A `KeyStoring` that **reports** a service and **records** whether it
    /// was read.
    ///
    /// ⚠️ It never touches the real Keychain: `load()` returns a canned value.
    private final class RecordingKeyStore: KeyStoring {
        private let reportsProductionService: Bool
        private(set) var loadCallCount = 0

        init(reportsProductionService: Bool) {
            self.reportsProductionService = reportsProductionService
        }

        /// ID-REVIEW-1043: the **identity** property — not the concrete type.
        var keychainService: String? {
            reportsProductionService ? KeychainKeyStore.defaultService : "test-only-service"
        }

        func load() -> Data? {
            loadCallCount += 1
            return Data([0x01, 0x02, 0x03, 0x04])
        }

        func loadStatus() -> KeychainLoadStatus { .notFound }
        func store(_ keyData: Data) throws {}
        func delete() {}
    }

    /// A throwaway images directory (the snapshot enumerates it).
    private static func temporaryImagesDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Review1048-\(UUID().uuidString)", isDirectory: true)
    }

    /// A per-test isolated domain for the calls that need one.
    ///
    /// ⚠️ ID-REVIEW-1040: through `TestSuiteCleanup.makeSuite(named:)` — a
    /// suite created directly is invisible to the process-end sweep and its
    /// plist file leaks.
    private static func isolatedDefaults() -> UserDefaults {
        TestSuiteCleanup.makeSuite(named: "Review1048-\(UUID().uuidString)")
    }
}
