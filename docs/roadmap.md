# ClipMemory 开发规划

**版本**: v2.2.4
**更新**: 2026-07-16
**状态**: v2.2 + v2.3 完成 → v2.4 待启动（6 点）

---

## 目标

遵循 ECC 开发标准，在不破坏现有高质量代码的基础上，建立完整的测试体系（80% 覆盖率），引入轻量协议抽象，并持续优化 macOS 26 Liquid Glass 用户体验。

---

## 完成状态

| 维度 | 现状 | 达标 |
|------|------|------|
| 代码质量 | SwiftLint 零警告 | ✅ |
| 加密 | CryptoKit AES-GCM + Legacy 兼容 | ✅ |
| 线程安全 | OSAllocatedUnfairLock + 并发测试 10 项 | ✅ |
| LIQUID GLASS UI | NavigationSplitView + List(.sidebar) + QuickBar | ✅ |
| 测试覆盖 | **85 tests** → 估算约 40% | ✅ v2.2 目标达成 |
| 协议抽象 | StorageBackend + CryptoServiceProtocol + ServiceContainer | ✅ |
| CI | GitHub Actions + pre-commit hook | ✅ |

---

## v2.1.x — 已完成 ✅

### v2.1.0 — Liquid Glass UI + 测试体系

#### Liquid Glass UI 重构
- NavigationSplitView + List(.sidebar) + badge() 主窗口
- 磨砂玻璃工具栏遮罩（系统 toolbarBackground）
- QuickBar 适配 Liquid Glass（移除自定义材质）
- 工具栏 Console 风格（搜索 + 日期筛选 + 清空菜单）
- 侧边栏圆角 + Logo 设计
- Welcome 页面 6 步指南 + 设置页重新查看入口
- 批量操作栏浮动 overlay，不推内容
- 双击/单击/星标手势分离（ExclusiveGesture）

#### 测试体系（64 tests）
| 模块 | 测试数 | 说明 |
|------|--------|------|
| CryptoService (C.1-C.4) | 11 | AES-GCM 往返、随机 nonce、损坏数据、密钥文件、v2 格式、并发解密 |
| SensitiveDetector (D.1-D.3) | 13 | 密码/API Key/ID/SSN/JWT/私钥/长内容 |
| ClipboardItem (B.1-B.5) | 13 | 构造、Codable、Expiry、Equatable、contentHash |
| Concurrency (E.1-E.3) | 10 | skipNextCapture/recordOwnWrite/excludedBundleIds 并发 |
| Integration (G.1-G.3) | 17 | CRUD、去重、过期清理、pin 持久化、trim |

#### 代码审查修复
- `isOldFormat()` 改为试解密而非前缀检查
- 15 位身份证正则修正 + 假阳性优化
- github_pat_ / sk_live_ 检测规则
- 图片加密失败弹窗通知
- 图片迁移竞态修复
- 17 项 CRITICAL/HIGH 问题全部修复

#### 基础设施
- GitHub Actions CI（build + test on push/PR）
- Pre-commit hook（阻塞编译/测试失败）
- Homebrew cask 更新流程

---

## v2.2 — 富文本支持 + 协议抽象（已完成 ✅）

**目标**: 富文本粘贴板捕获 + 85 测试 + 协议抽象 + 体验优化

### v2.2a — 富文本支持

- `ClipboardItemType.richText` 枚举类型
- RTF 粘贴板自动检测与捕获（`ClipboardMonitor.processRichText`）
- NSAttributedString → AttributedString 渲染（ContentView + QuickBar）
- 复制回粘同时写入 `.rtf` 和 `.string` 类型
- 侧边栏新增「富文本」标签（图标 + 计数 + 类型筛选）
- 敏感内容遮罩支持富文本
- 7 语言 L10n

### v2.2b — 协议抽象 + DI

- `CryptoServiceProtocol` + `SensitiveDetectorProtocol` 定义
- `StorageBackend` 协议（`FileStorageBackend` + `MemoryStorageBackend`）
- `ServiceContainer` 轻量 DI 容器

### v2.2c — 体验优化

- Tips 快捷键教程页面
- 快捷键重置为默认按钮
- 图片渐进加载占位（photo 图标 + ultraThinMaterial）
- Unpin 菜单（today/yesterday/older/all）
- 最大条数裁剪弹窗（确认/取消 + 跳转设置）
- OSAllocatedUnfairLock → NSLock 回退（macOS 13 兼容）
- 启动时自动裁剪历史记录
- 设置页布局统一（每个 Section 一个控件 + footer 提示）

### v2.2d — 测试（85 tests）

