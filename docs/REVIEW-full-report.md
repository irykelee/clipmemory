# ClipMemory v2.0.0 全面审查报告

**审查日期:** 2026/05/09
**审查版本:** v2.0.0 (MARKETING_VERSION)
**项目路径:** ~/Projects/ClipMemory/
**审查维度:** 代码质量 / 安全漏洞 / UI-UX / 无障碍 / 配置构建 / 文档一致性

---

## 问题汇总

| 严重程度 | 数量 | 阻塞发布 |
|----------|------|----------|
| 🔴 Critical | 8 | ✅ 是 |
| 🔴 High | 9 | ⚠️ 分发前必须 |
| ⚠️ Medium | 13 | ❌ 否 |
| ⚠️ Low | 10 | ❌ 否 |
| ℹ️ Info | 12 | ❌ 否 |

---

## 🔴 Critical — 阻塞发布（8 个）

### [C-1] DEVELOPMENT_TEAM 为空
**文件:** `project.yml:18`
```yaml
DEVELOPMENT_TEAM: ""
```
**影响:** 分发构建（notarization）将失败，无法通过 Apple 公证分发。
**修复建议:** 在 project.yml 中填入有效 Apple Developer Team ID，或在 CI/CD 环境变量中注入。

---

### [C-2] Entitlements 配置矛盾
**文件:** `ClipMemory/ClipMemory.entitlements:6-7`
```xml
<key>com.apple.security.app-sandbox</key>
<false/>
<key>com.apple.security.files.user-selected.read-write</key>
<true/>
```
**影响:** `app-sandbox=false` 时 `files.user-selected.read-write` 无实际效果，属于无效配置。
**修复建议:** 要么启用 App Sandbox 并配置完整文件权限；要么移除所有 sandbox 专用 entitlement，保持逻辑一致。

---

### [C-3] Homebrew Formula SHA256 硬编码
**文件:** `Casks/clipmemory.rb:3`
```ruby
sha256 "ce43fdc67b624e3f327aaca2176db18c8c3554b30defd274651dfe883d42fca0"
```
**影响:** 每次发布必须手动更新 SHA256，否则 `brew upgrade` 会失败。
**修复建议:** 使用 GitHub Actions 自动更新 formula，或提供 `brew audit --new-formula` 验证脚本。

---

### [C-4] 打包脚本版本号过时
**文件:** `Scripts/package.sh:3`
```bash
VERSION=${1:-1.2.0}
```
**影响:** 项目已是 v2.0.0，但默认打包脚本仍引用 1.2.0。
**修复建议:** 改为 `VERSION=${1:-2.0.0}` 并同步更新 project.yml MARKETING_VERSION。

---

