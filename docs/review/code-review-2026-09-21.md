# ClipMemory 全面代码审查报告

- 日期：2026-09-21
- 范围：`ClipMemory/`（90 源文件，约 23.3k LOC）、`Tests/ClipMemoryTests/`（103 文件，约 22.6k LOC，静态估算见 `Scripts/test-count.sh`）、`.github/workflows/`、`Scripts/`、构建配置
- 方法：4 路并行审查（架构/规范、缺陷/边界、安全/性能、测试/CI），全部 P1 级发现经人工读码复核确认
- 基线：已与 `CLAUDE.md`「有意保留决策」表及既有 ID-XXX 审计修复去重，本报告只列**新发现**

## 严重度定义

| 级别 | 含义 |
|---|---|
| P1 | 可造成数据丢失 / 安全防线旁路 / 核心能力无回归保护，应尽快修复 |
| P2 | 明确的缺陷或债务，有实际影响但不紧急 |
| P3 | 次要问题、风格漂移、理论性风险 |

---

## 一、P1 发现（7 项，均已核实）

### P1-1 TrashStore 损坏哨兵永不清理 → 回收站跨启动永久失败态
- 证据：`Services/TrashStore.swift:170` 写入哨兵，`:132-133` 读取；全文件无任何 `removeObject(forKey: sentinelKey)`。成功加载路径 `:162-163` 只重置 `lastLoadFailed=false`，不清哨兵。
- 影响：一次 blob 损坏后，**每次**启动都在 `:143` 早退，`trashedItems=[]`；用户新存入回收站的内容保存成功但下次启动仍被吞掉——跨启动永久丢失。且 `lastLoadFailed` 恒 true 使 `ClipboardStore.loadItems:1052-1056` 永久跳过 `cleanupOrphanedImages`，图片只增不减。`:44` 注释声称"cleared on the next successful loadTrashedItems()"与实现不符。讽刺的是 H-2 修复本身正是为防哨兵后的二次故障，但哨兵本身成了新故障源。
- 建议：`loadTrashedItems()` 成功 `backend.load()` 后 `defaults.removeObject(forKey: sentinelKey)`，并补跨启动回归测试。

### P1-2 导入向导 `validateExternalPackage` 绕过 zip-slip 三道防线
- 证据：`Services/BackupPackage.swift:1155-1169` 直接 `Process /usr/bin/ditto -x -k` 解包外部 `.clipmemory` 到 staging；而同文件 `:255-264` 的 `unzipArchive`（解包前 `validateArchiveMembers:274` 拒 `../`/绝对路径/反斜杠，解包后 `validateExtractedTree:309` 查符号链接/落点）被正式导入路径 `importPackage:607` 使用。注释自称"same archive path as importPackage"——**不属实**，import 走的是带校验封装。此外该处 `waitUntilExit()` 无超时（对比 `runDitto:369` 有 30s 上限）。
- 影响：恶意包经邮件/IM 投递，用户在向导里选中文件（尚未输密码）即触发裸解包，`../` 成员以用户权限写到 staging 之外。这是全项目安全设计最完整的一道防线被一条旁路路径单独穿透。
- 建议：改用 `unzipArchive(archive, to: staging)`，一行改动即闭环。

### P1-3 TrashStore 保存重试（ID-STORE-0019）是死代码，违反三环节标准
- 证据：`TrashStore.swift:375-376` `flushSave()` 先置 `needsSave=false` 再调 `saveTrashedItems()`；失败进 `scheduleSaveRetry():264` 时 `guard needsSave else { return }` 立即返回——重试**永不排程**。对照正确写法 `ClipboardStore+Persistence.swift:40-44`（注释明确记录 H-1 教训：曾同样因 needsSave=false 导致静默丢失）。
- 影响：回收站保存失败时三环节中"重试"leg 缺失，仅剩通知；用户不再产生新 mutation 即退出则改动丢失。这是 H-1 已修过的 bug 模式在 TrashStore 抽出时（2026-07-26）的复发。
- 建议：失败分支先 `needsSave = true` 再 `scheduleSaveRetry()`。

