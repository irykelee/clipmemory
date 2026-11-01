import XCTest
@testable import ClipMemory

/// ID-REVIEW-1049 (2026-10-28): 两个独立核验员（1047 第二轮 + 1048）报出的
/// **存活变异**的处置 —— 「测试基础设施污染用户真实环境」这一族的**收尾轮**。
///
/// ## 这一轮收掉的 5 条存活变异
///
/// | 变异 | 形状 | 收口 |
/// |---|---|---|
/// | **M2** | 恢复向导的 **import** 调用点省掉 `defaults:` ⇒ 静默取 `.standard`（生产域） | 守卫 ⑷（**形状**扫描） |
/// | **M4** | 登录项的**读**闸门被删 ⇒ ⑱（纯函数 + 文件集合）与 ⑱b（**写**）都看不见 | 守卫 ⑶（**可注入读 seam**） |
/// | **M6** | `ImageStorage.init` 的测试进程早退被删 ⇒ §47.10 的「已闸门」失效 | 守卫 ⑸（**形状**：早退必须早于第一次写） |
/// | **M7** | `ClipboardStore.xcTestDefaults` 的**测试半边**被改成 `.standard` | 守卫 ⑴ + ⑵（**纯 resolver** ⇒ 两半都可断言） |
/// | **M8** | `ClipboardStore.xcTestDefaults` 的**生产半边**被改成隔离 suite | 守卫 ⑴（生产半边此前**不可达** ⇒ 改成纯函数才可断言） |
/// | **F2** | 备份入口的**默认参数** = 生产身份 ⇒「省略参数」＝ 静默取用户的域 | 守卫 ⑹ ⑹b ⑺ ⑺b（**改默认值本身** ⇒ 缺陷在源头消失） |
///
/// ## 为什么 M7/M8 要先改**生产代码**才谈得上守
///
/// `ClipboardStore.xcTestDefaults` 原先是一个 `if/else`：
///
/// ```swift
/// if !TestIsolation.isRunningTests { return .standard }
/// return UserDefaults(suiteName: "ClipboardStore-XCTest-isolation") ?? .standard
/// ```
///
/// ⇒ 在测试宿主里 `TestIsolation.isRunningTests` **恒为真** ⇒ **生产半边结构性地
/// 不可达** ⇒ **没有任何守卫能断言它** ⇒ M8（把生产半边改掉）**存活**。
/// ⇒ 修法与 ID-REVIEW-1045 / 1047 同形：把判定抽成**纯函数**
/// `ClipboardStore.defaultsFor(isTestProcess:)` ⇒ **两半**都变得可断言。
///
/// ⇒ ⇒ **元模式**：*一个守卫只能断言「它能在测试里到达」的东西 ⇒
/// **不可达的那一半，等于没有守卫**。⇒ 「某条路径没被覆盖」的第一个追问
/// 应该是「**那半边在这个进程里可达吗**」。*
final class Review1049RegressionTests: XCTestCase {

    // MARK: - ⑴⑵ ClipboardStore 的 seam 两半（M7 / M8）

    /// ⑴ **纯函数**守卫：`ClipboardStore.defaultsFor` 的**两半**。
    ///
    /// ⇒ 生产半边：必须**就是** `UserDefaults.standard`（生产零变化）。
    /// ⇒ 测试半边：必须**不是**生产域。
    func testTheClipboardStoreSeamHasBothHalves() {
        XCTAssertTrue(
            ClipboardStore.defaultsFor(isTestProcess: false) === UserDefaults.standard,
            "生产半边**必须**就是 `UserDefaults.standard`"
            + "（核验员 M8：它此前**不可达** ⇒ 没有任何守卫能钉住它）"
        )
        XCTAssertFalse(
            TestIsolation.addressesProductionDomain(
                ClipboardStore.defaultsFor(isTestProcess: true)
            ),
            "测试半边**不得**是生产域（核验员 M7）"
        )
    }

    /// ⑵ **行为**守卫：测试进程里 `ClipboardStore.shared` 绑的域**不得**是生产域。
    ///
    /// ⚠️ 守卫 ⑴ 断言的是**纯函数** ⇒ 纯函数被断言**不等于**实例真的用了它
    /// ⇒ 这里问实际实例。
    @MainActor
    func testTheSharedClipboardStoreIsNotBoundToTheProductionDomain() {
        XCTAssertFalse(
            TestIsolation.addressesProductionDomain(ClipboardStore.shared.defaults),
            "测试进程里的 `ClipboardStore.shared` **不得**绑到生产域"
            + "（恢复向导与导出路径都依赖这条 seam）"
        )
    }

    // MARK: - ⑶ 登录项的**读**闸门（M4）

