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
| **v2.7.x** | 纯加固线 | Round-6 五项修复 + STORE-0005 测试宿主隔离起步；⌘⇧V 循环粘贴、文本转换菜单等一两天小项可作为抛光穿插（不算新功能线） |
| **2.8 / 2.9**（不定死，3.0 之前即可） | 视 bug 修复情况顺延 | macOS 13/14 的最后一个功能版本视修复进度落在 2.8.0 或 2.9.0，不钉具体号 |
| **v3.0.0** | 功能 + 现代化 | **应用锁（Touch ID/密码）** + **Snippets** + **macOS 15 最低要求** + **Swift 6 语言模式** + **ClipboardStore 拆分**。scope 封顶就这些，防巨兽版本 |
| **v3.1+** | 高级功能 | iCloud 同步（先设计文档评审再动工）；SQLite/SwiftData 迁移按 Instruments 实测决定（迁到 15 后可评估 SwiftData 替代手写 SQLite/GRDB）；Shortcuts/AppleScript |

**v3.0.0 升最低系统要求的两个操作项**（届时必做）：appcast 的 3.0.0 item 加 `<sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>`（否则老系统用户会收到装不上的推送）；cask `depends_on macos:` 从 `:ventura` 改 `:sequoia`。

---

## 建议添加的功能

### 第一梯队（v3.0.0 核心）

| 功能 | 价值 | 说明 |
|---|---|---|
| **应用锁（Touch ID / 密码）** | 高 | 剪贴板天然暂存密码/令牌/私聊，「打开历史需验证」是隐私故事最后一块拼图。`LAContext` + 现有 Keychain 基础设施，成本低感知高 |
| **Snippets（片段/模板）** | 高 | 置顶条目即是半成品 Snippet——升级为独立分区 + 占位符（`{日期}`/`{剪贴板}`），不从零做 |

### 第二梯队（低成本高感知，穿插）

| 功能 | 价值 | 说明 |
|---|---|---|
| **粘贴体验升级**（原「⌘⇧V 粘贴上一条」扩展） | 高 | 见下方专项设计 |
| **文本转换菜单** | 中 | 右键转大小写 / URL 编解码 / Base64 / MD 链接。纯函数好测试 |

#### 粘贴体验专项设计（2026-08-01 拍板）

- **循环粘贴（首选方案）**：按住 ⌘⇧ 连续点 V，像 ⌘Tab 一样在最近 N 条里循环，松手即粘贴当前选中条。单热键覆盖 90%「粘贴最近几条」场景，无需记槽位
- **槽位直达（补充）**：槽位 ≤4 个，默认用三修饰键组合（如 ⌃⌥⌘1/2/3，避开系统占用），设置里可改绑；默认只开槽 1，其余用户自行启用
- **权限分层**：无 Accessibility 权限时降级为「复制到剪贴板」（用户自己 ⌘V）；授权后才模拟 ⌘V 真粘贴
- **粘贴队列做成「模式」**：同一热键连按 = 进入队列模式按顺序逐条吐出，非独立功能
- **与 QuickBar 分工**：盲打前 1-2 条用热键，要翻更多历史开 QuickBar，不重复造面板
- **敏感条目联动**：循环粘贴/槽位能否吐出加密失败或应用锁保护中的条目，规则留到应用锁实现时一并定

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
| 2 | **存储迁移** | 维持原 Phase 2 判断：**先 Instruments 实测 1K/5K/10K 条再动手**；每次保存整库 JSON 重写是 O(n) 写放大。升 15 后评估对象改为 **SwiftData vs 手写 SQLite 二选一**（SwiftData 加密方案见「现代化」节 B 类）。**顺序：先拆 Store 再换存储**，切换面更小 |
| 3 | **测试隔离收尾** | 2026-08-01 三起测试宿主污染（ID-MON-0002 / ID-STORE-0005 / ID-STORE-0007）就是利息。M13 已闭环（§10.14）；残留：M12（10+ 测试直用 `.shared` 改注入） |
| 4 | **PERF-0016 缩略图降采样** | Round-5 deferred 尾巴：行缩略图全分辨率解码，内存虚高 |
| 5 | **Swift 6 语言模式** | 见下节「现代化」 |

---

## 现代化：Swift 6、部署目标与 macOS 15 红利（2026-08-01 增补）

**事实基础**（已核实）：

- Swift 6 **语言模式兼容 macOS 13 部署目标**——语言模式与部署目标是独立维度；Swift Concurrency 运行时自 5.5 起向后部署到 macOS 10.15。`SWIFT_VERSION=6.0 + MACOSX_DEPLOYMENT_TARGET=13.0` 合法可行
- 本机工具链已是 Xcode 26.6 / Swift 6.3.3 编译器（语言模式钉在 5.9）；`SWIFT_VERSION` 合法值只有 4.0/4.2/5.0/6.0，语言模式只有 5 和 6 两档
- CI 用 `macos-latest` runner；cask 声明 `depends_on macos: :ventura`

**分阶段路径**：

1. `SWIFT_STRICT_CONCURRENCY=complete`（保持 5.9 模式）——全部隔离问题以 warning 暴露，清零（SYNC-0003 是 Round-6 已知最后一点，翻开关后可能再冒新的）
2. `SWIFT_VERSION=6.0`——warning 变 error，锁定成果
3. **部署目标最终决策（2026-08-01 拍板）**：2.x 线全程保持 macOS 13 不动；**v3.0.0 直接跳到 macOS 15**，不设 14 中间档。理由：
   - 3.0.0 落地时 macOS 15 在 Apple n-2 支持线内，且 Ventura 已掉出安全更新，13/14 本就是名义支持（从未在 13/14 真机测试过）
   - macOS 15 的 SwiftData 已成熟，存储迁移可直接评估 SwiftData 替代手写 SQLite/GRDB，少一次中间迁移
   - `@Observable` 顺带获得，与 ClipboardStore 拆分同步做最划算
   - 届时配套：appcast 加 `sparkle:minimumSystemVersion`、cask `depends_on` 改 `:sequoia`（见「近期节奏」节操作项）

