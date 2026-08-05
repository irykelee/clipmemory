#!/bin/bash
# Tests for Scripts/release.sh pure functions.
#
# Covers: valid_semver / version_gt / latest_tag_version / classify_commit /
# strip_commit_prefix / generate_release_notes / extract_readme_changelog /
# validate_release_notes.
#
# Run: bash Scripts/test/test_release.sh
# Exit 0 = PASS, non-zero = FAIL

set -euo pipefail

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/release.sh"

PASS=0
FAIL=0
ok()   { echo "  ✅ $*"; PASS=$((PASS + 1)); }
bad()  { echo "  ❌ $*"; FAIL=$((FAIL + 1)); }

# expect_rc <expected-rc> <description> <cmd...>
expect_rc() {
    local want="$1" desc="$2"
    shift 2
    local got=0
    "$@" >/dev/null 2>&1 || got=$?
    if [[ "$got" -eq "$want" ]]; then ok "$desc"; else bad "$desc (rc=$got, want $want)"; fi
}

echo "=== valid_semver ==="
expect_rc 0 "2.5.12 valid"        valid_semver "2.5.12"
expect_rc 1 "v2.5.12 invalid"     valid_semver "v2.5.12"
expect_rc 1 "2.5 invalid"         valid_semver "2.5"
expect_rc 1 "2.5.12.1 invalid"    valid_semver "2.5.12.1"
expect_rc 1 "2.5.12-beta invalid" valid_semver "2.5.12-beta"

echo "=== version_gt ==="
expect_rc 0 "2.5.12 > 2.5.11"   version_gt "2.5.12" "2.5.11"
expect_rc 1 "2.5.9 < 2.5.11"    version_gt "2.5.9" "2.5.11"
expect_rc 1 "equal not greater" version_gt "2.5.11" "2.5.11"
expect_rc 0 "3.0.0 > 2.9.9"     version_gt "3.0.0" "2.9.9"
expect_rc 0 "2.10.0 > 2.9.0 (numeric, not lexicographic)" version_gt "2.10.0" "2.9.0"
expect_rc 1 "garbage rejected"  version_gt "abc" "2.5.11"

echo "=== classify_commit / strip_commit_prefix ==="
[[ "$(classify_commit 'feat(ui): add Quick Bar')" == "highlights" ]] && ok "feat → highlights" || bad "feat classify"
[[ "$(classify_commit 'perf: cache formatter')" == "highlights" ]] && ok "perf → highlights" || bad "perf classify"
[[ "$(classify_commit 'fix(ocr): log on fallback')" == "fixes" ]] && ok "fix → fixes" || bad "fix classify"
[[ "$(classify_commit 'docs: update README')" == "other" ]] && ok "docs → other" || bad "docs classify"
[[ "$(strip_commit_prefix 'fix(ocr): log on fallback')" == "log on fallback" ]] && ok "strip scoped prefix" || bad "strip scoped"
[[ "$(strip_commit_prefix 'feat!: breaking')" == "breaking" ]] && ok "strip bang prefix" || bad "strip bang"

echo "=== fixture git repo for log-based functions ==="
FIXTURE="$TEST_DIR/repo"
mkdir -p "$FIXTURE"
cd "$FIXTURE"
git init -q
git config user.email test@example.com
git config user.name Test
git config commit.gpgsign false

echo one > f.txt && git add f.txt && git commit -qm "feat(ui): add Quick Bar"
echo two >> f.txt && git add f.txt && git commit -qm "fix(ocr): log on fallback"
git tag v0.1.0
git tag v0.9.9
git tag v0.10.0
echo three >> f.txt && git add f.txt && git commit -qm "feat: new shiny thing"
echo four >> f.txt && git add f.txt && git commit -qm "fix(store): crash on empty list"
echo five >> f.txt && git add f.txt && git commit -qm "chore(release): v0.1.0 — housekeeping"

echo "=== latest_tag_version ==="
LATEST=$(latest_tag_version)
[[ "$LATEST" == "0.10.0" ]] && ok "latest = 0.10.0 (zero-padded sort)" || bad "latest = '$LATEST'"

