# ClipMemory 全面代码审查报告

- **日期**：2026-09-28
- **基线**：`main` @ `47afe0e`（工作区干净，与 `origin/main` 同步）
- **规模**：213 个 `.swift` / 50,870 行。生产代码 `ClipMemory/` ≈ 24.8K 行（Services 15,039 / Views 8,292 / Models 719 / Utils + AppDelegate）；测试 `Tests/ClipMemoryTests/` 112 文件 25,332 行
- **依赖**：仅 Sparkle 2.9.5（SPM，`Package.resolved` 已锁）
- **方法**：5 路独立子 agent 并行审查（架构/代码质量、安全、性能、测试、工具链与文档一致性），**所有 P1/P2 均由主 agent 直读源码逐条复核**；另跑 `xcodebuild Release build`（成功）、`xcodebuild test`（1010 通过 / 0 失败 / 47.3s）、`xccov` 覆盖率实测、`bash 3.2` 兼容性实测
- **与旧报告关系**：`docs/review/code-review-2026-09-21.md` 的 7 项 P1 已**全部修复并留痕**（见第六节），本报告只列**新发现**

## 严重度定义

| 级别 | 含义 |
|---|---|
| P1 | 可造成数据丢失 / 安全防线旁路 / 核心能力静默失效 / 阻断发布正确性 |
| P2 | 明确的缺陷或债务，有实际影响但不紧急 |
| P3 | 次要问题、文档漂移、理论性风险 |

---

## 一、P1 发现（6 项，全部经主 agent 直读复核 + 独立 verifier 复核）

> **本轮已下调 3 条**：P1-4 / P1-5 / P1-6 经独立核验后降为 P2 —— 因为它们相对本报告自订的 P1 定义（数据丢失 / 安全防线旁路 / 核心能力静默失效 / 阻断发布正确性）**虚高**。降级理由与审计轨迹见「一之二」。当前 P1 定义门槛被严格守住，不存在标签通胀。

### P1-1 `saveTags()` 三环节全缺 + `flushTagSave` 先清 flag → 标签定义静默丢失
- **证据**：`ClipMemory/Services/ClipboardStore+Tag.swift:151-157`（`catch` 只有 `logger.error`，无 retry / 无通知 / 不 `throw`）；`+Tag.swift:181-187`（`flushTagSave` 在 `:183` 先置 `tagNeedsSave = false`，`:187` 才调 `saveTags()`）；`Services/StorageBackend.swift:149-152`（`FileStorageBackend.saveTags` 只 `defaults.set`，**无 read-back**）
- **影响**：磁盘满 / cfprefsd 拒写时，新增或重命名的标签**会话内内存正确、落盘丢失**，下次启动标签消失，用户零感知。
- **完整调用链（已穷举验证）**：`saveTags()` 的**唯一**生产调用方是 `flushTagSave():187`；`flushTagSave` 只有 2 个调用点 —— 定时器 handler（`:170`）与 `flushPendingSaves()`（`+Persistence.swift:119`，即退出/terminate 路径）。`grep -rni "tagRetry|retryTag|tagSaveFailed|scheduleTagSaveRetry"` **全项目零命中**。即：**连应用退出时的最后一次落盘机会，走的都是同一条静默失败路径**。
- **复发性质**：这是 **ID-SILENT-0021（items 路径，已修）** 与 **旧 P1-3（trash 路径，已修）**之后的**第三处同型复发**。前两处都补了 `needsSave = true` 回滚，标签路径被漏掉。
- **修复建议（经核验修正：只补 catch 不够）**：`defaults.set` **返回 `Void`、永不抛错**，所以磁盘满时 `saveTags()` 的 catch 根本不会进入。照搬 items 路径的三环写法对**磁盘满**这一主场景无效。正确顺序是：
  1. **先补前置条件** —— `FileStorageBackend.saveTags:149-152` 复制 `saveBlob:120-135` 的 `synchronize()` + `readBack == data` 校验并改 `throws`（`StorageBackend.swift:96-119` 已诚实列出 read-back 抓不到什么，照着那个边界写）
  2. **再补三环** —— `flushTagSave` 的 catch 内 `tagNeedsSave = true` + `saveRetryState.recordFailure()` + `scheduleTagSaveRetry(after:)` + post `.clipboardSaveFailed`（带 `userInfo["source"] = "tagSave"`，`AppDelegate.swift:625-644` 的 throttler 已按 source 分桶，零新增 UI 代码）
  3. 参照实现 `ClipboardStore+Persistence.swift:143-167`

### P1-2 `ImageStorage.saveImage` 写盘失败 → 图片剪贴板静默失效
- **证据**：`ClipMemory/Services/ImageStorage.swift:480-487`（`catch` 仅 `logger.error` + `completion(nil)`）；对照同函数 `:465-478` 的**加密失败路径有** post `.encryptionFailed`（`:474`）—— 两条失败路径处理不对称
- **影响**：磁盘满时用户复制一张图片 → 存盘失败 → 条目不建立 → 无 NSAlert / 无 banner / 无诊断计数。用户以为存了。属数据持久化路径，违反项目「报错→重试→用户可见」三环节标准的第 2、3 环。
- **建议**：`:483` catch 内 post `.imageSaveFailed`（全项目当前零定义），`AppDelegate` 复用 `saveAlertThrottler`（`:85`）出提示；写盘移入已有的 `drainPendingWrites`（`:521`）骨架补第 2 环。

### P1-3 `.tagBackendCorrupted` 是死通知 —— 标签加载失败用户完全无感
- **证据**：`+Tag.swift:143` post，`Services/ClipboardStore.swift:35` 声明；全项目 **20 处 `addObserver` 调用点**（`AppDelegate.swift` 15 / `ClipboardStore.swift` 3 / `ClipboardMonitor.swift` 1 / `TrashStore.swift` 1）**无一监听该名**；`grep tagBackendCorrupted` 仅命中声明、post、一条注释、一条测试断言通知名字符串
- **影响**：`loadTags` catch 后 `tags = [:]`（`+Tag.swift:144`），用户侧边栏标签凭空消失，零信号。`+Tag.swift:140-142` 注释自承 "nothing observes this yet" —— 写注释时已知，仍未闭环。
- **严重度说明（核验后保留 P1 的理由）**：blob 损坏时数据已损坏，本条不产生**新的**数据丢失。但标签管理是 AGENTS.md 记录的核心能力（侧边标签筛选 / 批量操作），当前状态下用户的标签是**永久且无解释地消失**的，且用户无从得知需要从备份恢复 —— 命中 P1 定义中的「核心能力静默失效」。
- **建议**：`ClipboardStore+Diagnostics.swift` 的 `DecryptionDiagnostics` 加 `tagsLoadFailed: Bool`，`Views/Components/DiagnosticsBanner.swift:11` 已渲染该类型，UI 侧零新增。

