# ClipMemory v2

**新一代 macOS 剪贴板管理器 — 更好的 UI、更快的操作、更多功能**

[English](./docs/lang/README_EN.md) · [简体中文](./README.md) · [繁體中文](./docs/lang/README_ZH-HANT.md) · [日本語](./docs/lang/README_JA.md) · [한국어](./docs/lang/README_KO.md) · [Español](./docs/lang/README_ES.md) · [Português](./docs/lang/README_PT.md)

---

## 相比于 v1 的改进

| 维度 | v1 | v2 |
|------|----|----|
| **交互入口** | 菜单栏点击 → 菜单列表 → 打开窗口（三步） | 菜单栏点击 → Quick Bar 弹窗（一步） |
| **主界面** | 固定宽度的 ContentView，无侧边栏 | **NavigationSplitView 侧边栏**：All / Text / Image / Link / Pinned / Settings |
| **类型过滤** | FilterChip 水平按钮组 | 侧边栏垂直导航列表，带上自动计数的条目数量 |
| **时间分组** | 无分组 | 今天 / 昨天 / 本周 / 本月 / 更早，支持折叠 |
| **全局热键** | 仅 Cmd+Ctrl+V | 支持自定义快捷键（设置页录制） |
| **Quick Bar 弹窗** | 无 | 菜单栏点击弹出最近 8 条内容，搜索、复制、打开窗口一步到位 |
| **搜索高亮** | 在文本上高亮 | 高亮用 `offsetByCharacters` 计算，中英文准确匹配 |
| **长按预览** | 无 | 文本按住 0.4s 显示全文、敏感内容按住揭示原文、图片按住放大至 300px |
| **图标排列** | 复选框 + 类型图标 + 星标 + 内容 | 复选框 + 内容 + 星标 + 删除，去掉冗余类型图标 |
| **窗口样式** | 标准 NSWindow | `.fullSizeContentView` + `.ultraThinMaterial`/`.regularMaterial` 毛玻璃效果 |
| **红绿灯** | 标题栏内 | 标题栏隐藏，红绿灯嵌入工具栏同一行（macOS 26 Liquid Glass 风格） |
| **Dock 图标** | 一直隐藏 | 打开窗口时出现 Dock 图标，关闭后消失 |
| **右键高亮** | 不高亮 | 悬停自动高亮 |
| **字体缩放** | 无 | 设置页支持小/中/大三档全局字体缩放 |
| **开机自启** | 无（仅菜单栏操作） | 菜单栏保留「登录时启动」 |
| **设置页布局** | 基础的 Form | 侧边栏独立设置页，分组标明、间距优化 |

---

## 新增功能

### Quick Bar（菜单栏弹窗）
点击菜单栏图标 → NSPopover 弹窗 → 最近 8 条内容 → 点击复制 / 搜索 / 打开完整窗口

### 长按操作（0.4s）
| 内容类型 | 默认显示 | 长按后 |
|---------|---------|--------|
| 普通文本 | 前 200 字符，3 行截断 | 全文显示（无行数限制）|
| 敏感内容 | 遮罩 `ab••••••yz` | 揭示原文 + 搜索高亮 |
| 图片 | 缩略图 80px | 放大至 300px |

### 时间线分组
剪贴板列表自动按创建时间分组：今天 / 昨天 / 本周 / 本月 / 更早，可折叠。

### 全局字体缩放
设置页 → 字体大小 → 小/中/大，所有界面文字同步缩放。

### 快捷键自定义
设置页可录制新的全局快捷键替代默认 `Cmd+Ctrl+V`。

---

## 功能特点

- 📋 剪贴板历史记录（文本 / 图片 / 链接）
- ⭐ 收藏重要片段，不被自动清理
- 💾 图片加密文件存储，突破 10MB 限制
- 🔍 实时搜索，中英文精确高亮
- ✅ 复制绿色闪烁反馈
- ☑️ 多选批量收藏 / 删除
- 🔒 敏感信息自动检测（25+ 条规则）+ AES-256 加密 + HMAC 认证
- ⌨️ 全局快捷键 `Cmd+Ctrl+V`
- 🌍 7 种语言（简体中文 / 繁體中文 / English / 日本語 / 한국어 / Español / Português）
- 📎 设置 → 关于 → 发送反馈 → GitHub Issues

---

## 使用方法

| 操作 | 方式 |
|------|------|
| 弹出 Quick Bar | 左键点击菜单栏 📋 图标 / `Cmd+Ctrl+V` |
| 复制 Quick Bar 条目 | 点击条目 / 键盘 ↑↓ + Enter |
| 打开完整窗口 | Quick Bar → "打开完整窗口" |
| 搜索 | 输入关键词实时过滤，匹配高亮 |
| 收藏 / 取消收藏 | 点击 ⭐、双击条目、或右键菜单 |
| 删除 | 点击 🗑 或右键菜单 |
| 查看敏感内容 | 按住 0.4s 揭示原文，松开隐藏 |
| 查看图片原图 | 按住 0.4s 放大，松开恢复 |
| 查看全文 | 按住 0.4s 显示全部文字 |
| 多选 | 单击复选框进入多选模式 |
| 批量操作 | 多选后批量收藏 / 删除 |
| 关闭窗口 | `Esc` |
| 清空历史 | 顶栏 🗑 按钮（保留收藏条目） |

> 💡 已收藏的条目不会被自动清理。复制相同内容不会重复记录，只更新时间戳提到顶部。

---

## 安全特性

- **AES-256 + HMAC-SHA256 认证加密** — 所有文本和图片内容在存入磁盘前自动加密
- **智能检测** — 25+ 条检测规则（关键词 + 正则），自动识别密码、API key、token、私钥、身份证号、银行卡号等
- **自动清理** — 敏感内容可设置 1 小时 / 24 小时 / 48 小时 / 7 天后自动清除，或永不自动清除

---

## 设置选项

- 历史记录最大条数（50 / 100 / 200 / 500 条）
- 敏感信息清除策略（1 小时 / 24 小时 / 48 小时 / 7 天 / 不自动清除）
- 语言切换（7 种语言）
- 全局快捷键录制
- 字体大小（小 / 中 / 大）

---

## 系统要求

- macOS 13.0 (Ventura) 或更高版本

---

## 安装

```bash
brew tap irykelee/clipmemory https://github.com/irykelee/clipmemory && brew install --cask clipmemory
```

安装后 App 在 `/Applications/ClipMemory.app`。启动后看**屏幕右上角菜单栏**的 📋 图标，点击即可使用。

或从 [GitHub Releases](https://github.com/irykelee/clipmemory/releases) 下载 `.tar.gz` 手动解压到 `/Applications/`。

---

## 开发

```bash
brew install swiftlint xcodegen
xcodegen generate
xcodebuild -scheme ClipMemory -configuration Release
```

---

## 联系方式

- GitHub: https://github.com/irykelee/clipmemory
- Feedback: 设置 → 关于 → 发送反馈 → GitHub Issues