### P1-4 Services 层编译期依赖具体 View 类型
- 证据：`Services/WindowManager.swift:56`（`NSHostingController<QuickBarView>?`）、`:59`（`ContentView?`）、`:72-74`（默认工厂闭包直接构造 `ContentView()` / `QuickBarView(...)`）。
- 影响：分层约定（Services 不依赖 Views）被打破，`WindowManager` 无法脱离 UI 单测，View 重构会波及 Services 层；此耦合未记录在「有意保留决策」表中，属未申报的架构例外。
- 建议：类型擦除（`AnyView` 或协议化 content provider），由 AppDelegate 注入；或正式记入决策表豁免。

### P1-5 View 层直接访问 UserDefaults / 文件系统，绕开集中抽象
- 证据：`Views/ContentView.swift:137,286` 自行 JSON 编解码 `collapsedGroups`；`Views/WelcomeView.swift:170-179` View 文件内定义 `class FirstLaunchManager` 直写 `UserDefaults.standard`；`Views/Settings/HistoryCaptureSettingsView.swift:510-539` View 方法内用 `FileManager` 扫 `/Applications`、`NSHomeDirectory()` 拼路径。
- 影响：绕开 `StorageBackend`/`AppDirectories` 抽象；`HistoryCaptureSettingsView` 的扫盘逻辑无法脱离磁盘单测；key/路径变更时无法一处收敛。
- 建议：下沉为 store 属性或 `@AppStorage`；App 枚举移入独立 Service。

### P1-6 快照测试在 CI 中空转（零回归价值）
- 证据：`Tests/ClipMemoryTests/SnapshotTestHelpers.swift:93-97` 规定 golden 缺失时"录制并通过"；`.gitignore:15` 忽略 `__Snapshots__/`（`git check-ignore` 确认）。CI 每次全新 checkout → 永远走"录制并通过"分支，4 个快照套件从不真正比对。
- 影响：快照测试投入（helpers、专项套件）与收益完全脱钩，UI 回归靠它"看起来有防护"。
- 建议：golden PNG 提交入库（或走 LFS），首跑缺失改为 XCTFail + 显式录制命令。

### P1-7 NetworkMonitor 核心状态机无行为测试
- 证据：`Tests/ClipMemoryTests/NetworkMonitorTests.swift:56-70` 文件自述承认真实 `NWPathMonitor` 转换逻辑无法驱动，4 个测试仅断言单例同一性/通知名常量/reset 幂等；`testStartIsIdempotent:104` 调真实 `start()` 后故意不 `stop()`。
- 影响：MEDIUM-6 修复的原始 bug 场景无回归保护。
- 建议：为路径监控协议化注入（项目已有 `OCRServiceProtocol` 先例），补状态转换测试。

---

## 二、P2 发现（按维度分组）

### 缺陷 / 边界
1. **legacy 密文 IV 前缀撞 "v2" → 条目永久标记解密失败**：`CryptoService.swift:910,950-953` 以 `prefix(2)=="v2"` 分类，legacy 载荷前两字节是随机 IV，碰撞概率约 1/65536/条；误判后 `:809-811` 永久标记，`migrateToV2:957-965` 对"已带 v2"直接跳过，永不修复。建议：判定为 v2 但 GCM 解析失败时兜底尝试 legacy 解密（仅对 v1 存量）。
2. **FileStorageBackend.saveBlob 无法感知写失败**：`StorageBackend.swift:90-92` `defaults.set` 无失败检查，磁盘满/权限错误静默，H-1 三环节对真实落盘失效。建议：set 后 read-back 校验。
3. **Keychain 迁移失败时明文根密钥滞留磁盘且仅 silent log**：`CryptoService.swift:489-503` `keyStore.store` 失败保留 `.encryption_key` 文件、仅 `logger.error`，无 UI 可见路径——违反三环节标准第 3 环。
4. **restoreFromTrash 不 trim 不去重**：`ClipboardStore.swift:1756-1764` 批量恢复可超 10K 上限、产生重复条目。
5. **deleteTag 留下悬空 tagId**：`ClipboardStore.swift:1238-1247` 入回收站条目仍持有已删标签，恢复后显示幽灵标签。
6. **敏感检测对 >50KB 内容直接放行**：`ClipboardMonitor.swift:603` `detectSensitive` 返回 false，超长敏感内容不标记（未见豁免注释）。
7. **纯空白内容仍入库**：`ClipboardMonitor.swift:409` 只查 `isEmpty`；`:586-591` richText 条目无 contentHash 永不参与去重；`:307,310` HMAC 失败回退弱指纹可误吞同尺寸图像。