### P1-4 TSan 无任何判定门禁 —— 新增数据竞争不会阻塞合并
- **证据**：`.github/workflows/tsan.yml:33`（`tsan-pr-subset` job 级 `continue-on-error: true`）、`:158`（`tsan-full` 同样）；`:121` `raceCount` 只在 `github-script` 内被读取，`:141-143` 渲染成 PR 评论文本。全文件 3 处 `exit 1`（`:89` / `:100` / `:199`）分别是 build-canary 与 subset-count 断言，**没有任何 step 以 race 数量作为退出码**
- **影响**：TSan 检出 100 处 race 与检出 0 处，CI 结果完全相同。`ConcurrencyTests.swift:300-333 testNoDataRaceWithThreadSanitizer` 也不在 `tsan.yml:69-77` 的 `-only-testing` 列表内，只在 nightly 跑，而 nightly 同样无判定门。`tsan-full` 更无任何上报通道（PR comment 仅 `pull_request` 事件）。项目 `SWIFT_STRICT_CONCURRENCY: minimal`（`project.yml:20`）下编译器不提供任何兜底。
- **严重度说明（核验后保留 P1 的理由）**：这是**设计意图被架空**的防线 —— 机制被专门建来捕获竞态，却在所有路径上静默通过。配合 minimal 并发模式，风险无第二道网兜底。P1/P2 边界可议，读者可自行重判。
- **建议**：两个 job 末尾各加判定：`races=$(grep -c "WARNING: ThreadSanitizer" /tmp/tsan.log || true); [ "${races:-0}" -eq 0 ] || { echo "::error::$races races"; exit 1; }`；把 `ConcurrencyTests` / `DateHelpersBehaviorTests` 加进 `-only-testing` 并同步 `SUBSET_EXPECTED`。

### P1-5 发布流水线：appcast 强推失败被吞 + 无条件 `gh api PATCH ?force=true`
- **证据**：`.github/workflows/release.yml:528-530`（`push --force-with-lease … || echo "::warning::…"` —— 推送失败仅告警）；`:540` 的 `if` **只判断 `origin/<branch>` 是否存在，不判断上一步是否失败**，故 `:545` 的 `gh api -X PATCH …?force=true` **无条件执行**；`:547` 该 PATCH 自身失败也仅 `::warning::`
- **影响**：`--force-with-lease` 的 stale-ref 保护（发布期间 main 若前进则拒绝）被 `force=true` 完全旁路 → 强推覆盖 main 上的新 commit、**丢 commit**。appcast 彻底推送失败时流水线仍为绿，Sparkle feed 静默陈旧。
- **建议**：把 `:545` 的 PATCH 移入 `:528` push 失败的 `if` 分支内，且仅在 `--force-with-lease` 确认失败时执行；`:547` 改为 `exit 1`。

### P1-6 `Scripts/release.sh` 的 `declare -A` 在 macOS 自带 bash 3.2 下直接中止
- **证据**：`Scripts/release.sh:190` `declare -A emitted_lines=()`，全文件无 `BASH_VERSINFO` 守卫。**实测**：`/bin/bash -c 'set -euo pipefail; declare -A m=(); echo REACHED'` → `/bin/bash: line 0: declare: -A: invalid option`，**exit 2**（`/bin/bash` = GNU bash 3.2.57，已被独立 verifier 复现）
- **影响**：本机因 `/opt/homebrew/bin/bash`（5.3.20）遮蔽了 `/bin/bash`，shebang `#!/usr/bin/env bash` 侥幸命中 bash 5 而通过。在**未装 Homebrew bash 的 stock macOS** 上，`generate_release_notes` 会中止整条发布链。
- **同仓不一致**：`Scripts/lint-release-yml.sh:131` 与 `lint-tsan-filter.sh:25` 都**专门注释并规避了同一 bash 3.2 限制** —— 三个脚本标准不统一。
- **建议**：`generate_release_notes` 里的关联数组改用两个平行数组（`emitted_keys` / `emitted_values`）或 `mktemp -d` + 文件做去重；或在 release.sh 顶部加 `BASH_VERSINFO` 守卫并显式报错。

### 一之二、经核验后从 P1 降为 P2 的 3 项（审计轨迹保留）

降级理由统一为：这 3 项相对本报告自订的 P1 定义（数据丢失 / 安全防线旁路 / 核心能力静默失效 / 阻断发布正确性）**不足以构成 P1**。技术事实全部成立，已在 P2 段落保留完整证据。

| 原编号 | 条目 | 降级理由 |
|---|---|---|
| P1-4（原） | `saveItems()` 主线程同步 | 纯性能问题，无数据损坏、无安全影响。已移入 P2-「性能」 |
| P1-5（原） | `.clipmemory` 解压无总量上限 | 仅本机 DoS，报告自身即写明「非数据泄露或代码执行」。已移入 P2-「安全」 |
| P1-6（原） | 根密钥明文 `Data` 副本未清零 | 需本机内存读取原语（root 或同 uid + SIP 例外 / 内存转储）才能利用，属纵深防御加固。已移入 P2-「安全」 |

---

## 二、P2 发现（按维度分组）

