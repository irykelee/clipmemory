# ClipMemory 开发规划

**版本**: v2.0.5
**更新**: 2026-05-13
**状态**: 进行中

---

## 目标

遵循 ECC 开发标准，在不破坏现有高质量代码的基础上，建立完整的测试体系（80% 覆盖率），并引入轻量协议抽象以提升可测试性。

---

## 当前状态

| 维度 | 现状 | ECC 标准 | 差距 |
|------|------|----------|------|
| 代码质量 | SwiftLint 通过 | SwiftLint + SwiftFormat | 已达标 |
| 加密 | CryptoKit AES-GCM | CryptoKit 现代化加密 | 已达标 |
| 线程安全 | OSAllocatedUnfairLock | Actor 模式（长期） | 需改进 |
| 测试覆盖 | **0%** | **80%** | **严重不足** |
| 协议抽象 | 无 | 轻量协议 | 需建立 |
| 架构可测试性 | 低 | 依赖注入 + Mock | 需改进 |

---

## 阶段一：v2.1 — 安全关键测试

**目标**: 20% 覆盖（加密 + 敏感检测优先）

### 优先级顺序

```
C.1-C.4 (加密+legacy)    → P0，最先，安全关键
D.1-D.3 (敏感检测)        → P0，第二，安全关键
A.1   (测试目标配置)      → P0，独立，基础设施
B.1-B.5 (ClipboardItem)  → P1，低风险模型测试
E.1   (并发回归测试)      → P1，防止线程安全回退
```

### 任务详情

#### C.1-C.4 加密服务测试（P0 — 安全关键）

| 任务 | 内容 | 工时 |
|------|------|------|
| C.1 | AES-GCM 加密/解密往返测试 | 2点 |
| C.2 | 密钥生成与派生测试 | 2点 |
| C.3 | Legacy AES-CBC 兼容解密测试（v1 格式兼容） | 2点 |
| C.4 | 加密边界条件 + 并发回归测试 | 2点 |

#### D.1-D.3 敏感内容检测测试（P0 — 安全关键）

| 任务 | 内容 | 工时 |
|------|------|------|
| D.1 | 密码/凭证模式检测（password/pwd/token/sk-/ghp_/私钥等） | 2点 |
| D.2 | API Key/Token 模式检测（AWS/GitHub/JWT等） | 2点 |
| D.3 | 个人身份信息检测（身份证/银行卡/SSN） | 2点 |

#### A.1 测试目标配置（P0 — 基础设施）

| 任务 | 内容 | 工时 |
|------|------|------|
| A.1 | 创建 Swift Testing 测试目标，配置 XcodeGen + SwiftLint | 2点 |

#### B.1-B.5 ClipboardItem 模型测试（P1）

| 任务 | 内容 | 工时 |
|------|------|------|
| B.1 | ClipboardItem 构造与 Equatable/Codable 测试 | 2点 |
| B.2 | 内容匹配逻辑（SHA256 哈希预过滤）测试 | 1点 |
| B.3 | 过期时间计算（expiresAt）测试 | 1点 |
| B.4 | 相对/绝对时间格式化测试 | 2点 |
| B.5 | ClipboardItemType 枚举覆盖测试 | 1点 |

#### E.1 并发回归测试（P1 — 防回退）

| 任务 | 内容 | 工时 |
|------|------|------|
| E.1 | OSAllocatedUnfairLock 保护下的并发读写测试 | 2点 |
| E.2 | skipNextCapture 竞态条件测试 | 1点 |
| E.3 | @Published 跨线程修改不崩溃验证 | 1点 |

**v2.1 小计**: 20 点

### 验收标准

- [ ] `swift test --enable-code-coverage` 可运行
- [ ] AES-GCM 加密/解密往返测试通过
- [ ] Legacy v1 格式兼容解密测试通过
- [ ] 敏感内容检测覆盖主要模式类型
- [ ] 并发回归测试覆盖 stateLock 保护路径
- [ ] 测试覆盖率 ≥ 20%

---

## 阶段二：v2.2 — 协议抽象与轻量 DI

**目标**: 50% 覆盖

### 轻量 DI 方案

不采用全链路 constructor injection，使用 ServiceContainer 模式：

```swift
// 协议定义
protocol CryptoServiceProtocol: Sendable {
    func encrypt(_ string: String) -> String?
    func decrypt(_ base64String: String) -> String?
    func isOldFormat(_ base64String: String) -> Bool
    func migrateToV2(_ base64String: String) -> String?
}

protocol SensitiveDetectorProtocol: Sendable {
    func isSensitive(_ content: String) -> Bool
}

protocol ClipboardRepositoryProtocol: Sendable {
    associatedtype Item: Identifiable & Sendable & Codable
    var items: [Item] { get }
    func addItem(_ item: Item)
    func deleteItem(_ item: Item)
    func togglePin(_ item: Item)
    // ...
}

// 服务容器
enum ServiceContainer {
    static var crypto: CryptoServiceProtocol = CryptoService.shared
    static var detector: SensitiveDetectorProtocol = ClipboardMonitor.shared
    static var store: ClipboardRepositoryProtocol = ClipboardStore.shared
}

// 测试时替换
ServiceContainer.crypto = MockCryptoService()
```

