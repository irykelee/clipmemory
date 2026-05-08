# ClipMemory 剪忆

**Local Clipboard History Manager / 本地剪贴板历史管理器**

[English](./docs/lang/README_EN.md) · [简体中文](./README.md) · [Español](./docs/lang/README_ES.md) · [Português](./docs/lang/README_PT.md) · [日本語](./docs/lang/README_JA.md) · [한국어](./docs/lang/README_KO.md)

---

## 简介

剪忆是一款 macOS 本地剪贴板历史管理器，永久记忆你的每一次复制。

### 功能特点

- 📋 剪贴板历史记录（文本 / 图片 / 链接）
- ⭐ 收藏重要片段，不被自动清理
- 💾 图片突破存储限制（加密文件存储）
- 🔍 实时搜索，匹配内容高亮显示
- ✅ 复制反馈（绿色闪烁提示）
- ☑️ 多选批量操作（收藏 / 删除）
- 🔒 敏感信息自动检测 — 25+ 条规则，自动加密 + 定时清理
- ⌨️ 全局快捷键 `Cmd+Ctrl+V` 呼出
- 🌍 7 种语言（简体中文 / 繁體中文 / English / 日本語 / 한국어 / Español / Português）
- 📎 菜单栏「反馈」直达 GitHub Issues

### 安全特性

- **AES-256 加密存储** — 所有文本和图片内容在存入磁盘前自动加密
- **HMAC-SHA256 认证** — 防止密文被篡改
- **智能检测** — 25+ 条检测规则（含关键词匹配 + 正则匹配），自动识别密码、API key、token、私钥、身份证号、银行卡号等
- **自动清理** — 敏感内容可设置 1 小时 / 24 小时 / 48 小时 / 7 天后自动清除，或设为永不自动清除

### 使用方法

| 操作 | 方式 |
|------|------|
| 呼出窗口 | `Cmd+Ctrl+V`（全局热键，任意界面均可） |
| 上下选择 | `↑` / `↓` 键循环浏览 |
| 复制内容 | `Enter` 或单击（绿色闪烁提示） |
| 多选 | 单击复选框进入多选模式 |
| 批量操作 | 多选后批量收藏 / 删除 |
| 关闭窗口 | `Esc` |
| 搜索 | 输入关键词实时过滤，匹配内容高亮；敏感项搜索时自动显示匹配区域上下文 |
| 收藏 / 取消收藏 | 点击 ⭐、双击条目、或右键菜单 |
| 删除 | 点击 🗑 或右键菜单 |
| 查看敏感内容 | 点击遮罩文字「查看」（搜索时自动局部显现） |
| 清空历史 | 顶部「清空」按钮（保留收藏条目） |
| 提交反馈 | 菜单栏 → Feedback → 打开 GitHub Issues |

> 💡 已收藏的条目不会被自动清理，也不会被清空历史删除。复制相同内容不会重复记录，只更新时间戳提到顶部。

### 设置选项

- 历史记录最大条数（50/100/200/500条）
- 敏感信息清除策略（1小时/24小时/48小时/7天/不自动清除）
- 语言切换

### 系统要求

- macOS 13.0 (Ventura) 或更高版本

### 安装

```bash
brew tap irykelee/clipmemory https://github.com/irykelee/clipmemory
brew install --cask clipmemory
```

安装后 App 在 `/Applications/ClipMemory.app`。启动后看**屏幕右上角菜单栏**的 📋 图标，点击即可使用。「登录时启动」选项在菜单中，启用后每次开机自动运行。

或从 [GitHub Releases](https://github.com/irykelee/clipmemory/releases) 下载 `.tar.gz` 手动解压到 `/Applications/`。

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
