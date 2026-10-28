import XCTest
@testable import ClipMemory

/// ID-REVIEW-1047 (2026-10-28): 生产资源引用在**调用点**内联构造 /
/// **默认参数**就是生产身份 —— 「测试基础设施污染用户真实环境」这一族的
/// **第 10 例**。
///
/// ## 这一族的形状（1042 → 1046 已经踩过的五个实例）
///
/// | 轮次 | 被污染的用户资源 |
/// |---|---|
/// | 1042 | 系统通用剪贴板 |
/// | 1043 | 生产钥匙串项 |
/// | 1044 | 全局热键 ⌘⇧V + 菜单栏状态项 |
/// | 1045 | 崩溃哨兵文件 |
/// | 1046 | 崩溃计数共享 suite |
/// | **1047（本条）** | **首次启动标志 + 恢复向导的图片目录 / UserDefaults + 备份目录** |
///
/// ## 本条挖到的三个未收口实例
///
/// **① `FirstLaunchService.init()`（`FirstLaunchService.swift`）**
///
/// 修前：`self.store = .standard`。而且该文件的**头部注释宣称**：
///
/// > "Test seam: a `xcTestDefaults` suite name parallels the existing
/// `ClipboardStore.xcTestDefaults` pattern, so XCTest can redirect
/// `hasLaunchedBefore` reads/writes away from production `com.clipmemory.app`."
///
/// ⇒ **那个 seam 根本不存在**（该文件里零 `xcTestDefaults`）⇒ 一条写在
/// 注释里的、**没有被强制**的不变量 —— 与 ID-REVIEW-1043 的教训逐字同型
/// （「代码里写着的不变量 ≠ 被强制的不变量」）。
///
/// ⇒ 用户可见后果：`WelcomeView` 的「Get Started」按钮调
/// `FirstLaunchManager.markLaunched()` ⇒ **写 `hasLaunchedBefore` 到用户的
/// 真实域** ⇒ 用户的 app 此后**再也不弹欢迎页**（或反过来一直弹）。
///
/// **② `AppDelegate.showRestoreWizard()`（`AppDelegate.swift`）**
///
/// 修前：`imagesDirectory:` 内联拼 `ClipMemory/Images`（绕过
/// `ImageStorage` 的 `Images-Tests` 重定向），`defaults: .standard`
/// （绕过 store 的隔离 suite）—— 而它**导入进去的那个 store** 恰恰是隔离的
/// ⇒ 在测试宿主里，一次恢复会把**导入的历史写进用户的生产域**。
///
/// ⇒ 同一屏的另一个调用点（`BackupSettingsView.swift:207`，导出路径）
/// **本来就走了** `ImageStorage` 的 seam ⇒ 两个调用点不一致，正是缺口能
/// 长期隐形的原因。
///
/// **③ `BackupService.init(...)`（`BackupService.swift`）**
///
/// 修前：`defaults: UserDefaults = .standard` + 生产目录默认值 ⇒
/// **默认参数就是生产身份**（ID-REVIEW-1043 的教训原文）⇒ 测试里一个裸
/// `BackupService()` 会写用户的偏好域，而一次 `backupNow()` 更会**创建并
/// 剪掉用户的真实备份**。
///
/// ## 还有一个 canary 盲区
///
/// `ZZZSuiteTeardownTests.appLifecycleKeys` 里**有** `hasLaunchedBefore`
/// ⇒ 主 canary **跳过**所有白名单键 ⇒ 对这个键的写入**看不见**
/// （与 ID-REVIEW-1038 把 `ClipboardItems` 移出白名单的理由完全同型：
/// *能容忍变化 ⇒ 看不见破坏*）。
///
/// ## 本文件锁住的不变量
///
/// ① 测试进程里 `FirstLaunchService()` **不得**绑到生产域
/// ② `defaultsFor(isTestProcess: false)` **必须**就是 `.standard`（生产零变化）
/// ③ `defaultsFor(isTestProcess: true)` **不得**是生产域
/// ④ `ServiceContainer.firstLaunch` 这个 seam 本身**不得**绑到生产域
/// ⑤ `BackupService` 的两半同理
/// ⑥ 测试进程里的 `BackupService()` **不得**用生产目录
/// ⑦ 生产分支的目录/域**必须**与修前逐字节一致
/// ⑧ app 树里 `UserDefaults.standard` **只**允许出现在域判别器里
/// ⑨ 恢复向导**必须**走 `ImageStorage` / `ClipboardStore` 的 seam
/// ⑩ canary 的比较函数**必须**能分辨「加了 / 删了 / 翻了 / 什么都没发生」
final class Review1047RegressionTests: XCTestCase {

