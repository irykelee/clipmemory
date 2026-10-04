### v2.9.6 (2026-10-04) — 长按图片预览十方向滚动 + code-review backlog 闭环 + ID-CRASH-0038 收尾

- **🖼 长按图片预览 — 滚轮滑动同时支持纵、横向 + Shift+wheel**：修复按住左键滚动滚轮导致图片被意外 dismiss 的 bug（USER-FEEDBACK-2026-09-26，经多轮迭代修复）。现在预览面板在滚动期间保持显示，松手才正常关闭。同时支持纵向滚动、Logitech 鼠标侧键 / Magic Mouse 横向 swipe / trackpad 双指 swipe 的横向滚动，以及普通鼠标 + Shift+wheel 的横向滚动（macOS 标准约定）。图片超过预览窗口时滚动条正确移动。
- **🛠 code-review-2026-09-28 backlog 全闭环（38/38）**：7 项 P1 + 18 项 P2 + 5 项 follow-up 全部 ship；覆盖 L10n / Crypto / Window / Persistence / TSan / CI 工具链 / dependabot / 文档过期项 等加固。详见 `docs/audit/code-review-2026-09-28.md`。
- **🛠 ID-CRASH-0038 mass-skip 收尾（46 → 4）**：issue #93 runner restart 根因修复 + production code 全迁注入 seam（HotKey / SafeMode / ClipboardStore / Crypto / WindowManager）+ ZZZ canary re-enabled。42/46 测试恢复（AppDelegate terminate + IntegrationTests + HotKey 3 处条件 guard + MemoryWarning + WindowManager）；剩 4 处 snapshot golden 失配留 v2.9.7 调研（CI-only 环境差，本地 1025/4/0 真绿）。
- **🛠 ID-CRASH-0058/0059 — `@preconcurrency` 注解抑制 Swift 6 strict-concurrency warnings**：TSan advisory 6 处 warning 净减 0。`ClipboardMonitorDelegate` protocol + `ClipboardStore+OCR.swift` GCD 闭包两处加注解，runtime 语义不变。
- **🛠 ID-REVIEW-1012 lazy-init `ClipboardStore.shared`**：原 `static let shared = ClipboardStore()` 在模块加载时 eager 求值，xcTestDefaults env var 检测被骗。改 `nonisolated(unsafe) static var shared` + `MainActor.assumeIsolated` + NSLock 实现真正的 lazy 初始化。
- **🛠 Hygiene batch**：`trailing_newline` 51 处 SwiftLint 警告修复 + `.gitattributes` LF 行尾强制；2 个 shell script `chmod -x` 丢失恢复。

完整 1025 / 4 skipped / 0 failures（en + zh-Hans 双 locale）。

详见 `docs/skips-ledger.md`（v2.9.6 完整 ship 后归档）。
