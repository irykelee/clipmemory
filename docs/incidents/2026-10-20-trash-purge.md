# 2026-10-20 回收站数据丢失事故记录（ID-CRASH-0031）

> 本文是事故的**订正版**记录。第一版记录（提交 `c538b57` / `9b566f8` 的提交信息）
> 断言「测试进程走了生产路径，所以测试写坏了用户数据」。独立核验（verifier）
> **推翻了这个断言**：测试宿主进程里 `XCTestConfigurationFilePath` 是**存在的**
> （空字符串），而 `Optional("") == nil` 为 false ⇒ 旧的隔离守卫当时是**生效的**。
> 本文记录**订正后**的结论、证据，以及仍未闭环的部分。

## 1. 发生了什么

用户的 106 条回收站条目在 2026-10-20 从实时存储中消失，回收站只剩 1 条
（用户当天 17:29:03 新删的那条）。生产 `com.clipmemory.app` domain 的
`ClipboardTrashedItems` 从 228193 字节（106 条）变成 5705 字节（1 条）。

**历史部分未受影响**：`ClipboardItems` 始终是 100 条真实条目，未丢失。

## 2. 已确证的事实

| 事实 | 证据 |
|---|---|
| 106 条的 `deletedAt` 全部落在 2026-09-30 ~ 2026-10-07 | 解码 10-14 备份的 `trash.json` 逐条统计 |
| 默认保留期 7 天 ⇒ 这 106 条在 2026-10-07 之后即全部超期 | `TrashStore.trashRetentionDays` 默认值 |
| `purgeExpiredTrash()` 删除过期条目后**整数组替换**写回（`[]`） | `TrashStore.saveTrashedItems` → `backend.save(trashedItems)` |
| 该清理**此前无任何用户可见提示** | 事故前代码里没有通知/弹窗/日志 |
| 清理逻辑本身是**设计行为**（保留期是用户设置），不是 bug | `TrashStore` 注释与设置项 |

⇒ **最可能的机制**：一次普通启动触发了积压多日的保留期清理，把已经超期的 106 条
一次性清空并写回空数组。清理是设计的，**「清理了 106 条却一个字都没告诉用户」才是缺陷**。

⇒ 修复：`c4c565d` 已经让过期清理发出 `.trashItemsExpired`（含条数与保留期），
由 AppDelegate 弹 NSAlert（7 语种 L10n）。

## 3. 已被推翻的说法（订正）

第一版提交信息里的两条论断，经独立核验不成立：

1. ❌「测试宿主没有 `XCTestConfigurationFilePath`，所以隔离守卫失效、测试走了生产路径」
   —— 实测测试宿主**有**该变量，只是值为**空字符串**；`Optional("") == nil` 为
   false ⇒ 旧守卫（`ClipboardStore` / `HotKeyManager` / `SafeModeService`）
   当时是**生效**的，测试宿主用的是隔离 suite + `MemoryStorageBackend`，
   碰不到生产数据。
2. ❌「统一日志里的 `Successfully spawned ClipMemory` 证明发生过普通启动」
   —— 该日志行**测试宿主自己也会产生**（核验时复现了完全相同的行），不具区分力。

⇒ 因此「测试进程写坏了用户数据」这一说法**没有证据支撑**，本仓库不能把它当作
已确认的根因。

## 4. 那么 `c538b57` / `9b566f8` 交付的是什么

不是「事故的修复」，而是**让这一类事故不可能再静默发生**的两道防线：

1. **写入点硬闸**（`FileStorageBackend.assertWriteAllowed()`）：测试进程不得把
   `ClipboardItems` / `ClipboardTrashedItems` / `ClipMemoryTags` 写进生产
   `UserDefaults.standard`，拒绝时**抛错**（走既有「报错→重试→用户可见」链）。
2. **按字节比对的金丝雀**（`testProductionDataBlobsAreUnchanged`）：套件结束后把
   三个数据 blob 与开局快照**逐字节**比对，任何写入都让套件变红。

旧的金丝雀只比对**键是否存在**，而这两个键当时在白名单里 ⇒ 整数组被替换也看不见
（这正是 2026-10-20 这一天它保持全绿的原因）。

⇒ 价值：**下一次**无论是谁（一个没有环境变量的测试宿主、一次跑在测试期间的普通
启动、某条未来新增的代码路径）动了用户的数据，要么被闸门挡住，要么让套件变红。