### 架构 / 规范
8. **ClipboardStore 仍为 god object 且 lint 上限被文件级 disable 屏蔽**：`ClipboardStore.swift` 2129 行 / 69 func / 19 个 `@Published`，`:15` `// swiftlint:disable file_length` 使 `.swiftlint.yml:60` 的 error:1250 对最大文件完全失效。建议：撤销 disable、按 TrashStore 模式抽出 TagStore。
9. **UserDefaults key 常量被 10+ 处字面量绕过**：定义于 `ClipboardStore.swift:343,351`、`TrashStore.swift:38`，绕过于 `BackupService.swift:325-327`、`BackupPackage.swift:431-433,477-487`、`StorageBackend.swift:69`。重命名时备份/导出静默读空。
10. **备份落盘逻辑双份**：`BackupService.swift:324-347` 与 `BackupPackage.swift:467-498` 各自维护 blobs 表；新增数据类型必然分叉。
11. **审计 ID 体系名存实亡**：6+ 套格式并存（`ID-*`/`H-N`/`M-N`/`L-N`/`BUG-`/`NEW-`/裸 `HIGH-N`），`Scripts/lint-audit-ids.sh:46` 的 `BAD_PATTERN` 只匹配全拼、实跑对含 `H-1/M-23/L-7` 的文件输出 PASS（已复现）；映射表在仓库外。
12. **文件归层错位**：`Services/RestoreMode.swift`/`SaveRetryState.swift`/`LocalBackup.swift` 是纯模型；`Views/TagPickerLogic.swift`/`NewTagLogic.swift`/`SidebarTagFilter.swift`/`ColorHex.swift` 零 View；`ClipboardStore+Diagnostics.swift`（16 行）不含 extension。

### 性能
13. **剪贴板捕获路径主线程全量重编码**：`ClipboardStore.swift:1475` → `saveImmediately` → `flushSave`，10K 条目（10–50MB blob）时每次复制约 50–200ms 主线程停顿；`.sync` hop 是 CLIP-2 有意设计，但捕获路径绕过 500ms debounce 未被决策覆盖。建议：捕获改走 debounce，或 encode+set 全后台化、termination 处信号量收口。
14. **启动主线程全量解码**：`StorageBackend.swift:74-79` + `ClipboardStore.swift:536`，10K 条目约 100–300ms 一次性。
15. **OCR 明文绕过 NSCache cost 上限**：`ClipboardStore+OCR.swift:148` `setObject` 未传 `cost:`，ID-PERF-0017 的 totalCostLimit 对 `.ocr` 键不生效。
16. **图片行全尺寸解码**：`ImageStorage.swift:784-810`（代码注释已自认 downscale 为 follow-up，列为跟踪项）。

### 测试 / CI
17. **无覆盖率门禁**：全仓无 `xccov`/codecov 消费，根目录游离 `default.profraw`；测试数下限只能防"跑少了"，防不了"测薄了"。
18. **SwiftLint 不在 CI**：`ci.yml` 只有三个 bash lint；SwiftLint 仅本地 `release.sh:733`，而 `ci.yml:22-24` 自认全局 `core.hooksPath` 可绕过本地钩子——声称"CI 是唯一自动门禁"却不含 SwiftLint。
19. **无测试覆盖**：`Utils/DateHelpers.swift`（89 行，含 NSLock+DateFormatter 并发缓存，零引用）、`Utils/RichTextParser.swift`（畸形 base64/fallback 分支无直接断言）、`LocalizationService` 行为层（key 齐全性测试 ≠ 行为测试）。
20. **忙等模式**：7 处 `Thread.sleep`（`UpdateServiceTests.swift:938`、`BackupServiceTests.swift:122,423,491,516`）+ 约 15 处 `RunLoop.main.run(until:)`；CI 串行跑 en+zh 两套全量、无 `-parallel-testing`（但注意 P2-21）。
21. **测试字母序耦合无防护**：AAA/ZZZ canary 依赖串行字母序执行，一旦未来开启并行测试全部失效，代码与 project.yml 中无任何防护注释。

---

## 三、P3 摘要

