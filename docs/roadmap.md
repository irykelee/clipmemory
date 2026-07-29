# ClipMemory 路线图

> 基于 v2.4.0（回收站）之后的功能规划。优先级按 **数据安全 → 核心体验 → 效率集成 → 高级功能** 排列。
>
> **已交付（自路线图起始版本起的累计清单）**：
>
> - **自动更新（Sparkle 2）** — 后台每日检查 + 设置页手动检查，更新包 EdDSA 签名校验，appcast 托管于主仓 `appcast.xml`，随 Release workflow 自动更新；v2.4.2 加双渠道（jsDelivr 兜底）+ gentle reminders；**v2.5.6 改兜底为显式确认**（首次弹窗 + UserDefaults 持久化）+ 镜像陈旧则拒绝
> - **回收站** — v2.4.0 上线（删除项移到 Trash 7 天可恢复）；v2.5.5 强化：删除选项化、标签删除选项（仅删标签 vs 删标签+条目）、启动稳健；l10n 命名统一为 macOS 习惯（`Trash` / `垃圾桶`）
> - **本地自动备份** — v2.5.0，每日启动 >24h 节流备份 items/tags/trash + `Images/` 到 `Backups/<ts>/`，3/7/14/30 份可选
> - **加密导出/导入** — v2.5.0，`.clipmemory` 密码包（HKDF-SHA256 + AES-GCM 封缄），导入按 `id`/`contentHash` 合并去重；导入前自动先做一次本地备份
> - **条件删除** — v2.5.5，类型×时间二维删除确认弹窗（侧栏类型 tab 右键删整型 / 顶栏菜单 / 组 header 🗑 多入口）
> - **加密根密钥迁 Keychain**（C1） — v2.5.6，明文文件密钥（`~/Library/Application Support/ClipMemory/.encryption_key`）迁移到 macOS Keychain（service `com.clipmemory.app` / account `root-encryption-key` / `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`，不同步 iCloud）；启动时迁移 文件→Keychain→验证回读→删文件；XCTest 下不迁移（防测试污染）
> - **启动稳健性**（H6/H7） — v2.5.6，损坏密钥弹 NSAlert（quit / 重试 / reset）；存储失败可重试；CSPRNG 失败优雅退出；`AppDirectories` 解析器兜底 `~/Library`，4 处强解包清零
> - **图片原尺寸预览面板** — v2.5.6，长按条目出 NSPanel 浮窗（原尺寸渲染，>屏幕 90% 自动滚动），替代原 300px 行内缩放；主列表 + 回收站都接了
> - **设备端 OCR** — v2.5.5 上线 `OCRService`（Vision framework），支持图片条目 OCR + 自愈 backfill + live context-menu lookup；**v2.6.2 搜索高亮已接入**

---

## Phase 1：数据安全与恢复（建议 immediate）

直接对应「数据丢失不可恢复」的历史痛点，先把防丢和恢复做扎实。

| 功能 | 价值 | 说明 |
|---|---|---|
| 自动本地备份 | 高 | ~~每天/每次退出时把 `ClipboardItems` + `Images/` 打包到 `~/Library/Application Support/ClipMemory/Backups/`，保留最近 N 份~~ **已实现（v2.5.0，每日启动时备份，3/7/14/30 份可选）** |
| 回收站 | 高 | ~~删除的 item 和图片先移到 Trash，7 天后自动清理，期间可一键恢复~~ **已实现（v2.4.0，v2.5.5 强化）** |
| 手动导出/导入 | 高 | ~~导出为 `.clipmemory` 加密包（items + 图片 + key），换机或重装后可导入~~ **已实现（v2.5.0，密码保护 + 合并去重导入）** |
| **图片完整性校验** | 中 | ~~启动时扫描图片文件，发现缺失自动标记并提示~~ **已实现（v2.7.1+，启动异步扫描，即时状态显示）** — Phase 1 四项全部完成 ✅ |

> 做完这些之后，即使再有 bug 把文件删了，用户也能从备份或回收站找回来。

---

## Phase 2：存储与搜索升级（1-2 个月）

| 功能 | 价值 | 说明 |
|---|---|---|
| **SQLite 迁移** | 高 | 现在 `ClipboardItem` 存在 `UserDefaults` 里，数据量大时会卡。迁移到 SQLite/Core Data 能支撑几万条历史 |
| **模糊搜索** | 高 | ~~现在搜索是前缀/包含匹配。升级后支持拼音、模糊匹配、按类型/标签/时间范围过滤~~ **已实现（v2.7.1+，拼音转写 + token AND 匹配）** |
| **OCR 搜索高亮** | 中 | ~~OCR 服务已上线（v2.5.5）；把 OCR 文本接入搜索结果高亮，对截图特别有用；低成本串联~~ **已实现（v2.6.2）** |
| **快捷键粘贴上一条** | 中 | `⌘ + ⇧ + V` 直接粘贴最近一条，不用打开面板 |

---

## Phase 3：效率工具（2-3 个月）

