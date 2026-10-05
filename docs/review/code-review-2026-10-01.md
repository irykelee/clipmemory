# ClipMemory 全面代码审查报告

- **日期**：2026-10-01
- **基线**：`main` @ `c3ce6c3`（v2.9.5），仅基于最新代码，不考虑既有文档与路线图
- **范围**：26,385 行 Swift / 103 个源文件 / 112 个测试 Swift 文件（1,021 个测试函数）
- **方法**：5 个维度并行深度审查（架构与核心链路、存储/加密/备份安全、UI 层与代码质量、并发与性能缺陷、构建配置与工程化），关键结论经实机验证与抽查复核（本机 plist 解码、目录权限实测、4 处 P0/P1 论断逐条比对源码）
- **关联**：前次审查见 `code-review-2026-09-21.md`、`code-review-2026-09-28.md`

---

## 总体结论

这是一个工程纪律远超同类个人项目的代码库——AES-GCM 全线认证加密、审计 ID 可追溯、fail-closed 文化贯穿、本地化与无障碍几乎零漏网。但项目呈现明显的"补丁驱动演进"形态：**最底层的"全量历史塞进单个 UserDefaults blob"这一决策从未被推翻**，大量复杂度（加载竞态防御、terminate 三重 flush、保存失败重试梯子）本质上都是在为这个地基打补丁；加上 ClipboardStore 与 AppDelegate 两个 god object、发布链签名/公证缺位，构成了当前的三块结构性债务。

- 未发现 P0 级安全漏洞
- 发现 2 个 P0 级工程风险、约 15 个 P1 级问题（清单见文末总表）

---

## 一、项目结构与模块职责

**做得好的**：分层意图清晰（Models / Services 49 个文件 / Utils / Views）；`UserDefaultsKey` 集中注册表；`ServiceProtocols` 的多数协议是真抽象（`StorageBackend` 有 7 个测试 conformer、`CryptoServiceProtocol` 有 35 处注入、`OCRServiceProtocol` 有 5 个 mock）；注释中的审计 ID + 日期 + 复盘让每次修复可追溯。

| 优先级 | 问题 | 证据 |
|---|---|---|
| P1 | **ClipboardStore 是事实上的 god object**：主文件 2417 行 + 8 个扩展 ≈ 4000 行，同时承担条目存储、去重、加解密缓存、预热、OCR 编排、标签、垃圾桶转发、设置项存储。Swift 扩展不能有存储属性，导致 **14+ 处 `private → internal` 松绑**，8 个扩展文件可跨文件读写全部状态（saveTimer/tagSaveTimer/prewarmState/pendingFailedIDs/两把 NSCache/itemIndex 三件套/encryptedTagNamesBackup）。修改 prewarm 的人必须理解 pendingFailedIDs 的锁纪律；6 个 `nonisolated(unsafe)` 状态靠注释锁约束 | `ClipboardStore.swift:15-28`（自注 "god-object breakup is a deliberate defer"）、`611-614`、`786-790`、`805-815` |
| P1 | **AppDelegate 是第二个 god object**（1103 行）：直接手写构建 welcome/settings/recentCrashes 三个窗口（WindowManager 名存实亡，只被动接收 `registerSecondaryWindow`）、Keychain 重试策略（含 3s 魔法数延迟）、prewarm 5s 节流、3 个告警节流器，注册 ~15 个通知 observer，是事实上的通知总线。ID-LIFE-0020/0021 两轮窗口生命周期修复证明这套手写逻辑反复出 bug | `AppDelegate.swift:406-409`、`842-856`、`560-573`、`743-760` |
| P1 | **测试隔离靠环境探针而非依赖注入**：27 处 `XCTestConfigurationFilePath` 分支深埋生产路径（AppDelegate 9 处，另见 CryptoService/ImageStorage/UpdateService/ServiceProtocols）。例如 `addItem` 尾部 prewarm 在测试中被静默跳过——该逻辑从未被测试覆盖。`ServiceContainer` 用 `preconditionFailure` 挡生产 swap，注释自认 "完整修复是 DI via init injection (deferred)" | `ClipboardStore.swift:393-396`、`1801`；`AppDelegate.swift:155, 194, 594...`；`ServiceProtocols.swift:51-59` |
| P1 | **`pinnedItems` 是手工维护的第二份真相**：14 处 `updatePinnedItems()` 调用点靠纪律保持同步（mergePendingDecryptionFailures 原地改 items 就不调它，靠"不影响 pinned 判定"的隐式推理维持正确）；`invalidateItemIndex()` 同样靠 8 处手工调用 | `ClipboardStore.swift:127`、`2397-2399`、`636-638` |
| P2 | 四种跨模块通信机制混用（NotificationCenter / Combine / delegate / 闭包注入），一条"保存失败"要经 notification → AppDelegate observer → throttler → NSAlert 四跳；含用字符串字面量绕过类型检查的通知名 `Notification.Name("NetworkMonitor.didBecomeReachable")`。三种配置持久化范式并存（`@Published+didSet`、手写 NSLock+手动 send、直接读 UserDefaults——后者不触发 UI 刷新，设置项散落三处） | `ClipboardStore.swift:30-96`；`AppDelegate.swift:350`；`ClipboardStore+OCR.swift:17-31`（`ocrEnabled` 翻转后设置页不刷新） |
| P2 | 协议抽象局部伪抽象：`ClipboardStore` 自身无协议（`ContentView.swift:98` 默认值直连单例无法替身）；WindowManager 的 view factory 存在但 AppDelegate 兜底分支仍硬编码 `WelcomeView(...)` 等直连；monitor 号称经 delegate 解耦，却直接调 `ServiceContainer.crypto.hmacHex` 全局服务定位器 | `AppDelegate.swift:402, 837, 568`；`ClipboardMonitor.swift:305-313` |

**核心数据链路实测**：0.5s `DispatchSourceTimer` 轮询（utility QoS 专属队列）→ 读 `pasteboard.changeCount` → own-write 三重防护（skipNextCapture + changeCount + HMAC 指纹）→ Concealed/Transient 类型与排除 app 过滤 → RTF/文本/图片三分支捕获（文本截断 10MB 上限）→ 主线程 `addItem` → HMAC 去重 → `trimToMaxItems`（溢出进回收站）→ 500ms debounce 保存 → 全量 JSON encode → UserDefaults blob + `synchronize()` + 全量 memcmp 回读 → UI 300ms debounce 后全量重算过滤。轮询方案本身合理（NSPasteboard 无变更推送 API）。

---

## 二、核心功能实现

1. **【P1·用户可感】超大富文本被静默丢弃，日志却声称"回退 plaintext"**。else-if 链导致 RTF 超过 10MB 上限时既不走富文本分支也不走纯文本分支——什么都不捕获。从 Word/Pages 复制 >10MB 内容即复现；RTF 解析失败（`try? NSAttributedString` → ""）时即使剪贴板同时带 plain string 也不会被捕获。
   `ClipboardMonitor.swift:398-409`。修复：把 plaintext 分支放进 RTF 超限/解析失败的 fall-through 路径。
2. **【P1·用户可感】冷路径图片异步拷贝可覆盖后续任何剪贴板写入**。`pendingCopyToken` 只防"图-图"竞争，文本/RTF/暖图同步写路径从不触碰它——复制大图后紧接着复制文本，文本先落剪贴板，图片加载完成回调到达时 token 仍匹配 → 图片覆盖文本，用户粘贴得到几分钟前的图。
   `ClipboardStore.swift:2342-2351`。修复：同步写路径（`onRecordOwnWrite?()` 之前）统一 `pendingCopyToken = nil`，一行级修复，建议配回归测试。
3. **【P1·用户可感】多选图片时 Share 标签/拖拽范围 stale**。`ClipboardItemRow` 手写 `Equatable` 漏比较多选派生字段 `shareLabel/onShare/onDragProviders`（由父级按 `selectedItems` 派生），追加选图后 `==` 返回 true，SwiftUI 跳过重渲染 → 右键菜单停留旧数量、拖拽范围错误。`ClipboardItemRow.swift:283-289` 的行内注释记录了同类漏比较曾出过一次线上回归。
   `ClipboardItemRow.swift:271-290`、`ItemListView.swift:613-615`。修复：把派生值加入 `==`，或改用不含闭包的显式快照 struct。
