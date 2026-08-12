#!/usr/bin/env bash
# lint-hotkey-drift.sh — enforce hotkey description consistency across
#   code, docs, and UI labels.
#
# Why this exists: see feedback/2026-08-12-hotkey-drift-history.md.
# Multi-round Cmd+Ctrl+V ↔ ⌘⇧V churn (2026-07-16 S-3 → 2026-07-21 BUG-011
# → 2026-08-12 9384c11 → 0ddf119) showed that fixing one layer at a time
# leaves the other 5 stale. This lint enforces 3 invariants so the next
# hotkey change cannot regress docs/UI silently.
#
# Invariants:
#  1. SINGLE source of truth = HotKeyManager.swift:10 defaultConfig
#  2. README + L10n strings MUST contain the canonical symbol
#     (e.g. ⌘⇧V) and MUST NOT contain stale drift forms
#  3. L10n settings.hotkey.footer MUST mention "main window" (lang eqv)
#     and MUST NOT mention QuickBar (the hotkey opens the main window,
#     not the QuickBar — that conflation was the original S-3 bug)
#
# Usage:
#   ./Scripts/lint-hotkey-drift.sh                 # check all files
#   ./Scripts/lint-hotkey-drift.sh --staged        # check staged changes
#   ./Scripts/lint-hotkey-drift.sh --diff <base>   # check diff vs base
#
# Wired into:
#   - .git/hooks/pre-commit (after L18 lint-audit-ids)
#   - .github/workflows/ci.yml (lint-ids job, expanded)

set -euo pipefail

cd "$(git -C "$(dirname "$0")/.." rev-parse --show-toplevel)"

# ============ Config ============

HOTKEY_SOURCE="ClipMemory/Services/HotKeyManager.swift"

# 7 user-facing README files (1 root + 6 lang).
# Order matches L10N_DIRS for parallel iteration.
README_FILES=(
    "README.md"
    "docs/lang/README_EN.md"
    "docs/lang/README_JA.md"
    "docs/lang/README_KO.md"
    "docs/lang/README_ES.md"
    "docs/lang/README_PT.md"
    "docs/lang/README_ZH-HANT.md"
)

# 7 L10n directories (no fallback)
L10N_DIRS=(
    "ClipMemory/en.lproj"
    "ClipMemory/ja.lproj"
    "ClipMemory/ko.lproj"
    "ClipMemory/es.lproj"
    "ClipMemory/pt.lproj"
    "ClipMemory/zh-Hant.lproj"
    "ClipMemory/zh-Hans.lproj"
)

# "main window" translation per lang (sorted with README_FILES / L10N_DIRS)
MAIN_WINDOW_TERMS=(
    "main window"
    "メインウィンドウ"
    "메인 창"
    "ventana principal"
    "janela principal"
    "主視窗"
    "主窗口"
)

# Historical drift forms that MUST NOT appear in user-facing docs.
# Verbose form (Cmd+Shift+V) is also forbidden — symbol form is canonical.
DRIFT_FORMS=(
    "Cmd+Ctrl+V"
    "Ctrl+Cmd+V"
    "cmd+ctrl+v"
    "⌘⌃V"
    "Cmd+Shift+V"
    "Ctrl+Shift+V"
)

# ============ Parse canonical from HotKeyConfig.defaultConfig ============

