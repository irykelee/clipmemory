# 2026-07-29 代码审查 — 待实施/已丢弃项

> 本文件记录综合审查中"属实但尚未实施"以及"评估后丢弃"的条目，作为后续工作的参考。

---

## 待实施

### C1 · @MainActor DispatchQueue.main.async 闭包缺少编译期强制（🟠 Med）~~✅ DONE (0c3cc3c)~~

> 7 处全部替换为 `Task { @MainActor [weak self] in }`，与 cleanup timer 模式一致。

### ~~C1~~（已完成）

**位置**: `ClipboardStore.swift:669,706,1308,1352,1365,759,1017`

**现状**: 6+ 处 `DispatchQueue.main.async { self?.items[...] = ... }` 修改 `@MainActor` 状态，但闭包未被编译器推断为 @MainActor-isolated。当前靠 `SWIFT_STRICT_CONCURRENCY=minimal` 的弱检查 + 运行时巧合（闭包实际在主队列执行）保证安全。

**计划**:
1. 将 `SWIFT_STRICT_CONCURRENCY` 升级到 `targeted`（Swift 6 过渡模式），识别所有编译期警告。
2. 逐处替换为 `Task { @MainActor [weak self] in ... }`（团队已在第 364 行的 cleanup timer 使用此模式）。
3. 保存定时器（:759, :1017）的 `DispatchSource.makeTimerSource` 事件处理需特殊验证——确保 `Task` 的生命周期与 timer 一致。
4. 最终目标：升级到 `complete`，让编译器兜底所有 actor isolation。

**参考**: 现有迁移模式见 `ClipboardStore.swift:358-364`（注释 "F-1 phase 3: collapsed double-hop into Task { @MainActor }"）和 `:473-475`（"Handler now guaranteed to run on main thread by type system"）。

---

### C2 · BackupPackage.onMain 用 DispatchQueue.main.sync（🟡 Low）

**位置**: `BackupPackage.swift:298-301`

**现状**: `Thread.isMainThread` guard + `DispatchQueue.main.sync` 的反模式。当前调用方（`BackupService` 的 `DispatchQueue.global` 闭包）不会造成死锁，但一旦调用链出现主线程 → 等待后台线程 → 该后台线程调 onMain 的反转，即死锁。

**计划**:
1. 评估 `onMain` 的调用方是否可改为 async/await 模式。
2. 若可改：将 `onMain` 改为 `MainActor.run { try work() }` 或 async 版本。
3. 若不可改（同步上下文调用方多）：保持现状，但加 `#warning` 注释标记为反模式。

---

### A1 · ClipboardStore 1812 行巨型类（🟠 Med，长期重构）

**位置**: `ClipboardStore.swift`（1812 行）

**现状**: 单一 @MainActor 类承担捕获编排、去重、加密调度、JSON 持久化、OCR 触发、缓存管理、诊断合并、镜像完整性扫描、legacy 迁移/backfill。

**计划**:
1. 抽取 `PersistenceStore` — items/tags/trash 的 load/save/debounce 逻辑。
2. 抽取 `DecryptionCacheCoordinator` — contentCache / rtfPlaintextCache / 负缓存 的读写 + 预热编排。
3. 保持 `ClipboardStore` 作为薄门面 + `addItem` 编排中枢。
4. 拆分后单元测试可直接注入子组件，无需 `isRunningTests` env + `ServiceContainer.crypto` setter。

---

## 已丢弃（评估后不需要做）

### B2 · ServiceContainer.crypto 改为 let

**评估**: `var` 是测试注入所需（`ClipboardStore.init(backend:)` 接受 `MemoryStorageBackend` 但 crypto 不走 backend）。`didSet` 中的 `preconditionFailure` 已在生产环境禁止重赋值。改为 `let` 会破坏所有 XCTest 的 fake crypto 注入且无实际安全收益。**丢弃**。

### P3 · 图片捕获加 maxImageCaptureBytes

**评估**: 文档声称"无大小上限"，实测 `ImageStorage.saveImage()` 有 50MB guard。`ClipboardMonitor` 层缺护栏（B5 OPEN），但 50MB 的下游门控已足够防护。可在 B5 关闭时一并处理，无需独立实施。**丢弃**（等 B5 关闭时统一处理）。

### P4 · prewarmDecryptionCache cap=200

**评估**: 文档声称 cap=200，**经源码核实此声称不实**。参数名 `cap` 默认 `nil`（预热全部条目），无任何 200 常数值。**丢弃**。