4. **【P2】monitor 每 tick 在 `changeCount` guard 之前**固定执行 `pasteboard.types` 检查 + 排除表查找——每 0.5s 至少 2 次 Mach IPC 而非 1 次；排除归因有 0.5s gap，前置 app 切换后 0.5s 内的复制可能被错误归因给已排除的密码管理器而静默丢弃（注释自认）。
   `ClipboardMonitor.swift:384-395`。修复：`guard currentChangeCount != lastChangeCount` 提到最前。
5. **【P2】UI 刷新为全量重算**：任何 items 突变（含 OCR attach、tag 增删、pin 翻转）都替换整个 `@Published` 数组，10K 条目下一次 pin 点击 = 全表重过滤 + 全表分组 + 三份缓存重建 + 全量 prewarm。`ContentView.swift:424-466, 795-801`。千级条目可接受；随存储迁移把过滤/分组下推 SQL。
6. **【P2】terminate 路径三重冗余 + RunLoop 泵重入风险**：三条路径都调 `flushPendingSaves`（靠 `needsSave` 幂等兜底）；未完成首载时在主线程泵 RunLoop 最多 5s（`while !firstLoadCompleted { RunLoop.main.run(...) }`），`applicationWillTerminate` 期间重入窗口真实存在（AppDelegate 注释记录过该路径曾触发 libdispatch bug）。`ClipboardStore.swift:1238-1241`。修复：首载未完成时直接按当前内存快照写入（磁盘旧 blob 本就是完整历史，最坏丢 debounce 窗口内新条目）。

---

## 三、代码质量与可读性

**做得好的**：本地化几乎零漏网（UI 层无硬编码界面串，全走 `L10n` 单点，a11y 文案有专属 key 批次）；纯函数抽取文化（`SidebarTagFilter`、`computeTabCounts`、`RestoreWizardViewModel` 纯状态机等全部可脱离 SwiftUI 单测）；性能工程系统化（Task.detached 移出主线程、锁保护缓存、量化性能注释）；无障碍覆盖罕见完整（icon-only 按钮全补 label + hint）；AppKit 桥接边界注释扎实。

1. **【P1】三大块 UI 逻辑存在三份几乎逐行相同的拷贝且已实际漂移**：解密重试（200ms 重试 + `.cryptoKeyPrepared` bump token）在 `ClipboardItemRow.swift:876-942`、`QuickBarView.swift:557-617`、`TrashItemRow.swift:277-316` 三处重复；长按预览 `onChange(of: imageLongPressing)` 整块（约 45 行）与图片加载 `.task(id:)` 双份。`TrashItemRow.swift:131-133` 自证曾因漏改一处而出 bug（"was a batch-6 round-1 miss"）。
   修复：抽 `ViewModifier` 或 `RowContentLoader`（ObservableObject）收敛为单一实现。
2. **【P1】prop drilling 严重，ViewModel 缺位（代码自认的技术债）**：`ItemListView` 接收 15 个 `@Binding`（`ItemListView.swift:32-50`）；`ClipboardItemRow` init 18 个参数（`:301-317`）；ContentView 持有 6 个手写缓存、由 9 个 onChange/onReceive 触发器维护一致性（`ContentView.swift:106-132, 600-811`）；`ItemListView.swift:10-12` 自认 "Phase 5+ work to collapse into an `@StateObject` ViewModel is out of scope"。视图 6 处反向直连 `(NSApp.delegate as? AppDelegate)`（`QuickBarView.swift:270` 等）。
   修复：抽 `MainListViewModel`；路由改闭包注入或 `WindowRouter` 环境。
3. **【P1】本地化三处漏网**：
   - `CloseButton` 默认 a11y 标签硬编码英文 "Close"，4 个调用点全用默认值（日/韩 VoiceOver 用户听到英文）——`CloseButton.swift:17`；`.help()` 不进 VoiceOver 是项目自己总结过的教训（F-20）。
   - `TrashItemRow` 日期格式化绕过统一的 `DateHelpers` per-language 缓存设施，formatter 无 locale 绑定且不观察语言切换——`TrashItemRow.swift:60-67`（对照 ID-L10N-0017 修过同类问题）。
   - RecentCrashesView / RestoreWizardView 不订阅语言变化且窗口一次性构建，开着时切语言整窗文案滞留旧语言（对照 `SettingsRootView.swift:72` 的 `.id(languageManager.selectedLanguage)` rekey 方案）。
4. **【P2】巨型 body 与超长函数**：`ClipboardItemRow.body` ≈349 行（`:595`）、`TrashItemRow` ≈273（`:70`）、`QuickBarView` ≈263（`:119`）；>80 行函数 3 个（`attachLifecycle` ≈96 行、`filterItemsImpl` ≈89 行、`buildItemRow` ≈85 行）。
5. **【P2】搜索高亮 4 套实现各自为政**：主列表（截断 200）、OCR 宽窗（±40/+80）、OCR 窄窗（±20/+40，除两个常量外逐行相同）、QuickBar（只高亮第一个匹配）；颜色不一致（`.cyan.opacity(0.3)` vs `Color.yellow.opacity(0.7)` + `.black` 前景，后者深色模式观感差）。
   `ClipboardItemRow.swift:421-553`、`QuickBarView.swift:429-452`。修复：统一为 `highlightedSnippet(text:highlight:window:style:)`。
6. **【P2】样板与散落**：`let _ = fontScale` 在 12+ 个视图重复；`applyAppearance()` 两处逐行相同（`ContentView.swift:285-291` 与 `GeneralSettingsView.swift:143-149`）；模块级自由类型堆在视图文件（`SidebarTab`/`TimeGroup` 在 ContentView，`ClearMode` 在 ItemListView）；`FirstLaunchManager` shim 住在 `WelcomeView.swift:180-195`；`RestoreWizardWindowController.swift:15` 窗口标题硬编码英文而 `L10n.restoreWizardTitle` key 存在。
7. **【P2】审计史注释污染源码**：大量"修改历史"类注释写在实现中间（如 `ContentView.swift:350-378` 一段 27 行 OCR 回归史注释在过滤函数内），建议迁出源码进 docs/CHANGELOG。
8. 【P2】`FuzzySearchMatcher` 质量高（token AND、`en_US_POSIX` 钉死、pinyin 双 NSCache、内存告警 flush），微瑕：`matches()` 中同一 token 对 normalized 最多扫两遍可合并；`SearchDebounce` 34 行小而正确。

---

## 四、潜在缺陷与边界情况

1. **【P0】quarantineCorruptBlob 硬编码 `UserDefaults.standard`，绕过注入的 defaults**——`FileStorageBackend` 特意支持注入 suite，测试用 `xcTestDefaults` 保证不碰生产 plist（ID-STORE-0014 的全部努力），但这条错误路径在测试中触发加载失败（IntegrationTests 就在做）会直接读写生产 `com.clipmemory.app` 域，正是项目自己用 ZZZ canary 防的事。也是后端抽象泄漏的证据（quarantine 属存储层职责却散在 store 扩展里）。
   `ClipboardStore+Utilities.swift:47-54`。修复：改用注入的 `self.defaults`（一行）；长期随存储迁移入 backend 协议。
2. **【P1·数据丢失】Keychain 迁移"写后读不一致"分支会删除唯一回退副本**：verify mismatch 意味着 Keychain 内容已不可信，此时删除磁盘上的明文 key 文件（`.permanent` → `shouldDelete = true`）→ 下次启动把 Keychain 里的错误 32 字节当 canonical → **全部历史永久不可解密**。与同文件 unknown 错误 "err on caution, keep fallback"（`:50-52`）的原则自相矛盾——恰恰是 Keychain 已证明不可靠的场景最该保留回退。
   `CryptoService.swift:554-559`、`CryptoService+KeychainMigration.swift:57-62`。修复：verify-mismatch 分支 keep 文件 + 走 transient 处理。
