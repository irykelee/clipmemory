import XCTest
import AppKit
@testable import ClipMemory

/// ID-REVIEW-1045：把「是不是测试进程」这个**探针**从「不可测的全局常量」
/// 升级成「**可测的纯函数** + **跨进程黑盒哨兵**」。
///
/// ## 这个探针为什么是整族缺陷的**地基**
///
/// ID-REVIEW-1042（剪贴板）、1043（生产钥匙串）、1044（全局热键 + 菜单栏）
/// 三轮收口，每一轮的隔离闸门都挂在**同一个**探针上：
/// `TestIsolation.isRunningTests`。它是 2026-10-20 那次数据丢失事故
/// （ID-CRASH-0031）定下的**三信号**探针。
///
/// ## 修之前，这个探针有两半**测不到**
///
/// 修之前它是一段写在 `static let` 初始化器闭包里的逻辑 ——
/// 一个**运行期不可翻转的常量**：
///
/// 1. 「**非测试进程 ⇒ 探针为假**」这一半 —— 决定**生产** app 是否注册
///    全局热键、是否显示菜单栏图标、数据是否落在真实域。
///    在测试宿主里探针**恒为真** ⇒ 这一半**结构上不可达**。
/// 2. 「**判定逻辑本身对不对**」这一半 —— 比如某个本该是 OR 的信号
///    变成 AND，整个隔离 regime 就静默失效。
///
/// ⇒ 于是有第四条路没人看：**若探针被改成恒真** ⇒ **生产 app 永远不注册
/// ⌘⇧V、永远没有菜单栏图标、数据全写进隔离域** ⇒ **整个 app 静默失效**，
/// 而**全量测试全绿** —— 因为测试宿主里探针本来就恒为真，**同形**。
///
/// ## 这一轮怎么把它拆开
///
/// * **单元层**（本文件）：三信号抽成**值**（`TestProcessSignals`），
///   判定抽成**纯函数** `isTestProcess(signals:)` ⇒「三信号全假 ⇒ 不是
///   测试进程」这半边现在**直接可断言**（守卫 ①）。
/// * **结构层**（守卫 ⑨⑩）：`isRunningTests` 的**定义**必须由纯函数求值
///   ⇒ 有人把它改成常量（恒真或恒假）⇒ needle 消失 ⇒ 红。
/// * **跨进程层**（`Scripts/production-probe-smoke.sh`）：**纯函数也答不了**
///   最后一问 —— 「探针在**真生产进程**里是不是假」。因为测试宿主不是
///   生产进程。⇒ 哨兵脚本启动**真 Release 二进制**，再从**另一个进程**
///   问 Carbon「⌘⇧V 被谁占着」（Carbon 的键位组合是**系统级独占**，
///   换 signature 也一样返回 -9878 ⇒ 跨进程观察有效）。
///
/// ⚠️ **如实标注本文件的判据边界**：守卫 ①–⑧ 是**单元层**的断言，
/// 它们**证明不了**「探针在生产进程里为假」；那一条由跨进程哨兵承担。
/// 本文件能做的是把「判定逻辑」和「探针的定义」钉死，让**恒真**这个
/// 变异在**结构上**不可能悄悄发生。
final class Review1045RegressionTests: XCTestCase {

    // MARK: - ① 纯函数：三信号全假 ⇒ 不是测试进程

    /// ① **「非测试进程 ⇒ 探针为假」这半边，现在可测了。**
    ///
    /// 这一条在修之前**根本写不出来**：判定逻辑被关在 `static let`
    /// 初始化器闭包里，运行期不可翻转、也无法从外部喂值。
    ///
    /// 它是本轮最核心的一条 —— 生产 app 的全局热键、菜单栏图标、
    /// 存储域**全都**挂在这个判定上。
    func testNoSignalMeansNotATestProcess() {
        XCTAssertFalse(
            TestIsolation.isTestProcess(signals: .none),
            "三个信号全假 ⇒ 一定不是测试进程（否则生产 app 会静默失去"
            + "全局热键 / 菜单栏图标，并把数据写进隔离域）"
        )
    }

