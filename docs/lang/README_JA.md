[English](../../README.md) · [简体中文](../../README.md) · [Español](./README_ES.md) · [Português](./README_PT.md) · [한국어](./README_KO.md)

---

# ClipMemory 剪憶（日本語）

**ローカルクリップボード履歴マネージャー**

## 機能

- 📋 クリップボード履歴（テキスト/画像/リンク）
- ⭐ 重要なスニペットをピン留め
- 💾 画像はファイルとして保存（容量制限なし）
- 🔍 高速検索
- 🔒 機密情報保護（暗号化 + 自動削除）
- ⌨️ グローバルホットキー `Cmd+Ctrl+V` で呼び出し
- 🛡️ ログイン時に起動（オプション）
- 🌍 マルチリンガルサポート

## セキュリティ機能

- **AES-256暗号化** — パスワード、APIキーなどの機密コンテンツはAES-256で暗号化
- **安全なキー管理** — 暗号化キーはmacOS Keychainに安全に保管
- **スマート検出** — 25+の機密データパターン対応
- **自動削除** — 機密コンテンツの自動削除時間設定可能

## 使用方法

| 操作 | 方法 |
|------|------|
| ウィンドウ呼び出し | `⌘⇧V` |
| 移動 | `↑` / `↓` キー |
| コピー | `Enter` |
| 閉じる | `Esc` |
| 検索 | キーワード入力でリアルタイムフィルタリング |
| ピン留め | ⭐ クリックまたは右クリック→「ピン留め」 |
| 削除 | 🗑 クリックまたは右クリック→「削除」 |

## 設定

- 最大履歴数（50/100/200/500/1000/2000）
- 機密情報自動削除ポリシー（1時間/24時間/48時間/7日/なし）
- 言語切り替え

## 必要環境

- macOS 13.0 (Ventura) 以上

## インストール

```bash
brew install --cask https://raw.githubusercontent.com/irykelee/clipmemory/main/clipmemory.rb
```

## 開発

```bash
brew install swiftlint xcodegen
xcodegen generate
xcodebuild -scheme ClipMemory -configuration Release
```

## 連絡先

- GitHub: https://github.com/irykelee/clipmemory