### macOS 15 底线解锁清单（2026-08-01 盘点，按收益类型）

**A. 删码红利（抬底线即删，纯赚）**

- `ClipboardMonitor.swift:20-26` 的 `OSAllocatedUnfairLock` 兜底分支（macOS 14 API，为 13 留了两条路径）
- `OCRService.swift:86,348` 的 `macOS 13.0` 检查、`WelcomeView.swift:39` 的 `macOS 14.0` 分支（变死代码）
- 原则：每处 `#available` 双路径都是「只测一条」的隐患，抬底线后全局清理一遍

**B. 架构级升级（重头戏）**

- **`@Observable` 迁移**——全项目 18 文件 64 处 `ObservableObject/@Published/objectWillChange`（ClipboardStore 一个文件 31 处）。收益：手动 `objectWillChange.send()` 整体淘汰；细粒度观察，长列表只有变化行重渲染，列表/QuickBar 性能直接受益。**与 ClipboardStore 拆分同一次手术做**
- **SwiftData 替代手写存储**——取代原 SQLite/GRDB 评估项（二选一，Instruments 实测照旧）。15 的 SwiftData 自带迁移、谓词查询（搜索受益）。**硬约束：SwiftData 默认明文落盘，与真加密护城河冲突**——方案为「字段级密文 blob」（AES-GCM 加密内容字段，时间戳/类型/hash 留明文做索引），复用现有 Keychain 根密钥。iCloud 同步不受影响（设备绑定密钥决定同步必须自定义，设计先行原则不变）
- **Swift 6 并发收尾**——`PasteboardMonitor`/`OCRService` actor 化、模型 `Sendable` 化。**不依赖 macOS 15，2.x 即可做**（上方 step 1-2）

**C. 15 时代新框架能力（点缀，最后穿插）**

- **AppIntents** → Shortcuts 支持（原第三梯队项，15 上成熟）
- **`.privacySensitive`** → 配合应用锁做条目遮蔽，系统级标记，截图/快速查看同受保护
- **TipKit** → 循环粘贴/应用锁的原生引导，免自写 onboarding
- SwiftUI 细节：`scrollTargetBehavior`（QuickBar 键盘导航精确滚动）、`symbolEffects`、`@Entry`（干掉自定义 EnvironmentKey 样板）、`@Bindable`

**D. 明确不赶的**——Foundation Models、Liquid Glass、新版 Vision API、TextRenderer 全是 **macOS 26 独占**，floor 15 拿不到；真想要用 `#available(macOS 26, *)` 门控渐进采用，不再为它们抬底线

**落地顺序**：① 2.x：strict concurrency → Swift 6 模式（现在就能开工）→ ② 3.0 抬底线：删 A 类 shim + `@Observable` 随 Store 拆分 → ③ SwiftData 加密方案设计 + 实测 → ④ C 类点缀穿插

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
| Keychain biometric/ACL | M6 | OPEN——与应用锁（v3.0.0）天然捆绑，建议一起做 |
| UserDefaults HMAC 完整性 | M7 | OPEN——若决定迁 SQLite 则此项被取代，**建议并入 SQLite 评估一并决策，避免双重投入** |
| contentHash 去重降级 | M2 | OPEN（0.5 天） |
| Developer ID 证书评估 | M8 | OPEN（调研，$99/yr + 公证，能消掉首开「无法验证」提示） |

### P2 — 架构优化

| 项 | ID | 状态/说明 |
|---|---|---|
| ImageStorage 双队列 | M5 | OPEN（0.5 天） |
| 测试隔离：Store | M12 | **大部分已闭环**（ID-MON-0002 + ID-STORE-0005，2026-08-01）；残留：10+ 测试直用 `.shared` 改用注入 |
| 测试隔离：UserDefaults | M13 | **已闭环**（2026-08-01，ledger §10.14）：3 处直写按 STORE-0007 范本修复 + canary 加固。真债务残留：ImageStorage/UpdateService/ClipboardStore+OCR 硬连 `UserDefaults.standard` 不可注入 suite——并入未来 UserDefaults 抽象评估 |

### P3 — 代码整洁度（非阻塞）

- groupCounts O(n)、`isPinned`/`decryptionFailed` 变 `let`、移除 `AppDelegate.deinit`、`DateFilter`/`RichTextParser` 单独测试

---

## 执行原则

1. **先跑起来再抛光**——每项开工前先确认触发条件真实存在（Instruments / 真用户反馈），不为「路线图 TOP 1」硬上
2. **隐私护城河优先**——新功能按「是否加深本地优先 + 真加密」取舍
3. **先拆 Store 再换存储**——大重构串行不并行
4. **审计驱动**——新发现一律入 FINDINGS-LEDGER 再动工

---

*最后更新：2026-08-01（三次增补：macOS 15 底线解锁清单——删码红利 / @Observable 迁移 / SwiftData 字段级密文方案 / 新框架能力 / 26 独占不赶，附落地顺序；此前：粘贴体验专项设计、v3.0.0 跳 macOS 15、3.0 前版本号不定死）*
