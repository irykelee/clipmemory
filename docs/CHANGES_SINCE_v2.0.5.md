# Changes Since v2.0.5 (1d65652)

This document records all functional changes from commit `1d65652` to present.

---

## Commit: `69d1af2` — Liquid Glass UI + Legacy Image Encryption

### Files Changed
- `ClipMemory.xcodeproj/project.pbxproj`
- `ClipMemory/AppDelegate.swift`
- `ClipMemory/Services/ClipboardStore.swift`
- `ClipMemory/Services/ImageStorage.swift`
- `ClipMemory/Views/ContentView.swift`

### ContentView Changes (109 lines)
- Fix auto-refresh bug (cache only updated on tab/filter change, not on store.items change)
- Refactor DateFilter buttons to Liquid Glass style with `.ultraThinMaterial`
- Liquid Glass style improvements

### ImageStorage Changes
- Migrate unencrypted PNG from `~/Library/Application Support/ClipPaste/Images` to `~/Library/Application Support/ClipMemory/Images` (AES-GCM v2)
- Async notification to avoid race condition with ClipboardStore observer registration

### ClipboardStore Changes
- Clamp maxItems to [50, 100, 200, 500] range
- Handle image migration completion notification to update isEncrypted flags

---

## Commit: `4b1b465` — Test Infrastructure + Bug Fixes

### Files Changed
- `Tests/ClipMemoryTests/` (new test files)
- `ClipMemory/Models/ClipboardItem.swift`
- `ClipMemory/Services/ClipboardMonitor.swift`
- `ClipMemory/Services/ClipboardStore.swift`
- `ClipMemory/Services/CryptoService.swift`

### New Tests (64 tests total)
- **ClipboardItemTests**: 13 tests (model coverage)
- **CryptoServiceTests**: 11 tests (encryption coverage)
- **SensitiveDetectorTests**: 13 tests (pattern detection)
- **ConcurrencyTests**: 10 tests (stateLock protection)
- **IntegrationTests**: 16 tests (CRUD + deduplication)

### Protocol DI
- `StorageBackend` protocol for ClipboardStore dependency injection
- `MemoryStorageBackend` for tests (no UserDefaults pollution)
- `FileStorageBackend` wraps existing UserDefaults logic

### Bug Fixes
- `CryptoService.isOldFormat()`: try-decrypt approach (not byte prefix)
- Chinese 15-digit ID regex: fixed birthdate month validation
- `SensitiveDetector`: removed false-positive prone keywords, added missing patterns

---

## Commit: `5afedc2` — Liquid Glass Rebuild Backup

### Files Changed
- `ClipMemory/Views/ContentView.swift` (22 insertions, 17 deletions)

### Content
- NavigationSplitView + sidebar structure
- Frosted glass overlay with offset -52pt

---

## Commit: `af57abb` — Absolute Date + Remove Sensitive Button

### Files Changed
- `ClipMemory/Views/ContentView.swift` (14 insertions, 2 deletions)

### Changes
- Display absolute date+time for all clipboard items (today/yesterday/older)
- Remove redundant "查看/隐藏" button (long-press already reveals)

---

## Commit: `f9905ef` — Search Debounce + Cache + UI Polish

### Files Changed
- `ClipMemory/Services/WindowManager.swift`
- `ClipMemory/Views/ContentView.swift`
- `ClipMemory/Views/QuickBarView.swift`
- `ClipMemory/Views/WelcomeView.swift`

### ContentView Changes (96 lines)
- Add 250ms search debounce to reduce filter recomputation
- Cache `displayedItems`/`groupedItems` to avoid repeated filtering
- Add `Equatable` to `ClipboardItemRow` to reduce unnecessary re-renders

### QuickBar Changes
- Sync appearance with `NSApp.appearance` for dark mode

### WelcomeView Changes
- Capsule button with macOS 14+ availability check

---

## Commit: `a7d011f` — Date Filter Fix + Thread Safety + Liquid Glass Polish

### Files Changed
- `Casks/clipmemory.rb`
- `ClipMemory.xcodeproj/project.pbxproj`
- `ClipMemory/Models/ClipboardItem.swift`
- `ClipMemory/Services/ClipboardMonitor.swift`
- `ClipMemory/Services/ClipboardStore.swift`
- `ClipMemory/Services/WindowManager.swift`
- `ClipMemory/Views/ContentView.swift`

