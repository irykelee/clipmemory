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
| **模糊搜索** | 高 | 现在搜索是前缀/包含匹配。升级后支持拼音、模糊匹配、按类型/标签/时间范围过滤 |
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

## 近期建议

按当前进度（v2.7.1），**Phase 1 全部完成** ✅。可以启动 Phase 2：

1. **SQLite 迁移**（Phase 2 主项，1-2 周）— `ClipboardStore.swift` ≈ 1800 行，所有读路径都要切；触发条件（卡顿阈值）需先用 Instruments 跑 1000/5000/10000 条样本实测再决定是否上马，**不要因为路线图自荐 TOP 1 就动手**
2. **模糊搜索**（Phase 2，拼音/模糊匹配/按类型标签时间过滤）— 当前为前缀/包含匹配，大数据量下可精准性不足

> **执行原则**：先跑起来再抛光。每项开工前先确认触发条件真实存在（Instruments / 真用户反馈），避免为了"路线图 TOP 1"硬上。

---

*最后更新：2026-07-29（v2.7.1 发布 + Phase 1 全部完成）*