parse_canonical() {
    local line
    line=$(grep -E "defaultConfig[[:space:]]*=" "$HOTKEY_SOURCE" | head -1)
    if [ -z "$line" ]; then
        echo "ERROR: no defaultConfig in $HOTKEY_SOURCE" >&2
        return 1
    fi

    # Extract modifiers (right side of `modifiers:` up to `)`)
    local mods
    mods=$(echo "$line" | sed -nE 's/.*modifiers:[[:space:]]*UInt32\((.+)\).*/\1/p')
    if [ -z "$mods" ]; then
        echo "ERROR: cannot parse modifiers from: $line" >&2
        return 1
    fi

    # Extract keyCode letter (e.g. kVK_ANSI_V → V)
    local key
    key=$(echo "$line" | sed -nE 's/.*kVK_ANSI_([[:alpha:]]).*/\1/p')
    if [ -z "$key" ]; then
        echo "ERROR: cannot parse keyCode from: $line" >&2
        return 1
    fi

    # Build symbol in user-facing order: command first, then shift/option/control.
    # Matches the convention adopted in README.md line 37 ("⌘⇧V") and the
    # pre-existing v2.8.0 docs. HIG order (control→option→shift→command) is
    # documented but the user-facing convention in this repo is cmd-first.
    local sym=""
    if echo "$mods" | grep -q "cmdKey"; then sym+="⌘"; fi
    if echo "$mods" | grep -q "shiftKey"; then sym+="⇧"; fi
    if echo "$mods" | grep -q "optionKey"; then sym+="⌥"; fi
    if echo "$mods" | grep -q "controlKey"; then sym+="⌃"; fi
    sym+="$key"

    echo "$sym"
}

# ============ Checks ============

# $1=file, $2=canonical
check_drift_forms() {
    local file="$1"
    local err=0
    for form in "${DRIFT_FORMS[@]}"; do
        if grep -nF "$form" "$file" > /dev/null 2>&1; then
            # Allow in changelog context: any markdown bullet containing
            # `- **` (the project's changelog convention). These describe
            # what was fixed in past versions and erasing them would lose
            # the historical record of the S-3 vs BUG-011 work.
            local offenders
            offenders=$(grep -nF "$form" "$file" | grep -vF -- "- **" || true)
            if [ -n "$offenders" ]; then
                echo "❌ DRIFT in $file: '$form' (stale form, must be canonical)"
                echo "$offenders" | sed 's/^/    /'
                err=1
            fi
        fi
    done
    return $err
}

# $1=file, $2=canonical
check_canonical_present() {
    local file="$1" canonical="$2"
    if [ ! -f "$file" ]; then return 0; fi
    if ! grep -qF "$canonical" "$file"; then
        echo "❌ MISSING canonical '$canonical' in $file"
        return 1
    fi
    return 0
}

# $1=lproj, $2=expected "main window" term
check_l10n_footer() {
    local lproj="$1" term="$2"
    local file="$lproj/Localizable.strings"
    if [ ! -f "$file" ]; then return 0; fi

    local footer
    footer=$(grep 'settings.hotkey.footer' "$file" | head -1)
    if [ -z "$footer" ]; then
        echo "⚠️  MISSING settings.hotkey.footer in $lproj"
        return 1
    fi

    local err=0
    if ! echo "$footer" | grep -qF "$term"; then
        echo "❌ L10n $lproj: footer doesn't mention '$term'"
        echo "    $footer"
        err=1
    fi
    if echo "$footer" | grep -iE "QuickBar|快速面板|Quick\s*Bar" > /dev/null; then
        echo "❌ L10n $lproj: footer mentions QuickBar (hotkey opens main window)"
        echo "    $footer"
        err=1
    fi
    return $err
}

# ============ Main ============

CANONICAL=$(parse_canonical)
echo "=== Hotkey drift lint ==="
echo "Source: $HOTKEY_SOURCE:10"
echo "Canonical: $CANONICAL"
echo ""

ERRORS=0

echo "--- README hotkey rows ---"
for f in "${README_FILES[@]}"; do
    if [ ! -f "$f" ]; then echo "⚠️  $f missing"; continue; fi
    if ! check_drift_forms "$f"; then ERRORS=$((ERRORS+1)); fi
    if ! check_canonical_present "$f" "$CANONICAL"; then ERRORS=$((ERRORS+1)); fi
done

echo ""
echo "--- L10n settings.hotkey.footer ---"
for i in "${!L10N_DIRS[@]}"; do
    if ! check_l10n_footer "${L10N_DIRS[$i]}" "${MAIN_WINDOW_TERMS[$i]}"; then
        ERRORS=$((ERRORS+1))
    fi
done

echo ""
if [ $ERRORS -eq 0 ]; then
    echo "✅ PASS: all hotkey descriptions consistent with canonical '$CANONICAL'"
    exit 0
else
    echo "❌ FAIL: $ERRORS drift issues found"
    exit 1
fi
