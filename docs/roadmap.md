# ClipMemory 开发规划

**版本**: v2.1.5
**更新**: 2026-05-15
**状态**: v2.1.5 完成 → v2.2 待启动

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
| 测试覆盖 | **64 tests** → 估算约 30% | ✅ v2.1 目标达成 |
| 协议抽象 | StorageBackend（部分） | 🔲 需扩展 |
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

## v2.2 — 协议抽象 + 体验提升（当前阶段）

**目标**: 50%+ 测试覆盖 + 核心协议定义 + QuickBar Liquid Glass 体验

### v2.2a — 协议抽象 + ServiceContainer

不采用全链路 constructor injection，使用 ServiceContainer 模式：

```swift
// 服务容器（轻量 DI）
enum ServiceContainer {
    static var crypto: CryptoServiceProtocol = CryptoService.shared
    static var detector: SensitiveDetectorProtocol = ClipboardMonitor.shared
    static var store: ClipboardRepository = ClipboardStore.shared
}

// 测试时替换
ServiceContainer.crypto = MockCryptoService()
```

| 任务 | 内容 | 工时 |
|------|------|------|
| F.1 | 定义 CryptoServiceProtocol + SensitiveDetectorProtocol | 2点 |
| F.2 | 定义 ClipboardRepository（扩展 StorageBackend） | 2点 |
| F.3 | ServiceContainer 接入 + 默认实现替换 | 1点 |
| F.4 | MockCryptoService / MockSensitiveDetector / MockRepository 实现 | 3点 |
| F.5-F.7 | 基于协议重构 + 集成测试补齐 → ~65% 覆盖 | 6点 |

**小计**: 14 点

### v2.2b — QuickBar Liquid Glass 体验

| 任务 | 内容 | 工时 |
|------|------|------|
| H.1 | QuickBar 菜单项添加 `.glassEffect()`（macOS 26+） | 1点 |
| H.2 | Tips/教程页面（快捷键 + 隐藏功能一览） | 2点 |
| H.3 | 快捷键录制 UI 添加「重置为默认」按钮 | 1点 |
| H.4 | 图片预览渐进式加载占位 | 1点 |

**小计**: 5 点

### v2.2c — 集成测试补齐

| 任务 | 内容 | 工时 |
|------|------|------|
| G.4 | 批量选择操作测试（多选 + 批量固定/删除） | 2点 |
| G.5 | 分组折叠 + 持久化测试 | 1点 |
| G.6 | 长按预览 + IME 键盘导航测试 | 2点 |
| G.7 | AppPicker 排除应用功能测试 | 1点 |
| G.8 | 开机自启 + 语言切换测试 | 1点 |
| G.9 | Swift 6 严格并发检查 | 1点 |

**小计**: 8 点

**v2.2 总计**: 27 点

### 执行顺序

```
v2.2a (协议) ──→ v2.2c (测试补齐)
     │                  ↑
     └── (接口就绪) ─────┘

v2.2b (QuickBar + Tips) ← 独立，随时可做
```

v2.2a 和 v2.2b 互不依赖，可以并行。v2.2c 依赖 v2.2a 的协议定义。

### 验收标准

- [ ] CryptoServiceProtocol + SensitiveDetectorProtocol 定义完成
- [ ] ServiceContainer 正确接入生产代码
- [ ] Mock 实现可正常用于测试
- [ ] QuickBar 菜单项使用 `.glassEffect()` 的 Liquid Glass 交互
- [ ] Tips 教程页面可访问
- [ ] 现有 64 测试全部通过
- [ ] 测试覆盖率 ≥ 50%

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
| v2.2a | F.1 ∥ F.2（协议定义可并行） |
| v2.2a/b | F.1-F.4 ∥ H.1-H.4（架构与体验互不依赖） |
| v2.2b | H.1 ∥ H.2 ∥ H.3 ∥ H.4（各自独立） |

---

## 依赖关系

```
v2.1 (完成) → v2.2a (ServiceContainer) ──→ v2.2c (集成测试)
                                    ↘
                                     v2.2b (体验) → 独立
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
| 魔法数字硬编码（窗口尺寸等） | v2.2b 随 Tips 页面一起 |
| 重复日期格式化代码 | 按需提取 |
| SwiftLint 警告 | 保持零警告策略 |
| OSAllocatedUnfairLock → Actor | v2.3 并发检查时评估 |

---

## 风险与缓解

| 风险 | 缓解 |
|------|------|
| 协议抽象破坏现有 API | 保持现有接口不变，内部重构 |
| 测试覆盖达标但场景遗漏 | 关键路径必须覆盖（复制/粘贴/搜索） |
| v2.2b 影响 UI 稳定性 | 每次改动跑 64 测试 + 手动验证清单 |

---

**总计预估**: v2.2 ~27 点 + v2.3 ~14 点 = ~41 点
