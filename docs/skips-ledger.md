# Skipped Test 台账（ID-CRASH-0038）

- **建立**：2026-09-30（`803393b`，v2.9.5）；2026-10-01 多次修订；**2026-10-02 状态**（commit 序列 `d659a0b` → `730af74` → `c43844c` → `bdaadd9` → `3199485` → `2009a5e` → `75caf41`（已 push）；2026-10-02 auto-review FAIL rework（A/B/C/D 组）当前未提交）：**46 → 17 skip、ZZZ canary 通过（allowlist 收紧回 4 条 framework keys 严格模式）、1025/17/0 GREEN**
- **根因追踪**：issue #93（ID-CRASH-0037，GH Actions runner 环境调查）+ ID-CRASH-0038
- **恢复目标**：v2.9.6
- **计数口径**：17 处语句 / 17 个测试（2026-10-02 实测，本地 1025 / 17 skipped / 0 failures；测试总数以 `Scripts/test-count.sh` 为准，ID-TEST-0002）

## 背景

GH Actions macOS runner 环境（macOS 27 / 新 Xcode 镜像）下，下列测试会因环境差异失败，甚至直接杀死测试宿主进程（`Restarting after unexpected exit, crash, or test timeout`）。本地 `xcodebuild test` 全绿。

**2026-10-01 重大发现**（`b07e5a5`）：实测 ID-REVIEW-1009（test key path redirect）后，**28 个 skip 测试本地能 pass**——crypto-path pollution 之前是 local-host 的主 flake 机制，不是 ID-CRASH-0038 假设的 CI runner env。本地 1024 tests / 18 skipped / 0 failures。但 CI 端仍可能因 runner 镜像漂移失败，所以这 18 个剩余 skip 必须等到 CI 实测确认才能正式删台账。

⚠️ xcodebuild 的 `Executed N tests` 把 skipped 计入总数，因此 ci.yml 的最小计数门（ID-CRASH-0014 blind-spot-6）对 mass-skip 不敏感——**本台账是 skip 的唯一强制记录**。恢复任何条目时，必须同时删除对应 `XCTSkip` 语句并删除本表行；全部恢复后删除本文件并在 release notes 记录。

## 台账（2026-10-02 修订后，17 处 / 17 个测试）

| # | 测试文件 | XCTSkip 处 | 备注 |
|---|---|---|---|
| 1 | IntegrationTests.swift | 9 | restart-recovery / backend 等核心集成路径 |
| 2 | WindowManagerTests.swift | 1 | 仅保留 `testUnregisteringClosedSecondaryAllowsAccessorySink`（其他 4 已恢复） |
| 3 | MemoryWarningTests.swift | 1 | 仅保留 `testFlushAllClearsCaches`（其他 3 已恢复） |
| 4 | HotKeyRetainFailurePathTests.swift | 3 | 热键保留环：测试前提（"registration MUST fail"）在 CI 干净 macOS 上不成立，需要重构测试本身 |
| 5 | AppDelegateShouldTerminateTests.swift | 3 | terminate 路径。**CI 崩溃机制已确认并已修复（ID-CRASH-0057，见下方勘误）**：真因是 `ClipboardStore.shared` 的 dispatch_once 临界区内 pump RunLoop 重入 XCTest（tearDown 首触 `.shared` 同样致命；"类级 setUpWithError XCTSkip 必杀"是误归因——它只是共现现象）。skip 暂留至 CI 实测确认修复生效后再评估恢复；恢复时仍遵守 skip 置于测试体首行、tearDown 避免首触单例的保守模式 |
| | **合计** | **17** | **本地 1025 / 17 skipped / 0 failures**（2026-10-02） |

## ✅ ZZZ canary re-enabled（ID-REVIEW-1013 → 2026-10-02 收紧）