| 模块 | 测试数 | 说明 |
|------|--------|------|
| CryptoService (C.1-C.4) | 11 | AES-GCM 往返、随机 nonce、损坏数据、密钥文件、v2 格式、并发解密 |
| SensitiveDetector (D.1-D.3) | 13 | 密码/API Key/ID/SSN/JWT/私钥/长内容 |
| ClipboardItem (B.1-B.5) | 16 | 构造、Codable、Expiry、Equatable、contentHash、富文本往返 |
| Concurrency (E.1-E.3) | 10 | skipNextCapture/recordOwnWrite/excludedBundleIds 并发 |
| Integration (G.1-G.6) | 35 | CRUD、去重、过期清理、pin/upin、分组清除、语言切换、排除应用 |

---

## v2.3 — 完善测试覆盖（后续）

**目标**: 80% 覆盖

| 任务 | 内容 | 工时 | 理由 |
|------|------|------|------|
| T1 | ClipboardMonitor 单元测试（线程安全+敏感检测） | 3点 | 核心路径，现有代码可直接测 |
| T2 | ClipboardStore 补测（cache 失效、trim 边界） | 2点 | 核心逻辑 |
| T3 | ImageStorage（加解密往返、迁移） | 2点 | 安全链路 |
| T4 | HotKeyManager（注册、配置持久化） | 1点 | 快捷键可靠性 |

**跳过**:
- ContentView 搜索集成测试 — SwiftUI UI 测试 flaky，ROI 低
- 主题切换测试 — 一行 `NSApp.appearance` 调用，不值得写测试
- "兜底 9 点" — 替换为上面 4 项具体任务

**小计**: 8 点

---

## v2.4 — OCR 图片敏感检测（后续）

**目标**: 用 Vision 框架识别截图中的敏感内容

| 任务 | 内容 | 工时 | 说明 |
|------|------|------|------|
| O1 | VNRecognizeTextRequest 集成 | 2点 | Vision OCR 接线 |
| O2 | 异步 OCR 管线 | 1点 | utility queue 运行，不阻塞剪贴板监控 |
| O3 | 多语言支持 | 1点 | 主动设置中文等多语言 recognitionLanguages |
| O4 | 检测逻辑接线 | 1点 | OCR 文字送 detectSensitive() 检测 |
| O5 | 测试覆盖 | 2点 | OCR 管线 + 敏感检测集成 |

**技术要点**：
- macOS Vision 框架原生 OCR，无需第三方库
- OCR 在 utility queue 异步运行，不阻塞
- 需设置 `recognitionLanguages` 包含中文，否则漏检
- OCR 失败时 `isSensitive = false`，不走旧的大小启发式
- 复用现有 `detectSensitive()` 检测逻辑，零检测改动

**跳过**：
- 非常规格式降级处理 — OCR 失败静默忽略即可

**小计**: 6 点

---

## 可并行任务组

| 组别 | 并行任务 |
|------|----------|
| v2.2a-b-c-d | 富文本 / 协议 / 体验 / 测试（基本互不依赖） |

---

## 依赖关系

```
v2.1 (完成) → v2.2 (富文本 + 协议 + 85测试) → v2.3 (测试补齐) → v2.4 (OCR)
```

---

## 不纳入规划的内容

- **v3.0 SQLite 迁移**: 文件系统已够用，收益 < 维护代价
- **完整 DI 框架**: 单 window App，ServiceContainer 已够
- **SwiftUI → AppKit 迁移**: 当前混合方案运转良好，不拆
- **macOS 13 以下支持**: Liquid Glass 设计依赖 macOS 26 SDK

---

## 技术债务（v2.x 周期内处理）

| 债务项 | 处理时机 | 状态 |
|--------|---------|------|
| 魔法数字硬编码（窗口尺寸等） | 按需 | |
| 日期格式化重复代码 | ✅ 已提取到 Utils/DateHelpers.swift | ✅ 完成 |
| SwiftLint 警告 | 保持零警告策略 | |
| OSAllocatedUnfairLock → Actor | 推迟，评估后认为收益 < 成本 | ⏸️ |

---

## 风险与缓解

| 风险 | 缓解 |
|------|------|
| 富文本渲染性能（大块 RTF） | ContentView 使用 `.task` 异步加载，非主线程阻塞 |
| 测试覆盖达标但场景遗漏 | 关键路径必须覆盖（复制/粘贴/搜索） |
| macOS 13 兼容问题 | 已在 CI 中验证编译通过 |

---

**总计预估**: v2.2 + v2.3 ~35 点（已完成）+ v2.4 ~6 点（待） = ~41 点
