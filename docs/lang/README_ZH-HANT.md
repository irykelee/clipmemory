# 剪憶 ClipMemory v2.4.0

**新一代 macOS 剪貼簿管理器 — 一步開啟，複製即搜**

[English](./README_EN.md) · [简体中文](./README.md) · [繁體中文](./README_ZH-HANT.md) · [日本語](./README_JA.md) · [한국어](./README_KO.md) · [Español](./README_ES.md) · [Português](./README_PT.md)

---

## v1 → v2 核心升級

| 維度 | v1 | v2 |
|------|----|----|
| **互動入口** | 選單 → 選單 → 視窗（三步） | Quick Bar 彈窗（一步） |
| **主介面** | 固定寬度，無側邊欄 | 固定側邊欄，隨時切換類型 |
| **全域快捷鍵** | 僅 Cmd+Ctrl+V | 支援自訂錄製 |
| **Quick Bar** | 無 | 最近 8 條彈窗，即搜即複製 |
| **搜尋高亮** | 文字覆蓋高亮 | 不區分大小寫，不亂碼 |
| **長按預覽** | 無 | 0.4s 揭示全文 / 敏感 / 圖片原圖 |
| **時間分組** | 無 | 今天 / 昨天 / 更早，可折疊 |

---

## 📋 更新日誌

### v2.4.0 (2026-07-18) — 資源回收筒

- **🗑️ 資源回收筒（Recycle Bin）** — 刪除條目不再直接銷毀，而是先進入資源回收筒保留 7 天（可在設定中調整），期間可隨時復原或徹底刪除；清空資源回收筒帶確認彈窗；自動清理過期條目
- **✨ 自動更新（Sparkle 2）** — 應用內自動檢查更新：背景每日檢查 + 設定頁手動檢查；更新包經 EdDSA 簽章驗證後一鍵安裝重啟；Homebrew Cask 已宣告 auto_updates
- **資料安全** — 圖片檔案隨資源回收筒條目保留，徹底清除時才刪除；自動清理（trim/expire）不進入資源回收筒，避免誤留垃圾
- **UI 更新** — 側邊欄新增「資源回收筒」入口（badge 顯示數量）；刪除確認彈窗文案更新為「移至資源回收筒」；資源回收筒條目顯示刪除時間
- **測試** — 新增 12 項資源回收筒專項測試，全部通過

### v2.3.0 (2026-07-17) — 標籤系統與資料完整性

- **🏷️ 標籤系統（Tag System）** — 完整標籤生命週期：建立 / 刪除 / 自訂顏色；側邊欄 tag section + 跨 section AND / in-section OR 過濾；智慧 tag 建議（基於 NLTagger：程式碼 / 郵件 / 憑證 / 敏感）；TagPicker sheet（行內 chips + 長按彈選擇器）；刪除確認對話框
- **6 個資料完整性嚴重修復** — saveTimer 執行緒競爭 UB；FileStorageBackend 同步落盤；flushPendingSaves 同步 flush tag；legacy image items 錯誤加密標記修復；contentHash backfill；ImageStorage 部分失敗 recovery
- **UI 改進** — Welcome window dedupe；Esc 取消 hotkey recording（返回 event 給 responder）；跨午夜自動重新整理 currentDate；Search 模式 force-expand groups（鍵盤導覽同步）；pendingMaxItemsReduction typo 修復
- **重構 + 效能** — RTF NSCache；L10n bundle cache；WindowManager 狀態穩定化（@State 跨 close/reopen 保持）；windowDidMove/Resize debounce 0.5s；+9 net new tests（241 → 250）

### v2.2.4 (2026-07-16) — 發布衛生修復