### Bug Fixes
- Fix `.older` filter incorrectly including yesterday items
- Remove unused `itemsLock`, clarify thread-safety comment
- Remove dead `decryptedContent` property
- Fix `decryptionFailed` bypassing `contentCache`
- Replace fragile `regexIdx` index with paired tuple structure
- Refresh App Picker cache on sheet open

### Liquid Glass Polish
- Toolbar `.expanded` style
- Material naming polish

---

## Commit: `b656a92` — QuickBar Glass + Hotkey Fix + FCE82CA Patches

### Files Changed
- `ClipMemory/AppDelegate.swift`
- `ClipMemory/Services/ClipboardMonitor.swift`
- `ClipMemory/Services/ClipboardStore.swift`
- `ClipMemory/Services/ImageStorage.swift`
- `ClipMemory/Views/KeyCaptureView.swift`
- `ClipMemory/Views/QuickBarView.swift`
- `ClipMemory/*lproj/Localizable.strings` (6 files)
- `Tests/ClipMemoryTests/` (3 files)

### QuickBarView Changes
- Background: `Color(nsColor:.windowBackgroundColor)` → `Material.thin`
- Menu section: `Material.thin`
- Hover state: `Material.ultraThinMaterial`

### Hotkey Fix
- `⌘⌃V` → `showMainWindow()` (main window)
- Menu bar icon → `showQuickBar()` (popup)

### ClipboardMonitor Changes
- for-where loop refactor

### ClipboardStore Changes
- `GroupCounts` struct instead of tuple

### Localization
- All 6 language `.strings` files updated

### Test Fixes
- ConcurrencyTests, CryptoServiceTests, SensitiveDetectorTests fixes

---

## Commit: `7afa820` — Test Script (Non-Functional)

### Files Changed
- `Scripts/test-ui.sh` (new)

### Content
- UI smoke test script for basic verification
- Tests: app launch, CPU usage, process running

---

## Commit: `<current>` — Development Workflow

### Files Changed
- `.git/hooks/pre-commit` (new)
- `.github/workflows/ci.yml` (new)
- `docs/DEVELOPMENT.md` (new)

### Pre-commit Hook
- Blocks commit if build or test fails
- Auto-runs `xcodegen generate` when `project.yml` modified
- Build: `xcodebuild -scheme ClipMemory -configuration Debug build`
- Test: `xcodebuild -scheme ClipMemory -configuration Debug test`

### GitHub Actions CI
- Triggers on push and pull_request to main
- Jobs: build + test on macos-26

### Extended Verification Scenarios
| Scenario | What to Verify |
|----------|----------------|
| 设置 → 切语言 → 回到主界面 | 语言切换触发 view rebuild |
| 窗口关闭 → QuickBar 重新打开 | 窗口重建 @State 丢失问题 |
| 排除应用 sheet → 搜索 → 关闭 | Sheet 生命周期正常 |
| 字体缩放 小/中/大 各切换 | `sz()` 缓存问题 |
| 固定/取消固定 → 检查分组 | 固定项正确移动到 today |
| 删除分组 → 确认 → 检查计数 | 分组删除后计数正确更新 |
| 搜索防抖 → 快速输入 | 250ms 防抖后显示正确结果 |
| 批量选择 → 批量删除 | 多选状态正确保留 |

---

## ⚠️ KNOWN ISSUES

### Frozen/Lag Issue
- Appears in commits after `69d1af2` (Liquid Glass versions)
- Symptoms: scrolling freezes, double-click causes hang
- Root cause: **TBD** — suspected duplicate `onTapGesture(count: 2)` handlers in ContentView
- Stable version: `1d65652` (pre-Liquid Glass)

### Double-Click Behavior
- Current: both `onPin()` and `onCopyWithFeedback()` fire on double-click
- SwiftUI limitation: cannot prevent single-tap handler from firing on double-click
- Solutions attempted:
  1. `didDoubleTap` boolean → doesn't work (SwiftUI @State resets on re-render)
  2. `DispatchWorkItem` delay → causes freeze in certain configurations