### [C-5] AppDelegate 通知观察者未移除
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
NotificationCenter.default.removeObserver(self, name: .encryptionFailed, object: nil)
```

---

### [C-6] ClipboardMonitor Timer 未在 deinit 中清理
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

### [C-7] `group.thisMonth` 本地化键值缺失
**文件:** `LocalizationService.swift:175` 引用了 `"group.thisMonth"`
**缺失位置:** 所有 `.lproj/Localizable.strings` 文件
**影响:** 用户触发「本月」分组时，界面显示原始 key `"group.thisMonth"` 而非翻译文本，影响全部 7 种语言用户。
**7 语种修复值:**

| 语言 | 修复值 |
|------|--------|
| zh-Hans | `"本月"` |
| zh-Hant | `"本月"` |
| en | `"This Month"` |
| ja | `"今月"` |
| ko | `"이번 달"` |
| es | `"Este mes"` |
| pt | `"Este mês"` |

---

### [C-8] 所有交互元素完全缺少无障碍标签
**文件:** `Views/ContentView.swift`, `Views/QuickBarView.swift`, `Views/WelcomeView.swift`
**影响:** 所有按钮、图片、列表项均无 `.accessibilityLabel()`。VoiceOver 用户无法获知任何 UI 元素含义，App 在部分市场可能违反无障碍法规。
**修复建议:** 为每个交互元素添加 `accessibilityLabel`，示例：
```swift
Button(action: { onSelect?(!isSelected) }) {
    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
}
.accessibilityLabel(isSelected ? "取消选择此项" : "选择此项")
```

---

## 🔴 High — 分发前必须修复（9 个）

### [H-1] 缺少 Accessibility 权限描述
**文件:** `Info.plist`
**影响:** 全局热键（Cmd+Ctrl+V）和 KeyCaptureView 需要 Accessibility 权限，但无权限说明字符串。
**修复建议:** 添加：
```xml
<key>NSAppleEventsUsageDescription</key>
<string>ClipMemory 需要辅助功能权限来启用全局快捷键。</string>
```

---

### [H-2] Hardened Runtime 未在 Entitlements 中显式声明
**文件:** `ClipMemory.entitlements`
**描述:** `project.yml` 设置了 `ENABLE_HARDENED_RUNTIME: YES`，但 entitlements 中无显式声明。
**修复建议:** 在 entitlements 中添加：
```xml
<key>com.apple.security.hardened-runtime</key>
<true/>
```

---

### [H-3] 打包脚本路径引用错误
**文件:** `Scripts/package.sh:29`
```bash
cp -R /tmp/ClipMemory.app ~/Homebrew/
```
**影响:** macOS 上 Homebrew 路径是 `~/Library/Caches/Homebrew/` 或 `/usr/local/`，不是 `~/Homebrew/`。
**修复建议:** 确认正确的 tap 路径，构建产物应复制到 `Releases/` 目录。

---

### [H-4] Homebrew Tap 结构不完整
**描述:** 当前 `Casks/` 在项目仓库内，但标准 Homebrew tap 需要独立仓库结构（`homebrew-clipmemory`）。
**修复建议:** 创建独立 `homebrew-tap` 仓库，或重组现有结构符合 Homebrew tap 标准。

---

### [H-5] 全局热键注册后无注销机制
**文件:** `HotKeyManager.swift`
**影响:** `registerHotKey()` 注册全局热键，但 `AppDelegate.applicationWillTerminate` 中未调用 `unregisterHotKey()`。进程异常退出时热键可能残留。
**修复建议:** 在 `applicationWillTerminate` 中调用 `unregisterHotKey()` 注销所有已注册热键。

---

### [H-6] 图片加密存储路径可预测
**文件:** `ClipboardStore.swift` / `ImageStorage.swift`
**影响:** 加密图片以 UUID 命名存储于 `~/Library/Application Support/ClipMemory/Images/`。路径虽 UUID 但目录可遍历。
**修复建议:** 对存储路径增加额外混淆（如在 UUID 前加随机前缀目录），或使用 `FileProtection` 属性并显式设置 `chmod 600`。

---

### [H-7] 密钥文件权限未显式设置
**文件:** `CryptoService.swift:34`
```swift
try keyData.write(to: keyFileURL, options: [.atomic, .completeFileProtection])
```
**影响:** 未显式设置文件系统权限，其他应用可能读取密钥文件。
**修复建议:**
```swift
try keyData.write(to: keyFileURL, options: [.atomic, .completeFileProtection])
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFileURL.path)
```

---

### [H-8] 加密密钥生成/存储失败时静默
**文件:** `CryptoService.swift:29-37`
```swift
guard result == errSecSuccess else {
    logger.error("Failed to generate random key bytes")
    return // 静默失败，应用后续行为未定义
}
```
**影响:** 密钥生成失败时应用继续运行但无法加密/解密数据，用户完全无感知。
**修复建议:** 在初始化失败时向用户显示 alert 或阻止应用启动，避免以不安全状态运行。

---

### [H-9] 红绿灯窗口控制按钮未隐藏
**文件:** `WindowManager.swift:31-44`
**描述:** README 声称「红绿灯隐藏」，但实际代码仅隐藏了标题文字，红绿灯（关闭/最小化/最大化）仍可见。
**修复建议:**
```swift
window.standardWindowButton(.closeButton)?.isHidden = true
window.standardWindowButton(.miniaturizeButton)?.isHidden = true
window.standardWindowButton(.zoomButton)?.isHidden = true
```

---

## ⚠️ Medium（13 个）

### [M-1] `macOS 26` availability check 永远不会触发
**文件:** `Views/ContentView.swift:37`
```swift
if #available(macOS 26, *) { window.toolbarStyle = .unified }
```
**影响:** `toolbarStyle = .unified` 在 macOS 11.0 就已引入，`macOS 26` 检查永远不会成立（当前最新 macOS 是 15）。统一工具栏样式从未生效。
**修复建议:** 改为 `if #available(macOS 11.0, *)` 或直接移除（项目最低支持 macOS 13）。

---

### [M-2] 搜索高亮使用 byte offset 而非 character offset
**文件:** `Views/ContentView.swift:340-341, 348-353`
```swift
dsi = text.index(text.index(text.startIndex, offsetBy: mso), offsetBy: -20, ...)
```
**影响:** `String.Index.offsetBy:` 对普通 `String` 是 **byte offset**，非 character offset。CJK 字符每个占 2-4 字节，导致高亮区域与实际匹配文本错位。
**修复建议:** 使用 `AttributedString` 的 `offsetByCharacters:` 方法，或将 String 转为 `CharacterView` 处理。