- **版本號與發布標籤同步** — `project.yml` 的 `MARKETING_VERSION` 與 `CURRENT_PROJECT_VERSION` 升級到 `2.2.4`，重新生成 `project.pbxproj`。修正 v2.2.3 切標籤但未同步版本號導致下遊 cask 拿到舊版本的問題
- **Quick Bar 標籤修正** — 移除 Quick Bar「打開完整窗口」項上誤導性的 `⌘⌃V` 快捷鍵標籤。全域快捷鍵打開的是完整主窗口，Quick Bar 由菜單欄 📋 圖標左鍵打開
- **文檔快捷鍵說明更正** — 8 種語言 README 中關於 `Cmd+Ctrl+V` 的描述重寫，明確該快捷鍵打開主窗口而非 Quick Bar
- **打包腳本安全加固** — `Scripts/package.sh` 默認版本號改為從 `project.yml` 讀取 `MARKETING_VERSION`（含讀取失敗的防護），避免在不帶參數調用時靜默打包一個舊版本號的 tarball

### v2.2.1 (2026-05-19) — 圖片敏感邏輯修復

- **圖片敏感判斷修復** — 圖片不再按大小（50KB）自動標記敏感，存儲由 maxItems 和手動清理控制
- **組件拆分重構** — ContentView 拆分為 FlowLayout、LogoView、DateFilterButton、AppPickerRow、ClipboardItemRow
- **共享工具類** — 提取 FontScaling.swift（sz()）和 DateHelpers.swift（日期格式化）
- **NSCache 內存壓力處理** — 添加系統內存警告監聽，觸發緩存清理

### v2.2.0 (2026-05-15) — 富文本支持

- **RTF 剪貼簿捕獲** — 自動識別並保存富文本內容
- **富文本渲染** — NSAttributedString → AttributedString 轉換
- **複製回粘** — 同時寫入 .rtf 和 .string 兩種剪貼簿類型
- **側邊欄標籤** — 新增「富文本」分類，含圖示、計數徽章和類型篩選
- **Quick Bar 展示** — 富文本圖示 + 純文本預覽
- **敏感內容遮罩** — 富文本條目同样支持敏感資訊掩碼
- **85 項測試** — 含 4 項富文本往返測試
- **搜尋優化** — 修復富文本搜尋功能

### v2.1.5 (2026-05-11) — 協議抽象與交互優化

- **協議抽象** — StorageBackend 協議 + MemoryStorageBackend 測試後端
- **81 項測試** — 完整測試基礎設施
- **最大條數裁剪對話方塊** — 超出歷史上限時彈窗確認
- **圖片佔位符** — 載入失敗時顯示優雅的佔位圖
- **分組操作** — 支援分組級別取消固定/清空

### v2.1.0 (2026-05-09) — Liquid Glass UI

- Liquid Glass 設計語言 — NavigationSplitView 側邊欄 + QuickBar 玻璃彈窗
- 鍵盤導航優化 — 滾動和搜尋框方向鍵處理修復

---

## 功能亮點

### Quick Bar — 一步即達

點擊選單列圖示 → NSPopover 彈出最近 8 條 → 點擊複製 / 搜尋 / 開啟完整視窗

### 長按 0.4s — 預覽無限制

| 內容類型 | 預設顯示 | 長按後 |
|---------|---------|--------|
| 一般文字 | 前 200 字元，3 行 | 全文顯示 |
| 敏感內容 | 遮罩 `ab••••••yz` | 揭示原文 |
| 圖片 | 縮圖 80px | 放大至 300px |

### 智能安全 — 加密 + 敏感檢測

- AES-256-GCM 加密（v2），相容舊版 AES-CBC+HMAC-SHA256
- 35 條規則自動識別敏感內容（密碼 / API 金鑰 / Slack/Discord/OpenAI 等 token / 身份證號等）
- 密碼管理員在前台時自動暫停，不從 App 內複製
- 加密失敗時內容不落地，拒絕明文儲存

---

## 功能列表

- 📋 剪貼簿歷史（文字 / 圖片 / 連結 / **富文本 RTF**）
- ⭐ 釘選重要條目，不自動清理
- 💾 圖片加密儲存，突破 10MB 限制
- 🔍 即時搜尋，所有語言高亮（含中日韓等多位元組字元）
- ⚡ 智慧去重，相同內容只更新時間戳
- 🔄 複製循環攔截，從 App 內複製自動跳過
- 🧹 孤立檔案清理，啟動時自動清理無引用圖片
- 🌍 7 種語言（簡體中文 / 繁體中文 / English / 日本語 / 한국어 / Español / Português）
- ☑️ 多選批次釘選 / 刪除
- ✅ 複製成功綠色閃爍回饋
- ⚙️ 首次啟動自動檢測快捷鍵衝突
- ⌨️ 全域快捷鍵 `Cmd+Ctrl+V`
- 🖥 開機自啟（設定中開啟）
- 📐 字體縮放（小 / 中 / 大）
- 🎨 外觀（淺色 / 深色 / 跟隨系統）
- 🗂️ 類型篩選（全部 / 文字 / 圖片 / 連結 / 富文本）
- ⌨️ 鍵盤導航優化（方向鍵滾動、搜尋框焦點處理）