### 安全
- **（原 P1-5，降级）`.clipmemory` 解压全程无总量上限（zip bomb）**：`Services/BackupPackage.swift:255-264` 顺序为 `validateArchiveMembers` → `ditto -x -k` → `validateExtractedTree`；`validateArchiveMembers:274-299` 用 `unzip -Z1` **只解析成员名**，对 `..`/绝对路径/反斜杠做拒绝，**不累加任何字节数**；`:284 readDataToEndOfFile()` 无上限；全部体积守卫（`maxStoreBlobBytes` 100MB @ `:181` / `maxManifestBytes` 1MB @ `:190` / `ImageStorage.maxImageSize` 50MB）都在**解压之后**才生效。攻击者投递 1 MB 的 `.clipmemory`，内含 N 个 `pad.bin`（既非 `items.json`/`trash.json`/`tags.json`/`manifest.json`/`key.enc`，也不在 `Images/` 下的 `.png`）—— 这类成员**不在任何体积守卫覆盖内**；用户在导入向导选中文件即触发（`RestoreWizardViewModel.swift:110` → `validateExternalPackage:1185` → `unzipArchive`），`ditto -x` 先把全部内容写进 `$TMPDIR/clip-wizard-validate-<UUID>/` 才做检查。**影响面**：仅本机用户且需用户主动选中（非远程无人触发）；后果是 `$TMPDIR` / 磁盘打满 DoS，**非数据泄露或代码执行** —— 这正是它从 P1 降为 P2 的理由。建议：`validateArchiveMembers` 改用 `unzip -Z -v` 取每成员 uncompressed size 求和，超阈值（如 2 GB）在 `ditto` 之前 fail-closed；限制成员总数与 `listingData` 读取上限。这与 `FeedProbeEngine.swift:222-240` 已落地的「流式上限、绝不先收满再判」是同一纪律，目前只在 update 侧存在。
- **（原 P1-6，降级）根密钥明文 `Data` 副本在多条生产路径上未清零，与代码自述不变量矛盾**：`CryptoService.swift:139-140` 声明「every such path now routes through the shared `wipeKeyMaterial` helper」；`wipeKeyMaterial` **全项目 5 处调用**（经核验修正，原写 3 处）—— `CryptoService.swift:328`（测试夹具）、`:595`（`generateAndStoreKey`）、`BackupPackage.swift:691`（包密钥）、`Tests/ClipMemoryTests/CryptoKeyPreparationTests.swift:563` 与 `:567`。未清零的路径：
  - **`CryptoService.swift:300`** `loadKeyData()` → `return cached.withUnsafeBytes { Data($0) }` —— **每次调用都产出一份新 `Data` 且从不 wipe**，这是下游 `:762` 与 `BackupSettingsView.swift:148` 的**共同源头**（核验时补入）
  - `CryptoService.swift:489-503` 迁移路径：`let keyData = readKeyFile(...)` → `SymmetricKey(data: keyData)`，`let` 绑定使其无法就地清零，无 `defer`（与同文件 `:592-595` 的正确写法直接对照）
  - `CryptoService.swift:1102` `decryptLegacy`：`let keyData = key.withUnsafeBytes { Data($0) }`，**每次** legacy 条目解密产生一份未清零副本
  - `ImageStorage.swift:762` 与 `Views/Settings/BackupSettingsView.swift:148`：`guard let key = CryptoService.loadKeyData()`，调用方从不 wipe
  - **影响面**：需本机内存读取原语（`vmmap` + `process_vm_read`，或内存转储 / hibernation 镜像）。拿到即持根密钥 → 可解密全部历史。`clearInMemoryKey:141-146` 只丢 `SymmetricKey` 引用，救不了已复制的 `Data`。
  - **建议**：`loadKeyData()` 改为 `withKeyData<R>(_ body: (inout Data) throws -> R)`（一处修好全部下游），或调用方 `defer { CryptoService.wipeKeyMaterial(&key) }`；迁移路径 `let` 改 `var` + `defer`（注意顺序：`SymmetricKey(data:)` 必须先拷贝再清零，`BackupPackage.swift:230-237` 已记录此坑）。
1. **测试会清空用户真实剪贴板**：`ClipboardMonitorSkipWindowTests.swift:33,37,58,65,85,110`、`ClipboardStoreRTFCacheTests.swift:30,34`、`ClipboardStoreTests.swift:154,198,242`、`CopyOcrTextOwnWriteTests.swift:17,21` 直接写 `NSPasteboard.general`。CI runner 无害（ephemeral），**本地跑测试会摧毁用户当前剪贴板**，且 `ClipboardStoreRTFCacheTests.swift:80` 还把测试字符串留在系统剪贴板上。这是项目 Keychain / Images-Tests / UserDefaults 隔离投入中唯一漏管的真实用户资源通道。
2. **测试直写生产 `UserDefaults.standard` 的 `fontScale`**：`Audit20260720RegressionTests.swift` 的 `:209` / `:247` / `:280` / `:302` 四处写 `fontScale`（经核验修正，原写的 220-293 范围漏了 302），靠 `defer` 恢复；测试中途崩溃或被 CI 15 分钟 timeout `SIGKILL` 时 `defer` 不执行，`fontScale=Double.infinity` 留在生产域。`ZZZSuiteTeardownTests` 只比对 before/after 快照，捕捉不到"改了又改回"。
3. **CI 测试数下限 920 vs 实际 1010**：`ci.yml:191` / `:223` 硬编码 `920`，比实测少 90 —— 删/改 90 个测试仍绿。`ci.yml:161-163` 注释已说明「The 920 threshold is a lower bound — a partial-suite abort that loses more than this many tests fails the gate」，即**语义上是早退保护而非真值校验，设计本身成立**；但硬编码违反 `CLAUDE.md` 的 ID-TEST-0002「测试数唯一 source of truth = `Scripts/test-count.sh`」。**建议**：`ci.yml:191/223` 改为从 `Scripts/test-count.sh` 取值再减余量。
4. **17 个零断言测试**（1010 中的 1.7%）：`SensitiveDetectorTests.swift:120,155`（循环体 `_ = item.isSensitive` 结果丢弃 —— 删掉全部敏感检测逻辑此测试仍绿）、`NetworkMonitorTests.swift:47,55,61`、`ConcurrencyTests.swift:59,169,271,300`、`HotKeyManagerTests.swift:197`、`MemoryWarningTests.swift:46` 等。另 **642/1010（63.5%）测试 ≤2 条断言**。
5. **`.clipmemory` 临时文件权限不一致**：`ShareService.swift:31-34` 把**已解密的图片字节**写到 `$TMPDIR/<UUID>.png`，`data.write(to:options:.atomic)` 无 `attributes`（典型 0644），60 秒后才删 —— 全项目唯一明文剪贴板内容落盘。`BackupPackage.swift:261,470,1175` 的 staging 目录同样未传 `attributes`（默认 0755），与 `ImageStorage.swift:82`（0o700）纪律不一致。macOS 的 `$TMPDIR` 是 per-user 0700，**不是已验证可利用的跨用户读取**，但破坏了自建防御纵深。