    /// ⑶ **行为**守卫：测试进程里的登录项**读**不得触达系统。
    ///
    /// ⚠️ 核验员 M4：删掉 `isEnabled` 里的闸门 ⇒ **全部**守卫仍绿 ——
    /// ⑱ 只断言**纯函数** `shouldApply` + **文件集合**，⑱b 只覆盖**写** ⇒
    /// **读**是零覆盖的。
    /// ⇒ 修法：给读路径也一个**可注入的 status provider** ⇒ 守卫注入一个
    /// 记录闭包 ⇒ 断言「这个进程**从未**问过系统」
    /// —— 而**不用**去查用户的注册状态（那样就等于守卫自己破坏了它要守的闸门）。
    func testReadingTheLoginItemInATestProcessNeverReachesTheSystem() throws {
        var queried = false
        let enabled = LaunchAtLoginService.isEnabled {
            queried = true
            return .notFound
        }
        XCTAssertFalse(queried, "测试进程里的登录项**读**不得触达系统")
        XCTAssertFalse(enabled, "测试进程里必须报告「未启用」（不查询 ⇒ 确定性）")

        // ⚠️ The PRODUCTION half is **structurally unreachable** from a test
        // host: `TestIsolation.isRunningTests` is always true there ⇒
        // `shouldApply(isRunningTests: true)` ⇒ the gate is always closed.
        // ⇒ Asserting it *behaviourally* here is impossible — that is the
        // ID-REVIEW-1045 shape, and the reason every seam in this family
        // splits its decision into a **pure function**.
        // ⇒ The production half is pinned by the **pure** function
        // (`shouldApply(isRunningTests: false) == true`), which guard ⑱
        // already asserts; re-assert it here so this guard stands alone.
        XCTAssertTrue(
            LaunchAtLoginService.shouldApply(isRunningTests: false),
            "生产半边（纯函数）**必须**放行 —— 生产行为零变化"
            + "（它的**行为**半边在测试宿主里**结构上不可达** ⇒ 只能用纯函数钉）"
        )
    }

    // MARK: - ⑷ 导入 / 导出调用点必须显式传域（M2）

    /// ⑷ **形状**守卫：app 树里每个 `importPackage(` / `importFromLocalBackup(` /
    /// `exportPackage(` **调用**都必须显式传一个 `defaults:` 参数。
    ///
    /// ⚠️ 核验员 M2：恢复向导的 **import** 调用点省掉 `defaults:` ⇒ 静默取
    /// `BackupPackage.importPackage` 的默认值 `.standard` ⇒ **用户的真实域**
    /// —— 而守卫 ⑮ / ⑰ 只覆盖**导出**那一个调用点 ⇒ **零覆盖**。
    ///
    /// ⇒ 这里用**形状**判据（不是拼写）：扫描每个调用的**实参列表** ⇒
    /// 里面**必须**有 `defaults:`。⇒ 与参数名拼写无关（参数名就是契约本身）。
    func testEveryBackupPackageCallSitePassesItsDomainExplicitly() throws {
        let callees = ["importPackage", "importFromLocalBackup", "exportPackage"]
        var offenders: [String] = []
        for url in try TestSourceScanner.appSourceFiles() {
            let source = try String(contentsOf: url, encoding: .utf8)
            // ⚠️ ID-REVIEW-1049 (independent verifier P3-1): the scan runs on a
            // **BLANKED** copy (comments and string literals replaced by
            // spaces) ⇒ a doc comment that merely mentions `exportPackage(` is
            // not a call site. The verifier proved the false positive with a
            // comment-only patch (the guard went red on a file that had no
            // call site at all).
            let blanked = TestSourceScanner.blankingCommentsAndStrings(source)
            let relative = TestSourceScanner.appRelativePath(of: url)
            for callee in callees {
                for range in Self.callRanges(of: callee, in: blanked) {
                    // A **definition** is not a call site.
                    let lineStart = blanked[..<range.lowerBound].lastIndex(of: "\n")
                        .map { blanked.index(after: $0) } ?? blanked.startIndex
                    let prefix = blanked[lineStart..<range.lowerBound]
                    if prefix.contains("func ") { continue }
                    let arguments = String(blanked[range])
                    if arguments.contains("defaults:") { continue }
                    let line = blanked[..<range.lowerBound].filter { $0 == "\n" }.count + 1
                    offenders.append("\(relative):\(line) — `\(callee)(` 没有显式传 `defaults:`")
                }
            }
        }
        XCTAssertEqual(
            offenders, [],
            "每个备份包的导入/导出调用点**必须**显式传 `defaults:` —— "
            + "不传就会静默取默认的 `.standard` = 用户的真实域：\(offenders)"
        )
    }

    // MARK: - ⑸ ImageStorage 的测试进程早退（M6）