---

## 使用方法

| 操作 | 方式 |
|------|------|
| 開啟完整視窗 | `Cmd+Ctrl+V` |
| 彈出 Quick Bar | 左鍵點擊選單列 📋 圖示 |
| 複製條目 | 點擊條目 / 鍵盤 ↑↓ + Enter |
| 搜尋 | 輸入關鍵詞，匹配處高亮 |
| 釘選 / 取消釘選 | 點擊 ⭐ 或雙擊條目 |
| 刪除 | 點擊 🗑 或右鍵選單 |
| 預覽全文 / 敏感內容 / 圖片 | 按住 0.4s，鬆開恢復 |
| 多選批次操作 | 單擊核取方塊進入多選模式 |
| 清空歷史 | 頂欄 🗑（保留釘選條目） |
| 切換類型篩選 | 側邊欄點擊「文字/圖片/連結/富文本」 |

> 💡 釘選的條目不會被自動清理。複製相同內容不重複記錄，只更新時間戳。

---

## 安全特性

- **AES-256-GCM（v2）+ 相容舊版 AES-CBC+HMAC-SHA256** — 所有文字和圖片存入磁碟前自動加密
- **智慧檢測** — 35 條規則（關鍵詞 + 正規式），自動識別密碼、API 金鑰、Slack/Discord/OpenAI 等 token、私鑰、身份證號、銀行卡號等
- **自動清理** — 敏感內容可設定 1 小時 / 24 小時 / 48 小時 / 7 天後自動清除，或不自動清除

---

## 偏好設定

- 歷史記錄最大條數（50 / 100 / 200 / 500 條）
- 敏感資訊清除策略（1 小時 / 24 小時 / 48 小時 / 7 天 / 不自動清除）
- 語言切換（7 種語言）
- 全域快捷鍵錄製
- 外觀（淺色 / 深色 / 跟隨系統）
- 排除應用（自訂不監控的 App）
- 富文本捕獲開關

---

## 系統需求

- macOS 13.0 (Ventura) 或更高版本

---

## 數據遷移

歷史記錄（含加密密鑰）位於 ~/Library/Application Support/ClipMemory/。
重裝前備份此目錄即可遷移，重裝 macOS 或更換 Mac 後恢復即可繼續讀取。
刪除 App 前，可點擊主視窗頂欄 🗑 按鈕清除歷史記錄。

---

## 安裝

```bash
brew tap irykelee/clipmemory
brew trust irykelee/clipmemory
brew install --cask clipmemory
```

安裝後 App 在 `/Applications/ClipMemory.app`。啟動後看**螢幕右上角選單列**的 📋 圖示，點擊即可使用。

或從 [GitHub Releases](https://github.com/irykelee/clipmemory/releases) 下載 `.tar.gz` 手動解壓到 `/Applications/`。

> **首次打開若提示「Apple 無法驗證…」**：這是 macOS 對未公證應用的常規攔截，不是病毒。任選一種：① 右鍵點 App →「打開」→ 再點「打開」；② 系統設定 → 隱私與安全性 → 找到 ClipMemory 點「仍要打開」。僅需操作一次，之後正常。（透過 `brew install` 安裝不會遇到此提示）

---

## 開發

```bash
brew install swiftlint xcodegen
xcodegen generate
xcodebuild -scheme ClipMemory -configuration Release
```

---

## 聯絡方式

- GitHub: https://github.com/irykelee/clipmemory
- 回饋：偏好設定 → 關於 → 傳送回饋 → GitHub Issues