echo "=== generate_release_notes ==="
NOTES_OUT="$TEST_DIR/notes.md"
generate_release_notes "0.11.0" "0.10.0" "$NOTES_OUT"
grep -q '^## 中文' "$NOTES_OUT"    && ok "notes have ## 中文" || bad "notes missing 中文"
grep -q '^## English' "$NOTES_OUT" && ok "notes have ## English" || bad "notes missing English"
grep -q 'new shiny thing' "$NOTES_OUT" && ok "post-tag feat included" || bad "feat missing"
grep -q 'crash on empty list' "$NOTES_OUT" && ok "post-tag fix included" || bad "fix missing"
grep -q 'add Quick Bar' "$NOTES_OUT" && bad "pre-tag commit leaked" || ok "pre-tag commits excluded"
grep -q 'housekeeping' "$NOTES_OUT" && bad "release bookkeeping commit leaked" || ok "chore(release) excluded"
grep -q "发布日期 / Release Date\*\*: $(date +%F)" "$NOTES_OUT" && ok "date = today" || bad "date wrong"
grep -q 'v2.4.0 起带自动升级模块（Sparkle）的版本' "$NOTES_OUT" && ok "upgrade note = Sparkle v2.4.0 rule" || bad "upgrade note wrong"

echo "=== extract_readme_changelog ==="
# A human-polished notes file (no placeholders).
POLISHED="$TEST_DIR/polished.md"
cat > "$POLISHED" <<'EOF'
# 剪忆 ClipMemory v0.11.0 — Shiny Thing / 闪亮更新

**发布日期 / Release Date**: 2026-07-24

## 中文

### 主要更新 (Highlights)

- **✨ 闪亮更新** — 用户得到闪亮功能
- **🛡 崩溃修复** — 空列表不再崩溃

### 修复 (Fixes)

- **空列表崩溃** — 已修复

### 升级提示 (Upgrade Note)

- v0.10.0 及以上：等 App 内自动更新

## English

### Highlights

- **Shiny** — thing
EOF
CHANGELOG_OUT="$TEST_DIR/changelog.md"
extract_readme_changelog "$POLISHED" "0.11.0" "$CHANGELOG_OUT"
head -1 "$CHANGELOG_OUT" | grep -qE '^### v0\.11\.0 \([0-9]{4}-[0-9]{2}-[0-9]{2}\) — Shiny Thing$' \
    && ok "changelog heading format (pre_push_verify grep-compatible)" \
    || bad "changelog heading: $(head -1 "$CHANGELOG_OUT")"
grep -q '^### v0.11.0 (' "$CHANGELOG_OUT" && ok "matches pre_push_verify.sh A2.5 pattern" || bad "A2.5 pattern"
grep -q '完整 changelog: https://github.com/irykelee/clipmemory/releases/tag/v0.11.0' "$CHANGELOG_OUT" \
    && ok "changelog link line" || bad "link line"
# 3 bullets from 中文 section + link line; English bullets must not leak.
grep -q 'Shiny.*— thing' "$CHANGELOG_OUT" && bad "English section leaked" || ok "English section excluded"

echo "=== validate_release_notes ==="
expect_rc 0 "polished notes pass" validate_release_notes "$POLISHED" "0.11.0"
expect_rc 1 "missing file fails" validate_release_notes "$TEST_DIR/nope.md" "0.11.0"
NO_EN="$TEST_DIR/no-en.md"
grep -v '^## English' "$POLISHED" > "$NO_EN"
expect_rc 1 "missing ## English fails" validate_release_notes "$NO_EN" "0.11.0"
expect_rc 1 "draft with placeholders fails" validate_release_notes "$NOTES_OUT" "0.11.0"

echo ""
if [[ $FAIL -eq 0 ]]; then
    echo "✅ All $PASS checks passed."
    exit 0
else
    echo "❌ $FAIL of $((PASS + FAIL)) checks failed."
    exit 1
fi
