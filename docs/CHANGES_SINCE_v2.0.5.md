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

## Commit: `ccbde24` — Fix Image Sensitivity from Size Heuristic

### Files Changed
- `ClipMemory/Services/ClipboardMonitor.swift`
- `docs/roadmap.md`

### ClipboardMonitor Changes
- Images are no longer auto-marked sensitive based on size (50KB threshold removed)
- `processImageData()` now sets `isSensitive = false` unconditionally
- Storage controlled by maxItems and manual clearing only

---

## Commit: `9ef5ed0` — Extract Components + Shared Utils + NSCache Memory Pressure

### Files Changed
- `ClipMemory.xcodeproj/project.pbxproj`
- `ClipMemory/Models/ClipboardItem.swift`
- `ClipMemory/Services/ClipboardStore.swift`
- `ClipMemory/Utils/DateHelpers.swift` (new)
- `ClipMemory/Utils/FontScaling.swift` (new)
- `ClipMemory/Views/Components/AppPickerRow.swift` (new)
- `ClipMemory/Views/Components/ClipboardItemRow.swift` (new)
- `ClipMemory/Views/Components/DateFilterButton.swift` (new)
- `ClipMemory/Views/Components/FlowLayout.swift` (new)
- `ClipMemory/Views/Components/LogoView.swift` (new)
- `ClipMemory/Views/ContentView.swift`
- `ClipMemory/Views/QuickBarView.swift`
- `docs/roadmap.md`

### ContentView Refactoring (1192 → 759 lines)
- Extracted: FlowLayout, LogoView, DateFilterButton, AppPickerRow, ClipboardItemRow
- Extracted shared utilities: FontScaling.swift (sz()), DateHelpers.swift (date formatters)
- Added NSCache memory pressure handling via `NSMemoryWarningThread`

### ClipboardStore Changes
- Added `handleMemoryPressure()` to clear contentCache on system memory warning
- `totalCostLimit = 10 * 1024 * 1024` (10MB) to bound cache size

### ClipboardItem Changes
- Renamed `decryptionFailed` → `isDecryptionFailed` for clarity

---

## Commit: `7f1bb69` — Docs Sync: CLAUDE.md + Roadmap + README Links + CHANGES

### Files Changed
- `ClipMemory/AppDelegate.swift`
- `ClipMemory/Services/ClipboardStore.swift`
- `ClipMemory/Views/ContentView.swift`
- `ClipMemory/Views/KeyCaptureView.swift`
- `ClipMemory/Views/QuickBarView.swift`
- `README.md`
- `docs/CHANGES_SINCE_v2.0.5.md`
- `docs/roadmap.md`

### ContentView Changes
- Added keyboard navigation: ↑↓ arrows scroll through list, Enter copies
- Added `⌘F` to focus search field from QuickBar
- Added `collapsedIds` for remembering collapsed groups across sessions
- Added app picker "Excluded Apps" section with FlowLayout tags
- Fixed `sz()` to read from `@AppStorage` reactively instead of static UserDefaults
- Fixed date formatting with language-aware formatters

### Roadmap Redefined
- v2.3 redefined: 8 points for specific test coverage tasks (T1-T4)
- v2.4 added: 6 points for OCR image sensitive detection (O1-O5)

---

## Commit: `93bb675` — Update All 8 Language READMEs to v2.2.0

### Files Changed
- `README.md`
- `docs/lang/README_EN.md`
- `docs/lang/README_ES.md`
- `docs/lang/README_JA.md`
- `docs/lang/README_KO.md`
- `docs/lang/README_PT.md`
- `docs/lang/README_ZH-HANS.md`
- `docs/lang/README_ZH-HANT.md`

### Content
- Updated all 8 language READMEs to reflect v2.2.0 feature set
- Synced version numbers, feature descriptions, and installation instructions

---

## Commit: `331b598` — Chore: Update Cask SHA256 for v2.2.0

### Files Changed
- `Casks/clipmemory.rb`

### Content
- Updated SHA256 checksum for v2.2.0 Homebrew cask

---

## ⚠️ KNOWN ISSUES (已修复)

以下问题已在 v2.1.0+ 中解决：

### Frozen/Lag Issue
- Root cause: duplicate `onTapGesture(count: 2)` handlers in ContentView
- **Fixed in v2.1.0**: replaced with `ExclusiveGesture(TapGesture(count: 2), TapGesture())`

### Double-Click Behavior
- **Fixed in v2.1.0**: `ExclusiveGesture` prevents single-tap from firing on double-click