    /// ①b 同样的判定，用**显式构造**的三信号再断言一次 —— 防
    /// 「`.none` 这个常量本身被改成全真」这种绕过。
    func testAnExplicitlyEmptySignalSetIsNotATestProcess() {
        let signals = TestIsolation.TestProcessSignals(
            hasXCTestConfigPath: false,
            xcTestCaseClassLoaded: false,
            xctestBundleInjected: false
        )
        XCTAssertFalse(
            TestIsolation.isTestProcess(signals: signals),
            "显式构造的「三信号全假」同样必须判为非测试进程"
        )
    }

    // MARK: - ②③④ 每个信号单独 ⇒ 是测试进程

    /// ② 信号 1（`XCTestConfigurationFilePath` 存在，**任意值**）单独成立。
    ///
    /// ⚠️ 「任意值」是有实测依据的：2026-10-20 实测该变量在 app 宿主
    /// 测试进程里**存在且值为空字符串**，而 `Optional("") == nil` 为假
    /// ⇒ 旧的一信号判据其实也能识别测试宿主（那段最初的说法被实测推翻，
    /// 见 `docs/incidents/2026-10-20-trash-purge.md` §3）。
    func testTheEnvironmentSignalAloneIdentifiesATestProcess() {
        var signals = TestIsolation.TestProcessSignals.none
        signals.hasXCTestConfigPath = true
        XCTAssertTrue(
            TestIsolation.isTestProcess(signals: signals),
            "信号 1 单独成立 ⇒ 必须判为测试进程"
        )
    }

    /// ③ 信号 2（`XCTestCase` 类已加载）单独成立。
    func testTheLoadedXCTestCaseClassAloneIdentifiesATestProcess() {
        var signals = TestIsolation.TestProcessSignals.none
        signals.xcTestCaseClassLoaded = true
        XCTAssertTrue(
            TestIsolation.isTestProcess(signals: signals),
            "信号 2 单独成立 ⇒ 必须判为测试进程"
        )
    }

    /// ④ 信号 3（注入了 `.xctest` bundle）单独成立。
    func testTheInjectedXCTestBundleAloneIdentifiesATestProcess() {
        var signals = TestIsolation.TestProcessSignals.none
        signals.xctestBundleInjected = true
        XCTAssertTrue(
            TestIsolation.isTestProcess(signals: signals),
            "信号 3 单独成立 ⇒ 必须判为测试进程"
        )
    }

    /// ⑤ 组合语义：OR，不是 AND —— 只要**有一个**信号成立就算测试进程。
    ///
    /// ⚠️ 这条防的是「某个信号被误改成 AND 项」：三个信号全成立时
    /// AND 和 OR 的结果相同 ⇒ 只有「**恰好一个**成立」的组合才能分辨。
    func testAnySingleSignalIsEnough() {
        var onlyEnvironment = TestIsolation.TestProcessSignals.none
        onlyEnvironment.hasXCTestConfigPath = true
        XCTAssertTrue(TestIsolation.isTestProcess(signals: onlyEnvironment))

        var onlyClass = TestIsolation.TestProcessSignals.none
        onlyClass.xcTestCaseClassLoaded = true
        XCTAssertTrue(TestIsolation.isTestProcess(signals: onlyClass))

        var onlyBundle = TestIsolation.TestProcessSignals.none
        onlyBundle.xctestBundleInjected = true
        XCTAssertTrue(TestIsolation.isTestProcess(signals: onlyBundle))
    }

    // MARK: - ⑥ 探针在测试宿主里必须为真（抓「恒为假」）