    // MARK: - ① 测试进程里 FirstLaunchService 不得绑到生产域

    /// ① **行为**守卫：`FirstLaunchService()` 的默认 store 不得是生产域。
    ///
    /// ⚠️ 这条守卫**只读不写** —— 它用「这个实例绑到了哪个域」来断言，
    /// 而不是「写进去之后生产域有没有变」。
    ///
    /// ⇒ 原因（ID-REVIEW-1042 的教训）：用「写生产域再检查」来证明
    /// 「我们没写生产域」，那个**验证工具本身就是那个伤害源** ⇒ 一旦实现
    /// 退化，这条守卫会真的把用户的首次启动标志翻掉。
    func testFirstLaunchServiceDefaultStoreIsNotTheProductionDomain() {
        let service = FirstLaunchService()
        XCTAssertFalse(
            TestIsolation.addressesProductionDomain(service.store),
            "测试进程里的 `FirstLaunchService()` **不得**绑到生产域"
            + "（`hasLaunchedBefore` 写在用户的真实 `com.clipmemory.app` 里 ⇒"
            + "用户的 app 此后不再弹欢迎页）"
        )
    }

    // MARK: - ②③ 生产分支零变化 + 测试分支隔离（纯函数）

    /// ② **纯函数**守卫：生产分支必须**就是** `.standard`。
    ///
    /// ⇒ 生产行为零变化是这一族的硬约束（1042–1046 每一条都守住了它）。
    /// 而在测试宿主里探针**恒为真** ⇒ 这一半**结构上不可达** ⇒ 必须
    /// 把它做成可喂参的纯函数（ID-REVIEW-1045 的形状）。
    func testFirstLaunchServiceProductionBranchIsExactlyStandard() {
        XCTAssertTrue(
            FirstLaunchService.defaultsFor(isTestProcess: false) === UserDefaults.standard,
            "生产分支必须仍然是 `UserDefaults.standard`（生产行为零变化）"
            + "—— 把它改成别的东西会让用户丢设置"
        )
    }

    /// ③ **纯函数**守卫：测试分支不得是生产域。
    func testFirstLaunchServiceTestBranchIsIsolated() {
        let isolated = FirstLaunchService.defaultsFor(isTestProcess: true)
        XCTAssertFalse(
            isolated === UserDefaults.standard,
            "测试分支不得是 `UserDefaults.standard`"
        )
        XCTAssertFalse(
            TestIsolation.addressesProductionDomain(isolated),
            "测试分支不得指向生产域（域级判定，不是身份判定）"
        )
    }

    // MARK: - ④ seam 本身不得绑到生产域

    /// ④ **行为**守卫：`ServiceContainer.firstLaunch` 这个 **seam** 不得
    /// 绑到生产域。
    ///
    /// ⇒ 为什么要单独钉 seam：生产代码读的是
    /// `FirstLaunchManager.isFirstLaunch` → `ServiceContainer.firstLaunch`
    /// ⇒ seam 自己指向哪里，比「某个 service 的 init 对不对」更接近真正的
    /// 不变量（ID-REVIEW-1043：「在收敛点判定」）。
    func testTheFirstLaunchSeamItselfIsNotBoundToProduction() {
        XCTAssertFalse(
            TestIsolation.addressesProductionDomain(ServiceContainer.firstLaunch.store),
            "`ServiceContainer.firstLaunch` 这个 seam 在测试进程里**不得**指向生产域"
            + "（`FirstLaunchManager.isFirstLaunch` 读的就是它）"
        )
    }