## 5. 本轮补上的（verifier 提出）

- `TestIsolation.isRunningTests` 统一多信号探测（环境变量任意值 / `XCTestCase`
  类已加载 / 注入了 `.xctest` bundle），并替换 `ClipboardStore` /
  `HotKeyManager` / `SafeModeService` / `ImageStorage` 的单环境变量守卫。
  ⇒ 不再依赖「那个变量恰好存在」。
- 隔离（quarantine）路径纳入同一道闸：它**移动** blob（写 `.corrupt-*` 副本 +
  **删除原主键**），比写更狠。
- `BackupService.shared` 在测试进程下改用隔离 defaults + 临时目录 ⇒ 测试运行不再
  往用户真实 `Backups/` 目录写、也不再有 `lastBackupDate` 污染生产偏好。
- `productionWriteBlocked` 是**永久性**错误 ⇒ 不再进入无限退避重试（否则每 60 秒
  弹一次框）。
- 删掉定义了却从不抛出的 `staleBlob`（半成品防护 = 假象）。

## 6. 数据恢复

- 来源：`Backups/2026-10-14_225707.267/trash.json`（106 条，原始生产 blob 副本）。
- 方法：**字节级拼接**（不重新编码），106 条 + 当天新删的 1 条 = **107 条**，
  233897 字节。
- 校验：106 条与备份**逐字段一致**；id 全唯一；必填字段齐全；用 App 自己的
  `JSONDecoder().decode([ClipboardItem].self, …)` **实测可解码**（否则 App 下次启动
  会把整块 blob 隔离掉）。
- 保留期从默认 7 天改为 **30 天**：这 106 条的 `deletedAt` 在 2026-09-30 ~ 10-07，
  按 7 天会在下次启动被再次清掉；30 天的 cutoff = 2026-09-20 ⇒ **0 条会被清**。
  ⚠️ 30 天是产品允许的**上限**，最老那条会在 2026-10-30 之后被清掉 —— 需要更长
  的话只能导出 `.clipmemory` 包另存。
- 13 条图片条目的图片文件**在 10-14 备份里就已不存在**（更早的历史遗留，非本次
  事故造成）；22 条历史里的图片条目文件齐全。

## 7. 仍未闭环（待决策）

| 项 | 级别 | 说明 |
|---|---|---|
| **单实例护栏** | ✅ 已交付 | 已获拍板并实现（`ID-CRASH-0032`，见 §9）。两个 App 进程各自持有整数组快照，后写者用**陈旧快照**覆盖 ⇒ 丢更新；两个守卫都挡不住它（守卫只管测试进程）。 |
| 同 domain 不同实例绕过闸门 | 中 | 闸门判的是**实例身份**（`=== UserDefaults.standard`），不是 persistent domain。`UserDefaults(suiteName: "com.clipmemory.app")` 是另一个实例、指向同一 domain。仓库里**没有**这样的调用点；公开 API 也无法可靠判域（实测写后读回探针无效——同进程不同实例的内存缓存不共享）。 |
| 大额清理预警 | ✅ 已交付 | 见 §11（`ID-CRASH-0035`）：保留期清理一次性要删 ≥ 20 条时**先问再删**，低于阈值静默删除；过期的模态弹窗改成菜单栏角标。 |
| `.corrupt-*` 隔离副本不在备份白名单 | ✅ 已交付 | 2026-10-23 补上（`ID-BACKUP-0006`）：隔离副本进**每日自动备份**的 `Quarantine/` 目录、进 `.clipmemory` **导出包**（包密钥封装，因为隔离 blob 在 JSON 层已损坏、逐条重加密走不通），导入时还原回**原来的 `.corrupt-*` key**（绝不写主 key）。老包（manifest 无该字段）按空处理，向后兼容。 |
| 孤儿图片清扫与 sentinel 的交互 | ✅ 已闭环 | 2026-10-20 已补（`ID-CRASH-0022`）：items 侧有**持久** sentinel（`clipboardItemsLoadFailedSentinel`），且**空加载不算健康** —— sentinel 只在**非空**加载成功时清除 ⇒ 「blob 已损坏 + 下次启动」不会再被当成孤儿把图片删掉。回收站侧同构（`trashStore.lastLoadFailed` 由持久 sentinel 在启动时推出）。本行原记为「应用级待定」，查实后确认已闭环。 |
| 测试进程写生产域的「seam 复位」旁路 | ✅ 已交付 | 2026-10-23 修（`ID-CRASH-0066`）：`TestIsolation.defaults` 的**基线**原本是 `.standard`（生产域），且三个测试类的 `tearDown` 把它复位回 `.standard`；`ID-CRASH-0029` 把三个服务并到**同一份存储**之后，这个复位就从「只影响自己」变成「把生产域交给全部服务」。实测在测试跑期间生产域多出 `UpdateFallbackFeedConsent`（已清理）。现在基线在 XCTest 下是隔离 suite（生产分支仍为 `.standard`）、tearDown 改为**还原保存值**，并加了源码模式守卫 + 跑在最后的运行时守卫。 |

