import XCTest
import AppKit
import Carbon.HIToolbox
@testable import ClipMemory

/// ID-REVIEW-1044：测试进程**不得**占用**系统级全局资源** —— 全局热键 ⌘⇧V
/// 与菜单栏状态项。
///
/// ⑬ 测试往生产域写 → ⑭ 测试往用户磁盘写 20 万 plist → ⑮ 测试毁用户剪贴板
/// → ⑯ 测试把夹具文本写进用户剪贴板 → ⑰ 测试读用户生产钥匙串
/// ⇒ 本条是**同族第 6 例**：测试宿主**抢走用户的全局快捷键**。
/// （并附**同族第 7 例**：仓库里存在**两份**「是不是测试进程」的实现。）
///
/// ## 判据为什么是「系统级真尺子」
///
/// Carbon 的键位组合在**同一进程内**是独占的 —— 实测
/// （`/tmp/cm-carbon-semantics.swift`，2026-10-28）：同一个 ⌘⇧V，
/// **换一个 signature 再注册一样返回 -9878**
/// ⇒ 「本进程能不能注册 ⌘⇧V」直接反映「**本进程**是不是已经占着它」。
///
/// ⚠️ **订正（ID-REVIEW-1045 实测，2026-10-28）**：本文件早先写的
/// 「**系统级**独占」是**从同进程实测外推出来的**，而这个外推**不成立** ——
/// 跨进程实测：两个进程可以**同时**持有同一个 ⌘⇧V 组合（用不同 signature
/// 是 `noErr`；用**生产 signature**（0x434C5050 / id 1）**也是** `noErr`）
/// ⇒ **别的进程占不住它** ⇒ 哨兵 ⑦ 判的是「**本进程**有没有持有」，
/// 而**不是**「系统里有没有别人占着」。
///
/// 实测（2026-10-28，修之前）：`xcodebuild test` 跑起来时，测试宿主
/// （TEST_HOST = 真 app，日志里的 `ClipMemory[9077]`）打出
/// `[HotKeyManager] Hotkey registered: ⌘⇧V`
/// ⇒ 测试进程真的注册成功、真的占着用户的快捷键。真实后果是：
/// 用户按 ⌘⇧V 时，**测试宿主**（它的 handler 会 `showMainWindow()`）
/// **也会响应** ⇒ 在用户屏幕上弹一个假窗口。
/// ⚠️ 早先写的后果②（「生产 app 注册失败 ⇒ 用户的 app 静默失去热键」）
/// **实测不成立**（跨进程不独占）—— 但**修法完全不受影响**：后果①既是
/// 真实的，也必须修。
///
/// ## 修法（两道闸门，都在**收敛点**上）
///
/// 1. `HotKeyManager.register()` —— 全 app 树**唯一**的
///    `RegisterEventHotKey` 调用点（静态守卫 ⑧ 钉住这个「唯一」）；
///    `updateHotKey()` 也走 `register()` ⇒ **一道闸门覆盖全部路径**。
/// 2. `AppDelegate.setupStatusItem()` —— 全 app 树**唯一**的
///    `NSStatusBar.system.statusItem` 调用点（静态守卫 ⑨）。
///    `LSUIElement = true` ⇒ 这个 `NSStatusItem` 就是 ClipMemory 在菜单栏上
///    的**全部存在** ⇒ 测试宿主每跑一次测试，用户菜单栏就多一个来路不明的
///    ClipMemory 图标，点开还是**空的**（测试宿主读的是隔离 store）。
final class Review1044RegressionTests: XCTestCase {

    // MARK: - ① 行为守卫（承重）：测试宿主不得占着系统级全局资源