    // MARK: - ⑤⑥⑦ BackupService 的两半

    /// ⑤ **纯函数**守卫：`BackupService` 的生产分支 = `.standard`，
    /// 测试分支 ≠ 生产域。
    func testBackupServiceDefaultsBothHalves() {
        XCTAssertTrue(
            BackupService.defaultsFor(isTestProcess: false) === UserDefaults.standard,
            "生产分支必须仍然是 `UserDefaults.standard`（生产行为零变化）"
        )
        let isolated = BackupService.defaultsFor(isTestProcess: true)
        XCTAssertFalse(isolated === UserDefaults.standard, "测试分支不得是 `.standard`")
        XCTAssertFalse(
            TestIsolation.addressesProductionDomain(isolated),
            "测试分支不得指向生产域"
        )
    }

    /// ⑥ **行为**守卫：测试进程里一个裸 `BackupService()` 不得用生产目录。
    ///
    /// ⇒ 这一条比「域」更要紧：备份目录被摸到不只是写偏好域，而是一次
    /// `backupNow()` 会**创建并剪掉用户的真实备份**（保留份数有限）。
    func testABareBackupServiceInATestProcessTouchesNoProductionDirectory() {
        let service = BackupService()
        let appSupport = AppDirectories.applicationSupport.path
        XCTAssertFalse(
            service.backupsDirectoryURL.path.hasPrefix(appSupport),
            "测试进程里的 `BackupService()` **不得**用用户的真实备份目录"
            + "（一次 `backupNow()` 就会创建并剪掉用户的备份）"
        )
        XCTAssertFalse(
            service.imagesDirectoryURL.path.hasPrefix(appSupport),
            "测试进程里的 `BackupService()` **不得**用用户的真实图片目录"
        )
    }

    /// ⑦ **纯函数**守卫：生产分支的目录**必须**与修前逐字节一致。
    ///
    /// ⇒ 这一条是「生产零变化」的另一半：修的是「默认参数」，不能顺手把
    /// 生产路径也改了（比如换成一个「更规范」的目录名）。
    func testBackupServiceProductionPathsAreUnchanged() {
        let appSupport = AppDirectories.applicationSupport
        XCTAssertEqual(
            BackupService.defaultBackupsDirectory(isTestProcess: false),
            appSupport.appendingPathComponent("ClipMemory/Backups", isDirectory: true),
            "生产备份目录必须仍是 `ClipMemory/Backups`"
        )
        XCTAssertEqual(
            BackupService.defaultImagesDirectory(isTestProcess: false),
            appSupport.appendingPathComponent("ClipMemory/Images", isDirectory: true),
            "生产图片目录必须仍是 `ClipMemory/Images`"
        )
    }

    // MARK: - ⑧ app 树里不得有内联的生产域引用

    /// ⑧ **静态**守卫：app 树里 `UserDefaults.standard` **只**允许出现在
    /// 域判别器（`TestIsolation.swift`）里。
    ///
    /// ⚠️ 盯的是**资源身份**（`UserDefaults.standard` 这个 API 名没法用
    /// 别的写法绕开），不是「写法风格」—— 这正是 ID-REVIEW-1044 的教训
    /// （「静态守卫要盯资源/动作/顺序，不盯写法」）。
    ///
    /// ⇒ 判据用**文件集合**而不是**出现次数**：次数会随实现内部重构漂移，
    /// 而「这个 API 出现在哪个文件」才是要守住的东西。
    func testTheAppTreeReferencesTheProductionDefaultsOnlyInTheDomainDiscriminator() throws {
        let files = try Self.filesContaining("UserDefaults.standard")
        XCTAssertEqual(
            files, ["Utils/TestIsolation.swift"],
            "`UserDefaults.standard` 只允许出现在域判别器 `TestIsolation.swift` 里"
            + "（它要判断「这个实例是不是生产域」，所以必须提到它）"
            + "—— 其它任何一处都是在**调用点**内联生产身份"
        )
    }