## 8. 审查提出但**有意不修**的项（附理由，避免反复提）

审查（OpenCode 独立审查 / 独立核验）提出的下列条目是**已知取舍**，不是遗漏：

| 条目 | 为什么不改 |
|---|---|
| `load()` 不受写入闸门保护 | **读**不会破坏数据。挡住读会让 App 宿主无法读到自己需要的数据；闸门只该管写与删。 |
| 隔离（quarantine）路径只记日志、不弹窗 | 该路径只在**测试进程**里被触发（生产进程里它是「blob 损坏」的真实恢复路径）。测试进程弹模态框没有意义，记 `logger.error` 足够。 |
| `TestIsolation.isRunningTests` 是 `static let`，进程内只算一次 | 环境不会在进程生命周期内变化；`static let` 初始化是原子的。若要改语义应改探测内容，不是改求值时机。 |
| `BackupService.shared` 用 pid 作临时目录名、不清理 | 目录在 `NSTemporaryDirectory` 下，由系统回收；pid 后缀是为了并发测试进程不互相覆盖。 |
| 闸门判 domain 的实现方式 | 写后读回探针**两个方向都实测无效**（同进程不同实例不共享内存缓存）；最终判据是「实例能否读到生产数据 blob 的**值**」。此外实测：在 App 进程内 `UserDefaults(suiteName: <自己的 bundle id>)` **返回 nil** ⇒ 主 domain 无法在自身进程内被重新打开 ⇒ 该场景下「实例身份 ≡ domain」。两条都有测试钉住。 |
| `flushSave` 里 `needsSave` 的赋值顺序 | `needsSave` 在方法开头就被清成 false；永久错误分支里再显式赋一次是为了**表达意图**（这条路径不排下一次尝试），不是逻辑需要。其余失败分支仍会把它置回 true 并排重试。 |
| 生产 domain 里**三个数据 blob 全为 nil** 时，domain 判据无法区分「同 domain 的第二实例」 | 空 domain 与「无关的空 suite」在公开 UserDefaults API 下**无法区分**——不存在可用的判据。而且常见情形根本不受影响：`.standard` 由**身份检查**直接命中，所以「测试进程写 `.standard`」在任何 blob 状态下都被拒绝。残余缺口需要有「同 domain 的第二实例」，而它在 App / 测试宿主进程内**根本创建不出来**（`UserDefaults(suiteName: <自己的 bundle id>)` 返回 nil，实测）。 |
| 第三轮审查提出的「测试进程可能在空生产 domain 上畅通写入」 | 前提有误：闸门条件是 `isRunningTests && addressesProductionDomain(defaults)`，而 `addressesProductionDomain(.standard)` 由身份检查直接返回 true ⇒ **无论 blob 是否存在，`.standard` 都被拒绝**。被指出的假阴性只影响「非 `.standard` 的同 domain 实例」。 |

## 9. 单实例护栏（ID-CRASH-0032，已交付）

§7 里列为「待决策」的单实例护栏已经拍板并实现。

### 9.1 为什么整数组替换需要单实例

`ClipboardItems` / `ClipboardTrashedItems` 各是一整块 JSON blob，每次写都是**整数组替换**。
两个进程各自持有同一块 blob 的快照，后写者会把先写者的内容用**陈旧快照**覆盖 ⇒
先写者删掉的条目复活，先写者新增的条目消失。测试进程的写入闸门（§4）挡不住这个：
闸门只管「测试进程写生产 domain」，两个**都是生产实例**的进程谁都不在闸门范围内。

### 9.2 决策机制：`flock`，不是「有没有别的进程在跑」

