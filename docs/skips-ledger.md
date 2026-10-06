# Skipped Test 台账（ID-CRASH-0038）

- **建立**：2026-09-30（`803393b`，v2.9.5，ID-CRASH-0038 mass-skip 共 46 处 / 46 个测试）
- **2026-10-01 → 2026-10-02 多次修订**：逐步恢复测试，**46 → 21 skip、1025/21/0 GREEN**
- **2026-10-03 (post-#93-closed)**：**21 → 4 skip、1025/4/0 GREEN（en + zh-Hans 双 locale）**——本批 ID-CRASH-0060/0061/0062/0063 撤 4 处（HotKey 3 处条件 guard、MemoryWarning 1 处 skip 移除、WindowManager 1 处 skip 移除）
- **2026-10-03 v2.9.6 完稿后**：CI run 37111093369 实证 `cc5f2c3` 在 build-and-test job 上**失败**：4 处 snapshot test（`ClipboardItemRowSnapshotTests` × 2 + `WelcomeViewSnapshotTests` × 1 + `SettingsTabSnapshotTests` × 1）在 CI runner 上**仍 golden 失配**。本地 1025/0/0 真绿，但 CI runner env 触发了 ledger 的「golden 失配机制未定位」假设。**Revert**（`1743657`）`3846122`（snapshot re-enable）以恢复 CI 绿；snapshot 调研记入 v2.9.7 backlog（详见 ledger「未 ship」段）。
- **详细 commit 序列**：见 `git log --oneline 803393b..HEAD -- docs/skips-ledger.md`（22 次修订）
- **根因追踪**：issue #93（ID-CRASH-0037，GH Actions runner 环境调查）+ ID-CRASH-0038（**主因已修复**）
- **恢复目标**：v2.9.6（接近完成）
- **计数口径**：4 处语句 / 4 个测试（2026-10-03 实测，本地 1025 / 4 skipped / 0 failures；测试总数以 `Scripts/test-count.sh` 为准，ID-TEST-0002）

## 背景

GH Actions macOS runner 环境（macOS 27 / 新 Xcode 镜像）下，下列测试会因环境差异失败，甚至直接杀死测试宿主进程（`Restarting after unexpected exit, crash, or test timeout`）。本地 `xcodebuild test` 全绿。

**2026-10-01 重大发现**（`b07e5a5`）：实测 ID-REVIEW-1009（test key path redirect）后，**28 个 skip 测试本地能 pass**——crypto-path pollution 之前是 local-host 的主 flake 机制，不是 ID-CRASH-0038 假设的 CI runner env。本地 1024 tests / 18 skipped / 0 failures。但 CI 端仍可能因 runner 镜像漂移失败，所以这 18 个剩余 skip 必须等到 CI 实测确认才能正式删台账。

⚠️ xcodebuild 的 `Executed N tests` 把 skipped 计入总数，因此 ci.yml 的最小计数门（ID-CRASH-0014 blind-spot-6）对 mass-skip 不敏感——**本台账是 skip 的唯一强制记录**。恢复任何条目时，必须同时删除对应 `XCTSkip` 语句并删除本表行；全部恢复后删除本文件并在 release notes 记录。

## 台账（2026-10-02 snapshot re-skip 后，21 处 / 21 个测试）

| # | 测试文件 | XCTSkip 处 | 备注 |
|---|---|---|---|
| 1 | IntegrationTests.swift | 9 | restart-recovery / backend 等核心集成路径 |
| 2 | WindowManagerTests.swift | 1 | 仅保留 `testUnregisteringClosedSecondaryAllowsAccessorySink`（其他 4 已恢复） |
| 3 | MemoryWarningTests.swift | 1 | 仅保留 `testFlushAllClearsCaches`（其他 3 已恢复） |
| 4 | HotKeyRetainFailurePathTests.swift | 3 | 热键保留环：测试前提（"registration MUST fail"）在 CI 干净 macOS 上不成立，需要重构测试本身 |
| 5 | AppDelegateShouldTerminateTests.swift | 3 | terminate 路径。**CI 崩溃机制已确认并已修复（ID-CRASH-0057，见下方勘误）**：真因是 `ClipboardStore.shared` 的 dispatch_once 临界区内 pump RunLoop 重入 XCTest（tearDown 首触 `.shared` 同样致命；"类级 setUpWithError XCTSkip 必杀"是误归因——它只是共现现象）。skip 暂留至 CI 实测确认修复生效后再评估恢复；恢复时仍遵守 skip 置于测试体首行、tearDown 避免首触单例的保守模式 |
| 6 | ClipboardItemRowSnapshotTests.swift | 2 | snapshot golden 不匹配（store .shared 调查 + 漂移并存），2026-10-02 CI run 36978148927 后重新 skip，见下方新段 |
| 7 | WelcomeViewSnapshotTests.swift | 1 | 同上 |
| 8 | SettingsTabSnapshotTests.swift | 1 | tab 归因排除（渲染对 key 不变）；CI 失配机制未定位（双假设并存，见诊断条）；恢复前置=机制定位（CI actual.png 产物核查 / 探针重录——重录 gated on record path，见工具守卫条） |
| | **合计** | **21** | **本地 1025 / 21 skipped / 0 failures**（2026-10-02） |

## ✅ ZZZ canary re-enabled（ID-REVIEW-1013 → 2026-10-02 收紧）

ZZZ canary 不再 skip。ID-REVIEW-1013 曾临时把 `toleratedPollution` 扩到 11 条（7 个 test-side key）；auto-review-20261002-083606 FAIL 指出其中 **4 条在仓库 grep 不到任何 writer**（`safeMode.active` / `safeMode.crashCount` / `excludedBundleIds` / `WindowFrame`——最后一条还解除了 `appLifecycleKeys` 段落里明言的 WindowFrame regression tripwire），其余 3 条引用行号有误、且 `HotKeyManagerTests` 本就有类级 absence-aware setUp/tearDown 自清理、`TestHostIsolationTests` 为行内即时恢复。ID-REVIEW-1009/1010/1011/1012 + 2026-10-02 A/B rework（ClipboardStore `static let shared` revert、HotKeyManager.xcTestDefaults 恢复 isolated suite）落地后，**7 条 test-side 条目全部删除**，allowlist 回到 2026-08-06 校准的 4 条 framework keys（`AppleLanguages` + Sparkle `SU*`×3），全量 1025/17/0 GREEN（`testNoProductionPollution` 零 test-side 条目实证通过）。

**Production code 完全干净**（`grep -rn 'UserDefaults\.standard\.set' ClipMemory/` → 0 处实际代码调用，1 处为 ClipboardStore.swift 内注释）；canary 检出的污染全部来自测试 helper 自身写 `.standard` 没 cleanup。架构意图（让 production 代码用注入 defaults）在 ID-REVIEW-1009/1010/1011/1012 都 ship 了。

**2026-10-02 勘误（auto-review-20261002-083606 FAIL，ID-REVIEW-1012 rework）**：xcTestDefaults env-var 检测**可靠**——`XCTestConfigurationFilePath` 即使被设为空字符串，`== nil` 仍返回 false（`Optional("") == nil` 恒为 false），XCTest 分支正确路由到 isolated suite。2009a5e 的 "static let eager module-load" 根因叙事有误（Swift `static let` 本来就是 lazy `swift_once` 首触初始化，不存在 module-load 抢跑窗口），其引入的 `MainActor.assumeIsolated` trap（后台线程访问即 fatalError）+ 无锁 dead setter 已 revert 回 `static let shared`（known-good，行为与生产路径均不变），并由 `TestHostIsolationTests.testSharedSingletonRoutesToIsolatedDefaultsUnderXCTest` 钉住契约。HotKeyManager 的 xcTestDefaults 已于同日恢复 isolated suite（ID-REVIEW-1010 原始实现，d659a0b），`HotKeyManager-XCTest-isolation` suite 纳入 AAA bootstrap 每-test 清理（`XCTestIsolationSuiteObserver`），H.3.1 tautology 测试改为 UUID suite 真断言。

## ID-CRASH-0057（2026-10-02）：issue #93 宿主连环崩根因勘误 + 修复

**真因**（16 份 .ips + 代码双证，CI run 36954420379）：`ClipboardStore.init` 的 XCTest-only auto-wait（`waitForFirstLoadSync(timeout: 15)`，ID-CRASH-0049 加入）在 `ClipboardStore.shared` 的 **dispatch_once 临界区内** pump `RunLoop.main` 等 background first-load。pump 重入 XCTest 的 `RunTestsFromRunLoop`，字母序首个触碰 `.shared` 的测试（`ClipboardItemRowOCRTransitionTests`，经 `ClipboardItemRow.swift` 默认参数 `store: ClipboardStore = .shared`）在同线程对同一 once 重入加锁 → libdispatch `trying to lock recursively` → SIGTRAP。宿主每次重启 ~1s 即死、同因连环崩；本地绿是因为竞态下 background load 通常在 pump 派发出首个测试前已完成。

**误归因勘误**：此前 ledger 记录的 "类级 `setUpWithError` XCTSkip 在 @MainActor 类上必杀宿主" 与 " AppDelegateShouldTerminateTests 特有机制" 均为共现现象，不是因果——任何在主线程首触 `.shared` 的路径（tearDown、任意测试体）都触发同一 once 重入。

**修复**：SyncBarrier 移出 init（`loadItemsInBackgroundAsync()` 后 init 直接返回，生产/测试行为一致化）；`waitForFirstLoadSync`/`waitForFirstLoad` 保留为显式原语（AppDelegate boot 路径 `await waitForFirstLoad()`、`flushPendingSaves` terminate 门、测试显式等待——本修复累计 **23 处**（rework 1/2 新增 18 处：TagTests ×3 + IntegrationTests ×10（含 2 处 XCTSkip'd 站点防 re-enable 复崩）+ ClipboardStoreTrashTests ×2 + ContentViewTrimAlertTests ×1 + ContentHashKeyReadyBackfillTests setUp ×1 + DecryptionFailedLoopTests setUp ×1；rework 3 补 5 处（auto-review-20261002-124153 P2，把不变量落到全仓）：OCRTests setUp ×1 + ClipboardStoreSaveFailureTests setUp ×1 + ClipboardCaptureLimitTests ×3；ClipboardStoreTests 另有 3 处 P2-14 原有调用不计入）。首轮排查漏了 `testTogglePinUpdatesAndPersists`（`store2.items[0]` 空数组下标 → SIGTRAP 宿主崩 → 重启进程不重跑 AAA → isolation observer 失效 → QuickBar 读到脏 suite 的 maxItems=3 + ZZZ 7 keys 连锁假阳性；本地全量 2026-10-02 11:02/11:17 两次复现后补齐）。**规则**（两次审核迭代后收敛的正确不变量）：只要测试会**构造后**触碰 store 内存态（读 items、断言 flag/hash、直接赋值 `store.items`），就必须先 `waitForFirstLoadSync`——backend 构造时是否为空**无关紧要**，因为 background load 是**后读** backend：构造后 `backend.save(...)` 的快照会被异步 load 读到，`applyLoadResult` 按 id 用 backend 原始副本替换内存态（auto-review-20261002-114457 P1：预置 backend + 显式 `loadItems()`；auto-review-20261002-120112 P1：空 backend + 构造后 save，`DecryptionFailedLoopTests` 同类；auto-review-20261002-124153 P1：同机制在 `ContentViewTrimAlertTests` 以 defaults-suite 形态复现——`maxItems` didSet 写进共享 isolation suite，setUp/tearDown 只 save/restore `.standard`（no-op），suite 内前测 `maxItems=2` 泄漏 → 下测 `makeStore(4)` 截到 2 条 → `items[3]` 越界宿主崩（本地隔离确定性复现；CI run #3 全绿因 view 渲染类 skip 未暴露）。修法：per-test `makeTestDefaults()` 隔离（与 Audit20260720RegressionTests C-1 同模式），废弃 `.standard` save/restore）。barrier 与 crypto 注入顺序已归一为 crypto → construct → barrier（DecryptionFailedLoopTests 调整，124153 P2）。已记录的开放向量（P2 参考性）：① post-load sweep（`cleanupOrphanedImages` / `runImageIntegrityScan` / `startMigrationIfNeeded`）随异步 load 可落到后续测试期间，对共享 `Images-Tests` 目录是新的跨测试干扰面；② `flushPendingSaves` 入口的 `dispatchPrecondition(.onQueue(.main))` 在 release 是无条件 trap（pre-existing，本修复扩大了到达面）；③ IntegrationTests.swift 行数增长本身**不会** re-surface file_length 基线告警（baseline 不编码违规计数、`file_length` 报告在行 1——swiftlint 实测 exit 0）；真正的 re-surface 触发是 `.swiftlint-baseline` 存的绝对 `file:///Users/...` 路径在 CI checkout root 下全量失配（124153 P2 勘误；warning-only，接受）；④ barrier 等待用 `XCTAssertTrue`（非 guard/XCTUnwrap）——超时不中止 setUp，表现为后续断言失败而非 setUp 清晰报错；与全部既有站点一致（124153 P2 确认 "not a style deviation"），保留；⑤ 共享 `ClipboardStore-XCTest-isolation` suite 的**磁盘脏值**在 `-only-testing` 子集（不含 AAA → `XCTestIsolationSuiteObserver` 未注册）无人清理：裸用 `ClipboardStore(backend:)`（defaults 缺省路由共享 suite）的测试，init 会读到早前运行持久化的 `maxClipboardItems`（实证：13:06 修复前 TrimAlert 运行写入 `= 1`，`defaults read` 确认；`ContentHashKeyReadyBackfillTests` 的 merge 尾部 `trimToMaxItems()` 裁 2→1 → :163 断言失败 + :171/:172 越界宿主崩，任何不含 AAA 的子集确定性复现，CI 全量因 AAA 在场不受影响）。修法：`ContentHashKeyReadyBackfillTests` + `ClipboardCaptureLimitTests` 改 per-test `makeTestDefaults()`（与 TrimAlert/SaveFailure/Audit 同模式），对共享 suite 磁盘状态免疫。附带坑：宿主崩后 xcodebuild 崩溃恢复的重跑列表可能为空（`Executed 0 tests` 且 suite 报 passed）——"重跑变绿"是 0-test 假绿，勿据此排除确定性失败。

**遗留**：skip 不随本修复自动恢复；CI 全量实测已于 2026-10-02（run 36978148927）确认宿主 0 重启，AppDelegateShouldTerminateTests 3 处可进入恢复评估（下轮），snapshot 4 处因渲染漂移回到台账。

## 已恢复（25 个测试，截至 2026-10-02 snapshot re-skip 后）

| 文件 | 恢复数 | 备注 |
|---|---|---|
| WindowManagerTests | 4 | 4 个 close cycle 测试 |
| SettingsWindowTests | 4 | 4 个窗口 lifecycle 测试 |
| ClipboardItemRowTests | 7 | 3 equatable + 4 parseRTF |
| ClipboardItemRowOCRTransitionTests | 1 | OCR 过渡 |
| QuickBarViewTests | 1 | QuickBar 前缀 |
| MemoryWarningTests | 3 | 3 个 memory 通知测试（保留 1 个） |
| ContentViewTrimAlertTests | 4 | 4 个 trim 测试 |
| ZZZSuiteTeardownTests | 1 | **防污染 canary 通过**（allowlist 已收紧回 4 条 framework keys） |
| **合计** | **25** | ID-REVIEW-1009..1013 共同 unblock ZZZ canary |

（勘误：上表原含 ClipboardItemRowSnapshotTests ×2 / WelcomeViewSnapshotTests ×1 / SettingsTabSnapshotTests ×1 共 4 行——本地恢复后 CI run 36978148927 实证 golden 不匹配仍失败，2026-10-02 重新 skip 并移回台账 #6-#8，见下方新段。）

## ID-CRASH-0057 CI 实测（2026-10-02，run 36978148927）+ snapshot golden 不匹配 re-skip

**宿主崩溃修复实证**：f0487ea push 后 CI 全量 `Executed 1025 tests, with 17 tests skipped and 4 failures` 单宿主 66.5s 跑完，`Restarting after unexpected exit` **0 次**（修复前 run 36954420379 每次 ~1s 连环崩）——issue #93 主因（ID-CRASH-0057 once 重入）修复实证关闭；issue 本体待 CI 全绿后关闭（该 run 尚有 4 snapshot 失败未达全绿，对账标准与恢复清单 #1 统一）。AAA / AppDelegateShouldTerminate / ClipboardCaptureLimit / TrimAlert 等本批次修复相关套件全绿。

**snapshot golden 不匹配（4 失败：`testSettingsRootViewGeneralTab` tab 归因排除、CI 失配位置未证实、CI 失配机制未定位（双假设并存，见诊断条）；ClipboardItemRow/WelcomeView 3/4 调查仍开放，见下方实验）**：`ClipboardItemRowSnapshotTests` 2/2、`WelcomeViewSnapshotTests` 1/1、`SettingsTabSnapshotTests.testSettingsRootViewGeneralTab`（套件 5 选 1）。处置（user 2026-10-02 确认）：重新 skip（台账 #6-#8）。

- **根因假设演进（auto-review-161942 P1-1 勘误）**：cbc400a 曾记「runner 渲染漂移」并以 "`TrashItemRowSnapshotTests` 通过" 作选择性失败对照——**该对照错误**：TrashItemRowSnapshotTests **0 个活跃测试**（唯一方法 `xtestRendersImageInitialState_DISABLED_FOR_CHECKBOX_LAYOUT_CHANGE` 2026-08-10 停用、golden 从未入库），推断失去对照。cbc400a 的 commit message 与测试注释同错，c809277/b62ef5c 已更正。
- **tab 归因排除 + 像素事实（164609 P1 证伪；173240/184342/190433/202924 四轮独立解码逐步修正）**：164609 P1 主张「golden 误录 Update tab」——本地实验排除（隔离 key 后对既有 golden 两次 byte-compare PASS，含宿主域写入 `history`）→ **渲染对 `settings.selectedTab` 不变，key 不可能解释 CI 失配**。像素事实（几何）：root golden（680×560）rows 0-11 = `.padding(.top, 12)`、rows 12-35 = 24pt 内容带——**slot 已钉位但组件身份未证实**（530×24 居中、硬边无渐变；均匀 (255,204,0,255) 填充 + 仅 1 个字形簇 bbox x329-350 / y13-34（22×22、246 抗锯齿像素，性质未判）——与 4 段 Picker 应有的 4 标签 + 分隔符不符；横向也不符：源码 `.padding(.horizontal, 16)` 给 648pt 可用宽、实测带 530 两侧各 75 → 不得作为「非 Form 元素正确渲染」的证据）、rows 36-43 = `.padding(.bottom, 8)`、row 44 = `Divider()` 全宽发丝线（alpha 25；12+24+8+1=45 精确钉位）、rows 45-559 = 不透明白（rows 0-11 / 36-43 为透明 (0,0,0,0)——三段均无可见内容，不写「唯一空白区」）；全图 20 个 RGBA 值、13,400 可见非白像素。**归因勘误**：「ClipMemory 品牌黄块」解读撤回——`#FFCC00` 字面量全仓 `.swift/.yml/.json` 零命中，`SettingsRootView` git 历史从无 brand/logo/Color 元素；**颜色来源是「未排查」而非「未定位」**（202924 P2）：系统色本不以字面量出现，(255,204,0) 恰为 SwiftUI `Color.yellow` 浅色 Appearance 值候选，`Assets.xcassets` / `Color(red:green:blue:)` / accent 路径均在既有 grep 范围外——勿因字面量零命中关闭低成本探针（accent / selected-segment 填充 / 探针重录——重录 gated on record path，见工具守卫条）；「渐变边缘」不存在（实测 fringe=0）。**数字勘误**：「115,200 字节 / 28,800 px」是**跨尺寸比较**（root 680×560 vs sibling 640×480/520/560/400），而 `assertImageSnapshot` 只各自对自己的 golden 比较——该数字**不是存在的量**，与「0/921,600」「11,520」一并归档为无效/错误测量。**结论**：① tab 归因排除（成立）；② **CI 失配位置未证实**——仓内无 `<test>.actual.png` 产物核查记录，不得断言失配在 rows 0-44（此前「standing=runner 对品牌带失配」为无据断言）；③ 4 个 sibling golden 100% 纯白（各自视图只有 1 个 `Form {`）；④ root golden 自录制（`7c7d442`，2026-09-22，单 commit）以来 byte-stable。
- **诊断状态（202924 重写；取代 190433 的「ImageRenderer 不栅格化 Form/NSSegmentedControl」结案式诊断）**：诚实版本是**双假设并存，均未被证据钉死**。事实：① 4 个 sibling golden 100% 纯白（各视图仅 1 个 `Form {`）；② root 的空白区恰为 Form 子树；③ root 内容带是**退化渲染**（均匀填充 + 1 个字形簇，非 4 标签 + 分隔符）。推论勘误：③ 意味着「部分内容」在场 → **settle/capture-too-early 假设未被排除**（190433 一边用「非 Form 元素精确渲染」证明无 settle 竞态、一边把唯一被栅格化的内容带记为 NSSegmentedControl 不栅格化，自相矛盾且 ③ 直接拆掉前提）；① + ② 支持「ImageRenderer 对 AppKit-backed `Form` 栅格化缺失」假设但**未证实**。**关键开放事实**：本地多次运行 byte-match 且 golden 自 `7c7d442` byte-stable → 任何环境无关的渲染属性（无论 Form 空白还是 settle）都**不能解释 CI-only 失配**——CI 失败机制仍未定位。**处方撤回**：190433 的「settle-修法已否证勿照做」与「恢复前置=解决栅格化」两个硬性处方随之撤回。当前唯一站得住的门禁：**CI 失配机制未定位前，不得重录 golden、4 处保持 skip**（重录而不理解机制 = 台账自身警告的信号销毁动作）；定位路径 = CI 侧证据（保留/检查 `<test>.actual.png` 产物、CI 探针重录——重录 gated on record path，见工具守卫条）+ 本地低成本探针（accent / `Color.yellow` 候选排查）。
- **隔离修复（d64ea3e，164609 P1 处方，保留）**：`snapshotTestSetUp`/`snapshotTestTearDown` 以 fontScale 同款 missing-aware 模式隔离 `settings.selectedTab`（SettingsRootView.swift:31）+ `themeAppearance`（GeneralSettingsView.swift:13）。尽管 tab 归因被排除，两 key 仍是快照渲染路径仅存的生产 `.standard` 直读（@AppStorage 不可注入），隔离属正确卫生 + 防未来 golden 依赖宿主 defaults。**性质标注（202924 P2）**：`themeAppearance` 隔离为 **reasoned-inert 而非实测**——唯一可受其影响的 golden（`testSettingsRootViewGeneralTab`）当前 skip、无实测通路；`GeneralSettingsView` 仅在 `.onChange` 中改 `NSApp.appearance`（:79，另一消费点 :144 的 Picker 在未栅格化的 Form 内），恢复该 golden 时须先探针实测不变性（已列入恢复清单 #4）。行号勘误：:31 非 :30；`BackupSettingsView(backupService:)` 在 :64 非 :63（dead-code 结论不变）。ZZZSuiteTeardownTests.swift:197 的「didSet on tab click」描述失准——真 writer 是 `selectedTabBinding` setter（SettingsRootView.swift:34-38，setter :37）：**本提交已修正该 ZZZ 注释**（202924 P2，撤回 d64ea3e 时期「不追改」决定——该条目 gates 未来污染决策，机制描述必须正确），本条旧行号 :33-38 同步勘误为 :34-38。
- **ClipboardItemRow/WelcomeView 调查仍开放**：`ClipboardItemRow` 默认 `store: .shared`（ClipboardItemRow.swift:302），渲染期读 store 状态（:383 `ocrPreviewEnabled`、:707/:712 `imageMissingIds`/`imageCorruptedIds`、:880 `getDecryptedOcrText`、:901/:913 `getDecryptedContent`、:973 `item(forID:)`）——CI 上路由 isolation suite，冷启动 key 窗口（ID-STORE-0010）可改变渲染输出；`WelcomeViewSnapshotTests` 构造 fresh `HotKeyManager()`。需注入隔离 store 后 CI 迭代证实/证伪。
- **恢复条件（202924 修订；取代 190433 版）**：4 处 snapshot 恢复前置 = **定位 CI 失配机制**（CI 侧 `<test>.actual.png` 产物 / 探针重录——重录 gated on record path，见工具守卫条）——机制定位前 golden 重录无意义且属信号销毁；ClipboardItemRow/WelcomeView 恢复另需 store 注入 + CI 验证；`testRendersSensitiveItemMasked`（masking 哨兵，ClipboardItemRowSnapshotTests.swift:69-71 文档注释、方法 :72）**必须恢复，不得退场**——恢复时随 ClipboardItemRow hermeticity（store 注入）一并验证。⚠️ `Scripts/regenerate-snapshots.sh` 已降级为破坏性流程绊线（202924 P1-1 + 073406 P1，见下条）：无 record path 的情况下运行只会响亮失败并自动恢复，不会邀请提交 golden 删除。
- **re-record 工具守卫（202924 P1-1 + 073406 P1 入账）**：`Scripts/regenerate-snapshots.sh` 此前对 skip 无感知——先 `-delete` 全部 golden 再跑 4 个 snapshot 类，被 skip 的测试不渲染 → golden 永不重录，`|| true` 吞掉信号后仍打印 commit 邀请，会诱导删除 masking 哨兵 `testRendersSensitiveItemMasked.png` 等基线。202924 加了 post-run 缺失 golden 硬失败；**073406 P1 揭示更深一层**：`SnapshotTestHelpers` 自 0922 起**根本没有 record path**——缺失 golden → `XCTFail`+return（SnapshotTestHelpers.swift:125-134；8ac1bf5 行号，勘误见下条），全 Tests/ 唯一 `__Snapshots__` 写入是失配 artifact `<test>.actual.png`（:150；8ac1bf5 行号，勘误见下条；rg 全量确认）——守卫的通过分支在真实环境**不可达**（202924 的 stub 实测只验证了 bash 语义、未验证可达性，此处入账）。该既存 P1 已由 auto-review-20260922-090545.md:4 与 -111346.md:7 两次记录未修；1e58692 清除 helper 内 4 处「delete + 重跑即可重录」假声明（doc 注释 :89-100、P1-6 注释 :117-128、missing-golden 报错 :131-137、mismatch 报错 :156-162；行号按 1e58692）。**现状处置（1e58692 落地；083314/085151 rework 两轮加固，现行机制见下方 083314/085151 rework 条）**：脚本降级为**破坏性流程绊线**——dirty preflight（`__Snapshots__` 有未提交 tracked 改动即拒跑，防 `git checkout` 误伤）→ 盘点 → 删除 → 跑套件 → 逐一单文件恢复缺失 golden（保留真实重录的文件）→ exit 1 响亮报错；**合法基线退场 = `git rm` golden 连同退役/改造其测试，不经此脚本**（073406 P2-2）；恢复清单「重录」步骤显式 gate 在「实现 env-gated record path」上；**record path 落地当天守卫须同步从存在性校验升级为内容校验**（073406 P2-3，防重录成全白/退化 golden 仍通过——与台账「重录 = 信号销毁」门禁对齐），**且重跑须显式设 `CLIPMEMORY_SNAPSHOT_RECORD_PATH_LANDED=1`**（083314 引入的机械 forcing function；未设时 restored==0 分支一律 exit 1）。
- **083314 rework（2026-10-03，第 16 轮审核 FAIL 2P1+4P2 全修；报告 `auto-review-20261003-083314-43110.md`）**：① **P1-1 勘误上条「4 处」**——helper 头部 `renderToImage` doc 注释存在**逐句重复块**（1e58692 行号 :33-65，即 090545:7 / 111346:7 两次 P2 记录的重复段），其中含上条 4 处之外的第 5 处「delete + 重跑即可重录」假声明（:38-42 "Recording mode: implicit on first run… delete the PNG… re-run"）；本提交整体删除重复块（"~40/~50 lines" 行数不一致随之消失），假声明英文短语 grep（直陈式 instruction 措辞，Tests/ Scripts/ ClipMemory/）归零；helper 保留 3 处**否定式**提及（行号 :85/:90/:92 为**现行文件**行号——101344 P2 勘误：先前「1e58692 行号」标注失实，1e58692 时点 :85 为空行、:90/:92 处内容与现行不同；「auto-record branch was removed / not executable」等诚实否定句——rg -i 宽口径仍命中，非假声明，085157 P2 措辞收敛）。**行号勘误链**：上条 :125-134 / :150 是 8ac1bf5 行号（1e58692 后实为 :130-139 / :155）；删除重复块后 missing-golden guard = **:97-106**、actual.png 写入 = **:122**（脚本头部引用同步更新）。② **P1-2 恢复循环加固**：盘点从 `find` 改 `git ls-files`（**tracked-only**——未追踪 `<test>.actual.png` artifact 不再进入恢复列表；审核实证：旧盘点下 artifact 使 `git checkout --` 报 pathspec 错、`set -e` 中止循环、剩余 tracked golden 滞留删除态）；单文件 checkout 加 guard（失败不中止循环，以存在性复验为失败判据）；bulk sweep 只在失败路径执行（成功路径保留真实重录文件的原设计不变）；不可达成功分支加 `CLIPMEMORY_SNAPSHOT_RECORD_PATH_LANDED=1` env 门（073406 P2-3 内容校验升级的机械 forcing function——env 未设时成功分支 exit 1）。③ **P2**：`.gitignore` 增加 `*.actual.png`（090545:8 / 111346:10 遗留，同时拆掉 P1-2 触发链）；「探针重录」处方 6 处（表 #8 / 像素事实 / 诊断定位路径 / 恢复条件 / 仍开放 #2 / 恢复清单 #4）显式 gate 在 record path 上，与工具守卫条对齐。**脚本三分支实测（083314 rework 提交内）**：dirty preflight exit 1 树零改动 ✓；stub xcodebuild（恢复全部 golden）→ missing=0 → env 门 exit 1 ✓；真实 xcodebuild + 未追踪 stray `actual.png` → 8 golden 全检出缺失 → 全部恢复 → env 门 exit 1、树 0 dirty、8 golden 在场 ✓。
- **085151 rework（2026-10-03，第 17 轮审核双报告：hook `auto-review-20261003-085151-48028.md` FAIL（1 P1 + 5 P2）+ 手动 `auto-review-20261003-085157-48099.md` PASS（4 P2）——post-commit hook 与手动触发并行各产生一份报告，按纪律以 FAIL 报告为准，PASS 报告重叠 P2 一并修）**：① **P1 git fail-closed**——083314 rework 的 guarded 检查（`|| true`）在 git 本身故障时 fail-open：审核以 bogus `GIT_DIR` 实证 preflight 通过、盘点为空、`find -delete` 删光 8 golden、恢复循环空转、最后 env 门分支打印假结论。修法：删除前三重 fail-closed——`git rev-parse --show-toplevel`（bogus GIT_DIR / dubious ownership 即拒）、guarded `git status --porcelain`（命令失败即拒，非仅非空输出）、guarded `git ls-files` 盘点（失败**或为空**均拒，绝不把空盘点当成功）。② **restored 计数分流（085157 P2）**——083314 引入的 env 门分支注释自称 "unreachable by design"，实为每次运行的**默认路径**（无 record path → golden 被删 → 全部由 git 恢复 → restored=8 → 落入 env 门），其措辞在每次正常运行都是假话且吞掉「已从 git 恢复」的操作员确认。修法：恢复循环计数 `restored`/`restore_failed`，分流报告——`restored > 0` → 打印 "All N missing tracked goldens restored from git (tree back to pre-run state)" exit 1（诚实描述默认路径）；`restored == 0`（全部 golden 无 git 恢复即重现 = 无 record path 下不可能）→ 才是真 env 门。③ **失败路径 sweep 加 env 门（085151 P2）**——sweep 的安全性依赖「无 record path 不可能重录」这一随 record path 落地而失效的不变量：`restore_failed` 时若 `CLIPMEMORY_SNAPSHOT_RECORD_PATH_LANDED=1` 已设，拒绝 bulk sweep（防覆盖新录 golden）exit 1；env 未设才 sweep + 复验。④ **helper 假声明清除（085151 P2，1e58692 遗留第 6 处）**——`SnapshotTestHelpers.swift` "CI artifacts retain both"（:118-119）不实：无 `XCTAttachment`（rg 零命中），actual.png 经 `try?` 写**源码树**、从不进 xcresult，ci.yml 只上传 `results/`。修法：改为准确表述（artifact 落源码树 + gitignored + 不进 xcresult；CI 侧经 ci.yml 新增上传步骤可达）。**行号漂移**：该注释扩为 6 行（:118-123）使 `actualData.write` 从 :122 → **:126**，脚本头部引用同步更新（083314 勘误链续：97-106 不变 / 122→126）。⑤ **ci.yml actual.png 上传机制（085151 P2）**——`.gitignore` 加 `*.actual.png` 后「CI actual.png 产物核查」处方失配（产物既进不了 xcresult 也无法 `git add -f` 入库、无任何步骤收集）；build-and-test job 尾部新增 `Upload snapshot mismatch artifacts` 步骤（`if: failure()`、upload-artifact@v4、path `Tests/ClipMemoryTests/__Snapshots__/`、`if-no-files-found: ignore`、retention 7 天），处方恢复可执行（**101344 P1 勘误**：65c16e1 实际把该步骤误落 lint-ids job——无测试执行、与 macOS 测试 job 并行互不可见 workspace、`if: failure()` 键在 lint 失配上，三重原因使上传永不触发，helper/ledger 的对应声明随之失实；101344 rework 移入 build-and-test 两 Test 步骤之后，path 收窄 `**/*.actual.png` 防无关失败把 8 张基线当「mismatch」产物上传）。⑥ **第 7 处探针站点 gate（085151 P2）**——`SettingsTabSnapshotTests.swift:112` "probe re-record" 提示补 record-path gate（083314 已 gate 6 处，漏此第 7 处）。⑦ **台账计数口径勘误（085151 P2）**——本文件头部 :3 曾把「本地 1025/21/0 GREEN」归到 083314 rework，但其 commit 只跑了 `bash -n` + 三分支脚本实测、无测试运行，且 `Scripts/test-count.sh` 静态估已漂至 1026；已改为「2026-10-02 实测时点值 + 以 Scripts/test-count.sh 为准」（ID-TEST-0002 反模式自纠）。⑧ **grep 归零措辞收敛（085157 P2）**——上条 ① "假声明英文短语 grep 归零" 收敛为「直陈式 instruction 措辞归零；否定式提及 3 处（:85/:90/:92）保留，rg -i 宽口径仍命中、非假声明」。**四分支实测（本 rework 提交内）**：dirty preflight exit 1、树零改动 ✓；`GIT_DIR=/nonexistent` → rev-parse fail-closed exit 1、删除未发生、8 golden 完好 ✓；stub xcodebuild 两变体——no-op（模拟无 record path）→ 删除后无任何写入 → git 恢复全部 → restored=8 > 0 → "All 8 missing tracked goldens restored from git" 消息 exit 1 ✓、回写全部 golden（模拟 record path 已落地）→ restored=0 → 真 env 门 exit 1、树零 dirty ✓；真实 xcodebuild + 未追踪 stray actual.png → 8 golden 全由 git 恢复、"restored from git" 消息 exit 1、stray 被清、树零 dirty ✓。
- **101344 rework（2026-10-03，第 18 轮审核 FAIL 2P1+5P2 全修；报告 `auto-review-20261003-101344-65276.md`）**：① **P1 上传步骤落位修正**——085151 ⑤ 的 `Upload snapshot mismatch artifacts` 步骤在 65c16e1 实际落进 `lint-ids`（审核三重实证：ubuntu runner 无测试执行 / 与 build-and-test 并行互不可见 workspace / `if: failure()` 键在 lint 失配上，snapshot 失配时 lint-ids 通过、步骤整体跳过），本 rework 移入 `build-and-test` 两个 Test 步骤之后（YAML 解析验证：该 job 第 13 步即末步、lint-ids 无此步）。② **P1 假声明清除**——ledger 085151 ⑤「build-and-test job 尾部新增」与 helper :118-123「ci.yml uploads __Snapshots__/ as a run artifact on test-job failure」在 65c16e1 时点均不实（机制在错误 job）；落位修正后恢复为真，helper 措辞同步为「uploads *.actual.png when a test step in that job fails」（注释保持 6 行，`actualData.write` 锚点 **:126** 不漂移），步骤注释 "clipmemory-test-coverage artifact above" 在同 job 内成立。③ **P2 空库存分支可达化**——`git ls-files | grep '\.png$' | sort` 在 pipefail 下无匹配时 grep exit 1 被 `if !` 误吞为「golden inventory failed」，EMPTY guard 是死代码（审核 replay 实证）；修法 `{ grep '\.png$' || true; }` 让空匹配落入 EMPTY 分支、真 git ls-files 故障仍走 fail-closed 分支，commit message「失败**或为空**均拒」恢复为实。④ **P2 删除步骤后验门**——`find -delete 2>/dev/null || true` 是脚本唯一不可逆步骤却 fail-open 静默（与前三个 git fail-closed 门不对称）；**BSD find 的 -delete 恒 exit 0**（实测 unlink Permission denied 仍 exit 0），无法靠退出码 fail-closed，改为删除后枚举残留 *.png（`-print -quit`）非空即拒跑 + git checkout 恢复指引；GNU find 下删除失败由 set -e 中止（同样 fail-closed）。⑤ **P2 self-test 固化**——新增 `Scripts/test/test_regenerate_snapshots.sh`（沿用 Scripts/test harness 惯例；审核点名的 root seam 落地为 `CLIPMEMORY_SNAPSHOT_SCRIPT_ROOT`，生产默认仍从 $0 推导），六分支覆盖全部可达出口：bogus GIT_DIR fail-closed 金样完好 / dirty 拒跑且不动现场 / 空库存拒跑（断言走 EMPTY 分支而非「inventory failed」误报路由）/ no-op stub → restored=8 "restored from git" exit 1 + 未追踪 stray 被清不入恢复列表 / 重录 stub 无 env → 真 env 门 exit 1 / 重录 stub + `CLIPMEMORY_SNAPSHOT_RECORD_PATH_LANDED=1` → 唯一 exit 0 路径。**实测**：6 分支全 PASS；生产路径（seam 未设）bogus GIT_DIR fail-closed exit 1 ✓；bash -n ×2 ✓；锚定 XCTSkip=21 不变 ✓；helper :126 锚点 ✓。**排障记录**：self-test 首版 `$(dirname "$0")/..` 在 Scripts/test/ 位置少跳一级（SCRIPT 解析成 `Scripts/Scripts/…` 全分支 127）——从 test_update_appcast.sh（同级 source 惯例只需一级 ../）复制模板时未按「脚本本体在 Scripts/」的目录深度换算，`../..` 修正。⑥ **P2 citation 统一**——ci.yml 步骤标题归属 (083314 rework P2) → (085151 P2)，与 ledger ⑤ 对齐（65c16e1 commit message 的 085157 归属不追改，以 ledger 为准）。⑦ **P2 上传 glob 收窄**——path `__Snapshots__/` → `**/*.actual.png`，防无关失败把 8 张 committed 基线以「mismatch」名义上传（"nothing to upload" 诚实化）；archive 内 rootDirectory-strip 后为扁平 `<test>.actual.png`（步骤注释已注明，与 ci.yml Test step 既有 upload-artifact strip 机制说明一致）。
- **覆盖率（164609 P2 + 173240/184342/190433 记录）**：SettingsTab 5 个 golden 断言≈零视觉内容（4 个 sibling 100% 空白、root 仅退化内容带+发丝线，Form 内容区空白）——套件实质只是「渲染不崩 + 字节稳定」canary；SettingsRootView / ClipboardItemRow 快照 / WelcomeView 快照活跃覆盖归零。masking 像素级哨兵仅剩 ClipboardItemRowTests.swift:88（isSensitive equatable 差异）+ SensitiveDetectorTests（检测层）弱替代。
- **P2 决议（161942/163026/164609/184342 汇总）**：skip 文案统一 `ID-CRASH-0038 skip:` 前缀。统计口径（三种 grep 勿混）：① 锚定 `^[[:space:]]*throw XCTSkip` = **21**（= 台账）；② 未锚定 `throw XCTSkip` 朴素 grep = **22**，虚增 1 = IntegrationTests.swift:626 注释文本 "Always throw XCTSkip"；③ `ID-CRASH-0038 skip:` 字面 = **20** = 4 新 throw + 15 既有 throw + 1 注释（AppDelegateShouldTerminateTests.swift:24）；2 处既有 throw 用变体前缀（IntegrationTests.swift:629 `v2.9.5 skip:`、HotKeyRetainFailurePathTests.swift:39 `ID-CRASH-0038;`）。`testSettingsRootViewGeneralTab` 保持测试体首行 skip（类级门会连坐同套件其余测试）。

## v2.9.6 仍开放（21 处 skip 的根因）

1. issue #93 根因**已修复并经 CI 实测确认**（ID-CRASH-0057，run 36978148927 宿主 0 重启）——主因关闭；issue 本体待 CI 全绿后关闭（该 run 尚有 4 snapshot 失败未达全绿，与本节 #2 一致）
2. snapshot golden 不匹配 4 处：tab 归因已排除（渲染对 key 不变）；CI 失配位置未证实（仓内无 actual.png 产物核查）；CI 失配机制**未定位**——双假设并存（AppKit-backed `Form` 栅格化缺失 / settle 竞态；root 内容带为退化渲染 → settle 未被排除；环境无关属性不解释 CI-only 失配，见诊断条）——恢复前置 = 机制定位（CI actual.png 产物 / 探针重录——重录 gated on record path，见工具守卫条）+ CI 重验；ClipboardItemRow/WelcomeView 另有 store .shared 调查线；masking 哨兵必须恢复
3. 3 处 HotKeyRetainFailure 测试前提在 CI 不成立，需重构测试
4. 9 处 IntegrationTests 后端集成 CI flake（与 #93 重叠；宿主崩已修，恢复后重测是否仍 flake）
5. 1 处 MemoryWarning 缓存状态依赖 + 1 处 WindowManager unregister 测试前提
6. AppDelegate terminate 3 处——崩溃机制已修复且 CI 实证，**下轮优先恢复验证**

## v2.9.6 可选 cleanup（不阻塞 ship）

- ~~给所有 `UserDefaults.standard.set(...)` 的测试加 `tearDown` save/restore~~ **已完成（2026-10-02 rework）**：7 条 test-side 条目全部从 `toleratedPollution` 移除，canary 零 test-side 条目通过
- 验证 ID-REVIEW-1009/1010/1011/1012 的 production 修复在 CI 端实测（v2.9.6 ship 后跑 CI 验证 ID-CRASH-0038 全部修复）
- ~~评估 `release.yml` 删 `if: github.event_name == 'pull_request'` guard 恢复 fail-closed 路径~~ **已超范围推进 — 见 ID-REL-1 / ID-REL-2 段（2026-10-05）**：原 ID-CRASH-0038 自述 "v2.9.6 恢复" 的承诺由 ID-REL-1 (7e3b756, 16 actions 全 SHA pin) + ID-REL-2 (8ae0db5, tag-path 54-test smoke subset + drift guard) 落地；但因 8ae0db5 把 release.yml `if: github.event_name == 'pull_request'` 同步删除，PR dry-run 从 1025-test 全量降到同一 54-test 子集（详见 auto-review-20261005-132311 P2-3），后续若恢复 fail-closed PR 全量需权衡 PR-side 反馈信号 vs runner 时间

## ID-REL-1 / ID-REL-2（2026-10-05）：发布链 SHA pin + tag-path smoke subset

ID-CRASH-0038 这条 v2.9.6 恢复承诺被 ID-REL-1 + ID-REL-2 提前推动：

**ID-REL-1**（`7e3b756` ci(release): SHA pin all 16 GitHub Actions uses）：
- release.yml + ci.yml + tsan.yml 全部 16 处 `uses:` 改 40-char commit SHA（带版本注释）：checkout `fbc6f399…` (v5.1.0) / github-script `60a0d830…` (v7.0.1) / upload-artifact `ea165f8d…` (v4.6.2) / download-artifact `d3f86a10…` (v4.3.0) / cache `0057852b…` (v4.3.0) / softprops/action-gh-release `e598afbe…` (v3.0.3)
- 6 个 SHA 经 `api.github.com` tag refs 实证对应，零虚 pin；lit-through grep 16 处 0 unpinned 残留
- 根因：code-review-2026-10-01 五-5 已标 "15 处 `uses:` 全部用可变 major tag + dependabot 自称 'pinned by SHA'（实际 0 个）"；release.yml 持 contents:write + admin PAT，被劫持等于发布链被劫持
- 已知 P2（auto-review-20261005-132311 P2-5）：`softprops/action-gh-release@e598afbe…` 是 annotated-tag object SHA（`api.github.com` `object.type = "tag"`），其他 5 pins 是 commit SHA——不一致但可解析；后续可改 commit SHA `efb35369e0ad2afab669f228072c1b0d510eae64`（同 SHA 的 underlying commit）以与其他 pins 对齐

**ID-REL-2**（`8ae0db5` ci(release): restore tag-path test gate）：
- release.yml `Run tests` step 删 `if: github.event_name == 'pull_request'` guard → tag path 现在跑 smoke subset
- 子集：IntegrationTests + ClipboardStoreCryptoKeyThreadTests + UserDefaultsKeyTests，SUBSET_EXPECTED=54（4 snapshot 测试因 runner 渲染漂移仍 defer v2.9.7，**不在子集内**所以 SUBSET_EXPECTED 稳定）
- drift guard（`:228-238`）：`Executed N tests` 行 grep + 与 SUBSET_EXPECTED 比对；不匹配 → `::error::Smoke subset drift` + exit 1（镜像 tsan.yml:97-103 模式）
- 自述（comment block `:202-213`）：cdda2a6 命名漂移教训 + 子集选择理由 + 与 tsan.yml drift guard 一致

**auto-review 抓到并已修（commit 在本批次内；非 ship 后 retrofit）**：
- **P0（已修）**：release.yml:225 用了文件名 `ClipboardStoreCryptoKeyNotificationThreadTests` 而非类名 `ClipboardStoreCryptoKeyThreadTests`（`Tests/ClipboardStoreCryptoKeyNotificationThreadTests.swift:19` `@MainActor final class ClipboardStoreCryptoKeyThreadTests: XCTestCase`）——`-only-testing` 匹配类名不是文件名；2 个 crypto-thread 测试静默不跑 → 47+5=52 ≠ SUBSET_EXPECTED 54 → drift guard 触发 → 每次 v2.9.6 tag push release gate 必 FAIL。**auto-review 在任何 tag push 之前抓下**（事件先于后果）
- **P1（已修）**：54-test gate 没有 class-existence lint 防同类型 bug 再发；扩展 `Scripts/lint-tsan-filter.sh` 接受 workflow 参数（默认仍 tsan.yml）+ sed pattern 支持双引号 SUBSET_EXPECTED（`SUBSET_EXPECTED: "54"` 是 release.yml 格式，单引号是 tsan.yml 格式）+ ci.yml lint-ids job 加新 step 跑 release.yml 版
- **P2-1（已修）**：`set -euo pipefail` + `executed=$(grep | tail | awk)` assignment 错误处理——若 `grep` 找不到 summary line，`set -e` 让 step abort 但**无** `::error::` 诊断；改用 `|| true` 让 pipe return 0，再 `[[ -z "$executed" ]]` 兜底（tsan.yml:97 模式）
- **P2-2（已修）**：step 加 `shell: bash`——否则 `xcodebuild test | tee` 在 GH Actions macOS 默认 `bash -e {0}`（无 pipefail）下让 tee 的 exit-0 吞失败；`shell: bash` + `set -o pipefail` 是 lint-release-yml rule 1 的合法 carve-out（ID-CI-0019）
- **P2-3 / P2-4 / P2-5（docs drift，已修）**：7 README + dependabot.yml + code-review-2026-10-01.md 五-4 都还停留在 "release.yml Run tests step 是 PR-only / tag 不跑测试" 描述，与 ID-REL-2 实际不符（详见下方 docs drift 段）
- **P2-6（pin kind 一致性，deferred）**：softprops 是 annotated-tag SHA，其他 5 pin 是 commit SHA——可解析但不一致；后续可改 commit SHA 与其他对齐
- **P2-pre-existing（不动）**：ci.yml:369 注释 `SUBSET_EXPECTED=94` vs tsan.yml:39 是 `'95'`——pre-existing 注释漂移，非本 PR 引入，按 surgical changes 纪律不动
- **P2-7（deferred 单独 follow-up）**：IntegrationTests.swift 12 处 bare-construct `ClipboardStore(backend:)` 走共享 `ClipboardStore-XCTest-isolation` suite 与 `AAASuiteBootstrapTests` 缺位子集的 deterministic risk——需源码深审（auto-review P2-7 描述），不开在本批

**docs drift 同步（commit 同批）**：7 README（README.md + README_{EN,ZH-HANT,JA,KO,ES,PT}.md）v2.9.5 entry 中 "release.yml Run tests step 改为 PR-only (if: github.event_name == 'pull_request')，tag path 跳过" → 改 "tag path 跑 54-test smoke subset (IntegrationTests + ClipboardStoreCryptoKeyThreadTests + UserDefaultsKeyTests)，SUBSET_EXPECTED 锚定 class rename 自动 fail-closed"；code-review-2026-10-01.md 五-4 同样刷新

重新生成站点统计（必须锚定行首：朴素 grep 会把注释里提到的 "throw XCTSkip" 一并计入，虚增 1——naive 22 vs anchored 21，来自 IntegrationTests.swift:626 的注释提及）：

```bash
# 总站点数（应与 CI "N tests skipped" 一致）
grep -rnE '^[[:space:]]*throw XCTSkip' Tests/ClipMemoryTests/ | wc -l
# 分文件分布
grep -rnE '^[[:space:]]*throw XCTSkip' Tests/ClipMemoryTests/ \
  | cut -d: -f1 | sort | uniq -c | sort -rn
```

## v2.9.6 恢复清单（2026-10-02 状态：宿主崩修复 CI 实证）

1. ✅ **已完成** issue #93 主因修复 + CI 实测确认（ID-CRASH-0057，run 36978148927 宿主 0 重启）——CI 绿后即可关闭 issue
2. ✅ **已完成** 优先恢复 #6（ZZZ canary——ID-REVIEW-1013 临时 allowlist 已于 2026-10-02 收紧回 4 条 framework keys）
3. 下轮优先：AppDelegateShouldTerminateTests 3 处恢复验证（崩溃机制已修复且 CI 实证）
4. snapshot 4 处：先**定位 CI 失配机制**（CI actual.png 产物 / 探针重录——重录 gated on record path，见工具守卫条；双假设并存勿预设——机制定位前重录 golden 无意义且属信号销毁）→ **实现 env-gated record path**（当前无 record path：缺失 golden 只 XCTFail、唯一写入是 actual.png，见工具守卫条）+ 守卫升级内容校验 → 重录 → CI 重验；恢复 root golden 时先探针实测 `themeAppearance` 不变性（当前为 reasoned-inert，见隔离修复条）；ClipboardItemRow/WelcomeView 需 store 注入；masking 哨兵 `testRendersSensitiveItemMasked` 必须恢复（随 ClipboardItemRow store 注入一并验证）；`Scripts/regenerate-snapshots.sh` 现为破坏性流程绊线（dirty 拒跑 + 缺失自恢复 + exit 1），record path 落地前重录流程不可达
5. 逐文件删除 XCTSkip → 本地全量 → CI 全量验证（每个 release 都跑一遍台账 vs CI 计数对账）
6. 每恢复一个文件即删除本表对应行；全部恢复后删除本文件

## 已 ship 的 hygiene 项（2026-10-03 commit `hygiene`）

1. **`Scripts/test/test_remove_appcast_item.sh`** `644 → 755`（executable bit 加回，git 历史显示 `chmod -x` 在某次重命名时丢了）
2. **`Scripts/test/test_regenerate_snapshots.sh`** `644 → 755`（同上）
3. **Ledger "建立" line** 1737-char commit blob → 4 行紧凑 metadata（git log 引用指向完整 commit 序列，不再把整条 log 内联进单行）
4. **`.gitattributes`** 新增 —— 强制 Swift / Shell / YAML / Markdown LF 行尾；`.png` / `.app` / `.dSYM` / `.tar.gz` 等 binary 显式标注

## 未 ship 的 hygiene 项（需要非代码修改或用户决策）

5. **GPG sign 配置** —— `commit.gpgsign` 未启用，最近 5 个 commit 全部 `N`（无签名）。这是 **user-local git config**，不进仓库：
   ```bash
   git config --global user.signingkey <KEY_ID>  # 须先 gpg --gen-key
   git config --global commit.gpgsign true
   ```
   本批不修；记入 P3 user setup todo。

6. **TSan advisory run 37095054114 结论** —— 6 个 warning，全为 Swift 6 strict-concurrency compile-time warning（非 TSan runtime race）：
   - `ClipboardStore.swift:98` × 2：`ClipboardMonitorDelegate` conformance 跨 main actor 边界（Swift 6 mode 会变 error）
   - `ClipboardStore+OCR.swift:136, 158` × 4：non-Sendable closure → `@MainActor @Sendable` cast
   **真 race：0 个**。修复路径：加 `@preconcurrency` 注解或 explicit MainActor isolation。记入 v2.9.7 backlog，不阻塞 v2.9.6 ship。

7. **README 注册（`sync_readme.py` 在 `release.sh` 中实际未调用）** —— 这是**故意的人类编辑门**（`Scripts/release.sh:40-45` 注释明确："user takes over the README state is correct responsibility"，因为 sync_readme.py 需要 LLM API key），**不是 bug**。本批不修。

## ID-REVIEW-1018（2026-10-06, commit `53a0306`）—— backup hard-link + usage display

5 个非阻塞 follow-up，按优先级 + next-batch 顺手做标记：

### Next-batch 顺手做（建议随下批 ID-REVIEW-1022/Task D 一起）

1. **【测试缺口·P2】** `BackupServiceTests.swift:testBackupNowCleansUpPartialDirOnImageCopyFailure` 改 NoThrow 后，**1.2 "throw mid-flight → partial-dir cleanup" 路径失去直接覆盖**。原 chmod-0 触发器对 hard-link 不再触发（`linkItem` 不读 source）。可改用 chmod-0 *destination* (`imagesDestination`) 强制 link 失败 → 断言 throw + 目录清理，单测即可恢复覆盖。回归风险：跨卷 EXDEV / 目标目录 EACCES / `imagesDestination` 已是文件 等真实失败路径目前无测试覆盖。

2. **【文档】** `BackupServiceTests.swift:149` 仍写 `"chmod-0 file throws .imageCopyFailed"`，与改 NoThrow 后的新行为矛盾。同步注释指向 ID-REVIEW-1018 hard-link 章节 + 描述 `linkItem` 不读 source 的语义事实。

### Defer（默认安装不受影响，下下批或下下下批处理）

3. **【P3·健壮性】跨卷 EXDEV 回归** —— 若用户把 `Images/` 符号链接到其他卷（省空间），`linkItem` 报 `EXDEV` → 每日备份全失败（旧 `copyItem` 跨卷正常）。3 行修复：`catch` 中识别 `EXDEV` 时降级 `copyItem`。force-EXDEV-only path，所以默认安装（单卷 APFS）不受影响。

4. **【边界记档】chmod-0 文件进备份** —— hard link 对 `0o000` source 也成功（实测），所以未来 exportPackage 时 `ditto` 读不了该文件导致导出失败。低概率（正常图片恒 `0o600`），仅记档不修：导出包 v3 + ImageStorage 的写入纪律已默认 0o600。

5. **【P3·健壮性】`identifier as! NSObject` 强转** —— 实践安全（NSURL 内部实现必为 NSObject），但 `as?` + 默认值更稳：`let key = (identifier as? NSObject).map(AnyHashable.init) ?? AnyHashable(<URLResourceKey>)`（或用 URLResourceKey 作 fallback key，因 hard link 同 path 的 identifier 不同）。3 行替换，无行为变化。

