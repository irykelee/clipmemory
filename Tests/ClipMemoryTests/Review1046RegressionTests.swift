import XCTest
@testable import ClipMemory

/// ID-REVIEW-1046 (2026-10-28): 崩溃哨兵的**极性反了** —— 这是
/// ID-REVIEW-1045「同族第 9 例」（测试宿主删改用户崩溃哨兵）往下挖时
/// 挖出来的**根因**，也是一个**独立的生产缺陷**。
///
/// ## 缺陷本体
///
/// `SafeModeService` 的三处注释都写明了这套哨兵协议的**意图**：
///
/// * `SafeModeService.swift:5-9`（头部注释）：
///   「write a sentinel on applicationDidFinishLaunching, delete it on
///   applicationWillTerminate. **If the sentinel is still present when we
///   launch, the previous run terminated abnormally**（崩溃 / 强杀 / 内核
///   panic）」
/// * `SafeModeService.swift:304-306`（`clearSentinelOnNormalExit`）：
///   「The sentinel being ABSENT on the next launch means the previous run
///   didn't exit normally.」
/// * `AppDelegate.swift:397-400`（`applicationWillTerminate`）：
///   「clear the safe-mode sentinel on graceful exit. **If we crash, the
///   sentinel stays in place** and the NEXT launch's
///   `registerPreviousLaunchDidCrash()` counts this as a crash.」
///
/// ⇒ 协议是：**哨兵存在 ⇒ 上次没正常退出 ⇒ 记一次崩溃**。
/// （启动时写哨兵、正常退出时删哨兵 ⇒ 哨兵「还在」正好等价于「上次没走到
/// applicationWillTerminate」。）
///
/// **但实现是反的**（`SafeModeService.swift:174` 修复前）：
///
/// ```swift
/// guard fileManager.fileExists(atPath: sentinelURL.path) else {
///     // No sentinel = previous launch terminated abnormally   ← 反了
///     let newCount = crashCount + 1
///     ...
/// }
/// ```
///
/// ⇒ 后果（**在用户机器上实测到的**，不是推演）：
///
/// 1. **正常 ⌘Q 退出被记成一次崩溃** —— 因为 `clearSentinelOnNormalExit()`
///    在**正常退出**时删掉了哨兵，下一次启动自然「没有哨兵」⇒ 计数 +1。
///    ⇒ 用户的 `safeMode.crashCount` 涨到 **8**，`safeMode.active` 被置为
///    **true**（阈值是 3）⇒ **用户此刻正被一个从未崩溃过的 app 挡在安全模式
///    外面**。
/// 2. **真崩溃反而检测不到** —— 崩溃时哨兵**留在原地**，下一次启动走的是
///    「哨兵存在 ⇒ 一切正常」那半边 ⇒ 计数永远不涨 ⇒ 崩溃检测对它本来的
///    目的而言是**死的**。
/// 3. **1045 的既有测试把这个 bug 锁住了**：`SafeModeServiceTests`
///    里的 `testNormalExitPreventsCrashCount` —— 名字说「prevents」，断言
///    写的是 `crashCount == before + 1`，注释里甚至自陈「So the test
///    asserts the BAD case」，然后用「the 3-launch threshold absorbs the
///    noise」把矛盾糊过去。⇒ **测试名与断言互相矛盾 = 极性反了的确凿证据**。
///
/// ## 附带发现：计数从来不会被重置
///
/// `registerSuccessfulLaunch()`（"Resets the counter so a future crash
/// starts a fresh 3-launch window"）**在全仓没有任何调用点** ⇒ 即便把
/// 极性翻正，"3 次**连续**崩溃" 也会退化成 "一辈子 3 次崩溃"。
///
/// ## 本文件锁住的不变量
///
/// ① 正常退出（哨兵被删）⇒ 下一次启动**不计**崩溃
/// ② 上次崩溃（哨兵还在）⇒ 下一次启动**计**一次崩溃
/// ③ 三次连续崩溃 ⇒ 进入安全模式
/// ④ 正常退出反复发生 ⇒ 计数**永不**累积
/// ⑤ 被旧极性误置的安全模式状态 ⇒ **一次性**清理，且**只**清理一次
/// ⑥ `registerSuccessfulLaunch()` 必须有**生产调用点**
@MainActor
final class Review1046RegressionTests: XCTestCase {

