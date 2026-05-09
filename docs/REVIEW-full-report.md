# ClipMemory v2.0.0 全面审查报告

**审查日期:** 2026/05/09
**审查版本:** v2.0.0 (MARKETING_VERSION)
**项目路径:** ~/Projects/ClipMemory/
**审查维度:** 代码质量 / 安全漏洞 / UI-UX / 无障碍 / 配置构建 / 文档一致性

---

## ⚠️ 已确认不修复项（观点分歧）

以下问题经用户确认无需修复：

| 问题 | 原因 |
|------|------|
| Accessibility 无障碍标签 | 菜单栏工具过度工程，非必需 |
| UserDefaults 加密 | 数据本身非敏感，无需加密 |
| HMAC 实现质疑 | 实际实现已正确，无需修改 |
| DEVELOPMENT_TEAM 为空 | 开源项目正常，无需填入 |

---

## 问题汇总（排除不修复项后）

| 严重程度 | 数量 | 阻塞发布 |
|----------|------|----------|
| 🔴 Critical | 3 | ⚠️ 部分（见下文） |
| 🔴 High | 6 | ⚠️ 分发前建议 |
| ⚠️ Medium | 13 | ❌ 否 |
| ⚠️ Low | 10 | ❌ 否 |
| ℹ️ Info | 12 | ❌ 否 |

---

## ✅ 已验证无需修复

以下问题在当前代码中已不存在：

| 问题 | 验证结果 |
|------|---------|
| `group.thisMonth` 本地化缺失 | ✅ 7 语种 strings 文件全部存在 |
| `macOS 26` availability check | ✅ 直接使用 `.unified`，无 availability guard |
| ContentView.swift 重复 import | ✅ 只有一行 `import ServiceManagement` |
| Scripts/package.sh 版本号 | ✅ 已是 `VERSION=${1:-2.0.0}` |
| Entitlements 矛盾配置 | ✅ 只有 `app-sandbox: false`，无多余 entitlement |

---

## 🔴 Critical（3 个）

### [C-1] AppDelegate 通知观察者未移除
**文件:** `AppDelegate.swift:50-52`
```swift
NotificationCenter.default.addObserver(forName: .encryptionFailed, object: nil, queue: .main) { _ in
    // ...
}
// ⚠️ 这个观察者未在 deinit 中移除
```
**影响:** AppDelegate 释放后观察者仍然存在，可能导致内存泄漏和重复通知。
**修复建议:** 在 `deinit` 中添加：
```swift
deinit {
    NotificationCenter.default.removeObserver(self, name: .encryptionFailed, object: nil)
}
```

---

### [C-2] ClipboardMonitor Timer 未在 deinit 中清理
**文件:** `ClipboardMonitor.swift:122-126`
```swift
func stopMonitoring() {
    timer?.invalidate()
    timer = nil
    NSWorkspace.shared.notificationCenter.removeObserver(self)
}
// ⚠️ deinit 中未调用 stopMonitoring()
```
**影响:** 如果 monitor 在启动状态下被释放，Timer 可能不会被正确清理。
**修复建议:** 添加 `deinit { stopMonitoring() }`。

---

### [C-3] Homebrew Formula SHA256 硬编码
**文件:** `Casks/clipmemory.rb:3`
```ruby
sha256 "ce43fdc67b624e3f327aaca2176db18c8c3554b30defd274651dfe883d42fca0"
```
**影响:** 每次发布必须手动更新 SHA256，否则 `brew upgrade` 会失败。
**修复建议:** 使用 GitHub Actions 自动更新 formula，或提供 `brew audit --new-formula` 验证脚本。

---

## 🔴 High（6 个）

### [H-1] 打包脚本路径引用错误
**文件:** `Scripts/package.sh:29`
```bash
cp -R /tmp/ClipMemory.app ~/Homebrew/
```
**影响:** macOS 上 Homebrew 路径是 `~/Library/Caches/Homebrew/` 或 `/usr/local/`，不是 `~/Homebrew/`。
**修复建议:** 构建产物应复制到 `Releases/` 目录，或修正为正确的 Homebrew tap 路径。

---