ZZZ canary 不再 skip。ID-REVIEW-1013 曾临时把 `toleratedPollution` 扩到 11 条（7 个 test-side key）；auto-review-20261002-083606 FAIL 指出其中 **4 条在仓库 grep 不到任何 writer**（`safeMode.active` / `safeMode.crashCount` / `excludedBundleIds` / `WindowFrame`——最后一条还解除了 `appLifecycleKeys` 段落里明言的 WindowFrame regression tripwire），其余 3 条引用行号有误、且 `HotKeyManagerTests` 本就有类级 absence-aware setUp/tearDown 自清理、`TestHostIsolationTests` 为行内即时恢复。ID-REVIEW-1009/1010/1011/1012 + 2026-10-02 A/B rework（ClipboardStore `static let shared` revert、HotKeyManager.xcTestDefaults 恢复 isolated suite）落地后，**7 条 test-side 条目全部删除**，allowlist 回到 2026-08-06 校准的 4 条 framework keys（`AppleLanguages` + Sparkle `SU*`×3），全量 1025/17/0 GREEN（`testNoProductionPollution` 零 test-side 条目实证通过）。

**Production code 完全干净**（`grep -rn 'UserDefaults\.standard\.set' ClipMemory/` → 0 处实际代码调用，1 处为 ClipboardStore.swift 内注释）；canary 检出的污染全部来自测试 helper 自身写 `.standard` 没 cleanup。架构意图（让 production 代码用注入 defaults）在 ID-REVIEW-1009/1010/1011/1012 都 ship 了。

**2026-10-02 勘误（auto-review-20261002-083606 FAIL，ID-REVIEW-1012 rework）**：xcTestDefaults env-var 检测**可靠**——`XCTestConfigurationFilePath` 即使被设为空字符串，`== nil` 仍返回 false（`Optional("") == nil` 恒为 false），XCTest 分支正确路由到 isolated suite。2009a5e 的 "static let eager module-load" 根因叙事有误（Swift `static let` 本来就是 lazy `swift_once` 首触初始化，不存在 module-load 抢跑窗口），其引入的 `MainActor.assumeIsolated` trap（后台线程访问即 fatalError）+ 无锁 dead setter 已 revert 回 `static let shared`（known-good，行为与生产路径均不变），并由 `TestHostIsolationTests.testSharedSingletonRoutesToIsolatedDefaultsUnderXCTest` 钉住契约。HotKeyManager 的 xcTestDefaults 已于同日恢复 isolated suite（ID-REVIEW-1010 原始实现，d659a0b），`HotKeyManager-XCTest-isolation` suite 纳入 AAA bootstrap 每-test 清理（`XCTestIsolationSuiteObserver`），H.3.1 tautology 测试改为 UUID suite 真断言。

## ID-CRASH-0057（2026-10-02）：issue #93 宿主连环崩根因勘误 + 修复

**真因**（16 份 .ips + 代码双证，CI run 36954420379）：`ClipboardStore.init` 的 XCTest-only auto-wait（`waitForFirstLoadSync(timeout: 15)`，ID-CRASH-0049 加入）在 `ClipboardStore.shared` 的 **dispatch_once 临界区内** pump `RunLoop.main` 等 background first-load。pump 重入 XCTest 的 `RunTestsFromRunLoop`，字母序首个触碰 `.shared` 的测试（`ClipboardItemRowOCRTransitionTests`，经 `ClipboardItemRow.swift` 默认参数 `store: ClipboardStore = .shared`）在同线程对同一 once 重入加锁 → libdispatch `trying to lock recursively` → SIGTRAP。宿主每次重启 ~1s 即死、同因连环崩；本地绿是因为竞态下 background load 通常在 pump 派发出首个测试前已完成。

**误归因勘误**：此前 ledger 记录的 "类级 `setUpWithError` XCTSkip 在 @MainActor 类上必杀宿主" 与 " AppDelegateShouldTerminateTests 特有机制" 均为共现现象，不是因果——任何在主线程首触 `.shared` 的路径（tearDown、任意测试体）都触发同一 once 重入。

**修复**：SyncBarrier 移出 init（`loadItemsInBackgroundAsync()` 后 init 直接返回，生产/测试行为一致化）；`waitForFirstLoadSync`/`waitForFirstLoad` 保留为显式原语（AppDelegate boot 路径 `await waitForFirstLoad()`、`flushPendingSaves` terminate 门、测试显式等待——**11 处**显式等待已补：TagTests ×3、ContentViewTrimAlertTests ×1、IntegrationTests ×5、ClipboardStoreTrashTests ×2，另 ContentHashKeyReadyBackfillTests setUp ×1）。首轮排查漏了 `testTogglePinUpdatesAndPersists`（`store2.items[0]` 空数组下标 → SIGTRAP 宿主崩 → 重启进程不重跑 AAA → isolation observer 失效 → QuickBar 读到脏 suite 的 maxItems=3 + ZZZ 7 keys 连锁假阳性；本地全量 2026-10-02 11:02/11:17 两次复现后补齐）；Backfill setUp 等待防 late firstLoadTask 覆盖 merge 结果。其余站点或为空 Memory backend、或显式调同步 `loadItems()`。

