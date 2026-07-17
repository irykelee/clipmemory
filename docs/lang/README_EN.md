# ClipMemory v2.3.0

**Next-generation macOS clipboard manager — one tap to search, instant to copy**

[English](./README_EN.md) · [简体中文](./README.md) · [繁體中文](./README_ZH-HANT.md) · [日本語](./README_JA.md) · [한국어](./README_KO.md) · [Español](./README_ES.md) · [Português](./README_PT.md)

---

## v1 → v2 Key Upgrades

| Aspect | v1 | v2 |
|--------|----|----|
| **Interaction** | Menu → menu → window (3 steps) | Quick Bar popup (1 step) |
| **Main interface** | Fixed width, no sidebar | Fixed sidebar, switch types anytime |
| **Global hotkey** | Cmd+Ctrl+V only | Custom recording supported |
| **Quick Bar** | None | 8 recent items popup, search & copy instantly |
| **Search highlight** | Text overlay highlight | Case-insensitive, no garbled text |
| **Long-press preview** | None | 0.4s reveals full text / sensitive / image |
| **Time grouping** | None | Today / Yesterday / Older, collapsible |

---

## 📋 Changelog

### v2.3.0 (2026-07-17) — Tag System & Data Integrity

- **🏷️ Tag System** — Complete tag lifecycle: create / delete / custom colors; sidebar tag section with cross-section AND / in-section OR filtering; smart tag suggestions (NLTagger-based: code / email / credential / sensitive); TagPicker sheet (inline chips + long-press picker); deletion confirmation dialog
- **6 critical data-integrity fixes** — saveTimer thread-safety race (UB); FileStorageBackend synchronous writes; flushPendingSaves now also flushes tags; legacy image items incorrectly-flagged-as-encrypted repair; contentHash backfill; ImageStorage partial-failure recovery
- **UI improvements** — Welcome window dedupe; Esc cancels hotkey recording (event returned to responder); cross-midnight currentDate refresh; search-mode force-expand groups (keyboard nav sync); pendingMaxItemsReduction variable typo fix
- **Refactor + performance** — RTF NSCache; L10n bundle cache; WindowManager state stability (@State preserved across close/reopen); windowDidMove/Resize debounced 0.5s; +9 net new tests (241 → 250)

### v2.2.4 (2026-07-16) — Release Hygiene

- **Version stamp synced with release tag** — `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` bumped to `2.2.4` in `project.yml` and regenerated `project.pbxproj`. Resolves the v2.2.3 lesson where the tag was cut without bumping these fields.
- **Quick Bar label fix** — Removed misleading `⌘⌃V` shortcut label on the Quick Bar "open full window" item. The global hotkey opens the full main window; the Quick Bar is opened via left-click on the menu-bar 📋 icon.
- **Documentation hotkey correction** — The `Cmd+Ctrl+V` row in 8 language READMEs rewritten to clarify it opens the main window, not the Quick Bar.
- **Packaging safety** — `Scripts/package.sh` default version now reads `MARKETING_VERSION` from `project.yml` (with a guard if reading fails), preventing the pre-v2.2.4 footgun of packaging a stale-stamped tarball when invoked without an explicit version argument.

### v2.2.1 (2026-05-19) — Image Sensitivity Fix

- **Image sensitivity fix** — Images no longer auto-marked sensitive by size (50KB threshold removed), storage controlled by maxItems and manual clearing
- **Component extraction** — ContentView split into FlowLayout, LogoView, DateFilterButton, AppPickerRow, ClipboardItemRow
- **Shared utilities** — Extracted FontScaling.swift (sz()) and DateHelpers.swift (date formatters)
- **NSCache memory pressure** — Added system memory warning observer to clear cache on pressure

### v2.2.0 (2026-05-15) — Rich Text Support

- **RTF Clipboard Capture** — Automatically recognizes and saves rich text content
- **Rich Text Rendering** — NSAttributedString → AttributedString conversion
- **Copy Back** — Writes both .rtf and .string pasteboard types
- **Sidebar Tab** — New "Rich Text" category with icon, count badge, and type filter
- **Quick Bar Display** — Rich text icon + plain text preview
- **Sensitive Masking** — Rich text items support sensitive content masking
- **85 Tests** — Including 4 rich text round-trip tests
- **Search Fix** — Fixed rich text search functionality

### v2.1.5 (2026-05-11) — Protocol Abstraction & UX

- **Protocol Abstraction** — StorageBackend protocol + MemoryStorageBackend test backend
- **81 Tests** — Complete test infrastructure
- **Max Trim Dialog** — Confirmation dialog when history exceeds limit
- **Image Placeholder** — Elegant placeholder on load failure
- **Group Operations** — Unpin/clear at group level

### v2.1.0 (2026-05-09) — Liquid Glass UI

