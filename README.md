# ClipMemory 剪忆

**Local Clipboard History Manager / 本地剪贴板历史管理器**

[English](./docs/lang/README_EN.md) · [简体中文](./README.md) · [Español](./docs/lang/README_ES.md) · [Português](./docs/lang/README_PT.md) · [日本語](./docs/lang/README_JA.md) · [한국어](./docs/lang/README_KO.md)

---

## 简介

剪忆是一款 macOS 本地剪贴板历史管理器，永久记忆你的每一次复制。

### 功能特点

- 📋 剪贴板历史记录（文本/图片/链接）
- ⭐ 固定重要片段，永不丢失
- 💾 图片突破存储限制（文件存储）
- 🔍 快速搜索历史记录
- 🔒 敏感信息自动保护（加密存储 + 自动清理）
- ⌨️ 全局快捷键 `Cmd+Ctrl+V` 呼出
- 🛡️ 开机自启动（可选）
- 🌍 多语言支持（简体中文/English/日语/韩语/西班牙语/葡萄牙语）

### 安全特性

- **AES-256 加密存储** — 敏感内容（密码、API密钥等）使用 AES-256 加密存储
- **密钥安全保管** — 加密密钥存储在 macOS Keychain，设备级别保护
- **智能检测** — 支持 25+ 种敏感信息模式检测
- **自动清理** — 敏感内容可设置自动清除时间

### 使用方法

| 操作 | 方式 |
|------|------|
| 呼出窗口 | `⌘⇧V`（全局热键，任意界面均可） |
| 上下选择 | `↑` / `↓` 键循环浏览 |
| 复制内容 | `Enter` 复制选中项并关闭窗口 |
| 关闭窗口 | `Esc` |
| 搜索 | 输入关键词实时过滤 |
| 固定片段 | 点击 ⭐ 或右键菜单「固定片段」|
| 取消固定 | 再次点击 ⭐ 或右键菜单「取消固定」|
| 删除片段 | 点击 🗑 或右键菜单「删除」|
| 查看敏感内容 | 点击橙色遮罩文字「查看」|
| 清空历史 | 顶部「清空」按钮（保留固定片段）|

> 💡 固定片段不会被自动清理，也不会触发去重（复制相同内容会更新时间戳）

### 设置选项

- 历史记录最大条数（50/100/200/500/1000/2000条）
- 敏感信息清除策略（1小时/24小时/48小时/7天/不自动清除）
- 语言切换

### 系统要求

- macOS 13.0 (Ventura) 或更高版本

### 安装

```bash
brew install --cask https://raw.githubusercontent.com/irykelee/clipmemory/main/clipmemory.rb
```

### 联系方式

- GitHub: https://github.com/irykelee/clipmemory

### 开发

```bash
# 安装依赖
brew install swiftlint xcodegen

# 生成 Xcode 项目
xcodegen generate

# 构建
xcodebuild -scheme ClipMemory -configuration Release
```

---

## English

For English documentation, please visit: [English README](./docs/lang/README_EN.md)

### 简介

剪忆是一款 macOS 本地剪贴板历史管理器，永久记忆你的每一次复制。

### 功能特点

- 📋 剪贴板历史记录（文本/图片/链接）
- ⭐ 固定重要片段，永不丢失
- 💾 图片突破存储限制（文件存储）
- 🔍 快速搜索历史记录
- 🔒 敏感信息自动保护（加密存储 + 自动清理）
- ⌨️ 全局快捷键 `Cmd+Ctrl+V` 呼出
- 🛡️ 开机自启动（可选）
- 🌍 多语言支持（简体中文/English）

### 安全特性

- **AES-256 加密存储** — 敏感内容（密码、API密钥等）使用 AES-256 加密存储
- **密钥安全保管** — 加密密钥存储在 macOS Keychain，设备级别保护
- **智能检测** — 支持 25+ 种敏感信息模式检测：
  - 私钥格式（RSA、EC、OpenSSH）
  - API 密钥（AWS、Google AI、Stripe、Square 等）
  - 通用凭证模式（password=value、token=value 等）