    /// ⑥ 在**测试宿主**里，探针必须为**真**。
    ///
    /// 这一条有牙：它抓的是探针被改成**恒假**（⇒ 测试宿主跑去写用户的
    /// 生产域 —— ID-CRASH-0031 那次数据丢失事故的形状）。
    ///
    /// ⚠️ 与之相对，「恒**真**」在单元层**抓不到**（测试宿主里探针本来
    /// 就是真 ⇒ 同形）⇒ 那半边交给跨进程哨兵
    /// （`Scripts/production-probe-smoke.sh`）与守卫 ⑩。
    func testTheProbeIsTrueInsideATestHost() {
        XCTAssertTrue(
            TestIsolation.isRunningTests,
            "测试宿主里探针必须为真（恒假 ⇒ 测试进程会写用户的生产域，"
            + "那是 ID-CRASH-0031 数据丢失事故的形状）"
        )
    }

    /// ⑥b 测试宿主里，**三个信号本身**都必须成立 —— 这是「探针为真」
    /// 的**成因**，不是结论。断言成因可以顺手看出「哪个信号在起作用」。
    func testAllThreeSignalsArePresentInsideATestHost() {
        let signals = TestIsolation.currentTestProcessSignals()
        XCTAssertTrue(
            signals.hasXCTestConfigPath,
            "测试宿主里 `XCTestConfigurationFilePath` 必须存在（ID-CRASH-0031 实测：存在且值为空字符串）"
        )
        XCTAssertTrue(
            signals.xcTestCaseClassLoaded,
            "测试宿主里 `XCTestCase` 类必须已加载"
        )
        XCTAssertTrue(
            signals.xctestBundleInjected,
            "测试宿主里必须注入了 `.xctest` bundle"
        )
    }

    // MARK: - ⑦ 端到端：生产侧两道闸门必须放行

    /// ⑦ **生产 ⇒ 两道闸门都放行**。
    ///
    /// 这两条闸门是 ID-REVIEW-1044 加的（全局热键 + 菜单栏状态项），
    /// 它们在测试宿主里恒为「拒绝」⇒ 「生产 ⇒ 一定放行」那半边此前
    /// **测不到**。本轮把状态项闸门也抽成了纯函数
    /// （`AppDelegate.shouldCreateStatusItem`），于是两半都可测。
    ///
    /// ⚠️ 这一条是「**判定逻辑**正确」的断言；它**证明不了**「探针在
    /// 真生产进程里为假」—— 那一问由跨进程哨兵承担。
    func testProductionGatesLetTheRealFeaturesThrough() {
        XCTAssertTrue(
            HotKeyManager.shouldRegisterSystemHotKey(isRunningTests: false),
            "生产进程 ⇒ 必须注册全局热键 ⌘⇧V"
        )
        XCTAssertTrue(
            AppDelegate.shouldCreateStatusItem(isRunningTests: false),
            "生产进程 ⇒ 必须创建菜单栏状态项（`LSUIElement=true` ⇒ 它是 app 的全部存在）"
        )
    }

    /// ⑦b 测试宿主 ⇒ 两道闸门都**拒绝**。
    func testTestHostGatesBlockTheRealFeatures() {
        XCTAssertFalse(
            HotKeyManager.shouldRegisterSystemHotKey(isRunningTests: true),
            "测试宿主 ⇒ 不得注册系统级全局热键"
        )
        XCTAssertFalse(
            AppDelegate.shouldCreateStatusItem(isRunningTests: true),
            "测试宿主 ⇒ 不得创建菜单栏状态项"
        )
    }

    // MARK: - ⑧ 静态守卫：探针的定义必须走纯函数