- Liquid Glass design — NavigationSplitView sidebar + QuickBar frosted glass popup
- Keyboard navigation fixes — Scroll and search box arrow key handling

---

## Feature Highlights

### Quick Bar — One Tap Away

Click menu bar icon → NSPopover shows 8 recent items → click to copy / search / open full window

### Long Press 0.4s — Unlimited Preview

| Content type | Default | After long press |
|-------------|---------|-----------------|
| Plain text | First 200 chars, 3 lines | Full text |
| Sensitive content | Masked `ab••••••yz` | Revealed text |
| Image | Thumbnail 80px | Enlarged to 300px |

### Smart Security — Encryption + Detection

- AES-256-GCM encryption (v2), compatible with legacy AES-CBC+HMAC-SHA256
- 35 rules auto-detect sensitive data (credentials / API keys / Slack/Discord/OpenAI tokens / ID numbers / etc.)
- Auto-pauses when password manager is in foreground, no copying from the app itself
- Content never saved as plaintext if encryption fails

---

## Feature List

- 📋 Clipboard history (text / images / links / **rich text RTF**)
- ⭐ Pin important items, never auto-deleted
- 💾 Encrypted image storage, bypasses 10MB limit
- 🔍 Real-time search, all languages highlighted (CJK multibyte supported)
- ⚡ Smart deduplication, identical content updates timestamp only
- 🔄 Copy loop prevention, auto-skips copying from the app itself
- 🧹 Orphan file cleanup, auto-cleans unreferenced images on launch
- 🌍 7 languages (简体中文 / 繁體中文 / English / 日本語 / 한국어 / Español / Português)
- ☑️ Multi-select batch pin / delete
- ✅ Green flash feedback on successful copy
- ⚙️ Auto-detects hotkey conflicts on first launch
- ⌨️ Global hotkey `Cmd+Ctrl+V`
- 🖥 Launch at login (enable in Settings)
- 📐 Font scaling (Small / Medium / Large)
- 🎨 Appearance (Light / Dark / Follow system)
- 🗂️ Type filters (All / Text / Image / Link / Rich Text)
- ⌨️ Keyboard navigation (arrow key scroll, search box focus handling)

---

## How to Use

| Action | How |
|--------|-----|
| Open Quick Bar | Left-click menu bar 📋 icon |
| Copy item | Click item / keyboard ↑↓ + Enter |
| Open full window | `Cmd+Ctrl+V` (global hotkey) / Quick Bar → "Open Clipboard" |
| Search | Type keyword, matches highlighted |
| Pin / Unpin | Click ⭐ or double-click item |
| Delete | Click 🗑 or right-click menu |
| Preview full / sensitive / image | Hold 0.4s, release to hide |
| Multi-select mode | Click checkbox |
| Clear history | Top bar 🗑 (pinned items preserved) |
| Switch type filter | Click "Text/Image/Link/Rich Text" in sidebar |

> 💡 Pinned items are never auto-deleted. Copying identical content doesn't create duplicates, only updates the timestamp.

---

## Security

- **AES-256-GCM (v2) + legacy AES-CBC+HMAC-SHA256** — All text and images encrypted before disk storage
- **Smart detection** — 35 rules (keywords + regex) auto-identify credentials, API keys, Slack/Discord/OpenAI tokens, private keys, ID numbers, bank card numbers, etc.
- **Auto-clear** — Sensitive content configurable to auto-delete after 1h / 24h / 48h / 7 days, or never

---

## Settings

- Max history items (50 / 100 / 200 / 500)
- Sensitive auto-clear policy (1h / 24h / 48h / 7d / never)
- Language (7 languages)
- Global hotkey recording
- Appearance (Light / Dark / Follow system)
- Excluded apps (custom apps to skip monitoring)
- Rich text capture toggle

---

## Requirements

- macOS 13.0 (Ventura) or later

---

## Data Migration

History (including encryption key) is stored at `~/Library/Application Support/ClipMemory/`.
Back up this directory before reinstalling — it can be restored on the same Mac or a new Mac to continue reading your history.
Before removing the app, click the 🗑 button in the top toolbar to clear history.

---

## Installation

```bash
brew tap irykelee/clipmemory https://github.com/irykelee/clipmemory
brew trust irykelee/clipmemory
brew install --cask clipmemory
```

After install, App is at `/Applications/ClipMemory.app`. Launch and find the 📋 icon in the **menu bar** (top right corner).

Or download `.tar.gz` from [GitHub Releases](https://github.com/irykelee/clipmemory/releases) and extract to `/Applications/`.

---

## Development

```bash
brew install swiftlint xcodegen
xcodegen generate
xcodebuild -scheme ClipMemory -configuration Release
```

---

## Contact

- GitHub: https://github.com/irykelee/clipmemory
- Feedback: Settings → About → Send Feedback → GitHub Issues