    /// ⑸ **形状**守卫：`ImageStorage.swift` 里**每一处**测试进程闸门都必须是
    /// 「裸早退」（`if Self.isRunningTests { return }`）。
    ///
    /// ⚠️ 核验员 M6：把那道早退删掉 ⇒ `ImageStorage` 在测试进程里会跑
    /// **legacy 迁移** ⇒ 它会把 `ImageStorageMigrationComplete` 写进**用户的
    /// 生产域** ⇒ 而用户的真实迁移会被**永久禁用**。
    ///
    /// ⚠️ **为什么这一条是静态守卫而不是行为守卫**：一个**行为**守卫要证明
    /// 「迁移没跑」，只能去**观察生产域** ⇒ 而一旦早退真的没了，观察本身**就是
    /// 那个伤害**（迁移会把标志写进用户的域）⇒ ⇒ *验证工具本身不能成为它要
    /// 消灭的那种伤害源* ⇒ 只能钉**形状**。
    ///
    /// ⚠️ 钉的是**每一处**（该文件里有两个闸门：`init` 与
    /// `cleanupOrphanedImages`）⇒ 只钉一处 ⇒ 另一处仍可被删。
    func testEveryImageStorageTestProcessGuardIsABareEarlyReturn() throws {
        let url = Self.repoRoot
            .appendingPathComponent("ClipMemory/Services/ImageStorage.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let blanked = TestSourceScanner.blankingCommentsAndStrings(source)

        // ⚠️ 扫描逻辑抽成 helper（ID-REVIEW-1049 第四轮）：守卫 ⑸ 加了**词边界**
        // 检查后函数体 52 行 ⇒ 超过 `function_body_length` 的 50 行 ⇒ ⇒
        // **拆**，不放宽（lint 棘轮：baseline 只压既有违规 ⇒ 新增违规会冒出来）。
        let (guardCount, offenders) = Self.scanImageStorageGuards(in: blanked)

        XCTAssertGreaterThan(
            guardCount, 0,
            "ID-REVIEW-1049: no test-process guard found in `ImageStorage.swift` "
            + "— the guard's anchor moved (independent verifier M6)"
        )
        // ⚠️ The **count** is a ratchet, and it is the half that actually
        // catches the mutation: "every guard that EXISTS is a bare early
        // return" is satisfied by **one** guard ⇒ deleting the `init()` guard
        // (the one that stops the legacy migration) leaves the other one
        // intact ⇒ the shape check stays green ⇒ the verifier's M6 **survived**
        // the first version of this guard.
        // ⇒ ⇒ *「每一处**存在**的闸门都要对」不等于「**该有的**闸门都在」*
        //   ⇒ 需要一个**数量棘轮**。
        XCTAssertEqual(
            guardCount, 2,
            "ID-REVIEW-1049: `ImageStorage.swift` must keep **exactly 2** "
            + "test-process guards (`init` + `cleanupOrphanedImages`) ⇒ "
            + "deleting the `init()` one would let the legacy migration run in "
            + "a test host and write `ImageStorageMigrationComplete` into the "
            + "user's production domain (independent verifier M6)"
        )
        XCTAssertEqual(
            offenders, [],
            "ID-REVIEW-1049: every test-process guard in `ImageStorage.swift` "
            + "must be a **bare early return** — otherwise the legacy migration "
            + "would run in a test host and write "
            + "`ImageStorageMigrationComplete` into the user's production domain"
        )
    }

    // MARK: - ⑹⑺ 备份包入口的默认域（F2 · P1）

    /// ⑹ **形状**守卫：app 树里**不得**再有「默认参数 = 生产身份」的
    /// `defaults:` 参数。
    ///
    /// ⚠️ 核验员 **F2 · P1**：守卫 ⑮ / ⑰ 盯的是**拼写**
    /// （`defaults: .standard`）⇒ 于是「**省掉这个参数**」这个形状**完全隐形**
    /// —— 而省掉参数 ⇒ 静默取默认值 ⇒ **用户的真实域**。
    /// 核验员实测：测试树里有 **38 处**调用省掉了 `defaults:`。
    ///
    /// ⇒ 修法不是「再加一条扫描器」，而是**改默认值本身**：
    /// `BackupPackage` 的 3 个入口现在默认解析到一个**进程安全**的 seam ⇒
    /// **省略参数不可能再到达用户的域** ⇒ 缺陷在**源头**消失。
    /// ⇒ 这一条钉的就是「源头确实换掉了」：**零**处 `defaults: UserDefaults
    /// = .standard`。
    ///
    /// ⚠️ **范围**：只扫 `BackupPackage.swift`，**不是**整棵 app 树 ——
    /// app 树里另外 **7 处** `= .standard`（`ImageStorage` 3 / `LanguageManager` 1 /
    /// `StorageBackend` 1 / `SQLiteStorageBackend` 1 / `TrashStore` 1）已由
    /// **台账 §47.10 逐条判定**为「已闸门 / 不可达」，并由**守卫 ⑲ 的逐文件
    /// 库存棘轮**盯着 ⇒ 把它们也塞进本守卫会把「已判定」变成「被禁止」，
    /// 反而让**下一次**「看 33 个」的真发现淹没在噪声里。
    func testNoBackupEntryPointDefaultsToTheProductionIdentity() throws {
        let url = Self.repoRoot
            .appendingPathComponent("ClipMemory/Services/BackupPackage.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let count = TestSourceScanner.occurrenceCount(
            of: "defaults: UserDefaults = .standard",
            in: TestSourceScanner.blankingCommentsAndStrings(source)
        )
        XCTAssertEqual(
            count, 0,
            "备份入口的 `defaults:` 默认参数**不得**是生产身份 `.standard` —— "
            + "省掉参数就会静默到达用户的真实域（核验员 F2）"
        )
    }

    /// ⑹b **数量棘轮**：`BackupPackage` 的 **3 个**入口（导出 / 导入包 /
    /// 导入本地备份）**每一个**都必须走 seam。
    ///
    /// ⚠️ ⑹ 只钉「没有 `.standard`」⇒ **一处**入口改回生产身份、另两处仍走
    /// seam ⇒ ⑹ 仍绿（`occurrenceCount` 是**按文件**的 ⇒ 但本条把总数钉成
    /// 3 ⇒ 少一处即红）。
    func testEveryBackupPackageEntryPointResolvesItsDomainThroughTheSeam() throws {
        let url = Self.repoRoot
            .appendingPathComponent("ClipMemory/Services/BackupPackage.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let seam = "defaults: UserDefaults = "
            + "BackupPackage.defaultsFor(isTestProcess: TestIsolation.isRunningTests)"
        let count = TestSourceScanner.occurrenceCount(
            of: seam,
            in: TestSourceScanner.blankingCommentsAndStrings(source)
        )
        XCTAssertEqual(
            count, 3,
            "ID-REVIEW-1049: `BackupPackage` 的 **3 个**入口"
            + "（`exportPackage` / `importPackage` / `importFromLocalBackup`）"
            + "**每一个**都必须把默认域解析到 seam —— 少一个，那个入口就会在"
            + "省略参数时静默绑到生产域（核验员 F2）"
        )
    }

    /// ⑺ **纯函数**守卫：`BackupPackage.defaultsFor` 的**两半**。
    ///
    /// ⇒ 生产半边：必须**就是** `UserDefaults.standard`（生产零变化）。
    /// ⇒ 测试半边：必须**不是**生产域 ⇒ **省略参数**的那个形状就落在隔离域上。
    func testTheBackupPackageSeamHasBothHalves() {
        XCTAssertTrue(
            BackupPackage.defaultsFor(isTestProcess: false) === UserDefaults.standard,
            "生产半边**必须**就是 `UserDefaults.standard`（生产零变化）"
        )
        XCTAssertFalse(
            TestIsolation.addressesProductionDomain(
                BackupPackage.defaultsFor(isTestProcess: true)
            ),
            "测试半边**不得**是生产域（核验员 F2：省略参数 ⇒ 静默取生产域）"
        )
    }

    /// ⑺b **单真相**守卫：app 侧的 suite 名字必须与测试侧登记的名字**一致**。
    ///
    /// ⚠️ ID-REVIEW-1034 的教训：两个副本一旦分叉，守卫就会**静默地**看着
    /// **错误的** suite 而通过。
    func testTheBackupPackageSuiteNameHasASingleSourceOfTruth() {
        XCTAssertEqual(
            BackupPackage.xcTestIsolationSuiteName,
            XCTestIsolationSuiteBootstrap.backupPackageSuiteName,
            "app 侧与测试侧登记的 suite 名字必须一致 —— "
            + "分叉 ⇒ 清理脚本与写守卫会看着**错误的** suite 而通过"
        )
    }

    // MARK: - ⑻ 域解析器的兜底（F6 的**全族**）

    /// ⑻ **形状**守卫：app 树里**不得**再有 `?? .standard` 这种
    /// 「解析不到就退回生产域」的兜底。
    ///
    /// ⚠️ **这条是「修一个，看 33 个」的产物**：独立核验员 F6 只点了
    /// `StartupHealth.defaultsFor` 一处 ⇒ 本轮修了 `BackupService` 与
    /// `StartupHealth` ⇒ **漏了 5 处**：
    /// `SafeModeService` / `ClipboardStore` / `FirstLaunchService` /
    /// `HotKeyManager` / `TestIsolation`（规范 seam 本身）。
    /// ⇒ 而 push 后的本地审核（`githooks/orca-auto-review.sh`）把它作为
    /// **P1** 报了出来 ⇒ **独立审核确实抓到了作者自己的漏改**。
    ///
    /// ⇒ 为什么它是**活路径**（不是理论问题）：在测试宿主里
    /// `UserDefaults.standard` **就是**用户的真实 `com.clipmemory.app` 域 ⇒
    /// 一旦 suite 名被拒（拼写错误 / 未来改名漏改），兜底会把**测试**静默
    /// 接到**生产域**上 ⇒ 而这正是本族的核心形状。
    ///
    /// ⇒ 判据用**形状**（`?? .standard`），并**抹白注释与字符串** ⇒
    /// 本守卫自己的说明文字不会命中自己。
    func testNoDomainResolverFallsBackToTheProductionDomain() throws {
        var offenders: [String] = []
        for url in try TestSourceScanner.appSourceFiles() {
            let source = try String(contentsOf: url, encoding: .utf8)
            let count = TestSourceScanner.occurrenceCount(
                of: "?? .standard",
                in: TestSourceScanner.blankingCommentsAndStrings(source)
            )
            guard count > 0 else { continue }
            offenders.append("\(TestSourceScanner.appRelativePath(of: url)) (\(count) 处)")
        }
        XCTAssertEqual(
            offenders, [],
            "域解析器**不得**用 `?? .standard` 兜底 —— 在测试宿主里 `.standard` "
            + "**就是**用户的真实域 ⇒ 兜底会把测试静默接到生产域上"
            + "（独立核验员 F6 的形状，本轮修掉全部 5 处）：\(offenders)"
        )
    }

    // MARK: - ⑳ `XCTSkip` 必须是 Swift 抛错形式（**宏 vs overlay**）

    /// ⑳ **形状**守卫：测试树里每一处 `XCTSkip(` 都必须写成 `throw XCTSkip(`。
    ///
    /// ⚠️ **为什么这条存在**（实测 2026-11-01，本轮自己踩到）：Swift 侧的
    /// `XCTSkip` 是 **overlay 的 `Error` 结构体**（`public struct XCTSkip:
    /// Swift::Error`，`init(_ message:file:line:)`）⇒ **`XCTSkip(…)` 只是构造
    /// 一个值，**不抛**任何东西 ⇒ 写成 `try XCTSkip(…)` 时那个值被丢掉 ⇒
    /// 「跳过」**根本没发生** ⇒ 测试继续跑并 **pass** ⇒ 「跳过」变成假绿。
    ///
    /// ⇒ 真正会跳过的只有三种写法：`throw XCTSkip(…)` /
    /// `try XCTSkipIf(…)` / `try XCTSkipUnless(…)`（后两个是 overlay 里
    /// 真正 `throws` 的函数）。⇒ 仓库里既有的 11 处都用 `throw XCTSkip(…)`。
    ///
    /// ⇒ 实测：写成 `try XCTSkip(…)` ⇒ 锁探针一开 ⇒ 三个 canary **既记了跳过
    /// 又继续执行** ⇒ 审计看到 `3 executed + 3 skipped` ⇒ 报红 ⇒ 而更糟的是
    /// **「跳过」根本没发生**。
    ///
    /// ⇒ 判据是**形状**（`XCTSkip(` 前面必须是 `throw`）⇒ 与参数无关；
    /// 扫描跑在**抹白**后的副本上 ⇒ 本守卫自己的说明文字不会命中自己。
    func testEveryXCTSkipIsAThrowNotTheObjectiveCMacro() throws {
        var offenders: [String] = []
        for url in try TestSourceScanner.testSourceFiles() {
            let source = try String(contentsOf: url, encoding: .utf8)
            let blanked = TestSourceScanner.blankingCommentsAndStrings(source)
            var index = blanked.startIndex
            while let found = blanked.range(of: "XCTSkip(", range: index..<blanked.endIndex) {
                index = found.upperBound
                let before = String(blanked[..<found.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if before.hasSuffix("throw") { continue }
                let line = blanked[..<found.lowerBound].filter { $0 == "\n" }.count + 1
                offenders.append(
                    "\(TestSourceScanner.relativePath(of: url)):\(line)"
                    + " — `XCTSkip(` 必须写成 `throw XCTSkip(`"
                )
            }
        }
        XCTAssertEqual(
            offenders, [],
            "每一处 `XCTSkip(` 都必须写成 `throw XCTSkip(` —— 裸 `XCTSkip` 命中的是 "
            + "**ObjC 宏** ⇒ 它抛的 NSException **不会**让 Swift 帧停下 ⇒ "
            + "「跳过」之后代码继续跑 ⇒ 测试 pass ⇒ 假绿：\(offenders)"
        )
    }

    // MARK: - ㉑ 树外闸门必须**存在**（独立核验员 P1-1）

    /// ㉑ **存在性 + 内容**守卫（仿守卫 ⑬）：树外闸门脚本必须存在，且必须保留
    /// 它赖以成立的那几件事。
    ///
    /// ⚠️ **为什么必须有这条**（独立核验员 P1-1，2026-11-01 实测）：把
    /// `Scripts/verify-production-canaries.py` + `.github/workflows/ci.yml` 里
    /// 调用它的那一步 + `Scripts/release.sh` 里的闸门块**一起删掉** ⇒
    /// 全量测试仍然 **1436 / 4 skipped / 0 failures / TEST SUCCEEDED**
    /// ⇒ CI 绿、发版绿、测试绿、**零告警** ⇒ ⇒ 第三轮的**唯一**新增机制可以
    /// 被无声移除 ⇒ ⇒ *「谁说自己做到了」搬到了树外，但**树外那把锁没人锁**。*
    func testTheOutOfBandCanaryGateScriptIsPresentAndKeepsItsEssentials() throws {
        let url = Self.repoRoot.appendingPathComponent("Scripts/verify-production-canaries.py")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "树外闸门脚本必须存在（`Scripts/verify-production-canaries.py`）"
            + "—— 它是「安全网关着而套件全绿」的唯一拦截者"
            + "（独立核验员 P1-1：连同它的两处接线一起删掉，套件仍然全绿）"
        )
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let source = try String(contentsOf: url, encoding: .utf8)
        for needle in [
            "PRODUCTION_CANARIES",
            "AUDIT_TEST",
            "testNoProductionPollution",
            "testProductionDataBlobsAreUnchanged",
            "testFirstLaunchFlagIsNeverChangedDuringTheSuite",
            "return 0",
            "return 1",
            "return 2"
        ] {
            XCTAssertTrue(
                source.contains(needle),
                "树外闸门脚本必须包含 \(needle)"
                + "（缺了它，闸门要么看不见 canary、要么分不清「网关着」与「闸门坏了」）"
            )
        }
    }

    // MARK: - ㉒ 树外闸门必须**接在线上**（独立核验员 P1-1）

    /// ㉒ **接线**守卫：树外闸门必须仍然被 **CI** 与 **发版 preflight** 调用，
    /// 且 **CI** 必须仍然区分「退出码 2 = 闸门自己坏了」。
    ///
    /// ⚠️ **为什么接线也要钉**：「脚本存在」不等于「脚本在跑」⇒ 删掉
    /// `ci.yml` 里那一步，脚本还在，但**永远不会执行** ⇒ 与删除脚本等价。
    ///
    /// ⚠️ **这条守卫自己的极限**（如实记录）：守卫、脚本、`ci.yml` 三者都在
    /// 仓库里 ⇒ **协同删除**仍然能让一切变绿 —— 这是「仓库内没有仓库外」的
    /// 结构性上限，不是本守卫能消掉的。⇒ 提高**协同成本**（三处、三种文件）
    /// 是这里能做到的全部；真正的下一层是**发布产物**里带一份自述。
    func testTheOutOfBandCanaryGateIsStillWiredIntoCIAndRelease() throws {
        let ci = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(".github/workflows/ci.yml"),
            encoding: .utf8
        )
        let release = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Scripts/release.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(
            ci.contains("Scripts/verify-production-canaries.py"),
            "CI 必须仍然调用树外闸门 —— 否则「安全网关着而套件全绿」在 CI 上无人拦截"
        )
        // CI 必须把「闸门坏了」与「安全网关着」**分开处理** ——
        // 两种合法写法：显式判 2（`== "2"`），或「除 0/1 外一律闸门坏了」
        // （`!= "0"`，ID-REVIEW-1049 第四轮 · 独立核验员 P3-3）。
        XCTAssertTrue(
            ci.contains("\"$code\" != \"0\"") || ci.contains("\"$code\" == \"2\""),
            "CI 必须仍然区分「闸门自己坏了」与「安全网关着」"
            + "—— 否则闸门坏了会被读成安全网关着 ⇒ 排查方向会被带偏"
        )
        XCTAssertTrue(
            release.contains("Scripts/verify-production-canaries.py"),
            "发版 preflight 必须仍然调用树外闸门 —— 否则发版放行时不再核对安全网"
        )
        XCTAssertTrue(
            release.contains("canary_gate"),
            "发版 preflight 必须仍然按三态处理退出码（0 开 / 1 关 / 2 闸门坏了）"
        )
        // 契约脚本本身也必须还在、且被 CI 调用 —— 否则「脚本的中和」无人发现。
        let contract = Self.repoRoot
            .appendingPathComponent("Scripts/test/test_verify_production_canaries.sh")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: contract.path),
            "闸门契约测试脚本必须存在（`Scripts/test/test_verify_production_canaries.sh`）"
            + "—— 它断言退出码 0/1/2 三态 ⇒ 脚本被改成「永远 exit 0」时它会变红"
        )
        if FileManager.default.fileExists(atPath: contract.path) {
            XCTAssertTrue(
                ci.contains("test_verify_production_canaries.sh"),
                "CI 必须调用闸门契约测试 —— 否则契约脚本永远不跑"
            )
            // ⚠️ ID-REVIEW-1049 第六轮（独立核验员 P1-1 / P3-5）：清单**自身**的
            //   完整性检查必须**单独**占一个 CI step ⇒ 否则「清单被掏空 ⇒ 契约
            //   脚本逐条通过（0 条 = 0 个问题）⇒ exit 0」这件事**在 CI 上不会被
            //   发现** ⇒ 而第五轮的新机制**寄生**在第四轮的 step 里 ⇒ 失败也
            //   归不了因。
            XCTAssertTrue(
                ci.contains("test_verify_production_canaries.sh --manifest"),
                "CI 必须单独跑清单完整性检查（`--manifest`）"
                + "—— 否则清单被掏空时 CI 无感（独立核验员 P1-1）"
            )
        }
    }