    private var tmpDir: URL!
    private var defaultsSuite: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "Review1046-\(UUID().uuidString)"
        defaultsSuite = TestSuiteCleanup.makeSuite(named: suiteName)
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        TestSuiteCleanup.destroy(defaultsSuite)
        try? FileManager.default.removeItem(at: tmpDir)
        tmpDir = nil
        defaultsSuite = nil
        suiteName = nil
    }

    // MARK: - ① 正常退出 ⇒ 不计崩溃

    /// ① **正常退出不是崩溃。**
    ///
    /// 完整生命周期：
    /// 1. launch-1 启动 → 写哨兵
    /// 2. launch-1 **正常退出** → 删哨兵
    /// 3. launch-2 启动 → 看到「没有哨兵」⇒ 上次是**正常退出** ⇒ **不计**
    ///
    /// 修复前这一条**必然失败**（计数 +1）—— 那正是用户 crashCount 涨到 8
    /// 的机制。
    func testNormalExitIsNotCountedAsACrash() {
        let service = makeService()

        service.registerPreviousLaunchDidCrash()   // launch-1：写哨兵
        service.clearSentinelOnNormalExit()          // launch-1 正常退出：删哨兵
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sentinelURL.path),
            "正常退出必须删掉哨兵（否则下一次启动会把它当成崩溃）"
        )

        service.registerPreviousLaunchDidCrash()   // launch-2
        XCTAssertEqual(
            service.crashCount, 0,
            "**正常退出不是崩溃** —— 哨兵被正常退出流程删掉了，下一次启动"
            + "不得把它计成崩溃（ID-REVIEW-1046：修复前这里 +1，用户的 "
            + "safeMode.crashCount 就是这样涨到 8、safeMode.active 被误置为 "
            + "true 的）"
        )
        XCTAssertFalse(service.isInSafeMode)
    }

    // MARK: - ② 上次崩溃 ⇒ 计一次崩溃

    /// ② **哨兵还在 ⇒ 上次没正常退出 ⇒ 计一次崩溃。**
    ///
    /// 这是协议的另一半，也是修复前**完全失效**的那一半（真崩溃从来不被计数）。
    func testSurvivingSentinelCountsAsACrash() throws {
        let service = makeService()

        // 上一次运行崩了 ⇒ 哨兵留在原地。
        //
        // ⚠️ 必须先建目录：服务端的 `writeSentinel()` 会
        // `createDirectory(withIntermediateDirectories: true)`，但**手动**
        // 写哨兵时目录还不存在 ⇒ `Data().write(to:)` 会失败 ⇒
        // `try?` 把它吞掉 ⇒ 测试会**假绿**（在没有哨兵的情况下断言
        // 「有哨兵 ⇒ 计崩溃」照样能过，因为无哨兵同样会被计数）。
        // ⇒ 这里显式建目录，并且**断言哨兵真的写进去了**。
        try FileManager.default.createDirectory(
            at: sentinelURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: sentinelURL)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sentinelURL.path),
            "哨兵必须真的落到磁盘上 —— 否则下面的断言测的不是「哨兵还在」"
        )

        service.registerPreviousLaunchDidCrash()
        XCTAssertEqual(
            service.crashCount, 1,
            "哨兵还在 ⇒ 上次没走到 applicationWillTerminate ⇒ **就是崩溃**，"
            + "必须计数（ID-REVIEW-1046：修复前这一半是反的 ⇒ 真崩溃永远不被"
            + "检测到）"
        )
        XCTAssertFalse(service.isInSafeMode, "1 < 3 threshold")
    }

    // MARK: - ③ 三次连续崩溃 ⇒ 安全模式

    /// ③ 三次连续崩溃 ⇒ 进入安全模式（阈值 3）。
    ///
    /// ⚠️ **off-by-one 是协议固有的**：哨兵是**上一次启动**写的，所以
    /// 「上一次崩溃」要到**本次启动**才被计到 ⇒ 3 次崩溃需要 **4 次启动**
    /// 才数满 3：
    ///
    /// | 启动 | 看到的哨兵 | 判定 | 计数 |
    /// |---|---|---|---|
    /// | #1 | 无（全新安装） | 上次没有「上一次」 | 0 |
    /// | #2 | #1 写的 ⇒ 上次崩了 | 崩溃 | 1 |
    /// | #3 | #2 写的 ⇒ 上次崩了 | 崩溃 | 2 |
    /// | #4 | #3 写的 ⇒ 上次崩了 | 崩溃 | 3 ⇒ 安全模式 |
    func testThreeConsecutiveCrashesActivateSafeMode() {
        let service = makeService()

        service.registerPreviousLaunchDidCrash()   // 启动 #1：全新安装 ⇒ 0
        XCTAssertEqual(
            service.crashCount, 0,
            "首次启动没有「上一次」可判 ⇒ 计数必须是 0"
            + "（**注意 off-by-one**：一次崩溃要到下一次启动才被计到）"
        )
        XCTAssertFalse(service.isInSafeMode)

        service.registerPreviousLaunchDidCrash()   // 启动 #2：上次崩了 ⇒ 1
        XCTAssertEqual(service.crashCount, 1)
        XCTAssertFalse(service.isInSafeMode, "1 < 3")

        service.registerPreviousLaunchDidCrash()   // 启动 #3：上次崩了 ⇒ 2
        XCTAssertEqual(service.crashCount, 2)
        XCTAssertFalse(service.isInSafeMode, "2 < 3")

        service.registerPreviousLaunchDidCrash()   // 启动 #4：上次崩了 ⇒ 3
        XCTAssertEqual(service.crashCount, 3)
        XCTAssertTrue(
            service.isInSafeMode,
            "3 >= 3 阈值 ⇒ 必须进入安全模式"
        )
    }

    // MARK: - ④ 正常退出反复发生 ⇒ 计数永不累积

    /// ④ 反复正常退出 ⇒ 计数**永不**累积。
    ///
    /// 这是用户在现实里每天做的事（每天开一次、⌘Q 关一次）。
    /// 修复前每一次都 +1 ⇒ 三天就把用户推进安全模式。
    func testRepeatedNormalQuitCyclesNeverAccumulateCrashes() {
        let service = makeService()

        for cycle in 1...10 {
            service.registerPreviousLaunchDidCrash()   // 启动
            service.clearSentinelOnNormalExit()          // 正常退出
            XCTAssertEqual(
                service.crashCount, 0,
                "第 \(cycle) 次「启动 → 正常退出」循环后计数必须仍是 0"
                + "（修复前每次 +1 ⇒ 第 3 次就把用户推进安全模式）"
            )
            XCTAssertFalse(service.isInSafeMode, "正常退出永远不该进安全模式")
        }
    }

    // MARK: - ⑤ 一次性清理被误置的状态

    /// ⑤ 旧极性误置的 `safeMode.active` / `safeMode.crashCount` ⇒
    /// **一次性**清理；且**只**清理一次。
    ///
    /// 为什么可以证明「清理是对的」而不是「猜测」：
    /// 旧极性下，计数**只**在「上次没有哨兵」时 +1，而「上次没有哨兵」
    /// 在协议里唯一对应「上次**正常退出**」⇒ **旧极性记下来的每一次
    /// 「崩溃」都是一次正常退出** ⇒ 计数与安全模式标志 100% 是假的。
    func testLegacySpuriousSafeModeStateIsReconciledExactlyOnce() {
        defaultsSuite.set(true, forKey: "safeMode.active")
        defaultsSuite.set(8, forKey: "safeMode.crashCount")

        let service = makeService()
        service.reconcileLegacyCrashPolarity()

        XCTAssertFalse(
            service.isInSafeMode,
            "旧极性下 `safeMode.active` 只可能被「把正常退出当成崩溃」的路径"
            + "置为 true ⇒ 它 100% 是假的 ⇒ 必须清掉（用户此刻正被它挡在"
            + "安全模式外面）"
        )
        XCTAssertEqual(service.crashCount, 0, "误计数必须一并清零")

        // 迁移**只做一次**：迁移之后新产生的合法安全模式不能被二次清掉。
        defaultsSuite.set(true, forKey: "safeMode.active")
        service.reconcileLegacyCrashPolarity()
        XCTAssertTrue(
            service.isInSafeMode,
            "一次性迁移**不得**在第二次运行时清掉后来产生的合法安全模式"
        )
    }

    /// ⑤b 没有旧状态的用户 ⇒ 迁移**不**产生任何副作用。
    func testLegacyReconciliationIsANoOpForACleanInstall() {
        let service = makeService()
        service.reconcileLegacyCrashPolarity()

        XCTAssertFalse(service.isInSafeMode)
        XCTAssertEqual(service.crashCount, 0)
    }

    /// ⑤c **启动路径真的会调迁移**（走真实入口，不直接调迁移方法）。
    ///
    /// ⚠️ 这一条是被变异 **N4** 逼出来的：只测「迁移方法本身」的话，
    /// **把调用点删掉**（用户被误置的状态永远清不掉）**没有任何测试会红**
    /// ⇒ 迁移方法可以是一段**永远不执行**的死代码。
    /// ⇒ 只能钉**调用点** ⇒ 这里从**生产入口**（`registerPreviousLaunchDidCrash`
    /// = 每次启动必经的那条路）走一遍，断言状态真的被清了。
    func testTheLaunchPathActuallyReconcilesTheLegacyState() {
        defaultsSuite.set(true, forKey: "safeMode.active")
        defaultsSuite.set(8, forKey: "safeMode.crashCount")

        let service = makeService()
        // 真实启动路径 —— 不是直接调 reconcileLegacyCrashPolarity()。
        service.registerPreviousLaunchDidCrash()

        XCTAssertFalse(
            service.isInSafeMode,
            "启动路径必须触发迁移 ⇒ 用户被误置的安全模式状态要自动清掉"
            + "（只测迁移方法本身的话，把**调用点**删掉也不会有任何测试变红 —— "
            + "变异 N4 实测存活）"
        )
        XCTAssertEqual(service.crashCount, 0, "误计数必须一并清零")
    }

    // MARK: - ⑥ registerSuccessfulLaunch() 必须被调用

    /// ⑥ `registerSuccessfulLaunch()` 必须有**生产调用点**。
    ///
    /// 修复前它**一个调用点都没有** ⇒ 计数永不重置 ⇒ 「3 次**连续**崩溃」
    /// 退化成「一辈子 3 次崩溃」。
    ///
    /// ⚠️ 断言的**不是**调用点的位置，而是「它被调用了」。位置无关紧要：
    /// 重置是**有条件**的（只有当本次启动**没有**检测到崩溃时才清零）⇒
    /// 把它挪到 `registerPreviousLaunchDidCrash()` 旁边也**无害** ⇒
    /// 「位置是致命的」这个旧说法只对**无条件**重置成立（已订正，见台账 §46）。
    func testRegisterSuccessfulLaunchHasAProductionCallSite() throws {
        let sites = try Self.callSites(of: "SafeModeService.shared.registerSuccessfulLaunch()")
        XCTAssertEqual(
            sites, ["AppDelegate.swift×1"],
            "`registerSuccessfulLaunch()` 必须**恰好有一个**生产调用点"
            + "（修复前是 0 个 ⇒ 崩溃计数永不重置 ⇒ 「3 次连续崩溃」变成"
            + "「一辈子 3 次崩溃」）"
        )
    }

    /// ⑥b **真实启动顺序**下，3 次连续崩溃必须真的进入安全模式。
    ///
    /// ⚠️ 这一条来自独立核验员的**实测**（他的 PROBE-A：连崩 8 次，计数仍是
    /// 0 ⇒ 阈值**永远够不到** ⇒ 安全模式是死代码）。
    ///
    /// 根因：`registerSuccessfulLaunch()` 在**每次**启动末尾把计数清零 ——
    /// **包括「刚刚检测到崩溃」的那一次启动**（检测到崩溃的这次启动本身也是
    /// 一次成功启动）⇒ 计数永远不超过 1。
    ///
    /// ⇒ 修法：重置**有条件** —— 只有当本次启动**没有**检测到崩溃时才清零。
    ///
    /// ⚠️ 本测试**模拟真实的启动顺序**（每次启动 = 一个新实例、同一 suite、
    /// 同一目录；「崩溃」= 没有走到优雅退出 ⇒ 哨兵留在原地）⇒
    /// 只测「计数器重置」或只测「单次崩溃」的测试**测不到**这个组合
    /// （核验员点名：`testThreeConsecutiveCrashesActivateSafeMode` 从不调用
    /// `registerSuccessfulLaunch()` ⇒ 它断言的是产品**没有**的行为）。
    func testThreeConsecutiveCrashesActivateSafeModeInTheRealLaunchOrder() {
        var last: SafeModeService?
        for launch in 1...4 {
            // A new launch = a new process: fresh service, same suite,
            // same sentinel directory.
            let service = SafeModeService(defaults: defaultsSuite, directory: tmpDir)
            service.registerPreviousLaunchDidCrash()   // the app's FIRST call
            // …startup work…
            service.registerSuccessfulLaunch()         // the app's LAST call
            // ⚠️ deliberately NO clearSentinelOnNormalExit() ⇒ this launch
            // "crashed" ⇒ its sentinel survives into the next launch.
            last = service
        }
        XCTAssertEqual(
            last?.crashCount, 3,
            "真实启动顺序下，3 次连续崩溃必须把计数累到 3"
            + "（独立核验实测：清零无条件时，连崩 8 次计数仍是 0 ⇒ 阈值永远"
            + "够不到 ⇒ 安全模式是死代码）"
        )
        XCTAssertTrue(
            last?.isInSafeMode == true,
            "真实启动顺序下，3 次连续崩溃必须进入安全模式"
            + "（这是这个功能**存在的全部理由**）"
        )
    }

    /// ⑥c **启动早期的崩溃必须被检测到**（哨兵要写在启动工作之前）。
    ///
    /// ⚠️ 独立核验的 P1-2（实测）：哨兵是在 `registerPreviousLaunchDidCrash()`
    /// 里写的 ⇒ 崩溃发生在它**之前**（窗口管理、状态项、剪贴板监控、网络
    /// 监控、热键……）时**没有留下任何哨兵** ⇒ 下一次启动读到的「没有哨兵」
    /// 在**翻正后的极性**下意味着「上次正常退出」⇒ **那些崩溃根本不会被计数**。
    ///
    /// ⇒ 修法：把这次调用提到**单实例守卫之后的最早期** ⇒ 哨兵在任何可能崩溃
    /// 的启动工作之前就存在了。
    ///
    /// ⇒ 守卫用**结构**判据（行号先后），因为「顺序」是这里的全部要害。
    func testTheCrashSentinelIsWrittenBeforeAnyStartupWorkThatCouldCrash() throws {
        let sentinelCall = try Self.lineNumber(
            of: "SafeModeService.shared.registerPreviousLaunchDidCrash()",
            in: "AppDelegate.swift"
        )
        XCTAssertNotNil(
            sentinelCall,
            "AppDelegate 里必须有 `SafeModeService.shared.registerPreviousLaunchDidCrash()`"
        )
        for startupStep in ["setupWindowManager()", "setupStatusItem()", "setupClipboardMonitor()"] {
            let stepLine = try Self.lineNumber(of: startupStep, in: "AppDelegate.swift")
            XCTAssertNotNil(stepLine, "AppDelegate 里必须有 \(startupStep)")
            XCTAssertLessThan(
                sentinelCall ?? .max, stepLine ?? .min,
                "崩溃哨兵必须在 \(startupStep) **之前**写下"
                + "（哨兵是「上次跑到哪儿了」的唯一证据 ⇒ 写在启动工作之后，"
                + "那些早崩就永远检测不到 —— 独立核验 P1-2 实测）"
            )
        }
    }

    /// ⑥d **写哨兵失败时不得把「上次崩了」当成事实来计数**。
    ///
    /// ⚠️ 独立核验的 P2-3：ID-CRASH-0004 的这条门（`guard writeOK else { return }`）
    /// 在**崩溃分支**里没有任何测试覆盖 ⇒ 变异 M7b（把门换成 `_ = writeSentinel()`）
    /// **存活**。
    ///
    /// 语义：我们的写失败 ⇒ 我们无法区分「上次真的崩了」与「我们自己写不出去」
    /// ⇒ 不计数（否则一次磁盘压力就能把用户推进安全模式）。
    func testACrashIsNotCountedWhenTheSentinelCannotBeWritten() throws {
        // The previous run crashed ⇒ its sentinel is still there.
        let dir = tmpDir.appendingPathComponent("ClipMemory", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent(".running-sentinel"))

        final class FailingWriter: FileManager, @unchecked Sendable {
            override func createDirectory(
                at url: URL,
                withIntermediateDirectories createIntermediates: Bool,
                attributes: [FileAttributeKey: Any]? = nil
            ) throws {
                throw NSError(domain: "test", code: 28 /* ENOSPC */)
            }
        }
        let service = SafeModeService(
            defaults: defaultsSuite,
            fileManager: FailingWriter(),
            directory: tmpDir
        )
        service.registerPreviousLaunchDidCrash()

        XCTAssertEqual(
            service.crashCount, 0,
            "哨兵写失败时**不得**计数：我们分不清「上次崩了」与「我们自己写"
            + "失败」（ID-CRASH-0004 的三件套门）⇒ 否则一次磁盘压力就能把用户"
            + "推进安全模式"
        )
        XCTAssertFalse(service.isInSafeMode)
    }

    /// ⑥e `countsCrashes` seam 必须按**身份**接线（不是写死）。
    ///
    /// ⚠️ 独立核验的 P2-4：变异 M10b（把 `countsCrashes` 写死为 `false`）
    /// **存活** ⇒ 那条变异会让**生产**环境的整个安全模式功能静默失效
    /// （不计数、不迁移、不写哨兵健康标志）—— 正是 1045 要消灭的
    /// 「探针说真 ⇒ 生产功能静默死掉」的形状，**由一个新 seam 重新引入**。
    func testTheSharedInstanceIsWiredToTheProductionProbe() throws {
        let sites = try Self.callSites(
            of: "SafeModeService(countsCrashes: !TestIsolation.isRunningTests)"
        )
        XCTAssertEqual(
            sites, ["Services/SafeModeService.swift×1"],
            "共享实例必须**按探针**决定要不要做崩溃记账"
            + "（`countsCrashes: !TestIsolation.isRunningTests`）"
            + "—— 写死 false 会让**生产**环境的整个安全模式功能静默失效"
            + "（独立核验变异 M10b 实测存活）"
        )
    }

    /// ⑥f 测试宿主**必须写自己的哨兵**，且**不得**碰用户的哨兵。
    ///
    /// ⚠️ 独立核验的 P3-4：变异 M12（把测试进程分支里的 `writeSentinel()` 删掉）
    /// **存活** ⇒ 因为没有任何测试断言「测试宿主确实写了（测试专用目录里的）
    /// 哨兵」⇒ 那个写可以整个消失，而守卫照样绿。
    ///
    /// ⇒ 这一条把「写哨兵」这件事**本身**变成可断言的。
    func testTheTestHostWritesItsOwnSentinelAndNeverTheUsers() throws {
        let appSupport = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/ClipMemory", isDirectory: true)
        let userSentinel = appSupport.appendingPathComponent(".running-sentinel")
        let testSentinel = appSupport
            .appendingPathComponent("SafeMode-Tests", isDirectory: true)
            .appendingPathComponent(".running-sentinel")

        // The user's sentinel must be recorded BEFORE, and compared AFTER.
        let userExistedBefore = FileManager.default.fileExists(atPath: userSentinel.path)
        let userAttrsBefore = try? FileManager.default.attributesOfItem(atPath: userSentinel.path)

        // Start from a clean slate in the TEST-ONLY directory so the
        // assertion below is about THIS call, not about a leftover.
        try? FileManager.default.removeItem(at: testSentinel)

        SafeModeService.shared.registerPreviousLaunchDidCrash()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: testSentinel.path),
            "测试宿主**必须**写自己的哨兵（`ClipMemory/SafeMode-Tests/.running-sentinel`）"
            + "—— 那次写入正是 ID-REVIEW-1045「同族第 9 例」守卫的牙齿"
            + "（独立核验变异 M12：把这次写入整个删掉，守卫照样绿）"
        )
        XCTAssertEqual(
            FileManager.default.fileExists(atPath: userSentinel.path), userExistedBefore,
            "测试宿主**不得**创建或删除用户的崩溃哨兵"
        )
        let userAttrsAfter = try? FileManager.default.attributesOfItem(atPath: userSentinel.path)
        XCTAssertEqual(
            userAttrsAfter?[.modificationDate] as? Date,
            userAttrsBefore?[.modificationDate] as? Date,
            "测试宿主**不得**改写用户的崩溃哨兵（mtime 必须不变）"
        )
    }

    /// ⑥b **测试宿主不得往共享 SafeMode suite 里写崩溃记账。**
    ///
    /// ID-REVIEW-1046 的连带发现（实测）：app 的启动跑在主 run loop 上 ⇒
    /// 它落在整轮测试的哪个时刻**不可控** ⇒ 它写进**进程共享**的
    /// `SafeModeService-XCTest-isolation` suite 时，ZZZ canary 会把这次写入
    /// 记到**当时正在跑的那个 test** 头上（实测抓到的是
    /// `TrashStoreMainActorTests` —— 一个根本没碰 SafeMode 的无辜旁观者）。
    ///
    /// ⇒ 修法不是「把 key 从 canary 的监控列表里拿掉」（那会削弱守卫），
    /// 而是**测试进程里根本不做崩溃记账**：那里没有「上一次启动」可判，
    /// 计数本就没有意义；而**哨兵文件仍然要写**（进测试专用目录）⇒
    /// ID-REVIEW-1045 的「同族第 9 例」守卫的牙齿**不受影响**。
    func testTheTestHostKeepsTheSharedSafeModeSuiteClean() {
        let suite = SafeModeService.xcTestDefaults
        // Start from a clean slate so the assertion below is about THIS
        // test's writes, not about a leftover.
        suite.removeObject(forKey: "safeMode.crashCount")
        suite.removeObject(forKey: "safeMode.active")
        suite.removeObject(forKey: "safeMode.sentinelHealthy")

        // The app's shared instance is the one that runs at startup.
        let shared = SafeModeService.shared
        shared.registerPreviousLaunchDidCrash()
        shared.registerSuccessfulLaunch()

        XCTAssertNil(
            suite.object(forKey: "safeMode.crashCount"),
            "测试宿主**不得**把崩溃计数写进进程共享的 SafeMode suite"
            + "（app 的启动时刻不可控 ⇒ 写入会被 ZZZ canary 记到当时正在跑的"
            + "那个 test 头上 ⇒ 实测抓错人：TrashStoreMainActorTests）"
        )
        XCTAssertNil(
            suite.object(forKey: "safeMode.active"),
            "测试宿主**不得**把安全模式标志写进进程共享的 SafeMode suite"
        )
        XCTAssertNil(
            suite.object(forKey: "safeMode.sentinelHealthy"),
            "测试宿主**不得**把哨兵健康标志写进进程共享的 SafeMode suite"
        )
    }

    // MARK: - Helper

    private func makeService() -> SafeModeService {
        SafeModeService(defaults: defaultsSuite, directory: tmpDir)
    }

    /// `directory` 覆盖下的哨兵路径（与 `SafeModeService.sentinelURL`
    /// 的 `directoryOverride` 分支一致：`ClipMemory/.running-sentinel`）。
    private var sentinelURL: URL {
        tmpDir.appendingPathComponent("ClipMemory/.running-sentinel", isDirectory: false)
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

    /// The 1-based line number of `needle` in the app file `relativePath`
    /// (e.g. "AppDelegate.swift"), or `nil` when it is not there.
    ///
    /// Used for ORDER guards: the "is this called before that" questions
    /// cannot be answered by counting occurrences.
    private static func lineNumber(
        of needle: String,
        in relativePath: String
    ) throws -> Int? {
        let files = try TestSourceScanner.appSourceFiles()
        guard let url = files.first(where: {
            TestSourceScanner.appRelativePath(of: $0) == relativePath
        }) else { return nil }
        let source = try String(contentsOf: url, encoding: .utf8)
        let blanked = TestSourceScanner.blankingCommentsAndStrings(source)
        for (index, line) in blanked.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated() where line.contains(needle) {
            return index + 1
        }
        return nil
    }
}