    /// ⑧ **`isRunningTests` 的定义必须由纯函数求值。**
    ///
    /// ⚠️ 这一条守的是一个**行为上抓不到**的洞：把
    /// `isRunningTests` 改成常量（`true` ⇒ 生产 app 全面静默失效；
    /// `false` ⇒ 测试宿主写用户生产域），在测试宿主里**行为完全一致**
    /// ⇒ 守卫 ①–⑦ **全绿**。
    ///
    /// ⇒ 只能从**结构**上钉：定义必须长得像
    /// `isTestProcess(signals: currentTestProcessSignals())`。
    /// 改成任何常量或内联逻辑，这个 needle 都会消失 ⇒ 红。
    ///
    /// ⚠️ 这是**文本**守卫：它认的是**形状**不是**来源**。
    /// 如实标注：把纯函数调用换成「手工拼一个全真的 signals」依然能骗过
    /// 它（那种形态由守卫 ⑩ 的锚点计数与跨进程哨兵兜底）。
    func testTheProbeDefinitionMustGoThroughThePureFunction() throws {
        let files = try TestSourceScanner.appSourceFiles()
        var occurrences = 0
        for url in files {
            let source = try String(contentsOf: url, encoding: .utf8)
            occurrences += TestSourceScanner.occurrenceCount(
                of: "isTestProcess(signals: currentTestProcessSignals())",
                in: TestSourceScanner.blankingCommentsAndStrings(source)
            )
        }
        XCTAssertEqual(
            occurrences, 1,
            "`isRunningTests` 的定义必须且只能由纯函数求值"
            + "（`isTestProcess(signals: currentTestProcessSignals())`）"
            + "——改成常量（恒真 ⇒ 生产 app 静默失效；恒假 ⇒ 测试宿主写用户生产域）"
            + "会让行为守卫全绿"
        )
    }

    /// ⑨ 三信号**来源**必须仍然只在 `Utils/TestIsolation.swift`。
    ///
    /// 与 ID-REVIEW-1044 守卫 ⑩ 同源，但**独立**重跑一遍：那条守的是
    /// 「只有一个探针实现」，这条守的是「三个信号各自的**读取点**只有一个」。
    ///
    /// ⚠️ **needle 用的是读取点**（`ProcessInfo.processInfo.environment[` /
    /// `NSClassFromString(` / `Bundle.allBundles`），不是信号**值** ——
    /// 值是字符串字面量，扫不到；而这三个 API 是「拿到进程状态」的
    /// **能力入口**，换了机制（比如换成 `dlsym` 查 XCTest 符号）就抓不到
    /// ⇒ 这是**已知**的边界（守卫 ⑪ 的控制组记录了别名绕过的形状）。
    func testTheThreeSignalSourcesLiveOnlyInTestIsolation() throws {
        for anchor in [
            "ProcessInfo.processInfo.environment[",
            "NSClassFromString(",
            "Bundle.allBundles"
        ] {
            let sites = try Self.callSites(of: anchor)
            XCTAssertEqual(
                sites, ["Utils/TestIsolation.swift×1"],
                "探针信号来源 \(anchor) 只能出现在 Utils/TestIsolation.swift 这一处"
            )
        }
    }

    /// ⑩ **状态项闸门**的调用点实参必须是规范探针。
    ///
    /// 与 ID-REVIEW-1044 守卫 ⑭ 同款（热键那条），这里补上状态项那条 ——
    /// 它同样是「把实参硬编码成 `true` ⇒ 生产 app 永远没有菜单栏图标」
    /// 这种**行为上抓不到**的洞。
    func testTheStatusItemGateCallSiteIsDrivenByTheCanonicalProbe() throws {
        let files = try TestSourceScanner.appSourceFiles()
        var total = 0
        var canonical = 0
        for url in files {
            let source = try String(contentsOf: url, encoding: .utf8)
            let blanked = TestSourceScanner.blankingCommentsAndStrings(source)
            total += TestSourceScanner.occurrenceCount(
                of: "shouldCreateStatusItem(isRunningTests: ",
                in: blanked
            )
            canonical += TestSourceScanner.occurrenceCount(
                of: "shouldCreateStatusItem(isRunningTests: TestIsolation.isRunningTests)",
                in: blanked
            )
        }
        XCTAssertEqual(
            total, 2,
            "shouldCreateStatusItem(isRunningTests: …) 在 app 树里只能出现 2 次（1 声明 + 1 调用）"
        )
        XCTAssertEqual(
            canonical, 1,
            "调用点的实参必须是规范探针 TestIsolation.isRunningTests"
            + "（硬编码 true ⇒ 生产 app 永远没有菜单栏图标，而行为守卫会全绿）"
        )
    }

