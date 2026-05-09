# ClipMemory v2

**次世代 macOS クリップボード管理 — より良いUI、より速い操作、より多くの機能**

[English](../docs/lang/README_EN.md) · [简体中文](../README.md) · [繁體中文](./README_ZH-HANT.md) · [日本語](./README_JA.md) · [한국어](./README_KO.md) · [Español](./README_ES.md) · [Português](./README_PT.md)

---

## v1 からの改善点

| 項目 | v1 | v2 |
|------|----|----|
| **操作** | メニューバー → メニュー → ウィンドウ | Quick Bar ポップアップ（1ステップ）|
| **メイン画面** | 固定幅、サイドバーなし | **サイドバーナビゲーション** |
| **タイプフィルター** | 横並びボタン | サイドバーの垂直リスト |
| **時間グループ** | なし | 今日 / 昨日 / 今週 / 今月 / 以前 |
| **ロングプレス** | なし | テキスト→全文、機密→表示、画像→拡大（0.4秒長押し）|
| **ウィンドウ** | 標準 NSWindow | Safari 26 スタイルのガラス効果 |
| **フォントサイズ** | なし | 小/中/大の3段階設定 |

## 新機能

- **Quick Bar**: メニューバークリック → 最近8件 → クリックでコピー / 検索
- **ロングプレス**: 0.4秒長押しで全文表示、機密内容表示、画像拡大
- **時間グループ**: 作成日時で自動グループ化（折りたたみ可能）
- **フォントスケーリング**: 設定でUIテキストサイズ調整
- **ショートカットカスタマイズ**: 設定でホットキー録音

## インストール

```bash
brew tap irykelee/clipmemory https://github.com/irykelee/clipmemory && brew install --cask clipmemory
```

起動後、**画面右上のメニューバー**の 📋 アイコンをクリック。または [GitHub Releases](https://github.com/irykelee/clipmemory/releases) からダウンロード。

## システム要件

macOS 13.0 (Ventura) 以降

## お問い合わせ
- フィードバック: 設定 → このアプリについて → GitHub Issues

- GitHub: https://github.com/irykelee/clipmemory
