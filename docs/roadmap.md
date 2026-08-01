# ClipMemory 路线图

> 定位：**本地优先 + 真加密**的剪贴板管理器（AES-GCM + Keychain 根密钥 + ConcealedType + 加密备份包）。路线图以加深这条护城河为取舍标准，不横向堆功能。
>
> **已交付（累计清单）**：
>
> - **自动更新（Sparkle 2）** — 后台每日检查 + 设置页手动检查，EdDSA 签名校验；v2.4.2 双渠道（jsDelivr 兜底）+ gentle reminders；v2.5.6 兜底改显式确认
> - **回收站** — v2.4.0 上线，v2.5.5 强化，v2.7.6 起过期自动清理改为进回收站 + 置顶豁免
> - **本地自动备份** — v2.5.0，每日启动 >24h 节流，3/7/14/30 份可选
> - **加密导出/导入** — v2.5.0，`.clipmemory` 密码包（HKDF-SHA256 + AES-GCM），合并去重；v2.7.6 起含回收站条目可导入
> - **条件删除** — v2.5.5，类型×时间二维确认
> - **加密根密钥迁 Keychain** — v2.5.6，设备绑定不同步 iCloud；v2.7.6 起内存密钥失焦/锁屏/休眠清零
> - **图片原尺寸预览面板** — v2.5.6，v2.7.4/2.7.5 修宽图/长截图显示
> - **设备端 OCR** — v2.5.5 Vision，backfill 自愈；v2.6.2 搜索高亮接入；v2.7.4-2.7.6 多轮加固（EXIF/看门狗/重试）
> - **模糊搜索** — v2.7.1 拼音转写 + token AND 匹配
> - **图片完整性校验** — v2.7.1，启动异步扫描
> - **质量基线** — 2026-07-24 起六轮全面审计（Round 1-6），~110 项 findings 闭环；FINDINGS-LEDGER 驱动（allocator + 状态机）；v2.7.6 起 712+ 测试全绿

---

## 近期节奏（2026-08 起）

| 版本 | 主题 | 内容 |
|---|---|---|
| **v2.7.7** | 加固发布 | Round-6 五项修复（SYNC-0003 隔离 / SECURITY-0006 路径校验 / SECURITY-0007 权限 / PERF-0019 预热合并 / VIEW-0008 冷回填）+ STORE-0005 测试宿主隔离——**防数据污染修复，尽快到用户手里** |
| **v2.8.0** | 隐私+效率故事 | **应用锁（Touch ID/密码）** + **Snippets（片段/模板）**，见下 |
| **v2.9.x** | 地基季 | ClipboardStore 拆分 → SQLite 评估 → 测试隔离收尾 → Swift 6 语言模式（见「现代化」节） |
| **之后** | 高级功能 | iCloud 同步设计评审、Shortcuts/AppleScript |

---

## 建议添加的功能

### 第一梯队（v2.8.0）

| 功能 | 价值 | 说明 |
|---|---|---|
| **应用锁（Touch ID / 密码）** | 高 | 剪贴板天然暂存密码/令牌/私聊，「打开历史需验证」是隐私故事最后一块拼图。`LAContext` + 现有 Keychain 基础设施，成本低感知高。原 Phase 4 提前至此 |
| **Snippets（片段/模板）** | 高 | 置顶条目即是半成品 Snippet——升级为独立分区 + 占位符（`{日期}`/`{剪贴板}`），不从零做。原 Phase 3 首项 |

### 第二梯队（低成本高感知，穿插）

| 功能 | 价值 | 说明 |
|---|---|---|
| **⌘⇧V 粘贴上一条** | 中 | 不开面板直接糊上一条，最高频操作，~1 天 |
| **文本转换菜单** | 中 | 右键转大小写 / URL 编解码 / Base64 / MD 链接。纯函数好测试 |

### 第三梯队（等基础设施）

| 功能 | 价值 | 说明 |
|---|---|---|
| **iCloud 同步** | 高（但重） | **SQLite 迁移完成前不碰**：UserDefaults JSON blob 整库重写、无增量、冲突无解；且根密钥 `ThisDeviceOnly` 设备绑定，同步需另做 E2E 密钥分发设计。多周项目，先出设计文档再动工 |
| **Shortcuts / AppleScript** | 中 | 存储层稳定后做，开放查/粘贴给自动化 |

### 明确不做

- CLI 工具（无人用的入口，纯维护成本）
- 使用统计（与隐私定位矛盾）

---

## 现有功能优化

| 优先级 | 项 | 说明 |
|---|---|---|
| 1 | **ClipboardStore 拆分** | 已 2070+ 行且每轮审计在涨（去重/过滤/诊断/预热/持久化/回收站桥接全在一类）。抽 `DecryptScheduler`/`DisplayCoordinator`。PERF-0020（O(n) 重建）挂在此次拆分上，也利于 strict concurrency 推进 |
| 2 | **SQLite 迁移** | 维持原 Phase 2 判断：**先 Instruments 实测 1K/5K/10K 条再动手**；每次保存整库 JSON 重写是 O(n) 写放大。**顺序：先拆 Store 再换存储**，切换面更小 |
| 3 | **测试隔离收尾** | 2026-08-01 一天两起测试宿主污染（ID-MON-0002 / ID-STORE-0005）就是利息。清掉 M12（10+ 测试直用 `.shared`）/ M13（测试直写生产 `UserDefaults.standard` migration key）残留 |
| 4 | **PERF-0016 缩略图降采样** | Round-5 deferred 尾巴：行缩略图全分辨率解码，内存虚高 |
| 5 | **Swift 6 语言模式** | 见下节「现代化」 |