    // MARK: - ⑪⑫ 控制组（证明守卫不是空绿）

    /// ⑪ 控制组：守卫 ⑧ 的 needle 必须能分辨「走纯函数」与「改成常量」。
    func testTheProbeDefinitionGuardDiscriminates() {
        let good = """
        nonisolated static let isRunningTests: Bool = isTestProcess(signals: currentTestProcessSignals())
        """
        let bad = """
        nonisolated static let isRunningTests: Bool = true
        """
        let needle = "isTestProcess(signals: currentTestProcessSignals())"
        XCTAssertEqual(
            TestSourceScanner.occurrenceCount(
                of: needle,
                in: TestSourceScanner.blankingCommentsAndStrings(good)
            ),
            1,
            "守卫 ⑧ 必须能认出「走纯函数」的定义"
        )
        XCTAssertEqual(
            TestSourceScanner.occurrenceCount(
                of: needle,
                in: TestSourceScanner.blankingCommentsAndStrings(bad)
            ),
            0,
            "守卫 ⑧ 必须能分辨「改成常量」的定义（恒真 ⇒ 生产 app 静默失效）"
        )
    }

    /// ⑫ 控制组：扫描器必须能发现**被植入的**探针读取点
    /// （证明守卫 ⑨ 不是空绿）。
    func testTheScannerFindsAPlantedSignalSource() {
        let sample = """
        func planted() {
            let hasEnv = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            let hasClass = NSClassFromString("XCTestCase") != nil
            let hasBundle = Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
        }
        """
        for anchor in [
            "ProcessInfo.processInfo.environment[",
            "NSClassFromString(",
            "Bundle.allBundles"
        ] {
            XCTAssertEqual(
                TestSourceScanner.occurrenceCount(
                    of: anchor,
                    in: TestSourceScanner.blankingCommentsAndStrings(sample)
                ),
                1,
                "扫描器必须能发现被植入的探针信号来源 \(anchor)（否则守卫 ⑨ 是空绿）"
            )
        }
    }

    // MARK: - ⑬ 跨进程哨兵必须在场

