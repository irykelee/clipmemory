# ClipMemory 开发规划

**版本**: v2.2.0
**更新**: 2026-05-16
**状态**: v2.2 完成 → v2.3 待启动

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
- `MockCryptoService` 测试实现

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

| 任务 | 内容 | 工时 |
|------|------|------|
| G.1 | ContentView 搜索功能集成测试（防抖 + 高亮） | 2点 |
| G.2 | QuickBarView 键盘导航测试（↑↓ Enter Esc） | 2点 |
| G.3 | 主题切换测试（system/light/dark） | 1点 |
| 补充 | 剩余的 UI + 集成场景 | 9点 |

**小计**: ~14 点

---

## 可并行任务组

| 组别 | 并行任务 |
|------|----------|
| v2.2a-b-c-d | 富文本 / 协议 / 体验 / 测试（基本互不依赖） |

---

## 依赖关系

```
v2.1 (完成) → v2.2 (富文本 + 协议 + 85测试) → v2.3 (测试补齐)
```

---

## 不纳入规划的内容

- **v3.0 SQLite 迁移**: 文件系统已够用，收益 < 维护代价
- **完整 DI 框架**: 单 window App，ServiceContainer 已够
- **SwiftUI → AppKit 迁移**: 当前混合方案运转良好，不拆
- **macOS 13 以下支持**: Liquid Glass 设计依赖 macOS 26 SDK

---

## 技术债务（v2.x 周期内处理）

| 债务项 | 处理时机 |
|--------|---------|
| 魔法数字硬编码（窗口尺寸等） | 按需 |
| 重复日期格式化代码 | 按需提取 |
| SwiftLint 警告 | 保持零警告策略 |
| OSAllocatedUnfairLock → Actor | 评估中 |

---

## 风险与缓解

| 风险 | 缓解 |
|------|------|
| 富文本渲染性能（大块 RTF） | ContentView 使用 `.task` 异步加载，非主线程阻塞 |
| 测试覆盖达标但场景遗漏 | 关键路径必须覆盖（复制/粘贴/搜索） |
| macOS 13 兼容问题 | 已在 CI 中验证编译通过 |

---

**总计预估**: v2.2 ~27 点（已完成）+ v2.3 ~14 点（待） = ~41 点