### 性能
- **（原 P1-4，降级）`saveItems()` 在主线程同步完成「全量 JSON 编码 + `synchronize()` + 全 blob 回读 memcmp」**：`Services/ClipboardStore+Persistence.swift:49-52`（`itemEncodingQueue.sync { encode }` → `backend.saveBlob`）；`Services/StorageBackend.swift:120-134`（`defaults.set` + `:129 synchronize()` + `:130-131 readBack == data` 全量 `Data` 比较）。`DispatchQueue.sync` 确实会阻塞调用线程，**性能结论成立**。**量级（代码自述，非本次实测）**：`ClipboardStore.swift:1693-1695` 明确记录「With 10K items (10-50MB blob), every capture blocked the main thread 50-200ms for JSON encode + write」。即当前每次 500ms 防抖 flush = 主线程一次 10-50 MB 编码 + `synchronize()` 的 cfprefsd 同步往返 + 10-50 MB 字节比较。**重要背景：这是已知且有意的取舍，不是疏忽** —— `ClipboardStore.swift:1691-1699` 显示作者已识别并**部分**修复（把捕获路径从"每次复制同步写"改成 500ms 防抖），保留了 `saveItems()` 内的 `.sync` hop，理由写为 "CLIP-2's intentional design (encoding off the calling thread, but the caller blocks for the encoded Data)"。**该注释与实现并不矛盾**（它讲的是持久化语义保留在调用方，不是讲非阻塞），本条准确表述是**问题已知、缓解了一半、剩余部分仍未消除**。降级理由：纯性能问题，无数据损坏、无安全影响。**建议**：`queue.async` + continuation 彻底移出主线程；若要保留 `.sync` 作为显式取舍，至少应把 `StorageBackend.saveBlob` 的 `synchronize()` + 全量 read-back 移出主线程 —— 那部分占同步耗时绝大部分且完全不需要主线程。
6. **启动时主线程遍历 `Images/` 目录并逐个 unlink**：`ClipboardStore.swift:1333`（`applyLoadResult` 标 `@MainActor`）→ `ImageStorage.swift:960-984`（`contentsOfDirectory` + 循环 `removeItem`）。第二次及之后每次启动，全部 readdir + unlink 同步在主线程。
7. **启动完整性扫描对每张图完整 AES-GCM 解密后丢弃，行渲染再解一遍**：`ClipboardStore.swift:1485-1505`（`imageStatus` 对 `.available` 直接 `break` 丢掉 `Data`）+ `ImageStorage.swift:595-622`（全量解密）；行渲染 `ClipboardItemRow.swift:605-607` → `ImageStorage.swift:855` 走同一段。单图上限 50MB，200 张 4K 截图即几百 MB 读盘 + 两轮 AES。
8. **搜索归一化缓存只有 `countLimit` 无字节上限**：`Utils/FuzzySearchMatcher.swift:22-28`（`pinyinCache.countLimit = 16_384`）、`:38-42`（`normalizedCache`），均无 `totalCostLimit`，`setObject` 未传 `cost:`，key 是完整正文。**同项目正确做法**就在隔壁：`ClipboardStore.swift:651-652` 给 `contentCache` 设了 `totalCostLimit = 10MB`，`ClipboardStore+Encryption.swift:225` 传了 `cost: plaintext.utf8.count`（ID-PERF-0017 正是修这个 `cost=0` 的坑）。搜索缓存漏了同一处理。
9. **达到 `maxItems` 上限后，每次剪贴板捕获在主线程跑 5 趟 O(n)**：`ClipboardStore.swift:1689-1690`（`addItem` 无条件 `trimToMaxItems()` + `updatePinnedItems()`）→ `:2034-2042`（2 filter + 1 Set + 1 filter）+ `:2285-2287`（`pinnedItems = items.filter`）。`itemsExceedingMaxItems` 的 `guard items.count > maxItems` 只在**恰好等于上限**时短路 —— 而这正是填满后的稳态。n=10K 即每次捕获 5 趟 × n 次 struct 拷贝。
10. **行 body 里同步做 RTF 解密 + 解析**：`ClipboardItemRow.swift:830`（`plainTextFallback` → `store.getRTFPlaintext`）→ `ClipboardStore.swift:1896` + `:1922`。`:822-827` 注释称"走缓存路径"，但冷缓存（内存告警清缓存后 / `.task` 未完成）必走冷路径。搜索路径（`ContentView.swift:334-343`）已正确实现"只读缓存、冷则跳过"，此处未对齐。
11. **图片缓存合计 200 MB 上限**：`ImageStorage.swift:25`（`imageCache` 100MB）+ `:38`（`fullSizeCache` 100MB），cost 模型是 `w*h*4` 完整位图。一张 6144×3456 截图 = 85MB，一张就占满 `fullSizeCache` 预算并把其余 7 个槽位全部挤掉（`countLimit 8` 形同虚设）。
12. **迁移 / OCR 回填合并结果用 O(n) `firstIndex`，整体 O(n·k)**：`ClipboardStore.swift:1466-1476`（legacy 迁移）、`:894-899`（`mergeBackfilledHashes` 在 `for` 循环内）、`ClipboardStore+OCR.swift:64,120`（attach/mark）。同文件 `ClipboardStore.swift:632-636` 已有 `resolvedIndex(for:)`，`+Encryption.swift:341-347` 已是这个写法，可直接照搬。