    // MARK: - ㉓ canary 必须**仍在做比较**（独立核验员 P2-1 / V6）

    /// ㉓ **接线钉**：三个生产 canary 必须仍然调用各自的**纯比较函数**。
    ///
    /// ⚠️ **这条修的是什么**（独立核验员 V6，2026-11-01 实测）：把
    /// `testNoProductionPollution` 的**比较体**整段删掉（只留
    /// `recordExecution()` 记账）⇒ canary 报 **passed**、树内审计报
    /// **passed**、树外闸门报「**安全网是开着的**」⇒ ⇒ **两层同时失明**。
    ///
    /// ⇒ ⇒ 根因：**判定逻辑只存在于 canary 的函数体里** ⇒ 它**不可直接断言**
    /// ⇒ ⇒ 修法（与 `firstLaunchFlagDrift` 同形）：把判定抽成**纯函数**
    /// ⇒ ① 正对照能直接证明它**还有牙**（守卫 ㉓b）；
    /// ② canary 不再调用它时，**本条接线钉**变红。
    func testEveryProductionCanaryStillCallsItsPureComparison() throws {
        let url = Self.repoRoot
            .appendingPathComponent("Tests/ClipMemoryTests/ZZZSuiteTeardownTests.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let blanked = TestSourceScanner.blankingCommentsAndStrings(source)
        let wiring: [(canary: String, helper: String)] = [
            ("testNoProductionPollution", "Self.newProductionPollution("),
            ("testProductionDataBlobsAreUnchanged", "Self.rewrittenProductionBlobs("),
            ("testFirstLaunchFlagIsNeverChangedDuringTheSuite", "Self.firstLaunchFlagDrift(")
        ]
        var offenders: [String] = []
        for (canary, helper) in wiring {
            guard let body = Self.memberBody(of: canary, in: blanked) else {
                offenders.append("\(canary) —— 找不到它的函数体")
                continue
            }
            if !body.contains(helper) {
                offenders.append("\(canary) 不再调用 \(helper) ⇒ 它的比较体可能已被掏空")
            }
            if !body.contains("XCTFail") {
                offenders.append("\(canary) 不再调用 XCTFail ⇒ 真有污染时它不会报红")
            }
        }
        XCTAssertEqual(
            offenders, [],
            "每个生产 canary 必须仍然调用它的纯比较函数并仍然会报红 —— "
            + "「掏空比较体」会让 canary / 树内审计 / 树外闸门**三层同时失明**"
            + "（独立核验员 V6）：\(offenders)"
        )
    }

    /// ㉓b **正对照**：三个纯比较函数必须**还有牙**（能真的报出污染）。
    ///
    /// ⚠️ 正对照必须**直接调用**那三个函数（不是**重实现**一遍逻辑）——
    /// 重实现的那份永远不会坏 ⇒ 它证明不了真身在坏（核验员 V6 的原话）。
    func testThePureProductionComparisonsStillHaveTeeth() throws {
        // 新增键 ⇒ 报出
        let added = ZZZSuiteTeardownTests.newProductionPollution(
            before: [:],
            after: ["zzz-review1049-new": "v"]
        )
        XCTAssertEqual(
            added.count, 1,
            "新增的生产域键必须被报成污染（`newProductionPollution` 没牙了）"
        )
        XCTAssertTrue(
            added.first?.contains("zzz-review1049-new") == true,
            "报出的污染必须点名那个键：\(added)"
        )
        // 删除键 ⇒ 报出（删除比新增更严重）
        let removals = ZZZSuiteTeardownTests.newProductionPollution(
            before: ["zzz-review1049-gone": "v"],
            after: [:]
        )
        XCTAssertEqual(
            removals.count, 1,
            "被删除的生产域键必须被报出（丢用户的值比污染更严重）"
        )
        // 两边一样 ⇒ 没有污染
        XCTAssertEqual(
            ZZZSuiteTeardownTests.newProductionPollution(
                before: ["zzz-review1049-same": "v"],
                after: ["zzz-review1049-same": "v"]
            ),
            [],
            "前后一致的快照**不得**报出污染"
        )
        // blob 字节变化 ⇒ 报出；字节相同 ⇒ 不报
        guard let key = TestIsolation.productionDataKeys.min() else {
            throw XCTSkip("生产数据键集合为空 ⇒ 无法构造 blob 正对照")
        }
        let blobBefore: [String: Any] = [key: Data([0x01, 0x02])]
        let blobAfter: [String: Any] = [key: Data([0x01, 0x03])]
        XCTAssertEqual(
            ZZZSuiteTeardownTests.rewrittenProductionBlobs(
                before: blobBefore,
                after: blobAfter
            ),
            [key],
            "生产数据 blob 的**字节**变了就必须被报出"
        )
        XCTAssertEqual(
            ZZZSuiteTeardownTests.rewrittenProductionBlobs(
                before: blobBefore,
                after: blobBefore
            ),
            [],
            "字节没变的 blob 不得被报出"
        )
    }

    // MARK: - Helpers

    /// The test-process guards in `ImageStorage.swift`: how many there are and
    /// which of them are malformed.
    ///
    /// ⚠️ ID-REVIEW-1049 第四轮（独立核验员 P2-3）：判据里加了**词边界** ——
    /// 原本是**子串**匹配 `if Self.isRunningTests` ⇒ 把谓词改名成
    /// `if Self.isRunningTestsDisabled {` 仍然命中 ⇒ 计数不变、形状不变 ⇒
    /// **守卫全绿** ⇒ 而真闸门已经失效。
    private static func scanImageStorageGuards(
        in blanked: String
    ) -> (count: Int, offenders: [String]) {
        var count = 0
        var offenders: [String] = []
        var searchStart = blanked.startIndex
        while let found = blanked.range(
            of: "if Self.isRunningTests",
            range: searchStart..<blanked.endIndex
        ) {
            count += 1
            searchStart = found.upperBound
            // The match must END the predicate — a word boundary.
            let afterMatch = blanked[found.upperBound...]
            if let next = afterMatch.first,
               next.isLetter || next.isNumber || next == "_" {
                offenders.append(
                    "a test-process guard whose predicate was RENAMED "
                    + "(`...isRunningTests` 后面紧跟标识符字符 ⇒ 它不是那个闸门了)"
                )
                continue
            }
            let after = String(blanked[found.upperBound...])
            guard let returnRange = after.range(of: "return") else {
                offenders.append("a test-process guard with NO `return`")
                continue
            }
            // The `return` must be the guard's OWN first statement — i.e. the
            // guard body is a bare early return, not a conditional inside a
            // longer block.
            let between = String(after[..<returnRange.lowerBound])
            if between.contains("if ") || between.contains("else") {
                offenders.append("a test-process guard whose `return` is not the first statement")
            }
        }
        return (count, offenders)
    }

    /// The body of the member function `name` inside `blanked` (a source
    /// whose comments and string literals have been replaced by spaces).
    ///
    /// ⚠️ Brace matching is safe on the BLANKED copy: string literals and
    /// comments are blanked ⇒ no stray `{` / `}` can appear inside them.
    private static func memberBody(of name: String, in blanked: String) -> String? {
        guard let signature = blanked.range(of: "func \(name)(") else { return nil }
        guard let open = blanked.range(of: "{", range: signature.upperBound..<blanked.endIndex) else {
            return nil
        }
        var depth = 0
        var index = open.lowerBound
        while index < blanked.endIndex {
            let character = blanked[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(blanked[signature.upperBound..<index])
                }
            }
            index = blanked.index(after: index)
        }
        return nil
    }

    /// Repository root, computed from this file's own location.
    private static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ClipMemoryTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
            .resolvingSymlinksInPath()
    }()

    /// The ranges of every **balanced** call to `callee` in `source`.
    private static func callRanges(of callee: String, in source: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var searchStart = source.startIndex
        while let found = source.range(of: "\(callee)(", range: searchStart..<source.endIndex) {
            searchStart = found.upperBound
            let open = source.index(before: found.upperBound)
            var depth = 0
            var index = open
            while index < source.endIndex {
                let character = source[index]
                if character == "(" { depth += 1 }
                if character == ")" {
                    depth -= 1
                    if depth == 0 {
                        ranges.append(open..<source.index(after: index))
                        break
                    }
                }
                index = source.index(after: index)
            }
        }
        return ranges
    }
}