---

## 现代化：Swift 6 与部署目标（2026-08-01 增补）

**事实基础**（已核实）：

- Swift 6 **语言模式兼容 macOS 13 部署目标**——语言模式与部署目标是独立维度；Swift Concurrency 运行时自 5.5 起向后部署到 macOS 10.15。`SWIFT_VERSION=6.0 + MACOSX_DEPLOYMENT_TARGET=13.0` 合法可行
- 本机工具链已是 Xcode 26.6 / Swift 6.3.3 编译器（语言模式钉在 5.9）；`SWIFT_VERSION` 合法值只有 4.0/4.2/5.0/6.0，语言模式只有 5 和 6 两档
- CI 用 `macos-latest` runner；cask 声明 `depends_on macos: :ventura`

**分阶段路径**：

1. `SWIFT_STRICT_CONCURRENCY=complete`（保持 5.9 模式）——全部隔离问题以 warning 暴露，清零（SYNC-0003 是 Round-6 已知最后一点，翻开关后可能再冒新的）
2. `SWIFT_VERSION=6.0`——warning 变 error，锁定成果
3. （可选激进档）**部署目标 13.0 → 14.0**：解锁 `@Observable`，淘汰 ObservableObject + 手动 `objectWillChange.send()` 打法，与 ClipboardStore 拆分同步做最划算；同步改 cask `depends_on`。**放弃 Ventura 用户在 2026 年是合理取舍**（ Ventura 2022 年发布，个人免费工具 + brew 分发）
4. （更激进）15.0 可再议——建议先到 14 吃 `@Observable` 红利，15 的收益增量待评估

---

## 可以去除/精简的

| 项 | 建议 | 理由 |
|---|---|---|
| 7 个空壳 `.stringsdict` | **删** | MISC-0003 曾文档化「有意保留」，重议：打包空文件无收益，决策记录留 ledger 即可 |
| HangDetector | **降级 Debug-only / 设置默认关** | 生产仅写日志、无处置路径；ID-LIFE-0024 已接受「抓不到现场栈」现状，对普通用户是死重 |
| jsDelivr 兜底更新渠道 | **保留但简化 UX** | 复杂度高（探测引擎/同意弹窗/双渠道切换/发版 purge），但 GitHub 国内可达性是真实问题。建议「探测失败自动切换」简化为「设置里手动选渠道」，删一个状态机（以真实使用反馈为准） |
| 回收站/条件删除/诊断横幅 | **不动** | 均为用户痛点直接催生，刚抛光 |

---

## Technical Debt & Infrastructure（2026-07-29 审查产出，状态已刷新）

### P1 — 数据安全加固

| 项 | ID | 状态/说明 |
|---|---|---|
| Keychain biometric/ACL | M6 | OPEN——与应用锁（v2.8.0）天然捆绑，建议一起做 |
| UserDefaults HMAC 完整性 | M7 | OPEN——若决定迁 SQLite 则此项被取代，**建议并入 SQLite 评估一并决策，避免双重投入** |
| contentHash 去重降级 | M2 | OPEN（0.5 天） |
| Developer ID 证书评估 | M8 | OPEN（调研，$99/yr + 公证，能消掉首开「无法验证」提示） |

### P2 — 架构优化

| 项 | ID | 状态/说明 |
|---|---|---|
| ImageStorage 双队列 | M5 | OPEN（0.5 天） |
| 测试隔离：Store | M12 | **大部分已闭环**（ID-MON-0002 + ID-STORE-0005，2026-08-01）；残留：10+ 测试直用 `.shared` 改用注入 |
| 测试隔离：UserDefaults | M13 | OPEN（改用 `UserDefaults(suiteName:)`，0.5 天） |

### P3 — 代码整洁度（非阻塞）

- groupCounts O(n)、`isPinned`/`decryptionFailed` 变 `let`、移除 `AppDelegate.deinit`、`DateFilter`/`RichTextParser` 单独测试

---

## 执行原则

1. **先跑起来再抛光**——每项开工前先确认触发条件真实存在（Instruments / 真用户反馈），不为「路线图 TOP 1」硬上
2. **隐私护城河优先**——新功能按「是否加深本地优先 + 真加密」取舍
3. **先拆 Store 再换存储**——大重构串行不并行
4. **审计驱动**——新发现一律入 FINDINGS-LEDGER 再动工

---

*最后更新：2026-08-01（六轮审计闭环 + v2.7.6 发布后的全面重排：近期节奏表、应用锁/Snippets 提前、Swift 6 分阶段路径、去除/精简清单）*
