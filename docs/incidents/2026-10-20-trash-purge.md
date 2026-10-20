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
| **单实例护栏** | 建议 | 两个 App 进程各自持有整数组快照，后写者用**陈旧快照**覆盖 ⇒ 丢更新。两个守卫都挡不住它（守卫只管测试进程）。正确解法是第二个实例立即退出（`NSRunningApplication`），但那是**产品行为变更**，需要拍板。 |
| 同 domain 不同实例绕过闸门 | 中 | 闸门判的是**实例身份**（`=== UserDefaults.standard`），不是 persistent domain。`UserDefaults(suiteName: "com.clipmemory.app")` 是另一个实例、指向同一 domain。仓库里**没有**这样的调用点；公开 API 也无法可靠判域（实测写后读回探针无效——同进程不同实例的内存缓存不共享）。 |
| 大额清理预警 | 建议 | 一次删 106 条这种量级，建议先弹「将永久删除 N 条」再执行，而不是事后通知。 |
| `.corrupt-*` 隔离副本不在备份白名单 | 低 | `BackupBlobRegistry` 只含 items/tags/trash ⇒ 被隔离的历史永远进不了备份。 |
| 孤儿图片清扫与 sentinel 的交互 | 应用级 | 与本次事故无关，但会影响「损坏后能否恢复图片」。 |

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