3. **【P1】`fullSizeCache` 只有 countLimit=8 无字节上限**：单图允许 50MB（解码位图约 100MB），8 张大图契约上界 ≈800MB，cost 已计算却无处生效（ID-CRASH-0028 解释了为何去掉 100MB totalCostLimit，但应设宽裕双保险如 256MB）。`ImageStorage.swift:49-53, 1014-1017`。
4. **【P2】`pendingKeyItems` 无上限**：Keychain 长期未解锁 + 高频复制 → 每条最高 10MB 整文堆在内存数组。`ClipboardStore.swift:1693-1698`。修复：封顶（如 50 条/50MB），溢出丢弃并计数上报。
5. **【P2】超过 50MB 的图片被静默丢弃**，仅 log 无用户可见信号，与项目"加密/保存失败都有通知"的三环门纪律不符。`ImageStorage.swift:446-450`、`ClipboardMonitor.swift:560-562`。
6. **【P2】`NWPathMonitor` cancel 后 `start()` 静默失效**（Apple 文档：canceled 后不可复用；`NetworkMonitorProtocol` 声称 stop/start 可配对）。生产只 start 一次无碍，未来 teardown 路径会得到永不回调的监控。`NetworkMonitor.swift:74-91`。需验证 + 修复：stop 后重建实例。
7. **【P2】OCR backfill 对 Vision 永久失败的图片无限重试**（每 launch 重跑 15s watchdog 流程），无失败计数上限。`ClipboardStore+OCR.swift:286-296`。修复：`ocrRetryCount >= 3` 后标 `ocrAttempted`。
8. **【P2】`contentCache.totalCostLimit = 10MB` 而单条明文上限 10MB**——单条大文本反复自我驱逐，缓存对该条目形同直通。`ClipboardStore.swift:687-692`。
9. **【P2】AppDiscoveryService 进程内缓存永不过期**：装新 app 需重启才出现在排除列表 picker（有 `clearCache()` 但生产无触发点）。`AppDiscoveryService.swift:33-70`。
10. **【P3】小项**：`dispatchPrecondition(.onQueue(.main))` 后的 `guard Thread.isMainThread` 是死代码（`ClipboardStore.swift:1232-1236`）；`NetworkMonitor` 通知从 utility 队列 post（`NetworkMonitor.swift:148-151`）；AppDiscovery/HotKeyManager 无锁状态与同文件锁纪律不一致（需验证）。
11. **并发排查总体干净**：无生产路径强制解包（9 处 `try!`/`fatalError` 均为编译期常量或测试路径）；Timer/observer 生命周期纪律严格且有源码 grep 断言测试兜底（`NotificationObserverAssertionTests`）；17 处 `nonisolated(unsafe)` 均附锁契约注释，是 `SWIFT_STRICT_CONCURRENCY: minimal` 下的已知技术债，Swift 6 迁移候选已列档。

---

## 五、依赖与配置合理性

**做得好的**：唯一第三方依赖 Sparkle（面积极小）；仓库卫生干净（Releases/、Homebrew/、backups/、build/、default.profraw、.DS_Store 均未入库且 .gitignore 带理由注释）；XcodeGen 管理工程；`rollback-release.sh` 完整闭环（删 release/tag、恢复版本、摘 appcast、purge jsDelivr、反推 Cask SHA、非交互安全中止）；CI 反沉默 canary 体系（测试计数、TSan instrumentation、SwiftLint presence、coverage gate fail-closed）每条都有对应历史事故 ID。

1. **【P0】release.yml 的 appcast 推送兜底可回滚远端分支、丢并发提交**：`--force-with-lease` 失败的最典型原因恰恰是远端已前进，此时 `gh api PATCH force=true` 兜底会把窗口期内合入的 commit 全部摘掉——且用 admin PAT、分支保护 `enforce_admins: false`，这个 force 真能落地（ID-CRASH-0010 修好了无条件 PATCH，但保留了"失败才 PATCH"的路径——失败分支正是最危险的分支）。
   `.github/workflows/release.yml:555-560`。修复：删兜底改 fail-fast（appcast 补推本就是可重放操作）。
2. **【P1】发布链签名/公证缺位**：`Apple Development` 个人证书（2027-07 过期，全靠 `--timestamp` 锚定）+ 全链路无 notarization → 用户首次打开必遇 Gatekeeper 拦截；Development 证书政策上不能走 notarytool；`DEVELOPMENT_TEAM` 个人 Team ID 硬编码入库。`project.yml:25-27`、`release.yml:130-136`。需 Apple Developer Program（$99/年）决策；Team ID 移入本地 .xcconfig 或 CI secret。
3. **【P1】47 个 XCTSkip（约 4.6%）mass-skip，防污染 canary 与快照体系实质停摆**：`ZZZSuiteTeardownTests.testNoProductionPollution` 首行即 skip（`:235-236`）；`environmentInvariantCheck()` 不是 test 前缀方法 XCTest 永不调用；快照测试近乎全灭（含一个 `xtest` 前缀改名的测试）；xcodebuild 把 skipped 计入总数 → CI 测试数量下限门对 mass-skip 完全免疫；skip 只存在于注释里无台账跟踪。（**2026-10-01 部分闭环**：`docs/skips-ledger.md` 台账已建立——46 处/14 文件（锚定语句计数与 CI 实测一致）+ 逐条机制 + v2.9.6 恢复清单；canary 恢复仍待 v2.9.6，另发现类级 `setUpWithError` skip 在 @MainActor 类上必杀 runner 宿主，见第七节。）
   修复：建 skips 台账（docs/ 或 issue）；优先恢复 ZZZ canary（纯 UserDefaults diff，不影响 CI 稳定性）；UI 快照改环境变量门控。
4. **【P1】tag push 发布路径完全不跑测试**（`release.yml:205-206` `if: github.event_name == 'pull_request'`，ID-CRASH-0038 自述临时妥协），发布门实际只是作者本机一次可被 `--skip-tests` 绕过的 xcodebuild。**已闭环（ID-REL-2 `8ae0db5`，2026-10-05）**：删 `if: github.event_name == 'pull_request'` guard → tag path 现在跑 54-test smoke 子集（IntegrationTests + ClipboardStoreCryptoKeyThreadTests + UserDefaultsKeyTests）+ `Executed N` 漂移断言（SUBSET_EXPECTED 锚定；class rename 自动 fail-closed，参数化的 lint-tsan-filter.sh 同时覆盖 tsan.yml + release.yml，详见 `docs/skips-ledger.md` ID-REL-1/2 段）。连带 PR dry-run 从 1025-test 全量降到同一 54-test 子集（auto-review-20261005-132311 P2-3 披露）。
5. **【P1】15 处 Actions 全用可变 major tag 引用、0 个 SHA pin**，而 `.github/dependabot.yml:11-13` 自称 "pinned by SHA"——已失效。release.yml 持有 contents:write + admin PAT，checkout/gh-release 被上游劫持等于发布链被劫持。**已闭环（ID-REL-1 `7e3b756`，2026-10-05）**：release.yml + ci.yml + tsan.yml 全部 16 处 `uses:` 改 40-char commit SHA（带版本注释），6 distinct SHA 经 `api.github.com` tag refs 实证对应。`.github/dependabot.yml` 头部注释与下方 commit-message 同步刷新移除 "Actions are NOT SHA-pinned (0 SHA pins)" 陈述。known P2 (auto-review-20261005-132311 P2-5)：softprops/action-gh-release 用 annotated-tag SHA 而非 commit SHA，可解析但与其他 5 pins 不一致，deferred。
6. **【P2】并发与依赖策略**：`SWIFT_STRICT_CONCURRENCY: minimal`（`project.yml:20`）+ TSan PR 门 `continue-on-error: true`（夜间全量有 fail-closed race gate，这是对的）；Sparkle `from: "2.9.5"` 浮动 + dependabot swift 生态自认占位符（无产出，建议删或换定期 bump 脚本）；`release.yml:65` 缓存 key 引用不存在的 `ClipMemory/Package.resolved` 路径（实际在 `ClipMemory.xcodeproj/.../xcshareddata/swiftpm/`）。（**2026-10-01 更正**：PR #99 证明 dependabot swift 生态实际在产出 PR，`dependabot.yml` 的"占位符"注释已过时应改写；Sparkle 已随 #99 升至 2.10.0，见第七节追记。）
7. **【P2】SwiftLint/SwiftFormat 无版本 pin**（裸调 `which swiftlint`）；baseline 豁免 68 条全为 warning（line_length 47 条属"改 2 个字符"级别，建议一次性清掉并注销 baseline）；error 阈值（1250/400/700/45）自 2026-07 封顶后无下降计划。（**2026-10-01 SwiftLint 部分已修复**：风险已成真——新 runner 镜像删除了预装 SwiftLint 导致全分支 CI 红；ci.yml 现从 release URL 固定安装 0.65.1 + 下载 sha256 校验 + 版本漂移断言 + 绝对路径调用。SwiftFormat pin 与 baseline 清理仍开放。）
8. **【P2】`Scripts/test/` 的 8 个脚本测试未接入任何 CI**（release.sh 1229 行的纯函数只被人肉测试）——加一个 ubuntu-latest job 即可，是性价比最高的补洞。
9. **【P2】杂项**：`project.yml:6` `xcodeVersion: "15.0"` 已与现实脱节（纯误导性元数据）；githooks 对开源贡献者不友好（pre-push 强制跑作者私人环境的 AI 审核 hook、pre-commit 全量 xcodebuild，建议 AI hook 拆为可选安装）；appcast 无 `sparkle:releaseNotesLink`（更新弹窗只有版本号）；`CURRENT_PROJECT_VERSION` 复用 marketing 版本导致同版本 build number 不变（回滚语义受限）；`IntegrationTests.swift:88-91` 弱断言 `XCTAssertTrue(d1 == "Second" || d1 == "First")`。（**2026-10-01 追加**：appcast item 同时缺 `sparkle:minimumSystemVersion`——Sparkle 2.10.0 起为官方建议项，与 releaseNotesLink 一并补，见第七节。）

