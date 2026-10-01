# Skipped Test 台账（ID-CRASH-0038）

- **建立**：2026-09-30（`803393b`，v2.9.5）；2026-10-01 修订（`51fbedb`/`27eb1dd`：AppDelegateShouldTerminateTests 由类级 skip 改回 body 级 3 处）
- **根因追踪**：issue #93（ID-CRASH-0037，GH Actions runner 环境调查）+ ID-CRASH-0038
- **恢复目标**：**v2.9.6**（与各 skip 站点注释一致）
- **计数口径**：46 处语句 / 46 个测试（锚定语句计数与 CI 实测一致；run 36838993065 `Executed 1020 tests, with 46 tests skipped`）。注意朴素 grep 会把注释里的文字 "throw XCTSkip" 也数进去（虚增 2），必须锚定行首

## 背景

GH Actions macOS runner 环境（macOS 27 / 新 Xcode 镜像）下，下列测试会因环境差异失败，甚至直接杀死测试宿主进程（`Restarting after unexpected exit, crash, or test timeout`）。本地 `xcodebuild test` 全绿。在 runner 根因查明（issue #93）之前，这些测试被无条件 `XCTSkip`。

⚠️ xcodebuild 的 `Executed N tests` 把 skipped 计入总数，因此 ci.yml 的最小计数门（ID-CRASH-0014 blind-spot-6）对 mass-skip 不敏感——**本台账是 skip 的唯一强制记录**。恢复任何条目时，必须同时删除对应 `XCTSkip` 语句并删除本表行；全部恢复后删除本文件并在 release notes 记录。

## 台账

| # | 测试文件 | XCTSkip 处 | 备注 |
|---|---|---|---|
| 1 | IntegrationTests.swift | 9 | restart-recovery / backend 等核心集成路径 |
| 2 | ClipboardItemRowTests.swift | 7 | 行视图交互 |
| 3 | WindowManagerTests.swift | 5 | 窗口生命周期 |
| 4 | SettingsWindowTests.swift | 4 | 设置窗口生命周期 |
| 5 | MemoryWarningTests.swift | 4 | 内存告警 |
| 6 | HotKeyRetainFailurePathTests.swift | 3 | 热键保留环 |
| 7 | ContentViewTrimAlertTests.swift | 4 | 修剪告警 |
| 8 | ClipboardItemRowSnapshotTests.swift | 2 | 快照（golden 在库） |
| 9 | AppDelegateShouldTerminateTests.swift | 3 | terminate 路径。**CI 崩溃机制已确认**（runs 36833079602/36835842657 xcresult）：① 类级 `setUpWithError` XCTSkip 在 @MainActor 类上必杀 runner 宿主（`libdispatch: trying to lock recursively`，每测试一次重启）；② tearDown 里 `ClipboardStore.shared` 首触同样致命（tag run）。**skip 必须留在测试体首行**（与快照/窗口类的已验证安全模式一致），tearDown 不得触碰单例 |
| 10 | ZZZSuiteTeardownTests.swift | 1 | **防污染 canary**（生产 UserDefaults 域纯 diff，恢复优先级最高） |
| 11 | WelcomeViewSnapshotTests.swift | 1 | 快照 |
| 12 | SettingsTabSnapshotTests.swift | 1 | 快照 |
| 13 | QuickBarViewTests.swift | 1 | QuickBar |
| 14 | ClipboardItemRowOCRTransitionTests.swift | 1 | OCR 过渡 |
| | **合计** | **46** | 与 CI 实测 skip 测试数一致（口径：行首锚定的 `throw XCTSkip` 语句，不含注释提及） |

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
2. 优先恢复 #10（ZZZ canary——纯 UserDefaults diff，不依赖 UI 环境）
3. 逐文件删除 XCTSkip → 本地全量 → CI 全量验证
4. 每恢复一个文件即删除本表对应行；全部恢复后删除本文件
