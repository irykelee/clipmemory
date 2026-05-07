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
- 🌍 多语言支持（简体中文/英语/日语/韩语/西班牙语/葡萄牙语）

### 安全特性

- **AES-256 加密存储** — 敏感内容（密码、API密钥等）使用 AES-256 加密存储
- **密钥安全保管** — 加密密钥存储在本地，设备级别保护
- **智能检测** — 支持 25+ 种敏感信息模式检测
- **自动清理** — 敏感内容可设置自动清除时间

### 使用方法

| 操作 | 方式 |
|------|------|
| 呼出窗口 | `⌘⇧V`（全局热键，任意界面均可） |
| 上下选择 | `↑` / `↓` 键循环浏览 |
| 复制内容 | `Enter` 或单击复制选中项并关闭窗口 |
| 关闭窗口 | `Esc` |
| 搜索 | 输入关键词实时过滤 |
| 收藏/取消收藏 | 双击切换收藏状态 |
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