### CI / 发布 / 依赖
13. **覆盖率门禁形同橡皮章 —— 阈值 2% vs 实测 58.10%**：`ci.yml:366` `COVERAGE_THRESHOLD: '2'`，注释（`:361-365`）称 2026-09-22 实测基线 2.578%。**主 agent 于 2026-09-28 在当前 HEAD 实测：app target 行覆盖率 58.10%（15,647/26,932），双 target 合计 74.352%**。该 2.578% 基线在当前代码上无法复现。脚本默认 30%（`coverage-gate.sh:36`）从未在 CI 生效。允许 **96.6% 的相对退化**后 CI 仍为绿。
14. **`appcast.xml` 缺 3 个已发布 tag + 无 CI 断言**：`appcast.xml` 有 33 个 item，仓库 2.5+ tag 有 33 个，差集为 **2.7.1、2.9.2、2.9.3**（注：两侧数量相等是巧合 —— appcast 另含 2.4.0/2.4.1/2.4.2 三个 <2.5 的历史版本，tag 侧则含 2.5–2.7 区间未进 appcast 的项，两边各抵消 3 个）。且无任何 CI 断言"appcast ⊇ 已发布 tag"，同类缺失会继续静默累积。
15. **Sparkle 签名工具版本与内嵌 framework 版本无耦合**：`release.yml:285-293` 注释与 `:301` 写死下载 Sparkle **2.9.4** 签名工具，并声称 "Pin matches `packages.Sparkle.from: "2.9.4"` in project.yml"；实际 `project.yml:12` = **2.9.5**。注释事实错误，两者可无声分叉。
16. **`ci.yml` 触发器不含 `tags:`**：`ci.yml:3-7` 只有 `branches: [main]`，直接 `git push vX.Y.Z` 时 5 个自研 lint gate 全部跳过，而 `release.yml` 内无任何 lint 步骤。
17. **无自动依赖升级通道**：无 `.github/dependabot.yml`、无 `renovate.json`；`brew install xcodegen` 三处均无版本锁。
18. **一个未定位的 CI-only 测试失败至今无归因**：`README.md:64` 自述 v2.9.3 因 GH Actions `Run tests` substep 失败从未发布，"unconfirmed failing test — 需 GH admin 查 log"。`release.yml:183-195` 注释亦承认 "v2.9.3's failing test was never identified ... Bumping the SyncBarrier timeout is a separate concern (tracked outside this commit)"。**主 agent 本地跑全量 1010 测试 0 失败（47.3s）** —— 说明该失败是 CI 环境特有（runner 负载下的 5s barrier 超时），但**至今没有任何 tracking issue**。v2.9.4 的处理方式是加 `|| true` 绕过（已在 `da3cc6a` revert），根因未修。

