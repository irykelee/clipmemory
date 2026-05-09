# ClipMemory UI/UX 审查报告
**维度:** SwiftUI 界面 / 交互 / 无障碍访问

---

## 🔴 Critical

### 1. 所有交互元素完全缺少无障碍标签
**文件:** `Views/ContentView.swift`, `Views/QuickBarView.swift`, `Views/WelcomeView.swift`
**描述:** 所有按钮、图片、列表项均无 `.accessibilityLabel()`。VoiceOver 用户无法获知任何 UI 元素含义。
**示例:**
```swift
// ContentView.swift:375
Button(action: { onSelect?(!isSelected) }) {
    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
    // 缺失: .accessibilityLabel(isSelected ? "取消选择" : "选择此项")
}
```
**修改建议:** 为每个交互元素添加 `accessibilityLabel`，文本应描述功能而非外观。

---

### 2. 剪贴板内容行无障碍价值描述缺失
**文件:** `Views/ContentView.swift:373-413`
**描述:** `ClipboardItemRow` 展示文本/图片内容但不提供 `accessibilityValue`。敏感内容遮罩、收藏状态、复制状态均未暴露给屏幕阅读器。
**修改建议:**
```swift
.accessibilityValue("\(item.isFavorite ? "已收藏" : "") \(item.contentType) - \(item.preview)")
```

---

### 3. 键盘焦点无系统级焦点环集成
**文件:** `Views/ContentView.swift:182-189`
**描述:** `keyboardSelectedIndex` 通过 `Color(.selectedContentBackgroundColor).opacity(0.3)` 实现自定义高亮，但未集成系统无障碍焦点环。
**修改建议:** 使用 `.focusable()` modifier 并配置 `.accessibilityAddTraits(.selected)`。

---

## 🔴 High

### 4. 设置页 Picker 控件缺少无障碍标签
**文件:** `Views/ContentView.swift:247-276`
**描述:** `Picker` 使用 `L10n` 本地化标题但无显式 `.accessibilityLabel()`，屏幕阅读器可能朗读不完整。
**修改建议:**
```swift
Picker(L10n.settingsMaxItems, selection: $store.maxItems)
    .accessibilityLabel(L10n.settingsMaxItems)
```

---

### 5. 搜索框无障碍占位符不适配
**文件:** `Views/ContentView.swift:118-121`
**描述:** 搜索框使用 `L10n.searchPlaceholder` 但未设 `accessibilityPlaceholder`，VoiceOver 无法在字段为空时正确提示。
**修改建议:**
```swift
TextField(..., axis: .vertical)
    .accessibilityPlaceholder(L10n.searchPlaceholder)
```

---

### 6. 红绿灯窗口控制按钮未隐藏
**文件:** `Services/WindowManager.swift:31-44`
```swift
window.titlebarAppearsTransparent = true
window.titleVisibility = .hidden
window.styleMask.insert(.fullSizeContentView)
```
**描述:** 标题栏设置虽然隐藏了标题文字，但红绿灯（关闭/最小化/最大化）仍可见。README 声称「红绿灯隐藏」但实际未实现。
**修改建议:** 要完全隐藏红绿灯，需添加：
```swift
window.standardWindowButton(.closeButton)?.isHidden = true
window.standardWindowButton(.miniaturizeButton)?.isHidden = true
window.standardWindowButton(.zoomButton)?.isHidden = true
```
或在 `styleMask` 中使用 `.undecorated`（但会失去拖拽支持，需自行实现拖拽区域）。

---

## ⚠️ Medium

### 7. `macOS 26` availability check 永远不会触发
**文件:** `Views/ContentView.swift:37`
```swift
if #available(macOS 26, *) { window.toolbarStyle = .unified }
```
**描述:** `toolbarStyle = .unified` 在 macOS 11.0 就已引入，`macOS 26` 检查永远不会成立（当前最新是 macOS 15）。这导致统一工具栏样式从未生效。
**修改建议:** 改为 `if #available(macOS 11.0, *)` 或直接移除（项目最低支持 macOS 13）。

---