    // MARK: - ⑨ 恢复向导必须走 seam

    /// ⑨ **静态**守卫：恢复向导的图片目录与 UserDefaults **必须**来自 seam。
    ///
    /// ⇒ 两条断言分开写：一条钉「用了 seam」，一条钉「**没有**内联路径」。
    /// 只写前者的话，把 seam 换回内联、同时保留一行 seam 调用就能骗过它。
    ///
    /// ⚠️ 「用了 seam」这条用的是**包含**而不是**相等**：`BackupSettingsView`
    /// 的导出路径（`BackupSettingsView.swift:207`）本来就走同一个 seam
    /// ⇒ 未来多出一个合法调用点不该把守卫搞红。
    func testTheRestoreWizardResolvesItsResourcesThroughTheSeams() throws {
        let seamCall = try Self.filesContaining("imagesDirectory: ImageStorage.shared.imagesDirectoryURL")
        XCTAssertTrue(
            seamCall.contains("AppDelegate.swift"),
            "恢复向导的图片目录必须走 `ImageStorage.shared.imagesDirectoryURL`"
            + "（该 seam 在测试进程里指向 `Images-Tests`）"
            + "—— 实际出现在: \(seamCall)"
        )
        let inlined = try Self.filesContaining("imagesDirectory: AppDirectories")
        XCTAssertEqual(
            inlined, [],
            "恢复向导**不得**内联拼生产图片路径"
            + "（那会绕过 `ImageStorage` 的测试重定向）"
        )
    }

    // MARK: - ⑩ canary 比较函数的自测

    /// ⑩ **纯函数**守卫：canary 的比较函数**必须**能分辨四种情形。
    ///
    /// ⚠️ 为什么要给它单独一条自测：canary 的守卫
    /// （`testFirstLaunchFlagIsNeverChangedDuringTheSuite`）只有当
    /// **比较逻辑本身**是对的才有牙齿 ⇒ 如果那个逻辑恒返回「无漂移」，
    /// canary 会**永远绿**。
    ///
    /// ⇒ 而「给它一个会漂移的生产域输入」来证明它有牙，就等于**真的写
    /// 用户的生产域** ⇒ 不可接受 ⇒ 只能把逻辑下沉成**纯函数**再喂它。
    func testTheCanaryComparisonDistinguishesEveryDestructionShape() {
        // Flipped.
        XCTAssertNotNil(
            ZZZSuiteTeardownTests.firstLaunchFlagDrift(before: true, after: false),
            "true → false 必须是漂移"
        )
        // Added.
        XCTAssertNotNil(
            ZZZSuiteTeardownTests.firstLaunchFlagDrift(before: nil, after: true),
            "absent → present 必须是漂移"
        )
        // Removed.
        XCTAssertNotNil(
            ZZZSuiteTeardownTests.firstLaunchFlagDrift(before: true, after: nil),
            "present → absent 必须是漂移"
        )
        // Nothing happened.
        XCTAssertNil(
            ZZZSuiteTeardownTests.firstLaunchFlagDrift(before: true, after: true),
            "true → true 不是漂移"
        )
        // Absent on both sides (a cold domain) must NOT manufacture a failure.
        XCTAssertNil(
            ZZZSuiteTeardownTests.firstLaunchFlagDrift(before: nil, after: nil),
            "absent → absent 不是漂移（冷盘不得被守卫判成失败）"
        )
    }

    // MARK: - ⑪⑫⑬⑭ 窗口位置不得被测试宿主持久化