### 架构 / 可维护性
19. **`CryptoService.swift` 距 lint 阈值仅 1 行 + `import AppKit` 污染加密内核**：文件 1,249 行，`.swiftlint.yml:60-62` 的 `file_length: error 1250`；同时 `CryptoService.swift:2` `import AppKit`，`:624-682` 的 `presentKeyFailureAlert` 直接 `NSApp.setActivationPolicy` / `NSAlert().runModal()` / `NSApp.terminate`，加密内核无法脱离 AppKit 单测。
20. **`ClipboardStore.swift` 2,305 行且已豁免 lint，注释宣称受约束**：`ClipboardStore.swift:21-22` 注释称"文件约 1480 行"（实际 2,305），`:15` 的 `swiftlint:disable file_length` 使 1,250 行上限对最大文件完全失效。**这条注释最容易误导后续维护者**。
21. **并发纪律全靠注释维持**：`project.yml:20` `SWIFT_STRICT_CONCURRENCY: minimal`，生产代码 `NSLock` 27 处、`OSAllocatedUnfairLock` **0 处**（`ClipboardMonitor.swift:20` 有 1 处但包在 `#available(macOS 14)` 分支内，macOS 13 部署目标下走 NSLock fallback）。`nonisolated(unsafe)` 声明经核验为 **17 处**（原写 6 处，严重低估）—— `ClipboardStore.swift` 独占 11 处（`:648,659,761,762,770,771,1830,1831,1832,1833,1842`）、`LanguageManager.swift` 3 处（`:12,49,74`）、`UpdateService.swift` 2 处（`:186,198`）、`WindowManager.swift` 1 处（`:85`）；另有 3 个 `nonisolated` kernel（`+Encryption.swift:191`、`ClipboardStore.swift:1888`、`+OCR.swift:143`）从 prewarm 的 utility queue（`+Prewarm.swift:141`）与主线程**同时**读写上述共享状态，其线程安全完全由注释契约维持。`docs/SWIFT6_MIGRATION.md` 的 Gate 2（`SWIFT_STRICT_CONCURRENCY=complete` 构建）**未接入任何 CI job** —— 即"并发安全"目前无任何自动门。**建议**：把这 20 个符号的隔离决策依据记入 `docs/SWIFT6_MIGRATION.md` 清单；迁移时优先把 3 个 kernel 收进一个 `DecryptKernel` actor，而非逐个补 `nonisolated(unsafe)`。
22. **`Error 处理模式分布无规则**：全项目 85 个 `catch`，其中 46 个（54%）log-only、18 个 `throw`、3 个 `NSAlert`、1 个 `NotificationCenter`。分布在数据路径上无规律可循，review 时无法做局部判断。P1-1 / P1-2 都是这个分布的直接产物。
23. **三处测试隔离 seam 各自实现**：`WindowManager.swift:85`、`LanguageManager.swift:49`、`UpdateService.swift:186` 三处独立的 `nonisolated(unsafe) static var defaults: UserDefaults = .standard` + 两处 `injectedForTest`，共 5 个全局 seam，改隔离策略需改 5 处。
24. **恢复向导 ViewModel 直访文件系统**（旧 P1-5 唯一残留）：`Views/RestoreWizard/RestoreWizardViewModel.swift:70-77` 自行 `Data(contentsOf:)` + `JSONDecoder().decode([ClipboardItem].self)` + `contentsOfDirectory().hasSuffix(".png")`，与 `Services/BackupService.swift:262-385` 的备份布局知识重复。其余三处旧 P1-5 位置均已修复（`ContentView.swift:142` 改 `@AppStorage`、`WelcomeView.swift:180` 转发 `FirstLaunchService`、App 枚举移入 `AppDiscoveryService.swift:20-60`）。
25. **旧 P1-4 的豁免前提已失效**：`CLAUDE.md:189` WINDOW-P1-4 决策表的豁免理由是"零计划加第三 view"，但当前已有 5 处 `NSHostingView`/`NSHostingController` 构造点（`AppDelegate.swift:374` WelcomeView、`:533`、`:770` SettingsRootView、`RestoreWizardWindowController.swift:41`），后三个绕过 `WindowManager` 的 factory 直接构造。决策表未覆盖这层新增耦合。

---

## 三、P3 摘要

| 项 | 位置 | 说明 |
|---|---|---|
| `"v2"` 格式标记在 AEAD 认证范围之外 | `CryptoService.swift:913-919` | `AES.GCM.seal(bytes, using:)` 无 `authenticating:`，前缀明文且未被 tag 覆盖。本地攻击者删掉前 2 字节可强制降级到 legacy 分支（HMAC 校验在 CBC 解密前完成，**不是** padding oracle，仅可用性/完整性影响）。**注**：旧报告担心的 legacy IV 撞 `"v2"`（~1/65536）已被 `:994-998` 的 fallback + `:1229-1247` 测试夹具闭环。 |
| `time` 依赖与 UI 反馈重复 | `AppDelegate.swift:569-575,606-616,636-644` + `ShareService.swift:173,181,195` | 6 处 `NSAlert` 构造形状重复，throttler 决策散在 3 个闭包 |
| 250ms 去抖 + DispatchSourceTimer 惰性创建各重复 3-4 处 | `ContentView.swift:267-277` / `QuickBarView.swift:151-167`；`+Persistence.swift:57-75,173-186` / `+Tag.swift:161-177` / `TrashStore.swift:322-333` | delay 常量 0.25 在两处各写一遍 |
| 注释/记录与实现不符 4 处 | `ContentView.swift:7-9`（说含 settings Form，已拆独立窗口）、`StartupHealth.swift:15`（说 store 未标 `@MainActor`，`ClipboardStore.swift:96` 已是）、`ClipboardStore.swift:1516/1518` 同一句重复两行 | |
| `CLAUDE.md:107,125,165` 锁类型与符号名过时 | 称用 `OSAllocatedUnfairLock`（实为 NSLock，2026-07-24 C-1 审计为保 macOS 13 兼容回退）、称有 `stateLock` 符号（实际方法名 `withLock`） | 与 `ClipboardMonitor.swift:14-18` 的正确注释矛盾 |
| README 标题版本落后 | 7 个 README 标题均为 `v2.9.2`，changelog 已到 `v2.9.4` | `lint-translations.sh` 7 语种同步检查 PASS，不覆盖标题 |
| `Casks/clipmemory.rb` 停在 2.5.10 | 4 个版本差距，文件内无陈旧标记 | `package.sh:93-112` 已记录为有意保留 |
| `docs/review` / `docs/reviews` / `docs/superpowers` 三套审查目录 | `docs/reviews/` 209 文件但 `git ls-files` 仅 1 个入库 | 无索引文件 |
| `update_cask_sha` 生产无调用方 | `Scripts/package.sh:25-37`，唯一调用者是测试脚本 | 生产路径死代码 |
| `test-count.sh --run` 空匹配静默返回空串 | `Scripts/test-count.sh:42-44`，管道末端是 `sed` | `release.sh:329` 的 `|| echo "?"` 兜不住空串 |

---

## 四、值得肯定的地方

1. **零 force unwrap / `as!` 强转**：生产代码 213 文件中，`[标识符或右括号]!` 形式强解包 **0 处**（精确正则全量扫描确认，排除 `!=` 与注释行）；`as!` 唯一 1 次命中在 `ClipboardMonitor.swift:17` 的注释文字里。`try!` 生产树 **3 处**（经核验修正，原写 4 处 —— `RestoreWizardWindowController.swift:24` 与 `ClipboardItemRow.swift:85` 是 `fatalError("init(coder:)")` 占位而非 `try!`），全在编译期常量正则：`TagSuggestion.swift:278,315`、`HangDetector.swift:135`。
2. **零 TODO/FIXME/HACK**：全生产树 0 处。技术债以带日期的审计 ID 注释形式沉淀，不是散落的 TODO。
3. **零命令注入面**：全生产树 `Process(` 仅 2 处，均用 `executableURL` + `arguments` 数组传绝对路径，无 `sh -c`、无字符串拼接。
4. **legacy 路径是正确的 encrypt-then-MAC**：`CryptoService.swift:1086-1103` 先算 HMAC、用 `constantTimeCompare:1149-1156` 恒定时间比对（`result |= a[i] ^ b[i]`，非常早退），通过后才 `CCCrypt`。`ImageStorage.swift:775-781` 同样已迁到恒定时间比较。pre-1.2.0 的无认证 CBC 分支已彻底删除。
5. **剪贴板内容无出口**：`URL(string:)` 的 4 处调用全是编译期硬编码常量，没有任何路径把剪贴板文本 URL 化后交给 `NSWorkspace.open` 或 URL scheme handler —— 不存在 `file://` 劫持面。
6. **日志无明文**：`privacy: .public` 全项目 48 处，逐条核对后只出现 UUID、字节数、类型名、OSStatus、路径；`UIObservability.swift:66` 搜索埋点只记 `length`，不记查询词。
7. **versioned `itemIndex` 的失效契约完整**：`ClipboardStore.swift:576-599` 定义失效点，14 处 `items` 重排写入点**每一处**后面都紧跟 `invalidateItemIndex()`，另 4 处只改字段不改顺序的索引仍有效。PR #54 的前提没有被破坏 —— 这是最容易悄悄回归的契约，目前守住了。
8. **`StorageBackend.swift:96-119` 诚实标注了修复边界**：明确写出 read-back 能捕获什么（in-memory set 失败）、**不能**捕获什么（异步 daemon flush 失败、set 后进程崩溃），并给出"数据将在下次进程重启时静默消失"的后果陈述。
9. **7 语种 L10n 同步检查通过**：`Scripts/lint-translations.sh` → PASS，288 keys × 7 语言全绿。
10. **工程文档质量高**：`docs/SWIFT6_MIGRATION.md` 的行号引用（`:23` 指 `project.yml:20`、`:122` 指 `project.yml:9-12`）经核对**均正确**；发布流水线对 EdDSA 私钥（`umask 077` + `mktemp` + `chmod 600` + `rm -P` 三覆写）与 TAP token（只走一次性 extraheader，先 `unset-all` 避免双 Authorization）的处理是教科书级。
11. **测试隔离投入远超同类项目**：Keychain 独立 service、Images 重定向、UserDefaults suite、ZZZ canary 校准、网络全 `URLProtocol` mock、文件系统顺序显式 `.sorted()`。唯一漏管的是真实剪贴板（见 P2-1）。

---

## 五、修复优先级建议

**第一批（数据丢失路径，改动小、收益最大）**
1. P1-1 `saveTags()` —— **必须先给 `FileStorageBackend.saveTags` 加 read-back**（`defaults.set` 不抛错，磁盘满时 catch 不可达），再补三环
2. P1-2 图片写盘失败通知 —— 复用 `saveAlertThrottler`（`AppDelegate.swift:85`）
3. P1-3 `.tagBackendCorrupted` 接 `DiagnosticsBanner`（`tagsLoadFailed` 字段，UI 零新增）

> 这三条是同一个项目铁律（`CLAUDE.md` 的三环节标准）的三处漏网，且 P1-1 是已修过两次的同型复发。

**第二批（发布与 CI 正确性）**

4. P1-5 appcast 强推旁路 —— 改 `if` 分支嵌套，2 行
5. P1-6 `declare -A` bash 3.2 —— 改平行数组，10 行
6. P1-4 TSan 判定门 —— 加 3 行 grep 判定

**第三批（安全加固）**

7. P2-0a 根密钥 `loadKeyData():300` 改为 `withKeyData` 作用域式 wipe —— 一处修好全部下游
8. P2-0b zip bomb 上限 —— `validateArchiveMembers` 加 size 求和

**第四批（性能，需先 profiling 再定优先级）**

9. P2-0c `saveItems` 主线程同步（已知取舍，剩余部分未消除）
10. P2-8 搜索缓存 `totalCostLimit`（照抄 `contentCache` 的写法）
11. P2-6/7 启动主线程 I/O 与双份解密

**第五批（门禁与文档一致性）**

12. P2-13 覆盖率阈值：先做 1-11 项，用实测新基线定阈值（当前实测 58.10%，可设 50%）
13. P2-3 测试数下限脚本化，落实 ID-TEST-0002
14. P2-14 `appcast ⊇ tags` CI 断言
15. P2-4 修 17 个零断言测试（`SensitiveDetectorTests:120,155` 只需 2 行）
16. P2-1 剪贴板隔离（4 文件 × 6 行）

---

## 六、旧报告 P1 状态核验（`code-review-2026-09-21.md`）

> 以下 7 条经**独立 verifier 逐一复核，零误判**（verifier 用 `grep`/直读独立验证了行号与语义，包括确认 8 个 golden PNG 确已入库、`handlePathUpdate` 确从未被调用）。

| 旧 P1 | 状态 | 证据 |
|---|---|---|
| P1-1 TrashStore 损坏哨兵永不清理 | ✅ **已修复** | `TrashStore.swift:206` 成功路径 `removeObject(forKey: loadFailedSentinelKey)` |
| P1-2 `validateExternalPackage` 绕过 zip-slip 三道防线 | ✅ **已修复** | `BackupPackage.swift:1185` 改走 `unzipArchive(url, to: staging)`，与 `importPackage:625` 同一封装；`runDitto:346` 30s 超时 + `validateExtractedTree` 均接入 |
| P1-3 TrashStore 保存重试是死代码 | ✅ **已修复** | `TrashStore.swift:297` 先 `needsSave = true`，`:302` 再 `scheduleSaveRetry()` |
| P1-4 Services 依赖具体 View 类型 | ✅ **已修复** (ID-CRASH-0032) | `WindowManager` 加 4 个 factory closures (`welcomeViewFactory` / `settingsRootViewFactory` / `recentCrashesViewFactory` / `restoreWizardViewFactory`)。`AppDelegate` 与 `RestoreWizardWindowController` 改走 factory；4 个 NSHosting bypass site 现走单点；豁免前提 (`P2-25`) 同步闭合。`CLAUDE.md:189` 决策行待重新审计（见 §九） |
| P1-5 View 层直访 UserDefaults / 文件系统 | ✅ **已修复** (ID-CRASH-0026) | 4 处中第 4 处（`RestoreWizardViewModel.swift:70-77`）改走 `BackupService.previewCounts(for:)`；7 个新增测试覆盖（含 falsifiable non-zero assertion ID-CRASH-0026 v3） |
| P1-6 快照测试在 CI 空转 | ✅ **已修复** | `SnapshotTestHelpers.swift:125-134` golden 缺失改 `XCTFail`；`.gitignore:14-15` 忽略规则已注释掉；8 个 golden PNG 已入库（`git ls-files` 精确 8 个） |
| P1-7 NetworkMonitor 状态机无行为测试 | ⚠️ **部分修复** | 已抽出 `NetworkMonitorProtocol` + Mock；但生产 `handlePathUpdate`（`NetworkMonitor.swift:123-152`）在全部测试中**从未被调用**（verifier 用 grep 独立确认仅命中定义与生产调用点），3 个分支零执行覆盖。**本次 P2 batch 未触碰**（NetworkMonitor 行为测试超出本批 scope；剩余工作见 §九） |

---

## 七、验证记录

### 7.1 主 agent 实测

| 项 | 命令 | 结果 |
|---|---|---|
| Release 构建 | `xcodebuild -scheme ClipMemory -configuration Release build` | **BUILD SUCCEEDED** |
| 全量测试 | `xcodebuild test -configuration Debug` | **1010 tests, 0 failures, 47.318s** |
| 覆盖率（实测） | `xcrun xccov view --report --json` | app **58.10%**（15,647/26,932）/ xctest 92.33% / 合计 **74.352%** |
| 目录级覆盖率 | 同上，按目录聚合 | Utils 100% · Models 94.2% · Services 81.0% · AppDelegate 65.3% · **Views 38.2%** |
| 零覆盖文件 | 同上 | app target 94 个文件中 **15 个 0%**，21 个 <20% |
| bash 3.2 兼容性 | `/bin/bash -c 'set -euo pipefail; declare -A m=()'` | **exit 2**（`declare: -A: invalid option`） |
| 7 语种 L10n | `bash Scripts/lint-translations.sh` | **PASS**（288 keys × 7） |
| appcast 覆盖 | `comm` 比对 appcast item 与 git tag | 缺 **2.7.1 / 2.9.2 / 2.9.3** |
| 测试数 | `./Scripts/test-count.sh` | 静态估计 **1011**，实际执行 **1010** |

### 7.2 独立 verifier 核验结果（VERDICT: PARTIAL → 已修正）

报告落盘后另派一轮**对抗式 verifier**（任务定位为"挑错，不是赞美"），核验 44 条 + 11 条肯定项 + 7 条旧 P1 + 9 项实测数据：

| 维度 | 结果 |
|---|---|
| 核实无误（行号 + 事实 + 因果均对） | 33 / 44 |
| 行号偏差（1-3 行内） | 6（已全部修正） |
| 严重度相对本报告定义虚高 | 3（原 P1-4/5/6，**已降为 P2**） |
| 因果断言错误 | 2（原 P1-4「前提不成立」、P2-3「自相矛盾」，已改写） |
| 重复计数 / 已修复误判 | **0 / 0** |
| 数字低估自身发现 | 1（P2-21 `nonisolated(unsafe)` 6 → **17**，已修正） |
| 修复建议不可行 | 1（P1-1 只补 catch 解决不了磁盘满，**已重写为三步**） |

**可复现项 verifier 独立通过 3/3**：bash 3.2 exit 2、7 语种 288 keys PASS、appcast 缺 3 tag。覆盖率与测试数因无 xcresult 产物未复现，verifier 明确标注「不判错」。

### 7.3 方法学与已知局限

- 5 路子 agent 均为只读（`explore` 类型，禁止改文件）；主 agent 对每条 P1 与关键 P2 逐条直读源码复核。
- **过程��发现并丢弃 2 条问题**：① 架构 agent 报告的"`validateExternalPackage` 绕过 zip-slip 防线"使用过时行号，主 agent 直读 `BackupPackage.swift:1185` 确认已修复（安全 agent 独立得出相同结论），已剔除；② verifier 指出本报告自身 3 条 P1 标签通胀 + 1 条修复建议不可行，均已按其意见修正并保留审计轨迹。
- **未验证项**：所有性能类发现的毫秒数均为代码注释或文档中的历史记录，非本次实测 —— 需 Instruments（Time Profiler / Allocations）+ 真实 10K items 库验证后再定优先级。TSan nightly 历史上是否真检出过 race，需查 GitHub workflow 日志，本地无访问权限。verifier 未能复现覆盖率/测试数两项（本环境无 xcresult 产物），但其对这两项**未提出异议**。

---

## 八、本批 P1/P2/P3 闭合状态 (2026-09-29 ID-CRASH-0007..0045)

本报告的 6 个 P1 + 18 个 P2 + 10 个 P3 项**全部 ship 到 origin/main** (HEAD `2e04cd6`)，按 ID-CRASH-NNNN 编号落实。每项的「修复」列在 `docs/audit/code-review-2026-09-28-backlog.md`（committed at `2e04cd6` 的同一 batch）有完整列表 — 按 commit hash + diff sketch + 验证记录。

数字摘要：

- **P1 6/6** (0007 saveTags / 0008 tagBackendCorrupted / 0009 TSan gate / 0010 appcast force / 0011 bash 3.2 / 0012 imageSaveFailed)
- **P2 18/18** (0013 appcast lint / 0014 test count / 0015 coverage 50% / 0016 zip-bomb / 0017 zero-assert / 0018 pasteboard cleanup / 0019 ci tags / 0020 cache-first / 0021 search cache / 0022 root-key wipe / 0023 resolvedIndex / 0024 Sparkle doc / 0026 RestoreWizard FS / 0027 maxItems 2-pass / 0028 fullSizeCache / 0031 orphan sweep / 0033 thumbnail prepopulate / 0035 saveBlob off-main)
- **P3 12/13** — 0034 CryptoService AppKit-free / 0036 dependabot / 0037 issue #93 / 0038 7 README / 0039 update_cask_sha TEST-ONLY / 0040 SearchDebounce / 0041 settings Form doc / 0042+0043 stale comments / 0044 saveDebounce consolidation / 0030 Swift6 §8 roster / 0025 line-count doc — 共 12 项闭合。

剩余 work 详见 §九（每项已 track 在本地 ledger 或 GitHub issue）。

---

## 九、Remaining / Deferred (out-of-scope for this batch)

| 项 | 来源 | 状态 | 跟踪 |
|---|---|---|---|
| **NetworkMonitor.handlePathUpdate 0 覆盖** | 旧 P1-7 (本表 row 201) | 协议抽出来了但生产路径无测试调用 | 待单独 audit batch；3 个分支 zero execution coverage |
| **`CLAUDE.md:189` 决策表重审** | 旧 P1-4 + P2-25 | WindowManager factory 闭合后豁免前提已修正，但文档未重写 | 本地 CLAUDE.md (gitignored, `.gitignore:23`) |
| **`CLAUDE.md:107, :125, :165` lock-type stale** | P3 #5 audit | 文档说 `OSAllocatedUnfairLock`，实际代码已退到 `NSLock`（macOS 13 部署目标） | 本地 CLAUDE.md (gitignored) |
| **CryptoService 拆 4 unit (Keychain/Cipher/Legacy/Migration)** | P2-19 audit | ID-CRASH-0034 仅拆 AppKit 依赖，文件 ~1290 行仍 `// swiftlint:disable file_length` | CRYPTO-LINT-0001 (本地 ledger) |
| **Swift6 actor isolation (Phase 3)** | P2-21/22 + SWIFT6_MIGRATION.md:65 | ID-CRASH-0030 仅做 §8 roster doc，actor refactor 待 Phase 3 | docs/SWIFT6_MIGRATION.md:65 |
| **v2.9.3 CI test failure per-test identification** | P2-18 audit | 已知 CI 环境失败，local 1019/1019 GREEN，per-test 还需 GH admin 查 log | https://github.com/irykelee/clipmemory/issues/93 |
| **`code-review-2026-09-21.md` 7 P1 中 P1-4/P1-5/P1-7 row 反向更新** | 本批 closure | 旧 audit 的 audit-tracking 表未同步本批结果 | 待 `code-review-2026-09-21.md` 维护 commit (下次 audit session) |

---

*Last updated: 2026-09-29 — Section 1-9 updated, §六 audit-tracking table reconciled with batch ID-CRASH-0007..0045.*
