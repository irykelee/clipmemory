# ClipMemory 剪忆

**Local Clipboard History Manager / 本地剪贴板历史管理器**

[![English](https://img.shields.io/badge/-English-blue)](#english) [![中文](https://img.shields.io/badge/-中文-red)](#中文)

---

## 中文介绍 {#中文}

### 简介

剪忆是一款 macOS 本地剪贴板历史管理器，永久记忆你的每一次复制。

### 功能特点

- 📋 剪贴板历史记录（文本/图片/链接）
- ⭐ 固定重要片段，永不丢失
- 💾 图片突破存储限制（文件存储）
- 🔍 快速搜索历史记录
- 🔒 敏感信息自动保护（加密存储 + 自动清理）
- ⌨️ 全局快捷键 `Cmd+Ctrl+V` 呼出
- 🛡️ 开机自启动（可选）
- 🌍 多语言支持（简体中文/English）

### 安全特性

- **AES-256 加密存储** — 敏感内容（密码、API密钥等）使用 AES-256 加密存储
- **密钥安全保管** — 加密密钥存储在 macOS Keychain，设备级别保护
- **智能检测** — 支持 25+ 种敏感信息模式检测：
  - 私钥格式（RSA、EC、OpenSSH）
  - API 密钥（AWS、Google AI、Stripe、Square 等）
  - 通用凭证模式（password=value、token=value 等）
- **自动清理** — 敏感内容可设置自动清除时间

### 设置选项

- 历史记录最大条数（50/100/200/500条）
- 敏感信息清除策略（1小时/24小时/48小时/7天/不自动清除）
- 语言切换

### 系统要求

- macOS 10.15 (Catalina) 或更高版本

### 安装

```bash
brew install --cask https://raw.githubusercontent.com/irykelee/clipmemory/main/clipmemory.rb
```

### 联系方式

- GitHub: https://github.com/irykelee/clipmemory

---

## English {#english}

### Introduction

ClipMemory is a local clipboard history manager for macOS. Never lose what you copy.

### Features

- 📋 Clipboard history (text/images/links)
- ⭐ Pin important snippets, never lose them
- 💾 Images stored as files, no storage limits
- 🔍 Quick search through history
- 🔒 Sensitive info protection (encrypted + auto-clear)
- ⌨️ Global hotkey `Cmd+Ctrl+V` to summon
- 🛡️ Launch at login (optional)
- 🌍 Multi-language support (Chinese/English)

### Security Features

- **AES-256 Encryption** — Sensitive content (passwords, API keys) encrypted with AES-256
- **Secure Key Storage** — Encryption keys stored in macOS Keychain with device-level protection
- **Smart Detection** — 25+ sensitive data patterns:
  - Private key formats (RSA, EC, OpenSSH)
  - API keys (AWS, Google AI, Stripe, Square, etc.)
  - Generic credential patterns (password=value, token=value, etc.)
- **Auto-Clear** — Configurable auto-clear time for sensitive content

### Settings

- Max history items (50/100/200/500)
- Sensitive data auto-clear policy (1h/24h/48h/7days/never)
- Language switcher

### Requirements

- macOS 10.15 (Catalina) or higher

### Installation

```bash
brew install --cask https://raw.githubusercontent.com/irykelee/clipmemory/main/clipmemory.rb
```

### Contact

- GitHub: https://github.com/irykelee/clipmemory