    /// ⑬ **跨进程哨兵脚本必须在场**，且必须包含它赖以成立的那几件事：
    /// A/B 基线（先量 FREE 再量 HELD）、Carbon 独占判据、以及
    /// 「失败即红」的退出码。
    ///
    /// ⚠️ 这是一条**存在性**守卫：它证明不了脚本跑起来会对 ——
    /// 但它能挡住「哨兵被悄悄删掉」，而哨兵是「探针在生产进程里为假」
    /// 这条**唯一**的端到端证据来源。
    func testTheCrossProcessSentinelScriptIsPresentAndKeepsItsEssentials() throws {
        let url = Self.repoRoot()
            .appendingPathComponent("Scripts/production-probe-smoke.sh")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "跨进程哨兵脚本必须存在（`Scripts/production-probe-smoke.sh`）"
            + "——它是「探针在真生产进程里为假」的唯一端到端证据来源"
        )
        let source = try String(contentsOf: url, encoding: .utf8)
        for needle in [
            // The judgement basis: the production app logs "Hotkey registered:"
            // ONLY when RegisterEventHotKey returned noErr. The matching line
            // on the skip path ("Hotkey registration skipped") is the
            // negative control — it is exactly the failure the sentinel
            // exists to catch.
            "Hotkey registered:",
            "Hotkey registration skipped",
            // The subscription must ask for the info level: os_log's info
            // level is NOT persisted, so a later `log show` may miss it.
            "--level info",
            // The app must be started with the project's real signing
            // identity — an ad-hoc build trips the keychain ACL prompt and
            // blocks on the user's screen.
            "CODE_SIGN_IDENTITY"
        ] {
            XCTAssertTrue(
                source.contains(needle),
                "哨兵脚本必须包含 \(needle)（缺了它，判据或零污染前提就不成立）"
            )
        }
    }

    // MARK: - ⑭⑮⑯「看 33 个」的收获：崩溃哨兵的文件路径没被隔离

    /// ⑭ **生产 ⇒ 哨兵落在用户自己的目录**（纯函数那半边可测）。
    ///
    /// 测的是 `SafeModeService.sentinelDirectoryName` 这个纯函数：
    /// 生产进程里探针为假 ⇒ 哨兵必须落在 `ClipMemory/`（用户真 app
    /// 崩溃检测读写的那个目录）。
    func testProductionKeepsTheCrashSentinelInTheUsersOwnDirectory() {
        XCTAssertEqual(
            SafeModeService.sentinelDirectoryName(isRunningTests: false),
            "ClipMemory",
            "生产进程 ⇒ 崩溃哨兵必须落在用户的 ClipMemory 目录"
            + "（测试目录会让生产 app 永远看不到哨兵 ⇒ 崩溃保护失效）"
        )
    }

    /// ⑮ **测试宿主 ⇒ 哨兵必须重定向到测试专用目录**。
    ///
    /// 实测（2026-10-28，修之前）：跑一次测试后，用户的
    /// `~/Library/Application Support/ClipMemory/.running-sentinel`
    /// 的 **inode 与 mtime 都变了** ⇒ 测试宿主删除并重写了它。
    func testTheTestHostRedirectsTheCrashSentinelAwayFromTheUserDirectory() {
        XCTAssertEqual(
            SafeModeService.sentinelDirectoryName(isRunningTests: true),
            "ClipMemory/SafeMode-Tests",
            "测试宿主 ⇒ 崩溃哨兵必须重定向到测试专用目录"
            + "（否则测试宿主会删改用户的哨兵 ⇒ 崩溃计数被干扰、"
            + "可能误入安全模式）"
        )
    }

    /// ⑯ 结构守卫：哨兵路径的**分流**必须由规范探针驱动。
    ///
    /// 把实参硬编码成 `false` ⇒ 测试宿主又会去删改用户的哨兵，而
    /// 纯函数那两半仍绿（它们只测函数本身）⇒ 必须静态钉住调用点。
    func testTheSentinelRedirectCallSiteIsDrivenByTheCanonicalProbe() throws {
        let files = try TestSourceScanner.appSourceFiles()
        var total = 0
        var canonical = 0
        for url in files {
            let source = try String(contentsOf: url, encoding: .utf8)
            let blanked = TestSourceScanner.blankingCommentsAndStrings(source)
            total += TestSourceScanner.occurrenceCount(
                of: "sentinelDirectoryName(isRunningTests: ",
                in: blanked
            )
            canonical += TestSourceScanner.occurrenceCount(
                of: "sentinelDirectoryName(isRunningTests: TestIsolation.isRunningTests)",
                in: blanked
            )
        }
        XCTAssertEqual(
            total, 2,
            "sentinelDirectoryName(isRunningTests: …) 在 app 树里只能出现 2 次（1 声明 + 1 调用）"
        )
        XCTAssertEqual(
            canonical, 1,
            "调用点的实参必须是规范探针 TestIsolation.isRunningTests"
            + "（硬编码 false ⇒ 测试宿主会删改用户的崩溃哨兵）"
        )
    }

    // MARK: - Helper

    private static func repoRoot() -> URL {
        // Tests/ClipMemoryTests/<file>.swift → repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// App 树里 `needle` 的**代码**调用点，形如 `["Path/File.swift×n", …]`。
    private static func callSites(of needle: String) throws -> [String] {
        let files = try TestSourceScanner.appSourceFiles()
        var sites: [String] = []
        for url in files {
            let source = try String(contentsOf: url, encoding: .utf8)
            let count = TestSourceScanner.occurrenceCount(
                of: needle,
                in: TestSourceScanner.blankingCommentsAndStrings(source)
            )
            guard count > 0 else { continue }
            sites.append("\(TestSourceScanner.appRelativePath(of: url))×\(count)")
        }
        return sites
    }
}