### [H-2] Homebrew Tap 结构不完整
**描述:** 当前 `Casks/` 在项目仓库内，但标准 Homebrew tap 需要独立仓库结构（`homebrew-clipmemory`）。
**修复建议:** 创建独立 `homebrew-tap` 仓库，或重组现有结构符合 Homebrew tap 标准。

---

### [H-3] 全局热键注册后无注销机制
**文件:** `HotKeyManager.swift`
**影响:** `registerHotKey()` 注册全局热键，但 `AppDelegate.applicationWillTerminate` 中未调用 `unregisterHotKey()`。
**修复建议:** 在 `applicationWillTerminate` 中调用 `unregisterHotKey()` 注销所有已注册热键。

---

### [H-4] 密钥文件权限未显式设置
**文件:** `CryptoService.swift:34`
```swift
try keyData.write(to: keyFileURL, options: [.atomic, .completeFileProtection])
```
**影响:** 未显式设置文件系统权限，其他应用可能读取密钥文件。
**修复建议:**
```swift
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFileURL.path)
```

---

### [H-5] 加密密钥生成失败时静默
**文件:** `CryptoService.swift:29-37`
```swift
guard result == errSecSuccess else {
    logger.error("Failed to generate random key bytes")
    return // 静默失败
}
```
**影响:** 密钥生成失败时应用继续运行但无法加密/解密，用户完全无感知。
**修复建议:** 在初始化失败时向用户显示 alert 或阻止应用启动。

---

### [H-6] 红绿灯窗口控制按钮未隐藏
**文件:** `WindowManager.swift:31-44`
**描述:** README 声称「红绿灯隐藏」，但实际代码仅隐藏了标题文字，红绿灯仍可见。
**修复建议:**
```swift
window.standardWindowButton(.closeButton)?.isHidden = true
window.standardWindowButton(.miniaturizeButton)?.isHidden = true
window.standardWindowButton(.zoomButton)?.isHidden = true
```

---

## ⚠️ Medium（13 个）

### [M-1] 搜索高亮使用 byte offset 而非 character offset
**文件:** `ContentView.swift:340-341, 348-353`
```swift
dsi = text.index(text.index(text.startIndex, offsetBy: mso), offsetBy: -20, ...)
```
**影响:** `String.Index.offsetBy:` 对普通 `String` 是 **byte offset**，非 character offset。CJK 字符每个占 2-4 字节，导致高亮区域与实际匹配文本错位。
**修复建议:** 使用 `AttributedString` 的 `offsetByCharacters:` 方法。

---

### [M-2] QuickBarView 忽略字体缩放设置
**文件:** `QuickBarView.swift:28-95`
```swift
Font(.system(size: 12))  // 硬编码，无 sz() 缩放
Font(.system(size: 13))  // 硬编码，无 sz() 缩放
```
**影响:** 用户设置大字体后主窗口文字放大，但 Quick Bar 弹窗字体不变。
**修复建议:** 参照 `ContentView.swift` 的 `sz()` 缩放模式，或使用 `@AppStorage("fontScale")`。

---

### [M-3] 搜索高亮颜色对比度不足
**文件:** `ContentView.swift:353-354`
```swift
a[si..<ei].backgroundColor = .yellow.opacity(0.4)
a[si..<ei].foregroundColor = .orange
```
**影响:** 橙色文字配黄色背景不满足 WCAG 2.1 AA 对比度要求，且颜色不随 light/dark mode 自适应。
**修复建议:** 前景色改为自适应 `.primary`，背景改为 `.yellow.opacity(0.3)`。

---

### [M-4] 主题更改不同步到 Quick Bar 和 WelcomeWindow
**文件:** `AppDelegate.swift:23-28`, `QuickBarView.swift`
**影响:** 设置页切换主题即时生效，但 Quick Bar 已打开时不会更新，WelcomeWindow 首次启动时不应用主题设置。
**修复建议:** WelcomeWindow 创建时调用 `applyAppearance()`；Quick Bar 关闭时重新应用 `NSApp.appearance`。

---