- AES-GCM 未用 AAD（`CryptoService.swift:891`）：可整条搬移密文实现条目互换；同密钥复用于 GCM 与去重 HMAC（:881）属理论性。建议 itemID 作 AAD（需格式版本化）。
- `ShareService.swift:31-38` 明文图片落 $TMPDIR，60s 普通删除（per-user 0700 已收窄暴露面）；文件名取 `item.content` 未见路径校验（来源受 ImageStorage UUID 约束，需人工确认导入链外路径）。
- `AppDelegate.swift:468` 以 `$0.title == "Help"` 字面量匹配菜单，非英文 locale 下重复创建 Help 菜单。
- `ClipboardMonitor` 边界一组：空白入库、富文本无 hash、弱指纹回退（已并入 P2-7 明细）。
- 命名零星：`RestoreWizardView.swift:59` 全仓唯一未走 `sz()` 的硬编码字号；6 个无子类的 `class` 缺 `final`；`CLAUDE.md` 结构图落后实际文件 42/90 未列；`.swiftlint.yml:4` 引用了不存在的 AGENTS.md。
- `moveToTrash`/`restoreFromTrash` 的 didMove 闭包重复 3 次（`ClipboardStore.swift:1724-1756`）。
- TSan 为 advisory（`tsan.yml` continue-on-error，设计良好，仅记录）；CI 测试数下限硬编码两处（`ci.yml:159,175`）。
- `GITEE_TOKEN` 内嵌 query/URL（`sync_gitee_release.sh:145`，输出已 redact，低风险）。
- 需人工确认 2 处：`AppDelegate.swift:207-213` 后台队列调 `@MainActor flushPendingSaves()` 的隔离旁路；`quarantineCorruptBlob` 用 `UserDefaults.standard` 而非注入 suite 的测试污染风险。

## 四、值得肯定的方面

- 加密核心经多轮审计相当扎实：nonce 随机、legacy MAC-then-encrypt + constant-time 比较（:999）、pre-1.2.0 无 MAC 分支拒收、PBKDF2 600k + 随机盐、三条更新 feed 全 HTTPS + EdDSA 无降级、Keychain AfterFirstUnlockThisDeviceOnly + 锁屏清内存密钥、日志面全量 grep 无明文泄漏。
- 并发/持久化纪律高于同规模项目：强制解包仅 15 处、`try!` 3 处、空 catch 0 处、`swiftlint:disable` 仅 7 处；quarantine/orphan 保护、错误三环节大多有审计编号闭环。
- 断言质量好：XCTAssertEqual 1012 次 vs XCTAssertNotNil 123 次；Keychain 测试不碰生产密钥。
- 搜索性能（normalizedCache + versioned itemIndex，11×）、内存预警清理对称性、测试基建（canary/污染白名单/双 locale 矩阵）成熟。

## 五、修复优先级建议

| 序 | 项 | 成本 | 一句话 |
|---|---|---|---|
| 1 | P1-2 validate 旁路 | 一行 | 换用 `unzipArchive` |
| 2 | P1-1 哨兵清算 | 小 | 成功加载后 removeObject + 回归测试 |
| 3 | P1-3 Trash 重试 | 小 | 失败分支先置 `needsSave=true` |
| 4 | P1-6 快照 golden 入库 | 小 | 缺失即 XCTFail |
| 5 | P2-9 key 常量收敛 | 小 | 高收益防"静默读空" |
| 6 | P1-4/5 分层修复 | 中 | WindowManager 类型擦除；View 存储访问下沉 |
| 7 | P2-13/14 主线程编解码 | 中 | 捕获走 debounce、启动解码后台化 |
| 8 | P2-17/18 CI 补覆盖率 + SwiftLint | 中 | 唯一 pre-merge 门禁应含 lint |
| 9 | P2-11 ID lint 正则修补 | 小 | 补 `\b[HML]-[0-9]+\b`，映射表入 docs/ |
| 10 | P2-1 IV 碰撞兜底 | 小 | v2 解析失败时补一次 legacy 尝试 |

## 六、总体评价

这是一个经过多轮自我审计、纪律罕见的健康代码库——大部分传统风险（force unwrap、空 catch、明文泄漏、SQL/命令注入面）已被系统性清剿。残余风险高度集中在两个模式上：**（a）跨启动状态机缺少"成功即清算"的对称清理**（哨兵永不清除、IV 碰撞与 decryptionFailed 交互、Trash 重试死代码——三者同根），**（b）新增旁路路径未复用主路径防线**（validate 绕过 zip 校验、View 直访存储、CI 绕过 SwiftLint）。建议按第五节顺序先做四个小成本 P1 修复，再将分层与主线程 I/O 纳入 Swift 6 迁移路线图（`docs/SWIFT6_MIGRATION.md`）一并推进。