    /// ⑪ **纯函数**守卫：测试进程**不得**自动保存窗口位置。
    func testWindowFrameAutosaveIsOffInATestProcess() {
        XCTAssertFalse(
            WindowFrameAutosave.shouldAutosave(isRunningTests: true),
            "测试进程**不得**自动保存窗口位置"
            + "（AppKit 会把它写进用户的真实域 ⇒ 用户保存的窗口位置被测试改写）"
        )
    }

    /// ⑫ **纯函数**守卫：生产进程**必须**自动保存（生产行为零变化）。
    func testWindowFrameAutosaveIsOnInProduction() {
        XCTAssertTrue(
            WindowFrameAutosave.shouldAutosave(isRunningTests: false),
            "生产进程必须照旧自动保存窗口位置（生产行为零变化）"
        )
    }

    /// ⑬ **行为**守卫：测试进程里 `apply` **不得**真的挂上 autosave 名。
    ///
    /// ⇒ 只读断言（读 `frameAutosaveName`），不写任何东西。
    func testApplyingTheAutosaveInATestProcessLeavesTheWindowUntouched() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        XCTAssertTrue(
            window.frameAutosaveName.isEmpty,
            "前置条件：窗口本来就没有 autosave 名"
        )
        WindowFrameAutosave.apply(to: window, name: "com.clipmemory.app.SettingsWindow")
        XCTAssertTrue(
            window.frameAutosaveName.isEmpty,
            "测试进程里 `apply` **不得**挂上 autosave 名"
            + "（挂上了 ⇒ AppKit 会把窗口位置写进用户的真实域）"
        )
    }

    /// ⑭ **静态**守卫：`setFrameAutosaveName` **只**允许出现在
    /// `WindowFrameAutosave.apply` 里。
    ///
    /// ⇒ 盯的是**调用点**（资源身份 + 位置），不是「写法」——
    /// 直接调 `setFrameAutosaveName` 的新代码会立刻被抓到。
    func testFrameAutosaveIsOnlyEverAppliedThroughTheGate() throws {
        let files = try Self.filesContaining("setFrameAutosaveName")
        XCTAssertEqual(
            files, ["Services/WindowManager.swift"],
            "`setFrameAutosaveName` 只允许出现在 `WindowFrameAutosave.apply` 里"
            + "（那是唯一带测试进程闸门的入口）"
        )
        let source = try String(
            contentsOf: TestSourceScanner.appDirectory
                .appendingPathComponent("Services/WindowManager.swift"),
            encoding: .utf8
        )
        let count = TestSourceScanner.occurrenceCount(
            of: "setFrameAutosaveName",
            in: TestSourceScanner.blankingCommentsAndStrings(source)
        )
        XCTAssertEqual(
            count, 1,
            "`WindowManager.swift` 里 `setFrameAutosaveName` 必须**恰好出现一次**"
            + "（就是 `WindowFrameAutosave.apply` 里那一次）"
        )
    }

    // MARK: - Helper

    /// App 树里**代码**（注释与字符串字面量已抹白）出现 `needle` 的
    /// **文件集合**，按路径排序。
    ///
    /// ⚠️ 用 `TestSourceScanner` 的同一套抹白逻辑 ⇒ 守卫与 1041/1042 的
    /// 守卫对「什么算一处」的判断一致（两边各用各的判断标准，就等于互相
    /// 给对方留洞 —— ID-REVIEW-1038 的 M4 教训）。
    private static func filesContaining(_ needle: String) throws -> [String] {
        let files = try TestSourceScanner.appSourceFiles()
        var hits: Set<String> = []
        for url in files {
            let source = try String(contentsOf: url, encoding: .utf8)
            let count = TestSourceScanner.occurrenceCount(
                of: needle,
                in: TestSourceScanner.blankingCommentsAndStrings(source)
            )
            guard count > 0 else { continue }
            hits.insert(TestSourceScanner.appRelativePath(of: url))
        }
        return hits.sorted()
    }
}