**遗留**：17 处 skip 不随本修复自动恢复；待 push + CI 全量实测确认宿主不再崩后，按台账流程逐文件评估恢复（AppDelegateShouldTerminateTests 3 处优先验证）。

## 已恢复（29 个测试，截至 2026-10-02）

| 文件 | 恢复数 | 备注 |
|---|---|---|
| WindowManagerTests | 4 | 4 个 close cycle 测试 |
| SettingsWindowTests | 4 | 4 个窗口 lifecycle 测试 |
| ClipboardItemRowTests | 7 | 3 equatable + 4 parseRTF |
| ClipboardItemRowOCRTransitionTests | 1 | OCR 过渡 |
| ClipboardItemRowSnapshotTests | 2 | 2 个 snapshot 测试 |
| WelcomeViewSnapshotTests | 1 | snapshot |
| SettingsTabSnapshotTests | 1 | snapshot |
| QuickBarViewTests | 1 | QuickBar 前缀 |
| MemoryWarningTests | 3 | 3 个 memory 通知测试（保留 1 个） |
| ContentViewTrimAlertTests | 4 | 4 个 trim 测试 |
| ZZZSuiteTeardownTests | 1 | **防污染 canary 通过**（allowlist 已收紧回 4 条 framework keys） |
| **合计** | **29** | ID-REVIEW-1009..1013 共同 unblock ZZZ canary |

## v2.9.6 仍开放（17 处 skip 的根因不在本批次）

1. issue #93 根因**已定位并修复**（ID-CRASH-0057，见上方勘误段）——待 CI 实测关闭
2. 3 处 HotKeyRetainFailure 测试前提在 CI 不成立，需重构测试
3. 9 处 IntegrationTests 后端集成 CI flake（与 #93 重叠；#93 修复后需重测是否仍 flake）
4. 1 处 MemoryWarning 缓存状态依赖 + 1 处 WindowManager unregister 测试前提
5. AppDelegate terminate 3 处 runner 崩溃（机制已确认 = ID-CRASH-0057 once 重入，修复后待 CI 验证再评估恢复）

## v2.9.6 可选 cleanup（不阻塞 ship）

- ~~给所有 `UserDefaults.standard.set(...)` 的测试加 `tearDown` save/restore~~ **已完成（2026-10-02 rework）**：7 条 test-side 条目全部从 `toleratedPollution` 移除，canary 零 test-side 条目通过
- 验证 ID-REVIEW-1009/1010/1011/1012 的 production 修复在 CI 端实测（v2.9.6 ship 后跑 CI 验证 ID-CRASH-0038 全部修复）
- 评估 `release.yml` 删 `if: github.event_name == 'pull_request'` guard 恢复 fail-closed 路径（需先确认 17 处 skip 的根因都已关闭）

重新生成站点统计（必须锚定行首：朴素 grep 会把注释里提到的 "throw XCTSkip" 一并计入，虚增 2）：

```bash
# 总站点数（应与 CI "N tests skipped" 一致）
grep -rnE '^[[:space:]]*throw XCTSkip' Tests/ClipMemoryTests/ | wc -l
# 分文件分布
grep -rnE '^[[:space:]]*throw XCTSkip' Tests/ClipMemoryTests/ \
  | cut -d: -f1 | sort | uniq -c | sort -rn
```

## v2.9.6 恢复清单（2026-10-02 状态：canary 已 ship）

1. issue #93 根因**已修复**（ID-CRASH-0057：SyncBarrier 移出 init dispatch_once 临界区，见上方勘误段）——CI 实测通过即关闭
2. ✅ **已完成** 优先恢复 #6（ZZZ canary——ID-REVIEW-1013 临时 allowlist 已于 2026-10-02 收紧回 4 条 framework keys）
3. 逐文件删除 XCTSkip → 本地全量 → CI 全量验证（每个 release 都跑一遍台账 vs CI 计数对账）
4. 每恢复一个文件即删除本表对应行；全部恢复后删除本文件
