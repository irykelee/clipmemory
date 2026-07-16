# 剪忆 ClipMemory v2.2.4

**新一代 macOS 剪贴板管理器 — 一步开启，复制即搜**

[English](./docs/lang/README_EN.md) · [简体中文](./README.md) · [繁體中文](./docs/lang/README_ZH-HANT.md) · [日本語](./docs/lang/README_JA.md) · [한국어](./docs/lang/README_KO.md) · [Español](./docs/lang/README_ES.md) · [Português](./docs/lang/README_PT.md)

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

## 📋 更新日志

### v2.2.4 (2026-07-16) — 发布卫生修复

- **版本号与发布标签同步** — `project.yml` 的 `MARKETING_VERSION` 与 `CURRENT_PROJECT_VERSION` 升级到 `2.2.4`，重新生成 `project.pbxproj`。修正 v2.2.3 切标签但未同步版本号导致下游 cask 拿到旧版本的问题
- **Quick Bar 标签修正** — 移除 Quick Bar「打开完整窗口」项上误导性的 `⌘⌃V` 快捷键标签。全局快捷键打开的是完整主窗口，Quick Bar 由菜单栏 📋 图标左键打开
- **文档快捷键说明更正** — 8 种语言 README 中关于 `Cmd+Ctrl+V` 的描述重写，明确该快捷键打开主窗口而非 Quick Bar
- **打包脚本安全加固** — `Scripts/package.sh` 默认版本号改为从 `project.yml` 读取 `MARKETING_VERSION`（含读取失败的防护），避免在不带参数调用时静默打包一个旧版本号的 tarball

### v2.2.1 (2026-05-19) — 图片敏感逻辑修复

- **图片敏感判断修复** — 图片不再按大小（50KB）自动标记敏感，存储由 maxItems 和手动清理控制
- **组件拆分重构** — ContentView 拆分为 FlowLayout、LogoView、DateFilterButton、AppPickerRow、ClipboardItemRow
- **共享工具类** — 提取 FontScaling.swift（sz()）和 DateHelpers.swift（日期格式化）
- **NSCache 内存压力处理** — 添加系统内存警告监听，触发缓存清理

### v2.2.0 (2026-05-15) — 富文本支持

- **RTF 剪贴板捕获** — 自动识别并保存富文本内容
- **富文本渲染** — 支持 NSAttributedString → AttributedString 转换
- **复制回粘** — 同时写入 .rtf 和 .string 两种剪贴板类型
- **侧边栏标签** — 新增「富文本」分类，含图标、计数徽章和类型筛选
- **Quick Bar 展示** — 富文本图标 + 纯文本预览
- **敏感内容遮罩** — 富文本条目同样支持敏感信息掩码
- **85 项测试** — 含 4 项富文本往返测试
- **搜索优化** — 修复富文本搜索功能

### v2.1.5 (2026-05-11) — 协议抽象与交互优化

- **协议抽象** — StorageBackend 协议 + MemoryStorageBackend 测试后端
- **81 项测试** — 完整测试基础设施
- **最大条数裁剪对话框** — 超出历史上限时弹窗确认
- **图片占位符** — 加载失败时显示优雅的占位图
- **分组操作** — 支持分组级别取消固定/清空

### v2.1.0 (2026-05-09) — Liquid Glass UI

- Liquid Glass 设计语言 — NavigationSplitView 侧边栏 + QuickBar 玻璃弹窗
- 键盘导航优化 — 滚动和搜索框方向键处理修复

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
- 35 条规则自动识别敏感内容（密码 / API 密钥 / Slack/Discord/OpenAI 等 token / 身份证号等）
- 密码管理器在前台时自动暂停，不从 App 内复制
- 加密失败时内容不落地，拒绝明文存储

---

## 功能列表

- 📋 剪贴板历史（文本 / 图片 / 链接 / **富文本 RTF**）
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
- 🗂️ 类型筛选（全部 / 文本 / 图片 / 链接 / 富文本）
- ⌨️ 键盘导航优化（方向键滚动、搜索框焦点处理）

---

## 使用方法

| 操作 | 方式 |
|------|------|
| 弹出 Quick Bar | 左键点击菜单栏 📋 图标 |
| 复制条目 | 点击条目 / 键盘 ↑↓ + Enter |
| 打开完整窗口 | `Cmd+Ctrl+V`（全局快捷键）/ Quick Bar → "打开完整窗口" |
| 搜索 | 输入关键词，匹配处高亮 |
| 收藏 / 取消收藏 | 点击 ⭐ 或双击条目 |
| 删除 | 点击 🗑 或右键菜单 |
| 预览全文 / 敏感内容 / 图片 | 按住 0.4s，松开恢复 |
| 多选批量操作 | 单击复选框进入多选模式 |
| 清空历史 | 顶栏 🗑（保留收藏条目） |
| 切换类型筛选 | 侧边栏点击「文本/图片/链接/富文本」 |

> 💡 收藏的条目不会被自动清理。复制相同内容不重复记录，只更新时间戳。

---

## 安全特性

- **AES-256-GCM（v2）+ 兼容旧版 AES-CBC+HMAC-SHA256** — 所有文本和图片存入磁盘前自动加密
- **智能检测** — 35 条规则（关键词 + 正则），自动识别密码、API 密钥、Slack/Discord/OpenAI 等 token、私钥、身份证号、银行卡号等
- **自动清理** — 敏感内容可设置 1 小时 / 24 小时 / 48 小时 / 7 天后自动清除，或不自动清除

---

## 偏好设置

- 历史记录最大条数（50 / 100 / 200 / 500 条）
- 敏感信息清除策略（1 小时 / 24 小时 / 48 小时 / 7 天 / 不自动清除）
- 语言切换（7 种语言）
- 全局快捷键录制
- 外观（浅色 / 深色 / 跟随系统）
- 排除应用（自定义不监控的 App）
- 富文本捕获开关

---

## 系统要求

- macOS 13.0 (Ventura) 或更高版本

---

## 数据迁移

历史记录（含加密密钥）位于 ~/Library/Application Support/ClipMemory/。
重装前备份此目录即可迁移，重装 macOS 或更换 Mac 后恢复即可继续读取。
删除 App 前，可点击主窗口顶栏 🗑 按钮清除历史记录。

---

## 安装

```bash
brew tap irykelee/clipmemory https://github.com/irykelee/clipmemory
brew trust irykelee/clipmemory
brew install --cask clipmemory
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
