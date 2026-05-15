# ClipMemory v2

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
- 25+ rules auto-detect sensitive data (passwords / API keys / ID numbers / etc.)
- Auto-pauses when password manager is in foreground, no copying from the app itself
- Content never saved as plaintext if encryption fails

---

## Feature List

- 📋 Clipboard history (text / images / links)
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

---

## How to Use

| Action | How |
|--------|-----|
| Open Quick Bar | Left-click menu bar 📋 icon / `Cmd+Ctrl+V` |
| Copy item | Click item / keyboard ↑↓ + Enter |
| Open full window | Quick Bar → "Open Clipboard" |
| Search | Type keyword, matches highlighted |
| Pin / Unpin | Click ⭐ or double-click item |
| Delete | Click 🗑 or right-click menu |
| Preview full / sensitive / image | Hold 0.4s, release to hide |
| Multi-select mode | Click checkbox |
| Clear history | Top bar 🗑 (pinned items preserved) |

> 💡 Pinned items are never auto-deleted. Copying identical content doesn't create duplicates, only updates the timestamp.

---

## Security

- **AES-256-GCM (v2) + legacy AES-CBC+HMAC-SHA256** — All text and images encrypted before disk storage
- **Smart detection** — 25+ rules (keywords + regex) auto-identify passwords, API keys, tokens, private keys, ID numbers, bank card numbers, etc.
- **Auto-clear** — Sensitive content configurable to auto-delete after 1h / 24h / 48h / 7 days, or never

---

## Settings

- Max history items (50 / 100 / 200 / 500)
- Sensitive auto-clear policy (1h / 24h / 48h / 7d / never)
- Language (7 languages)
- Global hotkey recording
- Appearance (Light / Dark / Follow system)
- Excluded apps (custom apps to skip monitoring)

---

## Requirements

- macOS 13.0 (Ventura) or later

---

## Installation

```bash
brew tap irykelee/clipmemory https://github.com/irykelee/clipmemory && brew install clipmemory
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
