# Skipped Test 台账（ID-CRASH-0038）

- **建立**：2026-09-30（`803393b`，v2.9.5）；2026-10-01 多次修订；**2026-10-02 状态**（commit 序列 `d659a0b` → `730af74` → `c43844c` → `bdaadd9` → `3199485` → `2009a5e` → `75caf41` → `fc15122`（auto-review 083606 FAIL rework，A/B/C/D 组）→ `5e98830`（ID-CRASH-0057 主修复）→ `c664b73`（rework 1）→ `fc83212`（rework 2）→ `f0487ea`（rework 3，auto-review 124153 rework + pre-push 审核 151102 PASS）→ 本提交（snapshot CI re-skip ×4）：**46 → 21 skip、ZZZ canary 通过（allowlist 收紧回 4 条 framework keys 严格模式）、本地 1025/21/0 GREEN**；CI run 36978148927 实证宿主 **0 重启**（ID-CRASH-0057 修复生效，issue #93 主因关闭）、1025/17/4——4 个失败全为 snapshot golden 不匹配（根因调查中，见下方新段），本提交将其重新 skip
- **根因追踪**：issue #93（ID-CRASH-0037，GH Actions runner 环境调查）+ ID-CRASH-0038
- **恢复目标**：v2.9.6
- **计数口径**：21 处语句 / 21 个测试（2026-10-02 实测，本地 1025 / 21 skipped / 0 failures；测试总数以 `Scripts/test-count.sh` 为准，ID-TEST-0002）

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
| 6 | ClipboardItemRowSnapshotTests.swift | 2 | snapshot golden 不匹配（根因调查中，hermeticity 假设领先），2026-10-02 CI run 36978148927 后重新 skip，见下方新段 |
| 7 | WelcomeViewSnapshotTests.swift | 1 | 同上 |
| 8 | SettingsTabSnapshotTests.swift | 1 | 同上（仅 `testSettingsRootViewGeneralTab`，套件 5 选 1） |
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

**宿主崩溃修复实证**：f0487ea push 后 CI 全量 `Executed 1025 tests, with 17 tests skipped and 4 failures` 单宿主 66.5s 跑完，`Restarting after unexpected exit` **0 次**（修复前 run 36954420379 每次 ~1s 连环崩）——issue #93 主因（ID-CRASH-0057 once 重入）正式确认关闭。AAA / AppDelegateShouldTerminate / ClipboardCaptureLimit / TrimAlert 等本批次修复相关套件全绿。

**snapshot golden 不匹配（4 失败，根因调查中）**：`ClipboardItemRowSnapshotTests` 2/2、`WelcomeViewSnapshotTests` 1/1、`SettingsTabSnapshotTests.testSettingsRootViewGeneralTab`（套件 5 选 1）。处置（user 2026-10-02 确认）：重新 skip（台账 #6-#8）。