### 任务详情

| 任务 | 内容 | 工时 |
|------|------|------|
| F.1 | 定义 CryptoServiceProtocol + SensitiveDetectorProtocol | 3点 |
| F.2 | 定义 ClipboardRepositoryProtocol | 3点 |
| F.3 | ServiceContainer 接入 + 默认实现替换 | 2点 |
| F.4 | MockCryptoService / MockSensitiveDetector / MockRepository 实现 | 3点 |
| F.5 | 基于协议重构 ClipboardMonitor 使其可测 | 3点 |
| F.6 | 基于协议重构 ClipboardStore 使其可测 | 3点 |
| F.7 | 集成测试覆盖 CRUD + 过期清理 + 去重 | 6点 |

**v2.2 小计**: 23 点

### 验收标准

- [ ] 所有服务层协议定义并文档化
- [ ] ServiceContainer 正确接入生产代码
- [ ] Mock 实现可正常用于测试
- [ ] 现有功能回归测试通过
- [ ] 测试覆盖率 ≥ 50%

---

## 阶段三：v2.3 — 完善测试覆盖

**目标**: 80% 覆盖

### 任务详情

| 任务 | 内容 | 工时 |
|------|------|------|
| G.1 | ContentView 搜索功能集成测试（防抖 + 高亮） | 2点 |
| G.2 | QuickBarView 键盘导航测试（↑↓ Enter Esc） | 2点 |
| G.3 | 主题切换测试（system/light/dark + window effect） | 2点 |
| G.4 | 批量选择操作测试（多选 + 批量固定/删除） | 2点 |
| G.5 | 分组折叠 + 持久化测试 | 2点 |
| G.6 | 长按预览 + IME 键盘导航测试 | 2点 |
| G.7 | AppPicker 排除应用功能测试 | 1点 |
| G.8 | 开机自启 + 语言切换测试 | 1点 |
| G.9 | Swift 6 严格并发检查通过（无警告） | 2点 |

**v2.3 小计**: 16 点

### 验收标准

- [ ] 搜索、主题、键盘导航测试覆盖
- [ ] 批量操作 + 分组折叠测试覆盖
- [ ] Swift 6 严格并发检查通过
- [ ] 测试覆盖率 ≥ 80%

---

## 并行任务组

以下任务可并行执行：

| 组别 | 并行任务 |
|------|----------|
| C 组 | C.1 ∥ C.2 ∥ C.3 ∥ C.4 |
| D 组 | D.1 ∥ D.2 ∥ D.3 |
| B 组 | B.1 ∥ B.2 ∥ B.3 ∥ B.4 ∥ B.5 |
| F 组 | F.1 ∥ F.2 ∥ F.3 ∥ F.4（并行协议定义） |

---

## 依赖关系

```
v2.1:
  A.1 → C.1-C.4, D.1-D.3, B.1-B.5（基础设施完成后才能写测试）
  C.1-C.4 → E.1-E.3（加密测试驱动并发回归）

v2.1 → v2.2:
  C.1-C.4, D.1-D.3 测试通过后 → F.1-F.7 协议抽象 + DI

v2.2 → v2.3:
  协议 + DI 就绪后 → G.1-G.9 集成 + UI 测试
```

---

## 不纳入规划的内容

### v3.0 SQLite 迁移 — 不做

ClipMemory 核心需求是加密文件存储 + 少量元数据，文件系统比 SQLite 更适合：

- 已有 UserDefaults 存储元数据 JSON（几百到几千条完全够用）
- 图片已存文件系统
- SQLite 增加 C 库依赖 + 迁移复杂度
- 除非要支持百万级条目或复杂全文检索，否则收益 < 维护代价

若将来有复杂查询需求，再单独评估。

### UI — 冻结

Liquid Glass 重建已完成，专注测试和架构，不再改动 UI。

---

## 技术债务（可选，v2.x 周期内处理）

| 债务项 | 建议 | 优先级 |
|--------|------|--------|
| OSAllocatedUnfairLock → Actor | v2.2 协议抽象后自然迁移 | 低 |
| SwiftLint 警告 | 日常修复，不累积 | 低 |
| 魔法数字硬编码 | 提取为 Constants | 低 |
| 重复日期格式化代码 | 按需提取 A.2-A.4 | 按需 |

---

## 风险与缓解

| 风险 | 影响 | 缓解措施 |
|------|------|----------|
| Swift 6 并发迁移破坏现有代码 | 高 | 先加测试，再逐文件迁移 |
| 协议抽象改变 public API | 低 | 保持现有接口不变，仅内部重构 |
| 测试覆盖率达标但场景遗漏 | 中 | 关键路径必须覆盖（复制/粘贴/搜索） |

---

**总预估**: ~59 任务点

| 阶段 | 任务点 |
|------|--------|
| v2.1 | 20 点 |
| v2.2 | 23 点 |
| v2.3 | 16 点 |
