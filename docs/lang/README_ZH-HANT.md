# ClipMemory v2

**新一代 macOS 剪貼簿管理器 — 更好的 UI、更快的操作、更多功能**

[English](../docs/lang/README_EN.md) · [简体中文](../README.md) · [繁體中文](./README_ZH-HANT.md) · [日本語](./README_JA.md) · [한국어](./README_KO.md) · [Español](./README_ES.md) · [Português](./README_PT.md)

---

## 相較於 v1 的改進

| 項目 | v1 | v2 |
|------|----|----|
| **操作入口** | 選單列點擊 → 選單 → 開視窗 | 選單列點擊 → Quick Bar 彈窗（一步）|
| **主介面** | 固定寬度，無側欄 | **側邊欄導覽**：全部 / 文字 / 圖片 / 連結 / 收藏 / 設定 |
| **類型篩選** | 水平按鈕組 | 側邊欄垂直列表，附項目數量 |
| **時間分組** | 無 | 今天 / 昨天 / 本週 / 本月 / 更早（可折疊）|
| **長按預覽** | 無 | 文字→全文、敏感→揭示、圖片→放大（按住 0.4 秒）|
| **視窗樣式** | 標準 NSWindow | 毛玻璃效果（macOS 26 Liquid Glass 風格）|
| **字體縮放** | 無 | 設定頁：小/中/大三檔 |

## 新增功能

- **Quick Bar**：點擊選單列圖示 → 最近 8 條內容 → 點擊複製 / 搜尋
- **長按操作**：文字 0.4s 顯示全文、敏感內容揭示原文、圖片放大 300px
- **時間線分組**：自動按建立時間分組，可折疊
- **字體縮放**：設定頁調整全介面文字大小
- **快捷鍵自訂**：設定頁可錄製新的全域快捷鍵

## 安裝

```bash
brew tap irykelee/clipmemory https://github.com/irykelee/clipmemory && brew install --cask clipmemory
```

啟動後在**螢幕右上角選單列**找到 📋 圖示。或從 [GitHub Releases](https://github.com/irykelee/clipmemory/releases) 下載。

## 系統需求

macOS 13.0 (Ventura) 或更高版本

## 聯絡
- Feedback: 設定 → 關於 → 發送回饋 → GitHub Issues

- GitHub: https://github.com/irykelee/clipmemory
