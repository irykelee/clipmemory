# Skipped Test 台账（ID-CRASH-0038）

- **建立**：2026-09-30（`803393b`，v2.9.5）；2026-10-01 扩展（`51fbedb` 增加类级 skip）
- **根因追踪**：issue #93（ID-CRASH-0037，GH Actions runner 环境调查）+ ID-CRASH-0038
- **恢复目标**：**v2.9.6**（与各 skip 站点注释一致）

## 背景

GH Actions macOS runner 环境（macOS 27 / 新 Xcode 镜像）下，下列测试会因环境差异失败，甚至直接杀死测试宿主进程（`Restarting after unexpected exit, crash, or test timeout`）。本地 `xcodebuild test` 全绿。在 runner 根因查明（issue #93）之前，这些测试被无条件 `XCTSkip`。

⚠️ xcodebuild 的 `Executed N tests` 把 skipped 计入总数，因此 ci.yml 的最小计数门（ID-CRASH-0014 blind-spot-6）对 mass-skip 不敏感——**本台账是 skip 的唯一强制记录**。恢复任何条目时，必须同时删除对应 `XCTSkip` 语句并删除本表行；全部恢复后删除本文件并在 release notes 记录。

## 台账

| # | 测试文件 | XCTSkip 处 | 备注 |
|---|---|---|---|
| 1 | IntegrationTests.swift | 10 | restart-recovery / backend 等核心集成路径 |
| 2 | ClipboardItemRowTests.swift | 7 | 行视图交互 |
| 3 | WindowManagerTests.swift | 5 | 窗口生命周期 |
| 4 | SettingsWindowTests.swift | 4 | 设置窗口生命周期 |
| 5 | MemoryWarningTests.swift | 4 | 内存告警 |
| 6 | HotKeyRetainFailurePathTests.swift | 4 | 热键保留环 |
| 7 | ContentViewTrimAlertTests.swift | 4 | 修剪告警 |
| 8 | ClipboardItemRowSnapshotTests.swift | 2 | 快照（golden 在库） |
| 9 | AppDelegateShouldTerminateTests.swift | 1 | 类级 `setUpWithError` skip，覆盖 3 个测试（terminate 路径；宿主退出型失败） |
| 10 | ZZZSuiteTeardownTests.swift | 1 | **防污染 canary**（生产 UserDefaults 域纯 diff，恢复优先级最高） |
| 11 | WelcomeViewSnapshotTests.swift | 1 | 快照 |
| 12 | SettingsTabSnapshotTests.swift | 1 | 快照 |
| 13 | QuickBarViewTests.swift | 1 | QuickBar |
| 14 | ClipboardItemRowOCRTransitionTests.swift | 1 | OCR 过渡 |
| | **合计** | **46** | 站点数 ≠ 测试数（一处站点可守护多个测试，如 #9 一处覆盖 3 个） |

重新生成站点统计：

```bash
grep -rn "throw XCTSkip" Tests/ClipMemoryTests/ \
  | sed 's|Tests/ClipMemoryTests/||' | cut -d: -f1 | sort | uniq -c | sort -rn
```

## v2.9.6 恢复清单

1. issue #93 根因关闭（runner flake / SyncBarrier / 宿主退出，三者结论落地）
2. 优先恢复 #10（ZZZ canary——纯 UserDefaults diff，不依赖 UI 环境）
3. 逐文件删除 XCTSkip → 本地全量 → CI 全量验证
4. 每恢复一个文件即删除本表对应行；全部恢复后删除本文件
