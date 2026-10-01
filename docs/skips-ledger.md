# Skipped Test 台账（ID-CRASH-0038）

- **建立**：2026-09-30（`803393b`，v2.9.5）；2026-10-01 修订（`51fbedb`/`27eb1dd`：AppDelegateShouldTerminateTests 由类级 skip 改回 body 级 3 处）；2026-10-01 二次修订（`b07e5a5`：46 → 18 skip，**ID-REVIEW-1009 后的实测恢复**——crypto-path pollution 是 local-host flake 的主因，CI 端 ID-CRASH-0038 root cause 未关闭所以 CI 仍会失败）
- **根因追踪**：issue #93（ID-CRASH-0037，GH Actions runner 环境调查）+ ID-CRASH-0038
- **恢复目标**：**v2.9.6**（与各 skip 站点注释一致）
- **计数口径**：18 处语句 / 18 个测试（2026-10-01 实测，本地 1024 / 18 skipped / 0 failures）。注意朴素 grep 会把注释里的文字 "throw XCTSkip" 也数进去（虚增 2），必须锚定行首

## 背景

GH Actions macOS runner 环境（macOS 27 / 新 Xcode 镜像）下，下列测试会因环境差异失败，甚至直接杀死测试宿主进程（`Restarting after unexpected exit, crash, or test timeout`）。本地 `xcodebuild test` 全绿。

**2026-10-01 重大发现**（`b07e5a5`）：实测 ID-REVIEW-1009（test key path redirect）后，**28 个 skip 测试本地能 pass**——crypto-path pollution 之前是 local-host 的主 flake 机制，不是 ID-CRASH-0038 假设的 CI runner env。本地 1024 tests / 18 skipped / 0 failures。但 CI 端仍可能因 runner 镜像漂移失败，所以这 18 个剩余 skip 必须等到 CI 实测确认才能正式删台账。

⚠️ xcodebuild 的 `Executed N tests` 把 skipped 计入总数，因此 ci.yml 的最小计数门（ID-CRASH-0014 blind-spot-6）对 mass-skip 不敏感——**本台账是 skip 的唯一强制记录**。恢复任何条目时，必须同时删除对应 `XCTSkip` 语句并删除本表行；全部恢复后删除本文件并在 release notes 记录。

## 台账（2026-10-01 修订后，18 处 / 18 个测试）

| # | 测试文件 | XCTSkip 处 | 备注 |
|---|---|---|---|
| 1 | IntegrationTests.swift | 9 | restart-recovery / backend 等核心集成路径 |
| 2 | WindowManagerTests.swift | 1 | 仅保留 `testUnregisteringClosedSecondaryAllowsAccessorySink`（其他 4 已恢复） |
| 3 | MemoryWarningTests.swift | 1 | 仅保留 `testFlushAllClearsCaches`（其他 3 已恢复） |
| 4 | HotKeyRetainFailurePathTests.swift | 3 | 热键保留环：测试前提（"registration MUST fail"）在 CI 干净 macOS 上不成立，需要重构测试本身 |
| 5 | AppDelegateShouldTerminateTests.swift | 3 | terminate 路径。**CI 崩溃机制已确认**（runs 36833079602/36835842657 xcresult）：① 类级 `setUpWithError` XCTSkip 在 @MainActor 类上必杀 runner 宿主（`libdispatch: trying to lock recursively`，每测试一次重启）；② tearDown 里 `ClipboardStore.shared` 首触同样致命（tag run）。**skip 必须留在测试体首行**（与快照/窗口类的已验证安全模式一致），tearDown 不得触碰单例 |
| 6 | ZZZSuiteTeardownTests.swift | 1 | **防污染 canary**（生产 UserDefaults 域纯 diff，恢复优先级最高）。**ID-REVIEW-1009 后的实测**（2026-10-01）：1-6 修了 crypto key 路径，但仍检出新污染：`HotKeyKeyCode` / `HotKeyModifiers` 来自 `HotKeyManager.swift:17-18` 直接 `UserDefaults.standard.set(...)`（没走注入 defaults）、`WindowFrame` 来自 NSWindow autosave、`safeMode.active` / `safeMode.crashCount` 来自 SafeModeService 启动、`maxClipboardItems` / `excludedBundleIds` 走 `self.defaults` 但显然有路径绕过注入。**根因**：5+ 个生产代码路径写 `.standard`，不是 1-6 能解决的。**v2.9.6 恢复清单**：① HotKeyManager + WindowManager + SafeModeService + ClipboardStore 都迁注入 defaults（ID-STORE-0014 范式）；② 重新校准 `appLifecycleKeys` allowlist；③ 重跑 canary |
| | **合计** | **18** | 本地 1024 tests 全绿，CI 端待 issue #93 根因关闭后实测 |

## 已恢复（28 个测试，`b07e5a5`）

| 文件 | 恢复数 | 备注 |
|---|---|---|
| WindowManagerTests | 4 | 4 个 close cycle 测试，本地全绿 |
| SettingsWindowTests | 4 | 4 个窗口 lifecycle 测试，本地全绿 |
| ClipboardItemRowTests | 7 | 3 equatable + 4 parseRTF，本地全绿 |
| ClipboardItemRowOCRTransitionTests | 1 | 本地全绿 |
| ClipboardItemRowSnapshotTests | 2 | 2 个 snapshot 测试，本地全绿 |
| WelcomeViewSnapshotTests | 1 | 本地全绿 |
| SettingsTabSnapshotTests | 1 | 本地全绿 |
| QuickBarViewTests | 1 | 本地全绿 |
| MemoryWarningTests | 3 | 3 个 memory 通知测试，本地全绿（`testFlushAllClearsCaches` 保留 skip：依赖 prior test 缓存状态） |
| ContentViewTrimAlertTests | 4 | 4 个 trim 测试，本地全绿 |
| **合计** | **28** | |

重新生成站点统计（必须锚定行首：朴素 grep 会把注释里提到的 "throw XCTSkip" 一并计入，虚增 2）：

```bash
# 总站点数（应与 CI "N tests skipped" 一致）
grep -rnE '^[[:space:]]*throw XCTSkip' Tests/ClipMemoryTests/ | wc -l
# 分文件分布
grep -rnE '^[[:space:]]*throw XCTSkip' Tests/ClipMemoryTests/ \
  | cut -d: -f1 | sort | uniq -c | sort -rn
```

## v2.9.6 恢复清单

1. issue #93 根因关闭（runner flake / SyncBarrier / 宿主退出，三者结论落地）
2. 优先恢复 #6（ZZZ canary——纯 UserDefaults diff，不依赖 UI 环境，但需要 5+ 生产代码路径迁注入 defaults：HotKeyManager、WindowManager、SafeModeService、ClipboardStore 几个路径写 `.standard` 而非注入的 `self.defaults`）
3. 逐文件删除 XCTSkip → 本地全量 → CI 全量验证（每个 release 都跑一遍台账 vs CI 计数对账）
4. 每恢复一个文件即删除本表对应行；全部恢复后删除本文件