---

### [M-3] QuickBarView 忽略字体缩放设置
**文件:** `Views/QuickBarView.swift:28-95`
```swift
Font(.system(size: 12))  // 硬编码，无 sz() 缩放
Font(.system(size: 13))  // 硬编码，无 sz() 缩放
Font(.system(size: 10))  // 硬编码，无 sz() 缩放
```
**影响:** 用户设置大字体后主窗口文字放大，但 Quick Bar 弹窗字体不变。
**修复建议:** 参照 `ContentView.swift` 的 `sz()` 缩放模式，或使用 `@AppStorage("fontScale")`。

---

### [M-4] 搜索高亮颜色对比度不足
**文件:** `Views/ContentView.swift:353-354`
```swift
a[si..<ei].backgroundColor = .yellow.opacity(0.4)
a[si..<ei].foregroundColor = .orange
```
**影响:** 橙色文字配黄色背景（40% 透明度）不满足 WCAG 2.1 AA 小文本对比度要求（需 ≥4.5:1）。且颜色不随 light/dark mode 自适应。
**修复建议:** 前景色改为自适应 `.primary`，背景改为 `.yellow.opacity(0.3)`。

---

### [M-5] 主题更改不同步到 Quick Bar 和 WelcomeWindow
**文件:** `AppDelegate.swift:23-28`, `Views/QuickBarView.swift`
**影响:** 设置页切换主题通过 `NSApp.appearance` 即时生效，但 Quick Bar 已打开时不会更新，WelcomeWindow 首次启动时完全不应用主题设置。
**修复建议:** Quick Bar 关闭时重新应用 `NSApp.appearance`；WelcomeWindow 创建时也调用 `applyAppearance()`。

---

### [M-6] ContentView.swift 重复 import
**文件:** `Views/ContentView.swift:4-5`
```swift
import ServiceManagement
import ServiceManagement  // ← 重复
```

---

### [M-7] sensitivePatterns 数组无分组注释
**文件:** `ClipboardMonitor.swift:29-66`
**描述:** 27 条敏感检测模式（凭证、私钥、API 密钥、银行卡、身份证、SSN、JWT）未用注释分组，影响可维护性。
**修复建议:** 添加分组注释：
```swift
// Credentials
("password", false),
// Private Keys
("-----BEGIN.*PRIVATE KEY-----", true),
// ...
```

---

### [M-8] 图像敏感判断阈值过低
**文件:** `ClipboardMonitor.swift:193`
```swift
let isSensitive = imageData.count >= 10 * 1024 // 10KB
```
**影响:** 10KB 阈值过低，普通截图也会被标记为敏感。
**修复建议:** 提高阈值到更合理的值（如 100KB）或使用更智能的检测方法。

---

### [M-9] 「排除应用」功能未写入 README
**描述:** 代码中实现了「排除应用」功能（ClipboardStore.swift: excludedBundleIds），Settings UI 中有该选项，但 README 完全没有提及。
**修复建议:** 在设置选项章节增加「排除应用」说明。

---

### [M-10] 加密实现认证模式不够规范
**文件:** `CryptoService.swift`
**影响:** HMAC 认证在加密后独立计算，非标准 encrypt-then-MAC 模式。攻击者可能通过修改密文触发解密失败。
**修复建议:** 实现标准 encrypt-then-MAC：先加密生成密文，再对「盐值 + 密文」计算 HMAC，验证时先验 HMAC 再解密。

---

### [M-11] 重复内容检测每次都解密
**文件:** `ClipboardStore.swift:137-147`
```swift
let existingPlaintext = existing.isEncrypted
    ? (CryptoService.shared.decrypt(existing.content) ?? existing.content)
    : existing.content
return existingPlaintext == plaintextContent
```
**影响:** items 列表很大时，每次添加都需解密所有已有项目比对，性能差。
**修复建议:** 使用 `contentHash`（SHA256）进行快速预过滤，只有 hash 相同时才解密比对。

---

### [M-12] groupedItems 和 itemIndexMap 每次访问都重新计算
**文件:** `Views/ContentView.swift:70-98`
**影响:** `groupedItems` 和 `itemIndexMap` 是计算属性，每次访问都会重新计算整个列表的分组和索引映射。
**修复建议:** 使用 `@State` 缓存这些值，在 `displayedItems` 变化时更新缓存。

---