- `flock` 由**内核**在进程退出时释放（SIGKILL 也一样）⇒ 崩溃不会留下死锁。
- 锁落在文件上 ⇒ **同一台机器上的每一份 App 副本共用同一把锁**：
  `/Applications` 里的正式版和 DerivedData 里的 Debug 构建 bundle id 相同、
  UserDefaults domain 相同、因而数据相同 —— 只有文件锁能把它们互斥开。
- `flock` 是**原子**的：两个进程同一瞬间启动不可能都拿到锁；
  「列出正在运行的进程」这种判断存在竞态窗口。

实测（2026-10-20，本机）：`flock` 的锁挂在 *open file description* 上，
所以同进程内两个不同的 fd 也会互斥 —— 这让互斥性可以在单元测试里直接验证。

### 9.3 重复实例的退出路径必须绕过 AppKit 的终止流程

重复实例**不能**用 `NSApp.terminate(nil)` 退出：该路径会走
`applicationShouldTerminate` → `applicationWillTerminate`，而后者会实例化
`ClipboardStore.shared` / `ImageStorage.shared` 并 flush、还会清 safe-mode sentinel ——
等于让重复实例去写它本该拒绝碰的那块 blob。
因此重复实例走 `exit(EXIT_SUCCESS)`：跳过 AppKit 的终止序列，
而此时（守卫位于 `applicationDidFinishLaunching` 最前）本来也还没有任何
窗口、监听、热键或 store 需要清理。

### 9.4 测试宿主不抢锁

`xcodebuild test` 每次都会把 App 真二进制拉起来当测试宿主。测试宿主已经隔离到
自己的 UserDefaults suite（§5），本来就不与用户数据争用；而且它**不能**抢锁，
否则每次跑测试都会把用户挡在自己的 App 门外。
守卫因此以 `TestIsolation.isRunningTests` 为条件跳过。

### 9.5 实测：重复实例路径其实很罕见

实测（2026-10-20，用一个一次性 .app 验证）：macOS 对**已经在运行**的 App
再执行 `open` **不会**起第二个进程，只会把旧实例激活到前台；
只有 `open -n` 才会强制起新实例。
⇒ 「双实例」的真实来源是：同一台机器上装了两份不同的副本（如 Debug 构建 + 正式版）、
`open -n`、或某个外部工具以路径方式拉起 App。

### 9.6 残余边界

- `flock` 是**协作式**的：只有本 App 遵守。别的进程直接写同一个
  UserDefaults domain 不受此保护。
- 锁文件创建失败时**失败放行**（fail open）并记日志：守卫是纵深防御，
  不是数据主路径 —— 因为锁文件建不起来就让 App 起不来，比没有守卫更糟。
- 抢锁最多等 2 秒（覆盖「上一个实例正在退出」）；超过就拒绝启动，用户再点一次即可。

## 10. 交付护栏时的实测发现：一个「游离普通实例」真的存在（2026-10-20 22:31）

交付 `ID-CRASH-0032` 时顺带实测到一个此前没被记录的事实：

**`xcodebuild test` 会用 bundle id 通过 LaunchServices 拉起 App**（统一日志：
`Successfully spawned ClipMemory[...] because launch job demand`，originator =
`com.apple.coreservices.uiagent`，描述 `LS launch com.clipmemory.app`）。
观察窗口 22:15–22:45 内共 8 次启动，与 8 次测试调用一一对应。

其中有一次是**额外的普通实例**：

| 事实 | 证据 |
|---|---|
| 22:31:42 拉起 pid 34678（PPID=1，**未加载 XCTest** ⇒ 不是测试宿主） | `ps` + `lsof`（无 `.xctest`）+ 统一日志 `LS launch com.clipmemory.app` |
| 它写了**生产域**的 3 个键：`lastLaunchTime`、`ImageIntegrity.scannedMtimes`、设置窗口 frame | 跑测试前后 `defaults export` 逐键比对 |
| **用户的剪贴板数据没被动**：`ClipboardItems` 151706B / `ClipboardTrashedItems` 234307B **逐字节一致** | 同上（字节级比对） |
| 套件内**没有任何测试**会打开 App（`NSWorkspace.open` / `Process.launch` 只用于 ditto / zip / python3 辅助进程） | 全量 grep `Tests/` |
| App **自身也没有自启动路径**（`NSWorkspace.open` 只用于反馈 URL / 备份目录 / 崩溃报告） | 全量 grep `ClipMemory/` |
| 单套件定向跑（22:38）**只产生 1 次启动**（测试宿主）且不残留实例 | `ps` 前后对比 |