| 功能 | 价值 | 说明 |
|---|---|---|
| **片段/模板（Snippets）** | 高 | 把常用文本保存为可复用片段，比如邮箱、地址、命令，支持占位符 |
| **粘贴队列** | 中 | 按顺序复制多条，然后按顺序粘贴，适合表单填写 |
| **文本转换菜单** | 中 | 选中条目右键：转大写/小写、URL 编解码、Base64、Markdown 链接格式化等 |
| **合并复制** | 中 | 多选文本项，合并成一段带分隔符的文本再复制 |

---

## Phase 4：系统集成与高级功能（中长期）

| 功能 | 价值 | 说明 |
|---|---|---|
| **iCloud 同步** | 高 | 多台 Mac 之间同步剪贴板历史，需要端到端加密 |
| **快捷指令 / AppleScript** | 中 | 让 ClipMemory 能被 Shortcuts 和自动化工具调用 |
| **Touch ID / 密码锁** | 中 | 打开主窗口需要验证，保护敏感历史 |
| **CLI 工具** | 低 | 终端里 `clipmemory search/list/copy` |
| **使用统计** | 低 | 展示复制频次、最常用 App 来源等 |

---

## Technical Debt & Infrastructure（2026-07-29 全面代码审查产出）

> 以下项目不属于用户功能，但影响数据安全、可维护性和测试可靠性。来源：`docs/superpowers/audits/2026-07-29-comprehensive-code-review.md`。

### P1 — 数据安全加固（建议 v2.8.x 完成）

| 项 | ID | 说明 | 工作量 |
|---|---|---|---|
| **Keychain biometric/ACL** | M6 | `KeychainKeyStore` 仅用 `AfterFirstUnlockThisDeviceOnly`，无 `userPresence`/`biometryAny`。恶意进程可在首次解锁后读根密钥 | 1 天 |
| **UserDefaults HMAC 完整性** | M7 | 所有持久化 blob 无完整性校验。恶意进程可篡改 `maxItems`/`items`/`excludedBundleIds`。方案：存前 HMAC，取时验证 | 1 天 |
| **contentHash 去重降级** | M2 | Key 未就绪时 `contentHash=nil` 跳过去重。首次启动窗口内重复捕获堆积 | 0.5 天 |
| **Developer ID 证书评估** | M8 | 当前用 Apple Development 个人证书，无公证。考虑升级到 $99/yr Developer ID + 公证 | 调研 |

### P2 — 架构优化（建议 v2.9.x 完成）

| 项 | ID | 说明 | 工作量 |
|---|---|---|---|
| **ImageStorage 双队列** | M5 | `migrationQueue.sync` 串行化所有图片读取——包括走 v2 快路径的图片。拆分 legacy/current 队列 | 0.5 天 |
| **测试隔离：Store** | M12 | 10+ 测试文件直用 `ClipboardStore.shared`。跨测试状态污染风险。统一迁移到 `MemoryStorageBackend` | 1 天 |
| **测试隔离：UserDefaults** | M13 | `ImageStorageTests`/`ImageDedupTests`/`OCRTests` 直写生产 `UserDefaults.standard` migration key。改用 `UserDefaults(suiteName:)` | 0.5 天 |

### P3 — 代码整洁度（非阻塞，可顺带修）

| 项 | ID | 说明 |
|---|---|---|
| groupCounts O(n) | M13 (Services) | 每次 body 求值遍历全数组，10000 条目影响明显 |
| `isPinned` 变 `let` | — | 当前为 `var`，但 pin 操作走 `togglePin()` → `items[index].isPinned.toggle()`，不经过 `with()` |
| `decryptionFailed` 变 `let` | — | 仅 `ClipboardStore` 通过 `items[index].decryptionFailed = true` 设值，Model 不应 mutable |
| 移除 `AppDelegate.deinit` | L (AppDelegate) | `deinit` 无法执行（`main.swift` 强引用）。`applicationWillTerminate` 已覆盖 |
| `DateFilter` 单独测试 | L (Tests) | 无直接测试，仅通过 UIObservability 间接使用 |
| `RichTextParser` 单独测试 | L (Tests) | 无纯单元测试，仅通过 ClipboardItemRow/RTFCache 间接 |

---

## 近期建议

按当前进度（v2.7.1），**Phase 1 全部完成** ✅，**Phase 2 模糊搜索已交付** ✅。建议优先方向：

1. **Technical Debt P1** — M6/M7 数据安全加固（2 天），在 Phase 2 大功能前把地基补牢
2. **SQLite 迁移**（Phase 2 主项，1-2 周）— `ClipboardStore.swift` ≈ 1800 行，所有读路径都要切；触发条件需先用 Instruments 跑 1000/5000/10000 条样本实测
3. **快捷键粘贴上一条**（Phase 2，`⌘⇧V`）— 低成本高感知，1 天

> **执行原则**：先跑起来再抛光。每项开工前先确认触发条件真实存在（Instruments / 真用户反馈），避免为了"路线图 TOP 1"硬上。

---

*最后更新：2026-07-29（v2.7.1 发布 + Phase 1 完成 + 全面代码审查技术债入库）*