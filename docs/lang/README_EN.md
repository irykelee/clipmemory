<details>
<summary><b>🌐 Languages / 语言</b></summary>

| Language | Link |
|----------|------|
| English | [README_EN.md](./README_EN.md) |
| 简体中文 | [README.md](../README.md) |
| 日本語 | [README_JA.md](./README_JA.md) |
| 한국어 | [README_KO.md](./README_KO.md) |
| Español | [README_ES.md](./README_ES.md) |
| Português | [README_PT.md](./README_PT.md) |

---
</details>

---

# ClipMemory

**Local Clipboard History Manager**

---

## Introduction

ClipMemory is a local clipboard history manager for macOS. Never lose what you copy.

### Features

- 📋 Clipboard history (text/images/links)
- ⭐ Pin important snippets, never lose them
- 💾 Images stored as files, no storage limits
- 🔍 Quick search through history (with highlighted matches)
- ✅ Copy feedback (green flash confirmation)
- ☑️ Multi-select batch operations (batch pin/delete)
- 🔒 Sensitive info protection (encrypted + auto-clear)
- ⌨️ Global hotkey `Cmd+Ctrl+V` to summon
- 🛡️ Launch at login (optional)
- 🌍 Multi-language support (Chinese/English/Japanese/Korean/Spanish/Portuguese)

### Security Features

- **AES-256 Encryption** — Sensitive content (passwords, API keys) encrypted with AES-256
- **Secure Key Storage** — Keys stored locally with device-level protection
- **Smart Detection** — 25+ sensitive data patterns supported
- **Auto-Clear** — Configurable auto-clear time for sensitive content

### Usage

| Action | How |
|--------|-----|
| Summon window | `⌘⇧V` (global hotkey, works anywhere) |
| Navigate | `↑` / `↓` keys to cycle through items |
| Copy item | `Enter` or single-click copies (green flash confirms) |
| Multi-select | Click checkbox to enter multi-select mode, Shift+click for range |
| Batch actions | After selecting, batch pin/delete with toolbar buttons |
| Close window | `Esc` |
| Search | Type to filter history, matches highlighted |
| Pin/Unpin | Double-click to toggle pin status |
| Pin item | Click ⭐ or right-click → "Pin" |
| Unpin item | Click ⭐ again or right-click → "Unpin" |
| Delete item | Click 🗑 or right-click → "Delete" |
| Reveal sensitive | Click masked text → "View" (search shows matching region) |
| Clear history | Top "Clear" button (pinned items preserved) |

> 💡 Pinned items are never auto-cleared and won't trigger deduplication (re-copying updates timestamp)

### Settings

- Max history items (50/100/200/500/1000/2000)
- Sensitive data auto-clear policy (1h/24h/48h/7days/never)
- Language switcher

### Requirements

- macOS 13.0 (Ventura) or higher

### Installation

```bash
brew install irykelee/clipmemory/clipmemory
```

### Contact

- GitHub: https://github.com/irykelee/clipmemory

### Development

```bash
# Install dependencies
brew install swiftlint xcodegen

# Generate Xcode project
xcodegen generate

# Build
xcodebuild -scheme ClipMemory -configuration Release
```