    /// ① 测试宿主**不得**持有系统级全局热键。
    ///
    /// `hotKeyRef` 非 nil ⇔ 本进程**真的**向 Carbon 注册过 ⌘⇧V ⇒ 判据是
    /// **结果**，不是「源码里有没有某句话」。
    func testTheTestHostDoesNotHoldTheGlobalHotkey() throws {
        let delegate = try XCTUnwrap(
            NSApp.delegate as? AppDelegate,
            "测试宿主里 AppDelegate 应已启动（TEST_HOST = 真 app）"
        )
        XCTAssertNil(
            delegate.hotKeyManager?.hotKeyRef,
            "测试宿主不得持有系统级全局热键（hotKeyRef 非 nil ⇒ ⌘⇧V 被测试进程占着，"
            + "用户按 ⌘⇧V 时测试宿主**也会响应**，在用户屏幕上弹一个假窗口）"
        )
    }

    /// ② 新建的 `HotKeyManager` 调用 `register()` ⇒ **不得**拿到热键。
    ///
    /// 这一条直接覆盖「直接 new 一个 manager 再注册」的路（`HotKeyManagerTests`
    /// 就是这么调的）⇒ 闸门必须落在 `register()` 内部，而不是只在
    /// `AppDelegate.setupHotKey()` 外面挡一层。
    func testAFreshManagerRegisterDoesNotAcquireTheGlobalHotkey() {
        let defaults = makeTestDefaults()
        defer { TestSuiteCleanup.destroy(defaults) }

        let manager = HotKeyManager(defaults: defaults)
        manager.register()

        XCTAssertNil(
            manager.hotKeyRef,
            "测试进程里的 register() 不得注册系统级全局热键"
        )
        XCTAssertTrue(
            manager.registerAttempted,
            "注册**请求**必须被记录（闸门是「跳过系统级注册」，不是「假装没被调用」）"
        )
        manager.unregister()
    }

    /// ③ `updateHotKey()` 会走 `unregister()` + `register()` ⇒ 同样不得拿到热键。
    func testUpdateHotKeyDoesNotAcquireTheGlobalHotkey() {
        let defaults = makeTestDefaults()
        defer { TestSuiteCleanup.destroy(defaults) }

        let manager = HotKeyManager(defaults: defaults)
        manager.updateHotKey(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey | optionKey))

