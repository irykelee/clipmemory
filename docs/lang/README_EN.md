English · [简体中文](../README.md) · [Español](./README_ES.md) · [Português](./README_PT.md) · [日本語](./README_JA.md) · [한국어](./README_KO.md)

---

# ClipMemory

**Local Clipboard History Manager**

## Introduction

ClipMemory is a local clipboard history manager for macOS. Never lose what you copy.

### Features

- 📋 Clipboard history (text/images/links)
- ⭐ Pin important snippets, never lose them
- 💾 Images stored as files, no storage limits
- 🔍 Quick search through history
- 🔒 Sensitive info protection (encrypted + auto-clear)
- ⌨️ Global hotkey `Cmd+Ctrl+V` to summon
- 🛡️ Launch at login (optional)
- 🌍 Multi-language support (Chinese/English/Japanese/Korean/Spanish/Portuguese)

### Security Features

- **AES-256 Encryption** — Sensitive content (passwords, API keys) encrypted with AES-256
- **Secure Key Storage** — Encryption keys stored in macOS Keychain with device-level protection
- **Smart Detection** — 25+ sensitive data patterns supported
- **Auto-Clear** — Configurable auto-clear time for sensitive content

### Usage

| Action | How |
|--------|-----|
| Summon window | `⌘⇧V` (global hotkey, works anywhere) |
| Navigate | `↑` / `↓` keys to cycle through items |
| Copy item | `Enter` copies selected and closes window |
| Close window | `Esc` |
| Search | Type to filter history in real-time |
| Pin item | Click ⭐ or right-click → "Pin" |
| Unpin item | Click ⭐ again or right-click → "Unpin" |
| Delete item | Click 🗑 or right-click → "Delete" |
| Reveal sensitive | Click orange masked text → "View" |
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
brew install --cask https://raw.githubusercontent.com/irykelee/clipmemory/main/clipmemory.rb
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
