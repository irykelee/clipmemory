# ClipMemory v2

**Next-gen macOS Clipboard Manager — Better UI, Faster Actions, More Features**

[English](./README_EN.md) · [简体中文](./README_ZH-HANS.md) · [繁體中文](./README_ZH-HANT.md) · [日本語](./README_JA.md) · [한국어](./README_KO.md) · [Español](./README_ES.md) · [Português](./README_PT.md)

---

## What's New in v2 vs v1

| Aspect | v1 | v2 |
|--------|----|----|
| **Interaction** | Menu bar click → menu → open window (3 steps) | Menu bar click → **Quick Bar popup** (1 step) |
| **Main Window** | Fixed-width, no sidebar | **Fixed sidebar**: All / Text / Image / Link / Pinned Only / Settings |
| **Type Filter** | Horizontal buttons | Vertical sidebar navigation with item counts |
| **Time Grouping** | None | Today / Yesterday / Older, collapsible |
| **Global Hotkey** | Cmd+Ctrl+V only | Customizable (record from Settings) |
| **Quick Bar** | None | 8 recent items in popover, search + copy + open window |
| **Search Highlight** | Highlight on text | Case-insensitive, no garbled text |
| **Long Press Preview** | None | Text → full content, sensitive → reveal, image → enlarge (0.4s hold) |
| **Icon Layout** | Checkbox + type icon + star + content | Checkbox + content + star + delete, cleaner |
| **Window Style** | Standard window | Glass effect, more modern |
| **Window Buttons** | In titlebar | Hidden titlebar, unified toolbar area (macOS 26 Liquid Glass) |
| **Dock Icon** | Always hidden | Appears when window opens, hides when closed |
| **Hover Highlight** | None | Automatic highlight on hover |
| **Font Scaling** | None | Small / Medium / Large in Settings |
| **Launch at Login** | None (menu only) | Toggle in Settings |
| **Settings Page** | Basic Form | Sidebar independent page, grouped and optimized |

---

## New Features

### Quick Bar

Click menu bar icon → NSPopover with 8 recent items → click to copy / search / open full window

### Long Press Actions (0.4s)

| Content Type | Default View | Long Press Shows |
|-------------|-------------|------------------|
| Regular Text | First 200 chars, 3 lines | Full content (no truncation) |
| Sensitive Content | Masked `ab••••••yz` | Revealed text + search highlight |
| Image | Thumbnail 80px | Enlarged to 300px |

### Time Grouping

Items auto-grouped by creation time: Today / Yesterday / Older, collapsible sections.

### Font Scaling

Settings → Font Size → Small / Medium / Large — scales all UI text.

### Customizable Hotkey

Settings allows recording a new global hotkey to replace the default `Cmd+Ctrl+V`.

### Theme System

Settings allows adjusting Window Effect (Solid / Frosted / Ultra) and Appearance (Light / Dark / Follow System).

---

## Features

- 📋 Clipboard history (text / images / links)
- ⭐ Pin important items, never auto-cleared
- 💾 Images stored as encrypted files, surpasses 10MB limit
- 🔍 Real-time search with multilingual highlight (including CJK characters)
- ✅ Copy feedback (green flash)
- ☑️ Multi-select batch pin / delete
- 🔒 Sensitive data auto-detection (25+ rules) + AES-256-GCM encryption (v2) with legacy AES-CBC+HMAC-SHA256 compatibility
- 🔐 Auto-pause when password managers are in foreground, custom app exclusion supported
- ⚡ Smart deduplication — same content updates timestamp without duplication
- 🔄 Copy loop prevention — skips capture when copying from the app itself
- 🔒 Security first: content is discarded if encryption fails, never stored as plaintext
- 🧹 Orphan cleanup — removes unreferenced images on startup
- ⚙️ Hotkey conflict detection on first launch
- ⌨️ Global hotkey `Cmd+Ctrl+V`
- 🌍 7 languages (Simplified Chinese / Traditional Chinese / English / Japanese / Korean / Spanish / Portuguese)
- 📎 Settings → About → Send Feedback → GitHub Issues

---

## Usage Guide

| Action | How |
|--------|-----|
| Open Quick Bar | Click menu bar 📋 / `Cmd+Ctrl+V` |
| Copy from Quick Bar | Click item / ↑↓ + Enter |
| Open Full Window | Quick Bar → "Open Full Window" |
| Search | Type to filter, matches highlighted |
| Pin / Unpin | Click ⭐, double-click row, or right-click menu |
| Delete | Click 🗑 or right-click menu |
| Reveal sensitive | Hold 0.4s to show, release to hide |
| Enlarge image | Hold 0.4s to zoom, release to shrink |
| Show full text | Hold 0.4s on any text item |
| Multi-select | Click checkbox |
| Batch operations | Select multiple → batch pin / delete |
| Close window | `Esc` |
| Clear history | Top toolbar 🗑 (pinned preserved) |

> 💡 Pinned items are never auto-cleared. Re-copying same content updates timestamp without duplication.

---

## Security

- **AES-256-GCM (v2) + legacy AES-CBC+HMAC-SHA256** — All text and images encrypted before disk write
- **Smart Detection** — 25+ rules (keyword + regex) for passwords, API keys, tokens, private keys, IDs
- **Auto-Clear** — Configurable timer (1h / 24h / 48h / 7d / never)

---

## Settings

- Max history items (50 / 100 / 200 / 500)
- Sensitive auto-clear policy (1h / 24h / 48h / 7d / never)
- Language (7 languages)
- Global hotkey recording
- Font size (Small / Medium / Large)
- Window Effect (Solid / Frosted / Ultra)
- Appearance (Light / Dark / Follow System)
- Excluded Apps (custom apps to skip clipboard monitoring)

---

## Requirements

- macOS 13.0 (Ventura) or later

---

## Installation

```bash
brew tap irykelee/clipmemory https://github.com/irykelee/clipmemory && brew install --cask clipmemory
```

After installing, the App is at `/Applications/ClipMemory.app`. Find the 📋 icon in the **menu bar** (top right) after launching. Click to use.

Or download `.tar.gz` from [GitHub Releases](https://github.com/irykelee/clipmemory/releases) and extract manually to `/Applications/`.

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
