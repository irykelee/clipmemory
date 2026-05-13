# 剪忆 ClipMemory v2

**新一代 macOS 剪贴板管理器 — 一步开启，复制即搜**

[English](./docs/lang/README_EN.md) · [简体中文](./README.md) · [繁體中文](./docs/lang/README_ZH-HANT.md) · [日本語](./docs/lang/README_JA.md) · [한국어](./docs/lang/README_KO.md) · [Español](./docs/lang/README_ES.md) · [Português](./README_PT.md)

---

## v1 → v2 核心升级

| 维度 | v1 | v2 |
|------|----|----|
| **交互入口** | 菜单 → 菜单 → 窗口（三步） | Quick Bar 弹窗（一步） |
| **主界面** | 固定宽度，无侧边栏 | 固定侧边栏，随时切换类型 |
| **全局快捷键** | 仅 Cmd+Ctrl+V | 支持自定义录制 |
| **Quick Bar** | 无 | 最近 8 条弹窗，即搜即复制 |
| **搜索高亮** | 文本覆盖高亮 | 不区分大小写，不乱码 |
| **长按预览** | 无 | 0.4s 揭示全文 / 敏感 / 图片原图 |
| **时间分组** | 无 | 今天 / 昨天 / 更早，可折叠 |

---

## 功能亮点

### Quick Bar — 一步即达

点击菜单栏图标 → NSPopover 弹出最近 8 条 → 点击复制 / 搜索 / 打开完整窗口

### 长按 0.4s — 预览无限制

| 内容类型 | 默认显示 | 长按后 |
|---------|---------|--------|
| 普通文本 | 前 200 字符，3 行 | 全文显示 |
| 敏感内容 | 遮罩 `ab••••••yz` | 揭示原文 |
| 图片 | 缩略图 80px | 放大至 300px |

### 智能安全 — 加密 + 敏感检测

- AES-256-GCM 加密（v2），兼容旧版 AES-CBC+HMAC-SHA256
- 25+ 条规则自动识别敏感内容（密码 / API 密钥 / 身份证号等）
- 密码管理器在前台时自动暂停，不从 App 内复制
- 加密失败时内容不落地，拒绝明文存储

---

## 功能列表

- 📋 剪贴板历史（文本 / 图片 / 链接）
- ⭐ 收藏重要条目，不自动清理
- 💾 图片加密存储，突破 10MB 限制
- 🔍 实时搜索，所有语言高亮（含中日韩等多字节字符）
- ⚡ 智能去重，相同内容只更新时间戳
- 🔄 复制循环拦截，从 App 内复制自动跳过
- 🧹 孤立文件清理，启动时自动清理无引用图片
- 🌍 7 种语言（简体中文 / 繁體中文 / English / 日本語 / 한국어 / Español / Português）
- ☑️ 多选批量收藏 / 删除
- ✅ 复制成功绿色闪烁反馈
- ⚙️ 首次启动自动检测快捷键冲突
- ⌨️ 全局快捷键 `Cmd+Ctrl+V`
- 🖥 开机自启（设置中开启）
- 📐 字体缩放（小 / 中 / 大）
- 🎨 外观（浅色 / 深色 / 跟随系统）

---

## 使用方法

| 操作 | 方式 |
|------|------|
| 弹出 Quick Bar | 左键点击菜单栏 📋 图标 / `Cmd+Ctrl+V` |
| 复制条目 | 点击条目 / 键盘 ↑↓ + Enter |
| 打开完整窗口 | Quick Bar → "打开完整窗口" |
| 搜索 | 输入关键词，匹配处高亮 |
| 收藏 / 取消收藏 | 点击 ⭐ 或双击条目 |
| 删除 | 点击 🗑 或右键菜单 |
| 预览全文 / 敏感内容 / 图片 | 按住 0.4s，松开恢复 |
| 多选批量操作 | 单击复选框进入多选模式 |
| 清空历史 | 顶栏 🗑（保留收藏条目） |

> 💡 收藏的条目不会被自动清理。复制相同内容不重复记录，只更新时间戳。

---

## 安全特性

- **AES-256-GCM（v2）+ 兼容旧版 AES-CBC+HMAC-SHA256** — 所有文本和图片存入磁盘前自动加密
- **智能检测** — 25+ 条规则（关键词 + 正则），自动识别密码、API 密钥、token、私钥、身份证号、银行卡号等
- **自动清理** — 敏感内容可设置 1 小时 / 24 小时 / 48 小时 / 7 天后自动清除，或不自动清除

---

## 偏好设置

- 历史记录最大条数（50 / 100 / 200 / 500 条）
- 敏感信息清除策略（1 小时 / 24 小时 / 48 小时 / 7 天 / 不自动清除）
- 语言切换（7 种语言）
- 全局快捷键录制
- 外观（浅色 / 深色 / 跟随系统）
- 排除应用（自定义不监控的 App）

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
- 反馈：偏好设置 → 关于 → 发送反馈 → GitHub Issues