### 8. 搜索高亮使用 byte offset 而非 character offset
**文件:** `Views/ContentView.swift:340-341, 348-353`
```swift
dsi = text.index(text.index(text.startIndex, offsetBy: mso), offsetBy: -20, ...)
```
**描述:** `String.Index.offsetBy:` 对普通 `String` 是 **byte offset**，非 character offset。CJK 字符每个占 2-4 字节，导致高亮区域与实际匹配文本错位。
**修改建议:** 使用 `String.Index` 的 `offsetByCharacters:` 方法（需将 `String` 转为 `AttributedString` 或使用 `CharacterView`）。

---

### 9. 搜索高亮颜色对比度不足
**文件:** `Views/ContentView.swift:353-354`
```swift
a[si..<ei].backgroundColor = .yellow.opacity(0.4)
a[si..<ei].foregroundColor = .orange
```
**描述:** 橙色文字配黄色背景（40% 透明度）不满足 WCAG 2.1 AA 小文本对比度要求（需 ≥4.5:1）。且颜色不随 light/dark mode 自适应。
**修改建议:** 使用 `.foregroundColor` 自适应颜色如 `.primary`，背景改为 `.yellow.opacity(0.3)`。

---

## ⚠️ Low

### 10. QuickBarView 忽略字体缩放设置
**文件:** `Views/QuickBarView.swift:28-95`
**描述:** QuickBar 使用硬编码字号 `Font(.system(size: 12))` 等，不使用 `sz()` 缩放函数。用户设置大字体后主窗口文字放大但 Quick Bar 不变。
**修改建议:** 参照 `ContentView.swift` 的 `sz()` 模式，或在 QuickBarView 中使用 `@AppStorage("fontScale")`。

---

### 11. 长按手势 `.changed` 状态过早触发
**文件:** `Views/ContentView.swift:309-310`
```swift
@objc func pressed(_ sender: NSPressGestureRecognizer) {
    DispatchQueue.main.async { self.onPressChanged(sender.state == .began || sender.state == .changed) }
}
```
**描述:** `sender.state == .changed` 表示鼠标移动时也会触发预览，导致用户轻微移动鼠标（0.4s 内）就会激活预览。
**修改建议:** 仅用 `.began` 触发，`.ended/.cancelled` 释放。

---

### 12. 时间分组折叠状态不持久化
**文件:** `Views/ContentView.swift:34`
```swift
@State private var collapsedGroups: Set<TimeGroup> = []
```
**描述:** 用户折叠的分组在关闭 App 后重开时会全部展开。
**修改建议:** 用 `@AppStorage("collapsedGroups")` 持久化，或使用 JSON 文件存储。

---

### 13. 主题更改不同步到 Quick Bar 和 WelcomeWindow
**文件:** `AppDelegate.swift:23-28`, `Views/QuickBarView.swift`
**描述:** 设置页切换主题通过 `NSApp.appearance` 即时生效，但 Quick Bar 已打开时不会更新，WelcomeWindow 首次启动时完全不应用主题设置。
**修改建议:** Quick Bar 关闭时重新应用 `NSApp.appearance`；WelcomeWindow 创建时也调用 `applyAppearance()`。

---

### 14. 批量操作动画抖动
**文件:** `Views/ContentView.swift:410`
```swift
.animation(.easeOut(duration: 0.3), value: isCopied)
```
**描述:** 动画应用于整行视图，行布局变化时引发视觉抖动。
**修改建议:** 将动画限定于背景色属性：
```swift
.background(rowBackground)
.animation(.easeOut(duration: 0.3), value: isCopied)
```

---

### 15. solid 窗口效果无实际实现
**文件:** `Views/ContentView.swift:50-51`
```swift
case "solid": .regular
```
**描述:** 设置 "solid"（实心）时返回 `.regular` 而非纯色背景，与 "ultra" 和 default 无实质差异。
**修改建议:** solid 模式可返回 `Color(nsColor: .windowBackgroundColor)` 而非 Material。

---

## ℹ️ Info

### 16. 图片长按预览仅限 PressableImage
**描述:** 文本项使用双击预览全文，图片项使用长按放大。长按手势仅在 `PressableImage` 上实现，文本项没有长按体验。
**状态:** 设计决策，可接受。

### 17. 收藏状态和复制状态优先级
**文件:** `Views/ContentView.swift:325-326`
**描述:** `isCopied == true` 时优先显示绿色背景，遮盖选择状态高亮。
**状态:** 用户测试验证偏好。
