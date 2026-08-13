# Privacy Policy

**Last updated: 2026-08-13**

ClipMemory is a menu bar clipboard manager for macOS. Your privacy matters — this document explains what data the app handles and how.

## Summary

**ClipMemory does not collect, transmit, or sell your data.** All clipboard history is stored locally on your Mac, encrypted with AES-GCM (CryptoKit).

## Data Storage (local only)

All clipboard items you copy (text, images, links, RTF) are:

- Stored locally in `~/Library/Application Support/ClipMemory/`
- Encrypted with AES-GCM (256-bit key) before writing to disk
- Decrypted only when displayed in the app UI or when you actively restore them
- Never leave your Mac

## Encryption Key Storage

The root encryption key is stored in your macOS Keychain:

- Service: `com.clipmemory.app`
- Account: `root-encryption-key`
- Accessibility: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
- **Not synced to iCloud** (ThisDeviceOnly)

The key never appears in plaintext outside the app process. Backup export (`.clipmemory` files) re-encrypts with a password-derived key (PBKDF2-SHA256, 600k iterations).

## Network Requests

ClipMemory makes outbound network requests **only** for software updates:

- Sparkle 2.x auto-update framework
- Sources (in priority order): GitHub Releases → jsDelivr CDN fallback
- Updates are signed with EdDSA; signature verified before install

No telemetry, analytics, crash reporting, or usage tracking. Ever.

## What ClipMemory Does NOT Do

- ❌ Upload clipboard contents anywhere
- ❌ Phone home with usage statistics
- ❌ Share data with third parties
- ❌ Sync to cloud services (no iCloud, no Dropbox, no remote backend)
- ❌ Use third-party analytics SDKs

## Excluded Apps

You can configure ClipMemory to ignore specific apps (e.g., password managers). This is local-only — no notification or signal is sent to excluded apps. The list is stored in your local UserDefaults.

## Your Control

You can at any time:

- View all stored items in the app
- Delete individual items, all items, or items matching filters
- Export your data to a `.clipmemory` file (password-encrypted)
- Import from a `.clipmemory` file
- Uninstall the app — this removes all local data (`~/Library/Application Support/ClipMemory/`)

## OCR (on-device only)

When you copy an image, ClipMemory may extract text from it using Apple Vision framework (on-device, macOS-native OCR). The extracted text is stored encrypted alongside the image, locally. The image is never sent to any cloud OCR service.

## Changes to This Policy

Material changes will be noted in the release notes and the git history of this file. The git history is the canonical record.

## Contact

Privacy questions: <https://github.com/irykelee/clipmemory/issues>

---

This software is released under the MIT License — see [LICENSE](./LICENSE).