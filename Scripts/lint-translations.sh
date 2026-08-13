#!/usr/bin/env bash
# Scripts/lint-translations.sh
# L18-adjacent lint: every key referenced via `string("X")` or `plural("X")` in
# ClipMemory/Services/LocalizationService.swift must exist in every *.lproj/
# Localizable.strings file. Catches: missing translations (would cause en
# fallback in non-en locales, hidden behind a single missing line).
#
# Why a local script instead of a Swift package like swiftgen / translatelint:
# - Adds zero build-time / runtime dependency.
# - Pure-grep implementation runs in <100ms on this codebase.
# - The pre-commit + ci.yml gates already exist for lint-audit-ids and
#   lint-hotkey-drift; this script follows the same shape so the user
#   sees one consistent pattern.
#
# Behavior:
# - Source of truth: keys referenced in LocalizationService.swift.
# - Strict mode: every source key MUST exist in every language .strings file.
# - Plural variants: when a source uses `plural("X.count")`, the .one suffix
#   is OPTIONAL per-language (some languages have it, some don't; plural()
#   falls back to the base form when .one is missing). Only the base key
#   is required.
#
# Exit: 0 = pass, 1 = missing key in some .strings file, 2 = bad invocation.
#
# Usage:
#   lint-translations.sh                 # default check
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCALIZATION="$REPO_ROOT/ClipMemory/Services/LocalizationService.swift"
LANGS=(en zh-Hans zh-Hant ja ko es pt)
STRINGS_DIR="$REPO_ROOT/ClipMemory"

VIOLATIONS=0

# 1. Collect source keys — both `string("X")` (single key) and `plural("X.count")`
#    (single key + optional `.one` suffix per language).
SOURCE_KEYS=$(grep -oE '(string|plural)\("[^"]+"\)' "$LOCALIZATION" \
    | grep -oE '"[^"]+"' \
    | tr -d '"' \
    | sort -u)

if [ -z "$SOURCE_KEYS" ]; then
    echo "lint-translations.sh: no keys found in $LOCALIZATION — check grep pattern" >&2
    exit 2
fi

echo "=== Translation lint (ID-LINT-0001) ==="
echo "Source: $LOCALIZATION"
echo "Keys defined: $(echo "$SOURCE_KEYS" | wc -l | tr -d ' ')"
echo

# 2. Per-language check — every source key must exist in every .strings file.
for lang in "${LANGS[@]}"; do
    strings_file="$STRINGS_DIR/$lang.lproj/Localizable.strings"
    if [ ! -f "$strings_file" ]; then
        echo "❌ $lang.lproj/Localizable.strings: FILE MISSING"
        VIOLATIONS=$((VIOLATIONS + 1))
        continue
    fi

    # Extract keys from .strings file: lines matching `"key" = ...`.
    lang_keys=$(grep -oE '^"[^"]+"' "$strings_file" | tr -d '"' | sort -u)

    # Find keys in source that are NOT in this language.
    missing=$(comm -23 <(echo "$SOURCE_KEYS") <(echo "$lang_keys"))

    if [ -n "$missing" ]; then
        count=$(echo "$missing" | wc -l | tr -d ' ')
        echo "❌ $lang: $count missing key(s):"
        while IFS= read -r key; do
            echo "   - $key"
        done <<< "$missing"
        VIOLATIONS=$((VIOLATIONS + 1))
    else
        echo "✅ $lang: all $(echo "$SOURCE_KEYS" | wc -l | tr -d ' ') keys present"
    fi
done

echo
if [ "$VIOLATIONS" -gt 0 ]; then
    echo "❌ Translation lint FAILED: $VIOLATIONS language(s) with missing keys"
    echo "Add the missing keys to each flagged .strings file. En (development"
    echo "language) is shown first; other languages typically mirror its entries."
    exit 1
fi

echo "✅ Translation lint PASS: all 7 languages in sync with LocalizationService.swift"