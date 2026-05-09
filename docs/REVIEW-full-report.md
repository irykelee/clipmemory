# ClipMemory v2.0.0 全面审查报告

**审查日期:** 2026/05/09
**审查版本:** v2.0.0 (MARKETING_VERSION)
**项目路径:** ~/Projects/ClipMemory/

---

## ❌ 审查报告的事实错误（已移除）

以下问题由用户指出为审查本身的错误，非实际代码问题：

| 报告来源 | # | 错误描述 | 实际情况 |
|---------|---|---------|---------|
| code-security | 1 | HMAC 认证顺序错误 | CryptoService 实现是**正确的** encrypt-then-MAC |
| code-security | 2 | SensitiveDetector.swift 存在 ReDoS | 该文件不存在；正则在 ClipboardMonitor 中且无风险 |
| ui-ux | 7 | 文件定位：ContentView.swift:37 | 实际在 WindowManager.swift:37，无 availability 问题 |
| ui-ux | 8 | 使用 byte offset → CJK 高亮错位 | 代码早已使用 `offsetByCharacters` |
| ui-ux | 11 | `.changed` 导致预览过早触发 | NSPressGestureRecognizer 是 Force Touch 触发，行为正确 |
| config-build | 5 | 需要 Accessibility 权限 | Carbon RegisterEventHotKey 不需要 |
| High | H-1 | SHA256 硬编码需修复 | Homebrew Cask 标准要求 SHA256 必须硬编码，非问题 |
| High | H-2 | ~/Homebrew/ 路径不存在 | 实际是 `${PROJECT_DIR}/Homebrew/` 项目内路径，正常 |
| High | H-3 | Tap 结构不符合标准 | `brew tap irykelee/clipmemory` 当前可用，非问题 |
| High | H-4 | applicationWillTerminate 未 unregister | HotKeyManager deinit 已调 unregister()，进程退出 macOS 自动清理 |

---

## ✅ 需修复（核实后共 3 个）

| 严重程度 | # | 问题 | 文件 | 影响 |
|----------|---|------|------|------|
| 🔴 Critical | C-1 | `encryptionFailed` 通知观察者未在 deinit 移除 | AppDelegate.swift:50-52 | 低（闭包无 self 引用，AppDelegate 存活期不释放） |
| 🔴 Critical | C-2 | NSWorkspace 观察者以 strong self 注册，未调 `stopMonitoring()` | ClipboardMonitor.swift:106 | 低（AppDelegate 持有整个生命周期不会释放） |
| 🔴 High | H-5 | 密钥文件未设 Unix 文件权限 0o600 | CryptoService.swift:34 | **中高**（sandbox=false + 同用户其他 app 可读，有实际风险） |

---

### [C-1] encryptionFailed 观察者未在 deinit 移除
**文件:** `AppDelegate.swift:50-52`
```swift
NotificationCenter.default.addObserver(forName: .encryptionFailed, object: nil, queue: .main) { _ in
    // ...
}
// ⚠️ deinit 中只清理了 languageObserver，这个未移除
```
**分析:** 闭包内未引用 self，无内存泄漏风险。AppDelegate 不会在 app 存活期释放。低影响，但属于未完成清理。
**修复建议:**
```swift
deinit {
    NotificationCenter.default.removeObserver(self, name: .encryptionFailed, object: nil)
    NotificationCenter.default.removeObserver(self, name: .languageChanged, object: nil)
}
```

---

### [C-2] ClipboardMonitor NSWorkspace 观察者未清理
**文件:** `ClipboardMonitor.swift:106`
```swift
NSWorkspace.shared.notificationCenter.addObserver(self, ...)
```
**分析:** NSWorkspace 观察者以 strong self 注册，`stopMonitoring()` 中虽调用了 `removeObserver`，但 deinit 未自动调。实际场景中 AppDelegate 持有 monitor 整个生命周期不会释放。低影响。
**修复建议:**
```swift
deinit {
    stopMonitoring()
}
```

---

### [H-5] 密钥文件未设 Unix 文件权限 0o600
**文件:** `CryptoService.swift:34`
```swift
try keyData.write(to: keyFileURL, options: [.atomic, .completeFileProtection])
```
**分析:** `.completeFileProtection` 在 macOS 上是 no-op（这是 iOS 概念），Unix 文件权限未显式设置。加上 `app-sandbox=false`，同用户下的其他 app 理论上可读取密钥文件。**这是唯一有实际安全隐患的问题。**
**修复建议:**
```swift
try keyData.write(to: keyFileURL, options: [.atomic, .completeFileProtection])
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFileURL.path)
```

---

## ✅ 无需修复（观点分歧或非问题）

| 问题 | 原因 |
|------|------|
| Accessibility 无障碍标签 | 菜单栏工具，过度工程 |
| UserDefaults 加密 | 数据本身非敏感 |
| DEVELOPMENT_TEAM 为空 | 开源项目正常 |
| HMAC 实现质疑 | 实际已正确实现 |
| SHA256 硬编码 | Homebrew Cask 标准要求 |
| ~/Homebrew/ 路径 | 实际是 `${PROJECT_DIR}/Homebrew/` 项目内路径 |
| Tap 结构 | `brew tap` 当前可用 |
| applicationWillTerminate 未 unregister | HotKeyManager deinit 已处理 |

---

## ✅ 验证通过项

| 声称内容 | 验证结果 |
|---------|---------|
| AES-256-CBC + HMAC-SHA256 | ✅ encrypt-then-MAC 正确实现 |
| 25+ 条敏感检测规则 | ✅ 实际 27 条 |
| Quick Bar 8 条 / 长按 0.4s / 文本截断 200 字符 | ✅ |
| 图片缩略图 80px / 长按 300px | ✅ |
| `offsetByCharacters` CJK 支持 | ✅ |
| 绿色复制反馈 / 悬停高亮 | ✅ |
| 开机自启 / 字体缩放 / 收藏不被清理 | ✅ |
| 路径遍历防护 / HMAC 先于解密验证 | ✅ |

---

*报告生成: 2026/05/09 | 核实: 2026/05/09*