---

## 六、安全性与性能

### 安全（总体：成熟度显著高于同类个人项目，无 P0 漏洞）

**实测验证做得好的**：本机 plist 解码确认**无任何明文剪贴板内容落盘**（items blob 100 条中 85 条 v2 AES-GCM 密文，其余为 image 项 UUID 文件名；12 条 ocrText 全部密文）；Keychain 锁定绝不会被误判为"无密钥"而触发再生成覆盖真实根密钥（P0-1/C-2/ID-CRYPTO-0001 三层修复）；`store` 先 `SecItemUpdate` 后 `SecItemAdd` 消除删除窗口；加密失败绝不回退明文（注释自注 "do NOT store as plaintext (security violation)"）；导入路径三层防御（`unzip -Z1` 成员名检查拒绝 `..`/绝对路径、2GiB 炸弹上限、符号链接与路径逃逸校验、包内图片名 UUID 白名单）；损坏 blob 先 quarantine 再清空；目录 0700/文件 0600 纪律。

1. **【P1】导出加密包内嵌机器根密钥**：`key.enc` 是被口令包裹的**根密钥本体**（`AES.GCM.seal(keyData, using: derivedKey)`，keyData 即 `CryptoService.loadKeyData()`），包内 items/tags/trash 全是根密钥下的密文——破解任一弱口令包 = 破解本机全部数据（活动 store blob、所有同根密钥的本地备份、偷到的磁盘/Time Machine）。
   `BackupPackage.swift:530-533`。修复：导出生成一次性随机包密钥，口令包裹包密钥，payload 用包密钥重加密，根密钥永不出机；格式 bump `formatVersion`。
2. **【P1】OCR 文本不参与敏感检测**：截图里的密码/密钥 OCR 后密文存储但**可搜索、可预览**，`isSensitive`/`expiresAt` 均不设置——"敏感内容 24h 自动清除"对最高频泄密载体之一完全失效（对照文本路径 `ClipboardMonitor.swift:611-617` 有完整处理）。
   `ClipboardStore+OCR.swift:47-89`。修复：`attachOCRText` 内对 OCR 文本跑 `detectSensitive`，命中按同一规则补写 `expiresAt`。
3. **【P1】测试夹具把明文 key 文件写进生产密钥路径**（实机已复现：`~/Library/Application Support/ClipMemory/.encryption_key` mtime 与测试运行吻合）：换机 Keychain 丢失时，`prepareKey` 会把测试遗留 key 迁进生产 Keychain，既有历史静默变砖。与 Images 的 `Images-Tests/` 重定向模式不一致。
   `CryptoService.swift:328-351`。修复：XCTest 下 key 文件重定向到专用测试目录（照抄 `ImageStorage.swift:75-77` 模式）。
