# Development Guide

## Workflow

### Branch Strategy

Trunk-based development with `main` as the always-releasable branch:

```
main ───●───●───●───●  (tag: v2.0.6, v2.0.7...)
          \   /    \   /
        feature/a feature/b
```

- Single developer: no `develop` intermediate layer needed
- Tags mark releases (v2.0.6, v2.0.7...)

### Pre-commit Hook

Located at `.git/hooks/pre-commit`. Automatically runs:

1. `xcodegen generate` (if `project.yml` was modified)
2. `xcodebuild -scheme ClipMemory -configuration Debug build`
3. `xcodebuild -scheme ClipMemory -configuration Debug test`

**Blocks commit** if build or test fails.

To bypass in emergencies: `git commit --no-verify` (use sparingly).

---

## Manual Verification Checklist

After any UI or lifecycle-affecting change, verify these scenarios:

| # | Scenario | What to Verify |
|---|----------|----------------|
| 1 | 设置 → 切语言 → 回到主界面 | 语言切换触发 view rebuild |
| 2 | 窗口关闭 → QuickBar 重新打开 | 窗口重建 @State 丢失问题 |
| 3 | 排除应用 sheet → 搜索 → 关闭 | Sheet 生命周期正常 |
| 4 | 字体缩放 小/中/大 各切换 | `sz()` 缓存问题 |
| 5 | 固定/取消固定 → 检查分组 | 固定项正确移动到 today |
| 6 | 删除分组 → 确认 → 检查计数 | 分组删除后计数正确更新 |
| 7 | 搜索防抖 → 快速输入 | 250ms 防抖后显示正确结果 |
| 8 | 批量选择 → 批量删除 | 多选状态正确保留 |

---

## Regression Testing

**When:**
- Bug fix → test within 72 hours
- Focus on: clipboard monitoring and encryption modules

**How:**
- Write test that covers "how this bug was triggered"
- Run full test suite: `xcodebuild -scheme ClipMemory test`

**High-risk areas:**
- `ClipboardMonitor` — thread safety, deduplication
- `CryptoService` — encryption/decryption, format migration
- `ClipboardStore` — NSCache invalidation, content deduplication

---

## Release Checklist

1. Update `project.yml` → `MARKETING_VERSION`
2. `xcodegen generate` + verify build
3. `xcodebuild -scheme ClipMemory -configuration Debug test` — all green
4. Run manual verification checklist
5. `Scripts/package.sh`
6. Update `Casks/clipmemory.rb` (version + SHA256)
7. Create GitHub Release (bilingual notes)
8. `git tag vX.Y.Z && git push --tags`

---

## Quick Commands

```bash
# Build
xcodebuild -scheme ClipMemory -configuration Debug build

# Test
xcodebuild -scheme ClipMemory -configuration Debug test

# Full rebuild
xcodegen generate && xcodebuild -scheme ClipMemory -configuration Release build

# Run app
open ~/Library/Developer/Xcode/DerivedData/ClipMemory-*/Build/Products/Debug/ClipMemory.app
```
