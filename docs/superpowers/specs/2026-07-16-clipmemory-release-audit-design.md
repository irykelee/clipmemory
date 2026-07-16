# ClipMemory v2.2.4 发布前审计与修复设计

- **日期**：2026-07-16
- **状态**：用户已批准设计
- **目标**：在创建 v2.2.4 Release 之前，确认并修复当前 `main` 中所有真实问题，再统一发布元数据与安装包。

## 1. 范围

本次工作覆盖当前 `main` 的发布前完整审计，不只处理已知的版本漂移：

### 核心功能

- 剪贴板捕获、去重和敏感内容处理
- 文本、图片、富文本三类数据
- 搜索、筛选、时间分组
- 收藏、删除、批量操作和敏感内容清理
- Quick Bar、主窗口和全局快捷键
- 设置持久化与语言切换

### 数据与安全

- AES-GCM v2 格式
- Legacy AES-CBC + HMAC 兼容读取
- 密钥文件创建、权限和竞态
- 文本和图片的加密落盘
- 图片路径校验与孤立文件清理
- 解密失败、损坏数据和敏感检测边界

### 并发与生命周期

- `ClipboardMonitor` 状态锁
- `@Published` 主线程约束
- `NSCache` 使用
- App 启动、退出和窗口重建
- 快捷键注册与注销
- 搜索 debounce 和后台任务

### 构建与发布

- `project.yml` 与生成的 Xcode 项目
- Debug / Release build
- `Scripts/package.sh`
- Homebrew Cask 的版本、URL 和 SHA256
- 7 个语言 README 与 `docs/roadmap.md`
- GitHub Release asset 完整性

OCR 属于后续 v2.4 功能，不纳入本次修复范围。

## 2. 问题分级与收口标准

只记录有证据的问题：可复现、可由代码路径证明，或由构建/测试工具明确报告。

| 级别 | 定义 | 发布要求 |
|------|------|----------|
| Blocker | 安全漏洞、数据丢失、无法构建或无法安装 | 必须修复 |
| High | 核心功能错误、发布包不可用、严重兼容问题 | 必须修复 |
| Medium | 明确可复现的边界缺陷、错误处理缺失、关键测试缺口 | 必须修复 |
| Low | 真实但不阻塞使用的问题，例如 lint warning、过期默认值、文档漂移 | 本次修复；纯风格偏好不处理 |

不把“可以换一种写法”、无收益重构或未来功能建议当作 Bug。

## 3. 审计与修复流程

### 阶段 1：建立基线

记录当前：

- `main` 与 `origin/main` 的关系
- 当前版本号、tag、Cask、README 和 roadmap
- 测试数量与结果
- SwiftLint warning
- Debug / Release build 状态

### 阶段 2：按数据流审计

核心链路按完整路径检查：

```text
系统剪贴板
  → ClipboardMonitor
  → 敏感检测 / 去重
  → ClipboardStore
  → CryptoService / ImageStorage
  → StorageBackend
  → ContentView / QuickBarView
  → 用户复制、删除、清理
```

每个发现都必须说明输入来源、经过的中间层、最终消费者、异常处理方式、相似路径的对照结果，以及复现或验证方式。

### 阶段 3：逐项修复

对每个确认的问题：

1. 先写最小回归测试
2. 确认测试在修复前能暴露问题
3. 做最小代码修改
4. 运行相关测试
5. 运行完整测试
6. 更新必要文档

无关问题不合并到同一处修改中。

### 阶段 4：发布质量门

只有以下条件全部满足才进入发布准备：

- 所有真实 Blocker / High / Medium / Low 问题已处理或明确排除
- SwiftLint 零 warning
- 单元和集成测试全部通过
- Release build 成功
- 关键功能完成实际运行验证
- 版本元数据统一为 `2.2.4`
- `v2.2.3` 历史 tag 未被改写
- Cask SHA256 与实际打包文件一致
- 7 个 README 与 roadmap 已同步

## 4. 预期变更文件

只在审计确认问题后修改：

- `ClipMemory/Services/` 中实际受影响的服务
- `ClipMemory/Views/` 中实际受影响的视图
- `Tests/ClipMemoryTests/` 中对应的回归测试
- `project.yml`
- `Scripts/package.sh`
- `Casks/clipmemory.rb`
- `README.md` 与 `docs/lang/` 下 6 个语言 README
- `docs/roadmap.md`

不引入新的第三方依赖，不做 SQLite 迁移或架构升级。

## 5. 版本与发布策略

保留现有 `v2.2.3` tag，不改写已发布历史。当前 `main` 审计和修复完成后，以 `v2.2.4` 为统一目标：

1. 更新 `project.yml` 版本
2. 重新生成 Xcode 项目
3. 运行测试与 Release build
4. 打包并计算 SHA256
5. 同步 Cask、README、roadmap 和打包脚本
6. 创建 `v2.2.4` Release
7. 上传 `ClipMemory.tar.gz`

GitHub push 和 Release 创建只在本地审计、修复、测试和打包全部通过后执行。

## 6. 不纳入本次工作的内容

- OCR 图片敏感检测
- SQLite 迁移
- 完整 DI 框架
- SwiftUI → AppKit 迁移
- 与发布稳定性无关的重构
- 纯个人风格偏好