- **根因假设演进（auto-review-161942 P1-1 勘误）**：cbc400a 曾记「runner 渲染漂移」并以 "`TrashItemRowSnapshotTests` 通过" 作选择性失败对照——**该对照错误**：TrashItemRowSnapshotTests **0 个活跃测试**（唯一方法 `xtestRendersImageInitialState_DISABLED_FOR_CHECKBOX_LAYOUT_CHANGE` 2026-08-10 停用、golden 从未入库），推断失去对照。cbc400a 的 commit message 与测试注释同错，本提交更正。
- **「runner 渲染漂移」假设被削弱（161942 P1-2）**：同套件 `SettingsTabSnapshotTests` 其余 4 个 golden 在 runner 上 byte-for-byte 通过（5 个 golden 同录于 `7c7d442`、同一 `renderToImage` byte-compare helper）→ runner 对同类输入的文本/材质渲染是稳定的，漂移解释不了同套件内 4/5。
- **领先假设（未证实，需 CI 迭代验证）**：非 hermetic 渲染输入。`ClipboardItemRowSnapshotTests` 渲染的 `ClipboardItemRow` 默认 `store: .shared`（ClipboardItemRow.swift:302），渲染期读 store 状态（:383 `ocrPreviewEnabled`、:707/:712 `imageMissingIds`/`imageCorruptedIds`、:880 `getDecryptedOcrText`、:901/:913 `getDecryptedContent`、:973 `item(forID:)`）——CI 上路由 isolation suite，冷启动 key 窗口（ID-STORE-0010）可改变渲染输出；`WelcomeViewSnapshotTests` 构造 fresh `HotKeyManager()`；`testSettingsRootViewGeneralTab` 传 `backupService: .shared`（root 复合视图可读共享态）。
- **恢复条件（161942 P1-3，取代 cbc400a 的「在 runner 镜像上重录 golden」——那会把 CI 环境依赖输出固化为 golden 并永久 retire masking 哨兵）**：① 修 hermeticity（snapshot 测试注入 per-test 隔离 store；审计 SettingsRootView/WelcomeView 的共享读）；② CI 重开验证不匹配是否消失；③ 仍有差异才从 hermetic 渲染重录 golden。`testRendersSensitiveItemMasked`（masking 回归哨兵，ClipboardItemRowSnapshotTests.swift:67-69 自述）**必须恢复，不得退场**。
- **P2 决议（161942）**：skip 文案统一回 `ID-CRASH-0038 skip:` 前缀（与 17 处既有站点 grep 联动一致）；`testSettingsRootViewGeneralTab` 保持测试体首行 skip（台账既有约定，不采纳类级门——会连坐同套件 4 个健康测试；setUp 死开销 <1ms 接受）；grep 统计注释「虚增 2」更正为「虚增 1」（naive 22 vs anchored 21）。

## v2.9.6 仍开放（21 处 skip 的根因）

1. issue #93 根因**已修复并经 CI 实测确认**（ID-CRASH-0057，run 36978148927 宿主 0 重启）——**可关闭**
2. 4 处 snapshot golden 不匹配（根因调查中：hermeticity 假设领先、渲染漂移被削弱，见上方 CI 实测段）——恢复需先修 hermeticity + CI 验证，仍有差异才重录 golden；masking 哨兵必须恢复
3. 3 处 HotKeyRetainFailure 测试前提在 CI 不成立，需重构测试
4. 9 处 IntegrationTests 后端集成 CI flake（与 #93 重叠；宿主崩已修，恢复后重测是否仍 flake）
5. 1 处 MemoryWarning 缓存状态依赖 + 1 处 WindowManager unregister 测试前提
6. AppDelegate terminate 3 处——崩溃机制已修复且 CI 实证，**下轮优先恢复验证**

## v2.9.6 可选 cleanup（不阻塞 ship）

- ~~给所有 `UserDefaults.standard.set(...)` 的测试加 `tearDown` save/restore~~ **已完成（2026-10-02 rework）**：7 条 test-side 条目全部从 `toleratedPollution` 移除，canary 零 test-side 条目通过
- 验证 ID-REVIEW-1009/1010/1011/1012 的 production 修复在 CI 端实测（v2.9.6 ship 后跑 CI 验证 ID-CRASH-0038 全部修复）
- 评估 `release.yml` 删 `if: github.event_name == 'pull_request'` guard 恢复 fail-closed 路径（需先确认 21 处 skip 的根因都已关闭）

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
4. snapshot 4 处：先修 hermeticity（注入 per-test 隔离 store / 审计共享读）→ CI 验证 → 仍有差异才从 hermetic 渲染重录 golden；masking 哨兵 `testRendersSensitiveItemMasked` 必须恢复
5. 逐文件删除 XCTSkip → 本地全量 → CI 全量验证（每个 release 都跑一遍台账 vs CI 计数对账）
6. 每恢复一个文件即删除本表对应行；全部恢复后删除本文件