⇒ 请求方**在构建/测试工具链里，不在本仓库的代码里**，但具体是哪个组件**未能定位**
（`lsd` 未记录客户端）。这一点如实记下，不做推测。

⇒ **对护栏的意义**：这正是护栏存在的场景。实测里这个游离实例**抢到了锁**
（`~/Library/Application Support/ClipMemory/.instance.lock` 因此被创建）——
如果当时用户的正式版正在运行，它会**抢不到锁而直接退出**，不会去写生产域。

⇒ **仍然存在的残余风险**：当用户的 App **没有**在运行时，一个游离实例仍会正常启动并写
几个应用状态键（`lastLaunchTime` 等）。本次实测中**用户数据未受影响**；
真正保护住那 106 条恢复数据的是 **30 天保留期**（cutoff 2026-09-20 ⇒ 0 条会被清）。
⚠️ 保留期回落到 7 天、或超过 30 天后，游离实例的一次启动就可能清掉它们 ⇒
**导出 `.clipmemory` 包另存**这件事不能再拖。

## 11. 回收站清理的可见性：先问再删 + 非模态角标（ID-CRASH-0035，已交付）

§7 的两项待决项按用户拍板落地：

1. **大额清理预警**：保留期清理一次性要删 **≥ 20 条**时**先问再删**；低于阈值**静默删除**。
2. **过期清理告警**：模态 `NSAlert` 改成**菜单栏项角标**，点击角标才展开确认。

### 11.1 为什么原来的模态弹窗本身就是个问题

`c4c565d` 给过期清理加了模态 `NSAlert`。但清理**不只在启动时跑**——
`ClipboardStore` 的 60 秒清理定时器也会调 `purgeExpiredTrash()`。
⇒ 模态框可能在用户正忙着的时候突然弹出来抢焦点。

### 11.2 现在的流程

| 过期条数 | 行为 |
|---|---|
| `< 20` | 静默删除（日常housekeeping）；结果记在菜单栏项的 **tooltip** 里，悬停可见 |
| `≥ 20` | **不删**。发 `.trashPurgePending` ⇒ 菜单栏图标加**红色数字角标** + tooltip 写明待清理条数 |

点击角标 ⇒ 弹出确认框（`永久删除` / `取消`）：
- `永久删除` ⇒ `ClipboardStore.confirmExpiredPurge()` 真的删，并发 `.trashItemsExpired`（角标清除）
- `取消` ⇒ **一条都不删**，角标保留（用户可以之后再决定）

⇒ **没有任何东西会在没有明确答复的情况下被删掉。**
保留期从此不再是硬上限 —— 这是刻意取舍（数据安全 > 保留期语义）。

### 11.3 阈值 20 是怎么定的

2026-10-20 事故一次删了 106 条 —— 远高于 20；而日常一天过期的量远低于 20。
阈值以下的量属于「 housekeeping」，弹窗打扰用户不划算。

### 11.4 角标的实现坑（实测）

菜单栏角标要把 SF Symbol 和一个红色数字圆点合成一张图。两个坑都是**实测**出来的，
不是查文档得来的：

1. **`NSImage.contentTintColor` 不存在** —— 那是 `NSButton` / `NSImageView` 的属性。
2. **模板图（`isTemplate = true`）画进自定义图里永远是黑色**：当前绘制颜色**不生效**
   （实测：设 `systemRed` 与不设，两种情况采样都是 `r=0 g=0 b=0`）。
   ⇒ 合成图里符号的着色必须用 **`.sourceAtop` 填充**：
   先画符号，再用 `rect.fill(using: .sourceAtop)` 填色 —— 它只填符号覆盖到的像素。
   实测：`systemRed` → `r=255 g=66 b=69`，`labelColor` → `r=216 g=216 b=216`。

合成图整体 `isTemplate = false`（否则菜单栏会把红色角标一起染掉），
符号本身用 `labelColor` 着色 ⇒ 深浅色菜单栏都能看清。

### 11.5 测试与判别力

新增 `TrashPurgeConfirmationTests`（5 个用例）：
阈值以下直接删且不打扰、阈值以上先问且**一条都不删**、确认后才删、
60 秒 tick 不重复问、角标图只在有待办时存在。

变异测试（证明这些用例不是恒绿）：
- 变异 A（永远直接删，守卫形同虚设）⇒ **9 处失败**
- 变异 B（永远先问，过度阻断）⇒ **3 处失败**