- **自动清理** — 敏感内容可设置自动清除时间

### 使用方法

| 操作 | 方式 |
|------|------|
| 呼出窗口 | `⌘⇧V`（全局热键，任意界面均可） |
| 上下选择 | `↑` / `↓` 键循环浏览 |
| 复制内容 | `Enter` 复制选中项并关闭窗口 |
| 关闭窗口 | `Esc` |
| 搜索 | 输入关键词实时过滤 |
| 固定片段 | 点击 ⭐ 或右键菜单「固定片段」|
| 取消固定 | 再次点击 ⭐ 或右键菜单「取消固定」|
| 删除片段 | 点击 🗑 或右键菜单「删除」|
| 查看敏感内容 | 点击橙色遮罩文字「查看」|
| 清空历史 | 顶部「清空」按钮（保留固定片段）|

> 💡 固定片段不会被自动清理，也不会触发去重（复制相同内容会更新时间戳）

### 设置选项

- 历史记录最大条数（50/100/200/500/1000/2000条）
- 敏感信息清除策略（1小时/24小时/48小时/7天/不自动清除）
- 语言切换

### 系统要求

- macOS 13.0 (Ventura) 或更高版本

### 安装

```bash
brew install --cask https://raw.githubusercontent.com/irykelee/clipmemory/main/clipmemory.rb
```

### 联系方式

- GitHub: https://github.com/irykelee/clipmemory

### 开发

```bash
# 安装依赖
brew install swiftlint xcodegen

# 生成 Xcode 项目
xcodegen generate

# 构建
xcodebuild -scheme ClipMemory -configuration Release
```

---

## English {#english}

### Introduction

ClipMemory is a local clipboard history manager for macOS. Never lose what you copy.

### Features

- 📋 Clipboard history (text/images/links)
- ⭐ Pin important snippets, never lose them
- 💾 Images stored as files, no storage limits
- 🔍 Quick search through history
- 🔒 Sensitive info protection (encrypted + auto-clear)
- ⌨️ Global hotkey `Cmd+Ctrl+V` to summon
- 🛡️ Launch at login (optional)
- 🌍 Multi-language support (Chinese/English)

### Security Features

- **AES-256 Encryption** — Sensitive content (passwords, API keys) encrypted with AES-256
- **Secure Key Storage** — Encryption keys stored in macOS Keychain with device-level protection
- **Smart Detection** — 25+ sensitive data patterns:
  - Private key formats (RSA, EC, OpenSSH)
  - API keys (AWS, Google AI, Stripe, Square, etc.)
  - Generic credential patterns (password=value, token=value, etc.)
- **Auto-Clear** — Configurable auto-clear time for sensitive content

### Usage

| Action | How |
|--------|-----|
| Summon window | `⌘⇧V` (global hotkey, works anywhere) |
| Navigate | `↑` / `↓` keys to cycle through items |
| Copy item | `Enter` copies selected and closes window |
| Close window | `Esc` |
| Search | Type to filter history in real-time |
| Pin item | Click ⭐ or right-click → "Pin" |
| Unpin item | Click ⭐ again or right-click → "Unpin" |
| Delete item | Click 🗑 or right-click → "Delete" |
| Reveal sensitive | Click orange masked text → "View" |
| Clear history | Top "Clear" button (pinned items preserved) |

> 💡 Pinned items are never auto-cleared and won't trigger deduplication (re-copying updates timestamp)

### Settings

- Max history items (50/100/200/500/1000/2000)
- Sensitive data auto-clear policy (1h/24h/48h/7days/never)
- Language switcher

### Requirements

- macOS 13.0 (Ventura) or higher

### Installation

```bash
brew install --cask https://raw.githubusercontent.com/irykelee/clipmemory/main/clipmemory.rb
```

### Contact

- GitHub: https://github.com/irykelee/clipmemory

### Development

```bash
# Install dependencies
brew install swiftlint xcodegen

# Generate Xcode project
xcodegen generate

# Build
xcodebuild -scheme ClipMemory -configuration Release
```