        XCTAssertNil(
            manager.hotKeyRef,
            "updateHotKey() 走 register() ⇒ 同样不得拿到系统级全局热键"
        )
        XCTAssertEqual(
            manager.config.keyCode, UInt32(kVK_ANSI_C),
            "配置本身照常更新（闸门只拦系统级注册，不该拦业务逻辑）"
        )
        manager.unregister()
    }

    /// ④ 测试宿主**不得**在用户的菜单栏里占一个位置。
    func testTheTestHostDoesNotCreateAMenuBarStatusItem() throws {
        let delegate = try XCTUnwrap(
            NSApp.delegate as? AppDelegate,
            "测试宿主里 AppDelegate 应已启动（TEST_HOST = 真 app）"
        )
        XCTAssertNil(
            delegate.statusItem,
            "测试宿主不得在用户菜单栏里创建状态项（LSUIElement=1 ⇒ 它就是菜单栏上的全部存在）"
        )
    }

    // MARK: - ② 判定函数（纯函数 ⇒ 两侧都可测）

    /// ⑤ 生产 ⇒ **一定注册**。
    ///
    /// ⚠️ 这一条是「把 `isRunningTests` 条件去掉」那条变异**唯一**能抓住的
    /// 地方 —— 那个变异在真机上会让**整个 app 失去全局热键**（用户按 ⌘⇧V
    /// 没反应，且没有任何报错）。把判定抽成纯函数，正是为了让它可测。
    func testTheDecisionFunctionRegistersInProduction() {
        XCTAssertTrue(
            HotKeyManager.shouldRegisterSystemHotKey(isRunningTests: false),
            "生产环境必须注册全局热键（否则用户按 ⌘⇧V 没反应）"
        )
    }

    /// ⑥ XCTest ⇒ **不注册**。
    func testTheDecisionFunctionDoesNotRegisterUnderXCTest() {
        XCTAssertFalse(
            HotKeyManager.shouldRegisterSystemHotKey(isRunningTests: true),
            "XCTest 下不得注册系统级全局热键"
        )
    }

    // MARK: - ③ 进程级哨兵：本进程不得持有生产组合 ⌘⇧V

    /// ⑦ **进程级**哨兵：用生产 signature/id 试着注册 ⌘⇧V。
    ///
    /// 判据来自实测的 Carbon 语义（键位组合在**同一进程内**独占，换
    /// signature 也一样 -9878）⇒ 这里的结果反映「**本进程**是不是已经
    /// 占着这个组合」。
    /// 修之前：测试宿主启动时注册了 ⌘⇧V ⇒ 这里必然 -9878 ⇒ 红。
    /// 修之后：测试宿主没占 ⇒ 这里是 `noErr` ⇒ 绿。
    ///
    /// ⚠️ 探针**不留下占用**：`defer` 里立刻注销。
    ///
    /// ⚠️ **订正（ID-REVIEW-1045 实测，2026-10-28）**：本守卫早先写的
    /// 「系统级」「被**别的进程**占着 ⇒ 跳过」是**基于一个不成立的外推**
    /// （跨进程实测：**不**独占 —— 别的进程占不住它）⇒ 那个 skip 分支
    /// 实际**不可达**。守卫的**真实语义**是「本进程有没有持有」，
    /// 而这一语义**依然成立且依然有牙**：探针与测试宿主同进程 ⇒ 宿主
    /// 注册过就必然 -9878。
    func testTheProductionHotkeyComboIsFreeSystemWide() throws {
        let delegate = try XCTUnwrap(
            NSApp.delegate as? AppDelegate,
            "测试宿主里 AppDelegate 应已启动（TEST_HOST = 真 app）"
        )
        let testHostHoldsIt = delegate.hotKeyManager?.hotKeyRef != nil

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            UInt32(cmdKey | shiftKey),
            EventHotKeyID(signature: Self.productionHotKeySignature, id: Self.productionHotKeyID),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        defer {
            if let ref { UnregisterEventHotKey(ref) }
        }

        if status == noErr {
            XCTAssertFalse(
                testHostHoldsIt,
                "Carbon 说组合是空的，但我们手里有 hotKeyRef ⇒ 状态不自洽"
            )
            return
        }
        if testHostHoldsIt {
            XCTFail(
                "测试宿主占着生产热键 ⌘⇧V（status=\(status)）—— "
                + "用户按 ⌘⇧V 时测试宿主**也会响应**，在用户屏幕上弹一个假窗口"
                + "（注意：Carbon 的键位组合只在**同一进程内**独占 —— 跨进程实测"
                + "两个进程可同时持有同一组合 ⇒ 用户的真 app **仍能**注册成功）"
            )
            return
        }
        // ⚠️ 订正（ID-REVIEW-1045 实测）：跨进程**不**独占 ⇒ 「别的进程
        // 占着 ⌘⇧V」在本进程里**看不到**（探针仍会注册成功）⇒ 这个
        // 分支实际上**不可达**。保留它作为防御：万一 Carbon 将来改成
        // 跨进程独占，这里的行为仍然是正确的。
        throw XCTSkip(
            "⌘⇧V 在本进程内已被占用（status=\(status)）—— 不是本条缺陷，跳过"
        )
    }

    // MARK: - ④ 静态守卫：收敛点必须真的是收敛点

    /// ⑧ `RegisterEventHotKey` 的调用点必须**只有一处**，且在
    ///    `HotKeyManager` 里。
    ///
    /// 这条钉住的是**结构**而不是某一行代码：将来若有人在别处再写一个
    /// 系统级热键注册，闸门就漏了 ⇒ 计数会变成 2 ⇒ 红。
    func testOnlyTheHotKeyManagerMayRegisterASystemGlobalHotkey() throws {
        let sites = try Self.callSites(of: "RegisterEventHotKey")
        XCTAssertEqual(
            sites, ["Services/HotKeyManager.swift×1"],
            "RegisterEventHotKey 的调用点必须只有 HotKeyManager 这一处"
        )
    }

    /// ⑨ 菜单栏状态项的**获取点**必须**只有一处**，且在 `AppDelegate` 里。
    ///
    /// ⚠️ **needle 用的是 `NSStatusBar.system`（资源身份），不是
    /// `NSStatusBar.system.statusItem`（调用写法）** ——
    /// 独立核验员实测出的真洞：把创建写成
    /// `let aliasBar = NSStatusBar.system; aliasBar.statusItem(...)`
    /// ⇒ 「调用写法」这个 needle 出现次数**不变** ⇒ 守卫 ⑨ 空绿，
    /// 而测试宿主**真的**在用户菜单栏里多占了一个图标（且因为没赋值给
    /// `AppDelegate.statusItem`，行为守卫 ④ 也看不见）。
    /// ⇒ **能创建状态项的路径必然经过 `NSStatusBar.system` 这个实例**
    /// ⇒ 盯住它就盯住了资源本身。
    func testOnlyTheAppDelegateMayCreateAMenuBarStatusItem() throws {
        let sites = try Self.callSites(of: "NSStatusBar.system")
        XCTAssertEqual(
            sites, ["AppDelegate.swift×1"],
            "NSStatusBar.system（状态项的唯一来源）只能出现在 AppDelegate 这一处"
            + "——用调用写法当 needle 会被别名绕过（ID-REVIEW-1044 独立核验实测）"
        )
    }

    /// ⑩ 全仓只能有**一个**「是不是测试进程」的探针实现。
    ///
    /// 读进程环境变量的**唯一**合法位置是 `Utils/TestIsolation.swift`
    /// （三信号探针 `TestIsolation.isRunningTests`）。ID-REVIEW-1043 的结论：
    /// 同一个仓库里出现**两份**实现时，加固了严格的那份，松的那份照样漏。
    /// 实测（修之前）：`ServiceProtocols.swift` 的两处 `precondition` 直接读
    /// `XCTestConfigurationFilePath`（**一个**信号）⇒ 已收敛到统一探针。
    ///
    /// ⚠️ **三个探针锚点都要盯，不能只盯 env 读取** ——
    /// 独立核验员实测出的真洞：把某处闸门换成
    /// `NSClassFromString("XCTestCase") != nil`（**另一个机制**实现的探针）
    /// ⇒ 只盯 env 读取的 needle **数不到** ⇒ 守卫 ⑩ 空绿。
    /// ⇒ 三个信号在代码里各自可见的锚点（`ProcessInfo.processInfo.environment[` /
    /// `NSClassFromString(` / `Bundle.allBundles`）都必须**只**出现在
    /// `Utils/TestIsolation.swift`。
    func testOnlyTheTestIsolationFileMayReadTheProcessEnvironment() throws {
        let anchors = [
            "ProcessInfo.processInfo.environment[",
            "NSClassFromString(",
            "Bundle.allBundles"
        ]
        for anchor in anchors {
            let sites = try Self.callSites(of: anchor)
            XCTAssertEqual(
                sites, ["Utils/TestIsolation.swift×1"],
                "探针锚点 \(anchor) 只能出现在 Utils/TestIsolation.swift 这一处"
                + "（换了机制的第二个探针实现也必须被抓住）"
            )
        }
    }

    // MARK: - ⑤ 控制组（证明守卫不是空绿）

    /// ⑯ 控制组：**别名写法**必须仍被守卫 ⑨ 抓到（ID-REVIEW-1044 独立核验
    /// 实测的真洞：改用 `NSStatusBar.system.statusItem` 当 needle 时，
    /// 别名写法会让计数不变 ⇒ 守卫空绿）。
    func testTheScannerFindsAnAliasedStatusItemSource() {
        let sample = """
        func planted() {
            let aliasBar = NSStatusBar.system
            _ = aliasBar.statusItem(withLength: NSStatusItem.variableLength)
        }
        """
        XCTAssertEqual(
            TestSourceScanner.occurrenceCount(
                of: "NSStatusBar.system",
                in: TestSourceScanner.blankingCommentsAndStrings(sample)
            ),
            1,
            "别名写法仍必须被守卫 ⑨ 抓到（资源身份 needle ⇒ 抓的是资源，不是写法）"
        )
        XCTAssertEqual(
            TestSourceScanner.occurrenceCount(
                of: "NSStatusBar.system.statusItem",
                in: TestSourceScanner.blankingCommentsAndStrings(sample)
            ),
            0,
            "旧的「调用写法」needle 对别名写法**无效** —— 这正是要换掉它的原因"
        )
    }

    /// ⑰ 控制组：**换了机制**的探针实现必须被守卫 ⑩ 抓到。
    func testTheScannerFindsAPlantedAlternativeProbeImplementation() {
        let sample = """
        func planted() {
            let inTest = NSClassFromString("XCTestCase") != nil
            let hasBundle = Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
        }
        """
        XCTAssertEqual(
            TestSourceScanner.occurrenceCount(
                of: "NSClassFromString(",
                in: TestSourceScanner.blankingCommentsAndStrings(sample)
            ),
            1,
            "守卫 ⑩ 必须能发现换了机制的探针实现（NSClassFromString）"
        )
        XCTAssertEqual(
            TestSourceScanner.occurrenceCount(
                of: "Bundle.allBundles",
                in: TestSourceScanner.blankingCommentsAndStrings(sample)
            ),
            1,
            "守卫 ⑩ 必须能发现换了机制的探针实现（Bundle.allBundles）"
        )
    }

    /// ⑪ 扫描器必须能发现**真实的**调用点。
    func testTheScannerFindsAPlantedGlobalHotkeyRegistration() {
        let sample = """
        func planted() {
            let status = RegisterEventHotKey(49, 256, hid, target, 0, &ref)
        }
        """
        XCTAssertEqual(
            TestSourceScanner.occurrenceCount(
                of: "RegisterEventHotKey",
                in: TestSourceScanner.blankingCommentsAndStrings(sample)
            ),
            1,
            "扫描器必须能发现真实的调用点（否则守卫 ⑧ 是空绿）"
        )
    }

    /// ⑫ 注释里的调用**不是**调用点。
    func testTheScannerIgnoresCommentedOutGlobalHotkeyRegistrations() {
        let sample = """
        // let status = RegisterEventHotKey(49, 256, hid, target, 0, &ref)
        /* let other = RegisterEventHotKey(49, 256, hid, target, 0, &ref2) */
        """
        XCTAssertEqual(
            TestSourceScanner.occurrenceCount(
                of: "RegisterEventHotKey",
                in: TestSourceScanner.blankingCommentsAndStrings(sample)
            ),
            0,
            "注释里的调用不是调用点（守卫 ⑧ 只看代码）"
        )
    }

    /// ⑬ 扫描器必须能发现**读进程环境变量**的代码。
    func testTheScannerFindsAPlantedEnvironmentRead() {
        let sample = """
        let inTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        """
        XCTAssertEqual(
            TestSourceScanner.occurrenceCount(
                of: "ProcessInfo.processInfo.environment[",
                in: TestSourceScanner.blankingCommentsAndStrings(sample)
            ),
            1,
            "扫描器必须能发现读进程环境变量的代码（否则守卫 ⑩ 是空绿）"
        )
    }

    /// ⑭ 判定函数的**调用点**必须由**规范探针**驱动。
    ///
    /// ⚠️ 这一条守的是一个**行为上测不到**的洞：把调用点的参数硬编码成
    /// `true`（⇒ 生产进程永远跳过注册 ⇒ **用户的 app 静默失去热键**），
    /// 在测试宿主里**行为完全一致**（都跳过）⇒ 行为守卫 ① ② ③ ⑦ **全绿**。
    /// 纯函数那一侧（⑤⑥）也测不到 —— 它测的是函数本身，不是调用点。
    ///
    /// 所以这里用**结构守卫**把调用点的**实参**钉死：
    /// ① `shouldRegisterSystemHotKey(isRunningTests: …)` 在 app 树里总共只
    ///    出现 **2** 次（1 次声明 + 1 次调用）⇒ 不存在第二个调用点；
    /// ② 其中**恰好 1** 次的实参是 `TestIsolation.isRunningTests`（规范探针）。
    ///
    /// ⚠️ 这是一条**文本**守卫（不是行为守卫）—— 如实标注：纯函数化的
    /// 「生产那一半不可测」是这个模式的**固有**限制（ID-REVIEW-1043 同款），
    /// 调用点的实参只能静态钉。
    func testTheDecisionCallSiteIsDrivenByTheCanonicalProbe() throws {
        let files = try TestSourceScanner.appSourceFiles()
        var total = 0
        var canonical = 0
        for url in files {
            let source = try String(contentsOf: url, encoding: .utf8)
            let blanked = TestSourceScanner.blankingCommentsAndStrings(source)
            total += TestSourceScanner.occurrenceCount(
                of: "shouldRegisterSystemHotKey(isRunningTests: ",
                in: blanked
            )
            canonical += TestSourceScanner.occurrenceCount(
                of: "shouldRegisterSystemHotKey(isRunningTests: TestIsolation.isRunningTests)",
                in: blanked
            )
        }
        XCTAssertEqual(
            total, 2,
            "shouldRegisterSystemHotKey(isRunningTests: …) 在 app 树里只能出现 2 次（1 声明 + 1 调用）"
        )
        XCTAssertEqual(
            canonical, 1,
            "调用点的实参必须是规范探针 TestIsolation.isRunningTests"
            + "（硬编码 true ⇒ 生产 app 永远失去热键，而行为守卫会全绿）"
        )
    }

    /// ⑮ 控制组：结构守卫 ⑭ 的判据本身必须能分辨「对」与「错」。
    func testTheCanonicalProbeGuardDiscriminates() {
        let good = """
        guard Self.shouldRegisterSystemHotKey(isRunningTests: TestIsolation.isRunningTests) else { return }
        """
        let bad = """
        guard Self.shouldRegisterSystemHotKey(isRunningTests: true) else { return }
        """
        XCTAssertEqual(
            TestSourceScanner.occurrenceCount(
                of: "shouldRegisterSystemHotKey(isRunningTests: TestIsolation.isRunningTests)",
                in: TestSourceScanner.blankingCommentsAndStrings(good)
            ),
            1,
            "守卫 ⑭ 必须能认出「规范探针」的调用点"
        )
        XCTAssertEqual(
            TestSourceScanner.occurrenceCount(
                of: "shouldRegisterSystemHotKey(isRunningTests: TestIsolation.isRunningTests)",
                in: TestSourceScanner.blankingCommentsAndStrings(bad)
            ),
            0,
            "守卫 ⑭ 必须能分辨「硬编码常量」的调用点"
        )
    }

    // MARK: - Helper

    /// 生产热键的 signature / id —— 与 `HotKeyManager.register()` 一致。
    private static let productionHotKeySignature = OSType(0x434C5050)
    private static let productionHotKeyID: UInt32 = 1

    /// App 树里 `needle` 的**代码**调用点，形如 `["Path/File.swift×n", …]`。
    ///
    /// 扫描跑在**抹掉注释和字符串字面量**的副本上 ⇒ 注释里提到的 API 不算
    /// 调用点。文件按路径排序 ⇒ 结果稳定。
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