4. **【P2】敏感检测绕过面**（漏报方向）：`4111 1111 1111 1111` 空格分组卡号漏检（正则要求 16-19 位连续数字）、无 Luhn 校验；`"password is xxx"`/`"登录密码 123456"`/`Authorization: Basic` 漏检；无 Unicode 归一化（零宽字符绕过 keyword 与正则）。`ClipboardMonitor.swift:102-166`。>50KB 文本保守标记为敏感是 fail-safe 方向，产品定位是"尽力而为的提示"——建议：卡号去空白分组后跑正则 + Luhn；补中英文密码模式；NFKC + 去 zero-width 归一化。
5. **【P2】zip 炸弹守卫在列表命令失败时 fail-open**：`unzip -Z -v` 非零退出时静默跳过未压缩总量检查（成员名检查是 fail-closed，同函数内纪律不一致）。`BackupPackage.swift:346`。修复：非零退出抛 `archiveFailed`。
6. **【P2】备份权限纪律不完整**（实机证据）：`Backups/` 父目录 0755、备份内 `items.json`/`trash.json` 0644（其他路径都是 0600）——备份拷到 U 盘/网盘后暴露条目数、时间线、密文体积等元数据。`BackupService.swift:281-285, 338`。修复：init 补设 0700；blob 写入后 set 0600。
7. **【P2】ShareService 明文图片写临时目录 0644 且 60s 后 Task 清理不保证执行**（app 提前退出则残留，无重启补偿）。`ShareService.swift:27-40, 236-241`。修复：写 0600 + app 专属 temp 子目录 + 启动清扫。
8. **【P2】"敏感自动清除"≠ 销毁且被备份链路放大**：过期敏感项走回收站再留 7 天，同时每日全量进本地备份与导出包（keepCount 3-30 份滚动）——密文在磁盘可存续数周，与用户预期有落差。`ClipboardStore.swift:2410-2424`、`BackupService.swift:123-127`。建议 UI/文档说明，或提供备份剔除选项。
9. **【P2】每日备份整份复制 Images/**：最多 30 份完整图像副本，无总量上限与告警。`BackupService.swift:345-353`。修复：同卷硬链接去重（图像内容不可变）或增量；设置页显示备份总占用。
10. **【P2】entitlements 客观评估**：非沙箱是全局热键/剪贴板轮询/ditto 子进程的现实选择；`disable-library-validation` 的增量是放宽对注入库的签名约束（对已获用户级代码执行的攻击者是便利而非新能力）。建议确认无 dlopen 第三方未签名库后移除 DLV（收缩面零成本）；README:128 的 MAS 合规叙事与沙箱关闭矛盾，措辞需调整。

### 性能（主要问题与 UserDefaults blob 同根）

1. **【P1】保存路径阻塞主线程**：`flushSave` 在 MainActor 上两次 `.sync` **原地等待**全量 encode + cfprefsd 重写 + `synchronize()` + 全量 memcmp 回读——注释称开销已移出主线程，但主线程延迟只是换了计数位置；blob 到几 MB 时每 500ms debounce 触发都是一次可感知卡顿；terminate 时同理。`ClipboardStore+Persistence.swift:34-78`、`StorageBackend.swift:120-135`。
   修复：(a) items 落盘改独立文件（Application Support + 原子写 + fsync）；(b) flushSave 去 `.sync` 改异步写 + 失败恢复 `needsSave`，terminate 路径保留同步契约。
2. **【P1】ShareService 主线程同步解密 + 读盘 + 拷贝**：`makeShareableFileURLs` → `loadImage` → 全量读文件 + AES 解密全在调用线程（`@MainActor`），批量分享 10 张 6K 截图 = 秒级 UI 冻结；`copyImagesToFolder` 文件拷贝循环同样在 main。与 ImageStorage 精心维护的"UI 路径必须 async"纪律（见 ImageStorage.swift 内对应修复注释）直接冲突。`ShareService.swift:27-39, 59-62, 103-201`。
3. **【P2】每次启动对全部图片做完整性扫描**（全量读盘 + AES，无 mtime/hash 增量标记），200 张 4K 图 = 每次启动数百 MB 读盘；与 OCR backfill / prewarm 共享 utility 池互相排队。`ClipboardStore.swift:1562-1589`。修复：记录"已扫描且 mtime 未变"集合，只扫新增/变更。
4. **【P2】CrashReportService 主线程同步枚举 + 解析最多 50 个 .ips 文件**（每个 `String(contentsOf:)` + 2×JSONSerialization，可达数百 ms）——诊断窗口自身就是"卡顿现场"。`CrashReportService.swift:116-139`、`RecentCrashesView.swift:195`。
5. **【P2】SafeModeService 启动主线程 `Thread.sleep` 重试最多 ~1.05s**（50+200+800ms，磁盘满/沙盒异常时白屏）；日志 off-by-one（`attempt + 1`）。`SafeModeService.swift:212, 225`。
6. **【P2】网络恢复瞬间 `drainPendingWrites` 在 main 同步等待串行写队列排空**——恰有 50MB 图在加密时主线程冻白数百 ms。`AppDelegate.swift:350-353`。
7. **自监控体系专项**：HangDetector 3 定时器 + 双 NSLock，固定开销可忽略，snapshot→re-entry 双段锁正确处理恢复与检测并发；已知缺陷自知（抓恢复时刻栈无 post-mortem 价值，accept-as-is 有记录）；误报面仅剩"主线程被合法阻塞 >60s"（如实报为 hang，算 feature）。CrashReportService 解析健壮；SafeModeService sentinel + degraded 设计优于裸 crash 计数。
8. **搜索/缓存/OCR 管道本身设计成熟**：pinyin 双 NSCache（16k 条/10MB）、Task.detached 解密移出主线程、OCR 4-slot semaphore 背压 + 30s watchdog + 2048px 降采样（6K HEIC 峰值从 ~100MB 压到 ~16MB）。

---

## 综合评估

### 1. 下一步最合理的实际开发方向

**以存储层迁移为纲**：把 items/trash/tags 从单 UserDefaults blob 迁到 `~/Library/Application Support` 下的 SQLite（GRDB 或原生）或分片 JSON + meta 索引，启动只加载头部 N 条。

理由：这一项迁移同时消解当前报告里约 1/3 的问题——

- 主线程保存阻塞（六-1）与 cfprefsd 静默丢失窗口（代码自注该场景 read-back 校验覆盖不了）
- blob 损坏 = 全部历史的全损面（quarantine 只是把 blob 复制一份存回 UserDefaults，污染面加倍）
- 后台加载 merge 的 120 行竞态防御代码（P2-14）、terminate 三重 flush、保存失败重试梯子
- 启动全量 decode（100-300ms）与 10K 条全表重算过滤（迁移后过滤/分组下推 SQL，FTS 索引 + LIMIT 分页）
- 备份整份复制 Images 的放大（可顺带做增量）

它是决定后续所有功能上限的地基。应与 **ClipboardStore 拆类**（`HistoryStore`/`TagStore`/`DecryptionCache`/`PrewarmEngine`/`SettingsStore` + 薄门面）、**构造注入替换 27 处 `isRunningTests` 探针**在同一批做——分开做成本远高于合并做（拆类时 items 突变出口可统一封装 `mutateItems { }`，顺带消掉 `pinnedItems`/`invalidateItemIndex` 的手工同步）。

在此之前，先做一批"速赢"（合计约 1-2 天）：release.yml 删 PATCH 兜底、quarantine 改用注入 defaults、RTF 超限回退修复、copy token 一行修复、CloseButton/TrashItemRow/窗口标题本地化、OCR 文本接入敏感检测、测试 key 路径重定向。

### 2. 当前亟待解决的核心问题（按序）

1. **release.yml force PATCH 兜底**（一行删除，消除仓库历史丢失风险）
2. **Keychain 迁移 verify-mismatch 删回退副本**（低概率、不可逆全损）
3. **导出包内嵌根密钥**（安全承诺与实际不符）
4. **RTF 超限静默丢弃 + 冷图异步拷贝竞争**（用户可感的功能缺陷）
5. **47 个 XCTSkip 台账 + 恢复 ZZZ canary**（防污染体系名存实亡）
6. **Developer ID + 公证的决策**（决定分发体验，涉及付费，需要项目所有者拍板）

### 3. 全栈架构是否仍有优化空间

**有，且方向明确，但要克制**。

- 存储层（上述）是最大单项
- 把扩展拆分升级为真正拆类（扩展拆分只拆了文件没拆对象，14 处 private→internal 使封装形同虚设）
- UI 层抽 `MainListViewModel` 收敛 6 个手写缓存与 9 个触发器（代码自认的 Phase 5+ 方向），三大块行视图重复逻辑收敛为单一 ViewModifier
- 通信机制从四类收敛：错误统一 `ErrorReporter`、store 间状态统一 Combine、通知只留系统事件；配置持久化统一为 `@Published + didSet`（或独立 SettingsStore）
- Swift 6 / strict concurrency 迁移按已有锁契约注释路线图推进（17 处 `nonisolated(unsafe)` 已列档）

同时要指出：**这个代码库的问题不是写得差，而是复杂度分配失当**——防御性工程的密度已经很高，继续在现有地基上叠补丁（更多审计 ID、更多重试梯子）的边际收益正在递减；上面每一条重构都会让一批现有补丁直接失效删除，这才是重构的真实回报。

---

## 修复优先级总表

| 级别 | 数量 | 代表项 |
|---|---|---|
| **P0（立即）** | 2 | release.yml PATCH 兜底；quarantine 硬编码 `.standard` 破坏测试隔离 |
| **P1（近期，1-2 个迭代）** | ~15 | 存储迁移（纲）；Keychain 迁移删副本；导出包根密钥；OCR 敏感检测；RTF 丢弃；copy token；主线程保存/分享阻塞；store/AppDelegate 拆类；skip 台账+canary 恢复；tag 路径跑测试；Actions SHA pin；Developer ID 决策；测试密钥写生产路径；行视图三份重复逻辑收敛；本地化三处漏网 |
| **P2（随批次清理）** | ~20 | fullSizeCache 字节上限、pendingKeyItems 封顶、terminate RunLoop 泵、敏感检测归一化、zip fail-open、备份权限、share temp 清理、备份硬链接去重、启动图片扫描增量、VM 抽取、高亮统一、Sparkle/dependabot 策略、SwiftLint pin、Scripts/test 入 CI、appcast releaseNotesLink 等 |

> 逐项改法与实施顺序见第八节（批次 0 速赢 / 批次 1 发布链与安全 / 批次 2+3 存储迁移与结构重构）。

---

## 七、追记：2026-10-01 修复批次（CI 恢复绿 + PR #99 合并）

本节记录报告发布同日的修复批次结果与新增注意事项。起因：处理 PR #99（Sparkle 2.10.0）与 issue #93 时发现 v2.9.5-rc2 / v2.9.5 tag 及 main 的 CI 全红，顺藤排查并修复。完整过程见 issue #93 评论（2026-10-01）与 `docs/skips-ledger.md`。

### A. 已落地（对应本报告条目）

| 报告条目 | 处置 | 落点 |
|---|---|---|
| 五-7 SwiftLint 无版本 pin | **已修复**（风险已实际发生：新 runner 镜像删除预装 SwiftLint，全分支 CI 红；现固定安装 0.65.1 + 下载 sha256 校验 + 版本漂移断言 + 绝对路径调用，Homebrew 遮蔽与下载篡改均不可绕过） | `ce288c5` + 本批次 |
| 五-3 skip 无台账 | **部分闭环**：`docs/skips-ledger.md`（46 处/14 文件、逐条机制、v2.9.6 恢复清单）；canary 恢复仍待 v2.9.6 | `e61a049` / `27eb1dd` |
| 五-4 tag 路径不跑测试（发布门缺失） | 未修（同报告建议），但主套件已在 main push 上恢复可绿 | — |
| —（#93 next step 2） | build-and-test 失败时上传 xcresult + 两份测试日志 artifact（`if: always()`） | `ce288c5` |
| —（lint-ids tag 时序误报） | appcast/tag 覆盖 lint 在 `ref_type == tag` 时跳过（tag 自身条目由 release 流程事后写入 main，tag checkout 上构造性不可通过）；v2.9.3 类"有 appcast 无 tag"仍在 main/PR 上把守 | `ce288c5` |
| 五-9 appcast 缺 releaseNotesLink | 未修；**新增**缺 `sparkle:minimumSystemVersion`（Sparkle 2.10 起官方建议），两者一并补 | — |
| 依赖 | Sparkle 2.9.5 → 2.10.0（含 2.9.6 安装器 symlink 加固与 root 进程提权修复、macOS 27 delta 更新修复；最低部署 12.0 不影响本项目 target 13.0） | PR #99 / `c911bba` |
| 文档 | 7 语言 README + `docs/release-notes/v2.9.5.md` 事实修正："14 项 env 敏感型测试" → 实为 14 文件/46 处 XCTSkip/46 测试（CI 实测一致）；"ZZZ canary 3/3" 与 "1021 测试全绿" → 如实标注 canary 本身处于 skip、本地绿包含 skip | `e61a049` / `ce5f75d` |
| 测试 | `AppDelegateShouldTerminateTests` 宿主崩溃修复（机制见 B-2）；`UserDefaultsKeyTests.testRoundTripAcrossSuite` locale 依赖断言修复 | `51fbedb` / `27eb1dd` / `7fc409f` |
| **【新 P1·已修】Sparkle floor 漂移** | PR #99（dependabot）只改 pbxproj + Package.resolved，`project.yml` 的 `from: "2.9.5"` 滞后 → 下次 `xcodegen generate`（ci.yml 与发版预检 `check_xcodegen_sync` 都会跑）会把 pbxproj 写回 2.9.5、预检必 FAIL，且每次 dependabot bump 都复现。已对齐 floor 至 2.10.0（`xcodegen generate` 后 pbxproj 零 diff 验证），并加**两层防回归**：① 防回归测试 `ReleaseReadinessTests.testSparkleFloor_projectYmlMatchesPbxproj`（每次 bump 后 CI 会红直到 project.yml 对齐）；② ci.yml 在 `xcodegen generate` 后新增 `git diff --exit-code pbxproj` 同步门（覆盖 project.yml↔pbxproj 全量漂移，不止 Sparkle——此前 CI 侧无任何同步校验，`c911bba` 带病全绿正说明这一点）；dependabot.yml 两条过时注释（"swift entry 占位符"、"Actions pinned by SHA"）一并改写 | 见本批次提交 |
| **Sparkle 2.10.0 API 兼容性** | 由 `c911bba` 的 build-and-test 绿间接证实（CI 在 Sparkle 2.10.0 下编译了引用 `SPUUpdaterDelegate`/`SPUStandardUserDriverDelegate` 的 UpdateService）——`c911bba` 时 floor 仍为 2.9.5，Package.resolved 已 pin 2.10.0，故构建解析的是 2.10.0 | run 36838993065 |

**结果**：main @ `7fc409f` 起 build-and-test / coverage-gate / swiftlint / lint-ids 首次全绿（含 zh-Hans 全量步骤）；`c911bba`（Sparkle 合并）同样全绿。

### B. 新增关注项（本批次新发现）

1. **【P2·新】`BackupServiceExceptionPathTests` 仅在 TSan 插桩 + 新 runner 下失败**：`testPruneContinuesAfterMidLoopRemoveFailure` 与 `testPruneListFailureNowRecordsLastPruneErrorForUI` 在 tsan-full job 挂（同批 3 次宿主重试归属），**race 门确认 0 真实 data race**，常规 Debug 套件通过。属 runner 镜像漂移同族环境问题（tsan-full 为 advisory 不阻断）。处置建议：triage 后入 `docs/skips-ledger.md`（若仅 TSan 可复现，参考 tsan.yml 的 `-only-testing` 子集模式摘出）；未 skip 前不算台账内条目。
2. **【P2·新】Sparkle 2.10.0 两条后续**：appcast 全部 item 需补 `<sparkle:minimumSystemVersion>`（2.10 官方建议，当前缺失）；下次发版签名时注意 `release.yml` 的 sparkle-cli 仍 pin 2.9.4 与 framework 2.10.0 的双轨（`adaf180` 有既有说明，升级 CLI 前先复核 EdDSA 兼容）。
3. **【更正·五-6 → 已处置】dependabot.yml 两条过时注释**："swift entry 是占位符、无产出"（PR #99 证伪）与 "Actions pinned by SHA"（五-5 实测 0 个 SHA pin）均已改写为如实描述。**连带发现的 P1 已修**：dependabot bump 只改 pbxproj/Package.resolved 不改 project.yml floor → 每次 bump 后 `xcodegen generate` 会写回旧 floor（`check_xcodegen_sync` 必 FAIL）；已对齐 floor 至 2.10.0 并加防回归测试 `testSparkleFloor_projectYmlMatchesPbxproj`（见 A 表）。**仍开放**：`release.yml:65` 缓存 key 引用不存在的 `ClipMemory/Package.resolved` 路径（实际在 `ClipMemory.xcodeproj/.../xcshareddata/swiftpm/`）。
4. **【工程化观察】pre-push AI 审核 hook 的 verdict 校准**：三连审核中一轮以纯 P2 结论给出 `VERDICT=FAIL`（与其自述"存在 P0/P1 才 FAIL"的规则不一致），但其余轮次以 P1（EN README 漏同步违反 7 语言纪律）拦下的批评全部成立并已采纳。建议：verdict 规则按其自述严格执行；P2 类发现改为评论不阻断。
5. **【环境事实·#93】runner 镜像漂移已实锤**：macOS 26.6.2 VM / Xcode 26.6 / swiftlint 被移除，且"类级 setUpWithError skip 在 @MainActor 类杀宿主"、"teardown 上下文单例首触崩溃"、"TSan 下 BackupServiceExceptionPathTests 失败"三项均为镜像变更后出现。issue #93 假设 #1 由"随机 flake"细化为"镜像漂移"；假设 #2（SyncBarrier）此前已由 ID-CRASH-0049 关闭；假设 #3（测试顺序）未介入。

### C. 仍开放（未受本批次影响，优先级不变）

- **P0**：release.yml appcast 推送的 `gh api PATCH force=true` 兜底（回滚远端分支、丢并发提交，一行删除待做）；`quarantineCorruptBlob` 硬编码 `UserDefaults.standard` 破坏测试隔离。
- **P1（多数未动）**：存储层迁移（纲）、Keychain 迁移 verify-mismatch 删回退副本、导出包内嵌根密钥、OCR 文本接入敏感检测、RTF 超限静默丢弃、冷图异步拷贝竞争、主线程保存/分享阻塞、store/AppDelegate 拆类、tag 路径测试门恢复、Actions SHA pin、Developer ID + 公证决策、测试密钥写生产路径、行视图三份重复逻辑收敛、本地化三处漏网（CloseButton / TrashItemRow formatter / 双窗口语言切换）。
- **注意**：`AppDelegateShouldTerminateTests` 的三条 skip 仍是 ID-CRASH-0038 台账条目（v2.9.6 恢复 = 删除三个 body 首行 XCTSkip；类注释已写明两种已确认的宿主崩溃机制，恢复时勿再改回类级 skip）。

---

## 八、建议修改方案（分阶段实施计划）

> 承接第七节 C 段的开放项，给出可落地的具体改法。批次 0 各项互相独立、可直接开工；批次 1 的 1-1 与 1-4 需项目所有者先做决策；批次 2 与批次 3 应同批实施。新修复建议沿用仓库惯例：从 `ID-REVIEW-1000` 起段分配审计 ID，测试先行，fail-closed。

### 批次 0：速赢（合计约 1-2 天，互相独立）

**0-1【P0】删除 release.yml 的 appcast PATCH 兜底**
- 现状：`release.yml:555-560` 的 `push --force-with-lease || gh api PATCH force=true` —— 兜底触发的最典型场景恰是远端已前进，会把窗口期并入的 commit 从分支上摘掉（admin PAT + `enforce_admins: false` 使其真能落地）。
- 改法：删除 `|| gh api ...` 整段，改为失败即 `exit 1` 并输出人工指引（"appcast 补推可重放：重跑 release workflow 的 appcast-push 步骤，或手动执行 `Scripts/update_appcast.sh`"）；同时清理不再需要的 admin bypass 相关注释。
- 验收：`Scripts/lint-release-yml.sh --selftest` 通过；演练一次 force-with-lease 失败确认走 fail-fast。

**0-2【P0】quarantineCorruptBlob 改用注入的 defaults**
- 现状：`ClipboardStore+Utilities.swift:47-54` 硬编码 `UserDefaults.standard`，测试中触发加载失败路径会写生产域。
- 改法（一行）：
  ```swift
  let defaults = self.defaults   // 替换 UserDefaults.standard，走注入 suite
  ```
- 验收：构造后端加载失败用例，断言 quarantine key 落在注入 suite 而非生产域；恢复 ZZZ canary 后此断言由 canary 兜底。

**0-3【P1】冷图异步拷贝竞争（一行）**
- 现状：`pendingCopyToken` 只防"图-图"竞争；`ClipboardStore.swift:2244-2327` 的文本/RTF/暖图同步写路径不作废在途异步写，粘贴得到旧图。
- 改法：同步写路径在 `onRecordOwnWrite?()` 之前统一 `pendingCopyToken = nil`。
- 验收：回归测试——冷图 copy 后立即同步写文本，断言剪贴板终态为文本。

**0-4【P1】RTF 超限回退 plaintext**
- 现状：`ClipboardMonitor.swift:398-409` else-if 链导致超限 RTF 两条分支都不走（静默丢条目，日志却称回退）。
- 改法：改平铺 gate——
  ```swift
  if captureRichText, let rtf = pasteboard.data(forType: .rtf),
     !rtf.isEmpty, rtf.count <= Self.maxTextCaptureBytes {
      processRichText(rtf)
  } else if let raw = pasteboard.string(forType: .string),
            Self.shouldCaptureText(raw) { ... }   // 超限/解析失败自然落到这里
  ```
- 验收：单测构造 >10MB RTF pasteboard，断言产出 plaintext 条目。

**0-5【P1】OCR 文本接入敏感检测**
- 现状：`ClipboardStore+OCR.swift:47-89` 的 `attachOCRText` 不调 `detectSensitive`、不设 `expiresAt`——"敏感 24h 清除"对截图密码失效。
- 改法：写入 `ocrText` 前对明文跑一次 `ClipboardMonitor.detectSensitive`，命中则 `isSensitive = true` 并按文本路径同规则补 `expiresAt`（清除管线自动接管）。
- 验收：单测——密码样式的 OCR 项到期进入清除流程（复用文本路径的清除测试基建）。

**0-6【P1】本地化三处漏网**
- `Views/Components/CloseButton.swift:17`：默认参数 `"Close"` → `L10n.buttonClose`；
- `Views/TrashItemRow.swift:60-67`：删除本地 `RelativeDateTimeFormatter`，改走 `DateHelpers.cachedRelativeDateString(from:relativeTo:languageCode:)`；
- `RecentCrashesView` / `RestoreWizardView`：加 `@ObservedObject languageManager = LanguageManager.shared` 并在 body 顶层 `.id(languageManager.selectedLanguage)`（照抄 `SettingsRootView.swift:72` 的 rekey 方案）。
- 验收：`lint-translations` 通过；运行时切语言三处即时生效。

**0-7【P2 速赢包】**
- `ImageStorage.swift:49-53`：`fullSizeCache` 补 `totalCostLimit = 256MB`（cost 已在算，只差一行）；
- `ClipboardStore.swift:1693-1698`：`pendingKeyItems` 封顶（50 条 / 50MB），溢出丢弃并写诊断计数；
- `ImageStorage.swift:446-450`：>50MB 图片静默丢弃 → post 轻量诊断通知（复用现有诊断面板通道）；
- `BackupPackage.swift:346`：`unzip -Z` 列表失败由 fail-open 改为抛 `archiveFailed`；
- `BackupService.swift:281-285, 338`：`Backups/` 父目录补 0700；blob 写入后 `setAttributes([.posixPermissions: 0o600])`。

### 批次 1：发布链与安全（约 3-5 天；1-1 需要所有者决策）

**1-1【P1】Developer ID + 公证（$99/年，需拍板）**
- 注册 Apple Developer Program → 签发 Developer ID Application 证书，`.p12` 入 CI secret；
- release.yml 打包后追加：`codesign --deep --force --options runtime` → `xcrun notarytool submit --wait`（凭据走 keychain profile secret）→ `xcrun stapler staple` → `spctl -a -vv` 校验，任一步失败即 FAIL；
- `project.yml` 的 `CODE_SIGN_IDENTITY` / `DEVELOPMENT_TEAM` 移出仓库（本地 `.xcconfig` + gitignore，CI 用 secret 注入）；
- 验收：干净机器双击打开无 Gatekeeper 拦截；`spctl -a -vv` 报 "Notarized Developer ID"。

**1-2【P1】tag 路径恢复测试门**
- 现状：`release.yml:205-206` `if: github.event_name == 'pull_request'` 使发布二进制在 CI 零测试。
- 改法：删除该 guard，改为确定性 smoke 子集（复用 tsan.yml 的 `-only-testing` 过滤 + `Executed N` 断言模式）：IntegrationTests + ZZZ canary + UserDefaultsKeyTests；全量测试仍以本地 `run_preflight --tests` 为权威门。
- 验收：注入必败用例演练一次，确认 tag push 的 release workflow 会 FAIL。

**1-3【P1】Actions SHA pin**
- 15 处 `uses:` 全部换 `<action>@<full-commit-sha>`；dependabot github-actions 生态自动提 digest 更新 PR（release.yml 持 contents:write + admin PAT，最优先）。
- 验收：`grep -rE "uses:.*@[0-9a-f]{40}" .github/workflows | wc -l` == 15。

**1-4【P1】导出包不再内嵌机器根密钥（需所有者确认格式变更）**
- 现状：`BackupPackage.swift:530-533` 的 `key.enc` 是口令包裹的**根密钥本体**，弱口令失守 = 全历史失守。
- 改法：导出时生成一次性 `packageKey`（`SymmetricKey(size: .bits256)`），payload 全部用 packageKey 重新加密，`key.enc` 改为口令包裹 packageKey；`formatVersion` 2→3，导入侧双读 v2/v3；
- 验收：单测断言 `key.enc` 解出的 key ≠ 根密钥；v2 旧包导入回归测试。

**1-5【P1】Keychain 迁移 verify-mismatch 保留回退**
- 现状：`CryptoService.swift:554-559` verify 失败即删磁盘上唯一正确的明文 key 文件 → 不可逆全损。
- 改法：该分支改为 keep 文件 + 走 `.transient`（下次启动重试）；仅连续 3 次失败且用户在 UI 明确确认后才允许删除；
- 验收：单测模拟 `load() != keyData`，断言文件保留、返回 transient。

**1-6【P1】测试密钥重定向**
- 现状：`CryptoService.swift:328-351` 测试夹具把明文 key 写进生产路径（实机已复现），换机丢 Keychain 时会把测试 key 迁进生产。
- 改法：XCTest 下 `keyFileURL` 重定向专用测试目录（照抄 `ImageStorage.swift:75-77` 的 seam 模式）；
- 验收：跑全量测试后 `~/Library/Application Support/ClipMemory/.encryption_key` mtime 不变。

### 批次 2：存储层迁移（约 2-3 周，与批次 3 同批做）

**2-1 新持久层**
- `~/Library/Application Support/ClipMemory/store.sqlite`（GRDB 或原生 SQLite；不想引依赖可先做分片 JSON + meta 索引）；
- schema：`items(id PK, created_at, content_hash, is_pinned, is_sensitive, expires_at, encrypted_text, ocr_*, tags)`，trash/tags 分表；图片维持现有文件布局；
- 启动只加载头部 N 条（= maxItems），过滤/分组/搜索下推 SQL（FTS5 顺带解决搜索 O(n) 重算）。

**2-2 迁移路径**
- 首启检测 UserDefaults blob → 原子导出 SQLite → 旧 blob 改名 `legacy-items.json` 保留一个版本周期（沿用 quarantine 语义），下下版删除；
- 现有"报错 + 重试 + 用户可见"三环门与 quarantine 语义平移到新 backend（`StorageBackend` 协议及 7 个测试 conformer 现成，接口面不变）。

**2-3 顺带消解（同一 PR 内做，成本远低于单做）**
- `flushSave` 的 `.sync` 等待改异步写 + 失败恢复 `needsSave`（terminate 路径保留同步契约）；
- `applyLoadResult` 的 120 行 merge 防御、terminate 三重 flush 收敛为单一路径；
- `waitForFirstLoadSync` 的 RunLoop 泵删除（即并发审查 F6）；
- 备份从整份复制 Images 改增量（SQLite 文件级 snapshot/hardlink）。

**2-4 验收**：全量测试在新 backend 跑绿（协议测试复用）；10K 条目 pin 点击不再全表重算；terminate 无 RunLoop 泵；迁移用例（blob→sqlite→重启）幂等。

### 批次 3：结构重构（随批次 2）

**3-1 ClipboardStore 拆类**：`HistoryStore`（items/pin/trim）+ `TagStore` + `DecryptionCache` + `PrewarmEngine` + `SettingsStore`（三种配置持久化范式收敛为 `@Published + didSet`），薄门面组合；统一 `mutateItems { }` 突变出口（自动 invalidate index / rebuild pinned / dedup set）——`pinnedItems` 的 14 处与 `invalidateItemIndex` 的 8 处手工调用随之消失。
**3-2 DI 收口**：27 处 `isRunningTests` 探针移到组合根，业务类全部构造注入（prewarm 在测试中被静默跳过的盲区随之消除）。
**3-3 UI**：抽 `MainListViewModel`（过滤/6 个缓存/键盘索引）；行视图解密重试/长按预览/图片加载三份拷贝收敛为一个 `RowContentLoader` ViewModifier；高亮统一为 `highlightedSnippet(text:highlight:window:style:)`。
**3-4 验收**：行视图重复块 grep 为 0；ContentView 手写缓存并入 VM；业务方法内 `isRunningTests` 出现次数为 0。

### 实施顺序建议

批次 0 →（1-1 决策并行）→ 批次 2+3（同一批 PR）→ 批次 1 剩余项穿插。每项落地时在 `docs/skips-ledger.md` / 本报告对应条目回写状态，沿用第七节的追记格式。

---

## 九、状态复核（2026-10-05）：批次 0 / 1 落地审计

> 第八节方案发布后，实施方（另一会话）落了 88 个提交（16 个 ID-REVIEW 修复 + 39 个机械重构 + 测试恢复）。本节逐项核对**代码现状**（非仅凭 commit message），取代第七节 C 段的状态记录。

### A. 已核实落地（每项均以当前 HEAD 的代码 grep / diff 复核）

| 报告项 | 状态 | 复核证据 |
|---|---|---|
| 0-1 release.yml PATCH 兜底 | ✅ 已删 | 全文件 0 处 `gh api -X PATCH`；`8ecb61a` |
| 0-2 quarantine 注入 defaults | ✅ | `ClipboardStore+Utilities.swift:57` `let defaults = self.defaults` |
| 0-3 copy token 作废 | ✅ | 同步写路径 `pendingCopyToken = nil`（`ClipboardStore.swift:2387`） |
| 0-4 RTF 超限回退 | ✅（带已知遗留） | 平铺 gate 落地；**遗留**：RTF 解析失败路径仍丢条目（commit 自注，延后 v2.9.6 提取 `processPlaintextIfPresent`） |
| 0-5 OCR 接入敏感检测 | ✅ | `attachOCRText` 跑 `detectSensitive` + 按规则写 `expiresAt`（`ClipboardStore+OCR.swift:91-102`） |
| 0-6 本地化三处 | ✅ | CloseButton → `L10n.buttonClose`；TrashItemRow → `cachedRelativeDateString`；两窗口 languageManager rekey |
| 0-7 P2 速赢包 | ✅ 五项全数 | fullSizeCache 256MB（`:71`）+ pendingKeyItems 封顶 + >50MB 诊断通知 + zip 守卫 fail-closed + Backups 0700/0600 |
| 1-5 Keychain verify-mismatch | ✅ | 降级 `.transient` 保留回退文件 + 5 不变量回归测试（`VerifyMismatchKeychainStore` mock） |
| 1-6 测试密钥重定向 | ✅ | XCTest 下 `keyFileURL` 重定向 + `CryptoServiceTests` 回归 |
| 超出方案 | ✅ | 1010/1011 hotkey 与 safe-mode 测试 seam；**1012** `ClipboardStore.shared` 惰性初始化（ZZZ 假绿根因）；**1013** ZZZ canary 恢复（skip 46→17，allowlist 收敛回 4 条 framework keys，经两轮 auto-review 打回重做） |

`05f623d`（"revert P0/P1 behavior changes"）复核结论：回退对象是**机械重构波自身引入的行为变更**（`String(bytes:encoding:)` 替换 `String(decoding:as:)` 破坏 zip fail-closed 与 10MB 截断语义），auto-review hook 抓住后修正——方向正确，未波及任何 ID-REVIEW 修复（1004 修正点复核仍在）。

### B. 未修（与报告一致，优先级不变）

- **1-1** Developer ID + 公证（$99/年决策未做）
- **1-2** tag 路径测试门：**已闭环（ID-REL-2 `8ae0db5`，2026-10-05，见五-4 注记）**——tag path 现跑 54-test smoke 子集 + `Executed N` 漂移断言（fail-closed，排在打包/发布步骤之前）；PR 路径全量由 ci.yml 兜底（release.yml 的 PR dry-run 同步降为同一 smoke 子集，已披露）
- **1-3** Actions SHA pin：**已闭环（ID-REL-1 `7e3b756`，2026-10-05，见五-5 注记）**——16 处 `uses:` 全部 40-char commit SHA；遗留 P2：softprops/action-gh-release 为 annotated-tag SHA（可解析，与其他 5 pins 不一致，deferred）
- **1-4** 导出包根密钥：**已闭环（ID-REVIEW-1015 `97151f0`，2026-10-05）**——v3 格式（formatVersion 1→3）：导出生成一次性 packageKey 并重加密全部 payload（含图片——首版实现漏了图片重加密导致含图包必然 `imageImportFailed`，复核时抓出并修复），key.enc 只含口令包裹的 packageKey，根密钥全程不出 CryptoService；导入双读 v1/v3；6 项验收测试（含跨机图片 round-trip）+ BackupPackage* 83 项全绿
- **批次 2 存储迁移 / 批次 3 拆类**：本轮 39 个 refactor 提交全部是**函数级机械拆分**（SwiftLint 阈值驱动），非第八节的目标形态（拆类 + 突变出口 + DI 收口）
- appcast `minimumSystemVersion`（0 处）/ `releaseNotesLink`
- P2 余项：敏感检测归一化、terminate RunLoop 泵（部分改进：SyncBarrier 已移出 init，泵降级为显式原语）

### C. 本轮新问题

1. **【已修·随本节提交】lint-ids 在 main 红**：tsan.yml 的 `-only-testing` 引用了重构中改名的类 `ClipboardStoreCryptoKeyNotificationThreadTests`（现名 `ClipboardStoreCryptoKeyThreadTests`，2 个测试），且计数漂移 95 vs 93——这正是 ID-CRASH-0010/ID-CI-0010 lint 防的"改名 → 过滤器失配"类，lint 如期起效。修复：tsan.yml 类引用更新（计数 95 复原无需改，漂移纯因类名失配）。**结构性提示**：函数级拆分与 tsan.yml 类引用的耦合还会复发，考虑 lint 失败信息直接给出新类名建议。
2. **tsan-full 仍红**（advisory）：TSan-only 失败（BackupServiceExceptionPathTests 等）待 triage，ledger 已记录。
3. **快照 4 测试再延 v2.9.7**：CI golden 失配 revert（`1743657`），本地真绿——runner golden 失配机制未定位（ledger 详记）。
4. **【P2】`05f623d` 有意恢复 5 处旧格式审计 ID**（legacy 格式字面量见该 commit message，L18 格式规则所禁）并 `--no-verify` 跳过 pre-commit：traceability vs 格式纪律的取舍已文档化，但豁免的长效策略（ID mapping 或 whitelist）待定——否则下个改动者会再撞一次。

### D. 数字对账（当前 HEAD `88b911c`）

- skip：46 → **17**（ZZZ canary 已恢复；4 个快照测试暂退 v2.9.7）
- 总测试：1020 → **1025**（修复批次自带回归测试）
- CI：build-and-test ✅ / coverage-gate ✅ / swiftlint ✅ / lint-ids ✅（本节随附 tsan.yml 修复）/ tsan-full ❌（advisory）
- 宿主崩溃：0 重启（run f0487ea 实证，issue #93 主因关闭）