### [M-5] sensitivePatterns 数组无分组注释
**文件:** `ClipboardMonitor.swift:29-66`
**描述:** 27 条敏感检测模式未用注释分组，影响可维护性。
**修复建议:** 添加分组注释（Credentials / Private Keys / API Keys / Personal IDs / Bank Cards）。

---

### [M-6] 图像敏感判断阈值过低
**文件:** `ClipboardMonitor.swift:193`
```swift
let isSensitive = imageData.count >= 10 * 1024 // 10KB
```
**影响:** 10KB 阈值过低，普通截图也会被标记为敏感。
**修复建议:** 提高阈值到 100KB 或使用更智能的检测方法。

---

### [M-7] 「排除应用」功能未写入 README
**描述:** 代码中实现了「排除应用」功能，Settings UI 中有该选项，但 README 完全没有提及。
**修复建议:** 在设置选项章节增加「排除应用」说明。

---

### [M-8] 加密实现认证模式不够规范
**文件:** `CryptoService.swift`
**影响:** HMAC 认证在加密后独立计算，非标准 encrypt-then-MAC 模式。
**修复建议:** 实现标准 encrypt-then-MAC：先加密生成密文，再对「盐值 + 密文」计算 HMAC，验证时先验 HMAC 再解密。

---

### [M-9] 重复内容检测每次都解密
**文件:** `ClipboardStore.swift:137-147`
**影响:** items 列表很大时，每次添加都需解密所有已有项目比对，性能差。
**修复建议:** 使用 `contentHash`（SHA256）进行快速预过滤，只有 hash 相同时才解密比对。

---

### [M-10] groupedItems 和 itemIndexMap 每次访问都重新计算
**文件:** `ContentView.swift:70-98`
**影响:** 两个计算属性每次访问都重新计算整个列表的分组和索引映射。
**修复建议:** 使用 `@State` 缓存这些值，在 `displayedItems` 变化时更新缓存。

---

### [M-11] SwiftLint 规则过于宽松
**文件:** `.swiftlint.yml`
**描述:** 禁用了 10 条规则，包括 `cyclomatic_complexity`、`file_length`、`force_cast`。
**修复建议:** 重新启用 `cyclomatic_complexity` 和 `file_length`。

---

### [M-12] 图片加密存储路径可预测
**文件:** `ImageStorage.swift`
**影响:** 加密图片以 UUID 命名存储于 `Images/` 目录，目录可遍历。
**修复建议:** 在 UUID 前加随机前缀目录，或使用 `FileProtection` 属性。

---

### [M-13] 长按手势 `.changed` 状态导致预览过早触发
**文件:** `ContentView.swift:309-310`
```swift
self.onPressChanged(sender.state == .began || sender.state == .changed)
```
**影响:** 用户轻微移动鼠标（0.4s 内）就会激活预览。
**修复建议:** 仅用 `.began` 触发，`.ended/.cancelled` 释放。

---

## ⚠️ Low（10 个）

| # | 问题 | 文件 |
|---|------|------|
| L-1 | `CURRENT_PROJECT_VERSION: "1"` 与 MARKETING_VERSION `2.0.0` 不一致 | project.yml:13 |
| L-2 | 打包脚本缺少代码签名（`codesign`）和公证（`xcrun notarytool`）步骤 | Scripts/package.sh |
| L-3 | 缺少网络 entitlement（`com.apple.security.network.client`） | ClipMemory.entitlements |
| L-4 | CFBundleDevelopmentRegion=zh_CN 与 7 语言国际支持不符 | Info.plist:6 |
| L-5 | 窗口默认大小（680x500）硬编码在多处 | WindowManager.swift:60-68 |
| L-6 | AppVersion.current 的 fallback 逻辑不够清晰 | AppVersion.swift:4-8 |
| L-7 | ImageStorage 的 NSCache 未设置 countLimit | ImageStorage.swift:13 |
| L-8 | HotKeyConfig 使用 Int 存储 keyCode，类型不安全 | HotKeyManager.swift:15-18 |
| L-9 | 时间分组折叠状态不持久化（每次重开 App 全部展开） | ContentView.swift:34 |
| L-10 | 批量操作动画应用于整行导致布局抖动 | ContentView.swift:410 |

---

## ℹ️ Info（12 个）

