# ClipMemory README 与文档审查报告
**维度:** README 多语言 / 功能描述一致性 / 代码 vs 文档对照

---

## 🔴 Critical

### 1. `group.thisMonth` 本地化键值缺失
**文件:** `LocalizationService.swift:175` 引用了 `"group.thisMonth"`
**缺失位置:** `zh-Hans.lproj/Localizable.strings` 和 `en.lproj/Localizable.strings`
**影响:** 用户触发「本月」分组时，界面显示原始 key `"group.thisMonth"` 而非翻译文本。
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

## 🔴 High

### 2. 功能声称 vs 代码验证不符
**问题:** README 称「红绿灯隐藏」，但 `WindowManager.swift` 仅隐藏了标题文字，红绿灯仍可见。
**代码位置:** `WindowManager.swift:31-44`

---

## ⚠️ Medium

### 3. 「排除应用」功能未写入 README
**描述:** 代码中实现了「排除应用」功能（ClipboardStore.swift: excludedBundleIds），Settings UI 中有该选项，但 README 完全没有提及。
**建议:** 在设置选项章节增加「排除应用」说明。

---

## ⚠️ Low

### 4. ContentView.swift 重复 import
**文件:** `Views/ContentView.swift:4-5`
```swift
import ServiceManagement
import ServiceManagement  // ← 重复
```

---

### 5. 无正式 Release Notes
**描述:** v2.0.0 发布但仓库无 Release Notes 文档，Releases 目录只有二进制文件。
**建议:** 创建 `docs/release-notes-v2.md`。

---

## ✅ 文档与代码一致项（已验证）

| 声称内容 | 验证结果 |
|---------|---------|
| AES-256 + HMAC-SHA256 | ✅ 准确，CryptoService.swift 实现 |
| 25+ 条敏感检测规则 | ✅ 准确，实际 27 条（23 keyword/regex + 4 valueRegex） |
| Quick Bar 显示 8 条 | ✅ `maxItems = 8` in QuickBarView.swift:15 |
| 长按 0.4s | ✅ `minimumPressDuration = 0.4` in ContentView.swift:301 |
| 文本截断 200 字符 | ✅ `String(decryptedContent.prefix(200))` |
| 图片缩略图 80px / 长按 300px | ✅ ContentView.swift:383 |
| `offsetByCharacters` CJK 支持 | ✅ ContentView.swift:351-352 |
| 绿色复制闪烁反馈 | ✅ Color.green.opacity(0.3) |
| 悬停高亮 | ✅ Color(.selectedContentBackgroundColor).opacity(0.3) |
| 开机自启 (SMAppService) | ✅ ContentView.swift:256-259 |
| 字体缩放 0.85/1.0/1.15 | ✅ ContentView.swift:276 |
| 收藏不被自动清理 | ✅ ClipboardStore.swift: 收藏项跳过自动删除 |
| 复制相同内容不重复记录 | ✅ ClipboardStore.swift: 重复检测逻辑 |
