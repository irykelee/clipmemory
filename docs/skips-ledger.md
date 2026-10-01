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
| 6 | ZZZSuiteTeardownTests.swift | 1 | **防污染 canary**（生产 UserDefaults 域纯 diff，恢复优先级最高）。**v2.9.6 调研进度**（`d659a0b`/`730af74`/`c43844c`，2026-10-01）：HotKey + SafeMode + Crypto 都已迁注入 seam。诊断日志（`c43844c` 前的临时 commit）显示 `HotKeyManager.xcTestDefaults` 正确返回 isolated suite（env 非 nil、suite 创建成功）。canary 仍 fail 的根因调查：**`TestHostIsolationTests.swift:104` 是关键线索**——它在 `testProductionDefaultsKeysAreNotMutated`（line 56）的执行过程中**主动** `HotKeyConfig(keyCode: 0, modifiers: 256).save(to: .standard)` 写 standard（值是 0，不是 9），然后按 snapshot 恢复。如果 snapshot 显示之前 `hotKeyCodeBefore = 9`（即 AAA bootstrap 之后、TestHostIsolation 之前已有人写过 standard），restore 把 0 改回 9。canary 在更后面跑，看到 `ADDED HotKeyKeyCode=9` 不是测试 helper 写——是 snapshot 之前某个 production 代码路径写过一次。`maxClipboardItems`/`safeMode.*`/`excludedBundleIds` 同理：TestHostIsolationTests 写 12345/250/sentinel 之类然后恢复，restore 把之前的 production-init value 写回。**v2.9.6 收尾**：① AppDelegate 启动路径 grep，看是不是某 init 写了 defaults 到 standard；② 验证 `xcTestDefaults` 在 `static var` 第一次访问时 env 是否真的已设（可能是 lazy evaluation cache 太早）；③ WindowManager 单独 ship，加 `WindowFrame` 进 `appLifecycleKeys` allowlist |
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