| # | 问题 | 文件/位置 |
|---|------|----------|
| I-1 | `contentHash` 命名不够清晰，建议改为 `plaintextHash` | ClipboardItem.swift:19 |
| I-2 | `EventHotKeyID` 的 signature `0x434C5050`（"CLPP"）无注释 | HotKeyManager.swift:121 |
| I-3 | 收藏状态和复制状态优先级：isCopied=true 时选择高亮被覆盖 | ContentView.swift:325-326 |
| I-4 | 图片长按预览仅限 PressableImage，文本项无长按体验 | ContentView.swift:384 |
| I-5 | "solid" 窗口效果返回 `.regular` 而非纯色背景 | ContentView.swift:50-51 |
| I-6 | L10n.string 方法使用 CVarArg，可考虑 Swift 5.9+ 的 String(localized:...) | LocalizationService.swift:24-27 |
| I-7 | sensitivePatterns 数组很长（27 条），分组注释见 Medium M-5 | ClipboardMonitor.swift:29-66 |
| I-8 | 无正式 Release Notes，v2.0.0 发布无文档记录 | docs/ |
| I-9 | Ad-hoc 代码签名（CODE_SIGN_IDENTITY: "-"）不足以分发 | project.yml:16 |
| I-10 | 加密失败时静默丢弃数据，用户无感知（安全设计） | ClipboardStore.swift:127-133 |
| I-11 | 错误处理不区分 HMAC 验证失败、密钥丢失还是数据损坏 | CryptoService.swift:86-89 |
| I-12 | "solid" 效果与 ultra/default 无实质差异 | ContentView.swift:50-51 |

---

## ✅ 验证通过项

| 声称内容 | 验证结果 |
|---------|---------|
| AES-256-CBC + HMAC-SHA256 认证加密 | ✅ CryptoService.swift 实现准确 |
| 25+ 条敏感检测规则 | ✅ 实际 27 条（23 keyword/regex + 4 valueRegex） |
| Quick Bar 显示 8 条 | ✅ `maxItems = 8` in QuickBarView.swift:15 |
| 长按 0.4s | ✅ `minimumPressDuration = 0.4` in ContentView.swift:301 |
| 文本截断 200 字符 | ✅ `String(decryptedContent.prefix(200))` |
| 图片缩略图 80px / 长按 300px | ✅ ContentView.swift:383 |
| 绿色复制闪烁反馈 | ✅ Color.green.opacity(0.3) |
| 悬停高亮 | ✅ Color(.selectedContentBackgroundColor).opacity(0.3) |
| 开机自启 (SMAppService) | ✅ ContentView.swift:256-259 |
| 字体缩放 0.85/1.0/1.15 | ✅ ContentView.swift:276 |
| 收藏不被自动清理 | ✅ ClipboardStore.swift 收藏项跳过自动删除 |
| 复制相同内容不重复记录 | ✅ ClipboardStore.swift 重复检测逻辑 |
| 路径遍历防护 (isValidFilename) | ✅ 实现正确 |
| HMAC 验证在解密前执行 | ✅ CryptoService.swift |

---

## 推荐修复顺序

### 第一批（内存安全，必须修复）
1. **[C-1]** AppDelegate 移除通知观察者
2. **[C-2]** ClipboardMonitor 添加 deinit

### 第二批（建议修复）
3. **[C-3]** Homebrew SHA256 自动更新机制
4. **[H-1]** 打包脚本路径引用修正
5. **[H-3]** 热键注销机制
6. **[H-4]** 密钥文件权限 0o600
7. **[H-5]** 密钥生成失败时 alert
8. **[H-6]** 隐藏红绿灯（README 与代码一致）

### 第三批（体验改进）
9. **[M-1]** CJK 搜索高亮 byte offset 修复
10. **[M-2]** QuickBarView 字体缩放支持
11. **[M-3]** 搜索高亮对比度修复
12. **[M-4]** 主题同步 Quick Bar / WelcomeWindow

---

*报告生成: 2026/05/09 | 用户确认不修复: Accessibility / UserDefaults加密 / HMAC质疑 / DEVELOPMENT_TEAM*