### [M-13] SwiftLint 规则过于宽松
**文件:** `.swiftlint.yml`
**描述:** 禁用了 10 条规则，包括 `cyclomatic_complexity`、`file_length`、`force_cast`。
**修复建议:** 重新启用 `cyclomatic_complexity` 和 `file_length`，保留 `trailing_whitespace` 和 `line_length` 警告但不报错。

---

## ⚠️ Low（10 个）

| # | 问题 | 文件 |
|---|------|------|
| L-1 | `CURRENT_PROJECT_VERSION: "1"` 与 MARKETING_VERSION `2.0.0` 不一致 | project.yml:13 |
| L-2 | 打包脚本缺少代码签名（`codesign`）和公证（`xcrun notarytool`）步骤 | Scripts/package.sh |
| L-3 | 缺少网络 entitlement（com.apple.security.network.client） | ClipMemory.entitlements |
| L-4 | CFBundleDevelopmentRegion=zh_CN 与 7 语言国际支持不符 | Info.plist:6 |
| L-5 | 窗口默认大小（680x500）硬编码在多处 | WindowManager.swift:60-68 |
| L-6 | AppVersion.current 的 fallback 逻辑不够清晰 | AppVersion.swift:4-8 |
| L-7 | ImageStorage 的 NSCache 未设置 countLimit 或 totalCostLimit | ImageStorage.swift:13 |
| L-8 | HotKeyConfig 使用 Int 存储 keyCode 和 modifiers，类型不安全 | HotKeyManager.swift:15-18 |
| L-9 | 长按手势 `.changed` 状态导致预览过早触发 | ContentView.swift:309-310 |
| L-10 | 时间分组折叠状态不持久化（每次重开 App 全部展开） | ContentView.swift:34 |

---

## ℹ️ Info（12 个）

| # | 问题 | 文件/位置 |
|---|------|----------|
| I-1 | `contentHash` 命名不够清晰，建议改为 `plaintextHash` | ClipboardItem.swift:19 |
| I-2 | `EventHotKeyID` 的 signature `0x434C5050`（"CLPP"）无注释 | HotKeyManager.swift:121 |
| I-3 | 批量操作动画应用于整行导致布局抖动 | ContentView.swift:410 |
| I-4 | 收藏状态和复制状态优先级：isCopied=true 时选择高亮被覆盖 | ContentView.swift:325-326 |
| I-5 | 图片长按预览仅限 PressableImage，文本项无长按体验 | ContentView.swift:384,393,398 |
| I-6 | "solid" 窗口效果返回 `.regular` 而非纯色背景，与 ultra/default 无实质差异 | ContentView.swift:50-51 |
| I-7 | L10n.string 方法使用 CVarArg，可考虑 Swift 5.9+ 的 String(localized:...) | LocalizationService.swift:24-27 |
| I-8 | sensitivePatterns 数组很长（27 条），分组注释见 Medium M-7 | ClipboardMonitor.swift:29-66 |
| I-9 | 无正式 Release Notes，v2.0.0 发布无文档记录 | docs/ |
| I-10 | Ad-hoc 代码签名（CODE_SIGN_IDENTITY: "-"）不足以分发 | project.yml:16 |
| I-11 | 加密失败时静默丢弃数据，用户无感知（安全设计，但可改进通知） | ClipboardStore.swift:127-133 |
| I-12 | 错误处理不区分 HMAC 验证失败、密钥丢失还是数据损坏 | CryptoService.swift:86-89 |

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
| `offsetByCharacters` CJK 支持 | ✅ ContentView.swift:351-352（但 byte offset 问题见 M-2） |
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

### 第一批（必须修复，影响可用性）
1. **[C-7]** 添加 `group.thisMonth` 7 语种本地化
2. **[C-8]** 添加所有交互元素的 accessibilityLabel
3. **[C-5]** AppDelegate 移除通知观察者
4. **[C-6]** ClipboardMonitor 添加 deinit

### 第二批（分发前必须，影响分发）
5. **[C-1]** 填写 DEVELOPMENT_TEAM
6. **[C-2]** 修复 entitlements 矛盾
7. **[H-2]** 显式声明 Hardened Runtime
8. **[C-3]** 更新 Homebrew SHA256
9. **[C-4]** Scripts/package.sh 版本号改为 2.0.0

### 第三批（重要改进）
10. **[H-9]** 隐藏红绿灯（README 与代码不符）
11. **[M-1]** 修复 macOS availability check
12. **[M-2]** 修复 CJK 搜索高亮 byte offset 问题
13. **[M-3]** QuickBarView 支持字体缩放

---

*报告生成: 2026/05/09 | 审查工具: team-reviewer + 3× general-purpose agents*
