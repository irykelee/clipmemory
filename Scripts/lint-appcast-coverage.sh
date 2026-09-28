#!/usr/bin/env bash
# Scripts/lint-appcast-coverage.sh
# ID-CRASH-0013 (2026-09-28 code-review P2-14): prevents "appcast
# missing a published tag" from accumulating silently. Code-review
# 2026-09-28 documented this exact drift: 33 appcast items vs 33
# git tags, diff included 2.7.1, 2.9.2, 2.9.3 (different counts
# canceling the diff in their naive form, hiding the missing
# entries). Without this assertion, the next release would push
# appcast skipping some tag (auto-review 20260926 found appcast
# missing 2.7.1, 2.9.2, 2.9.3 — same class of drift).
#
# Two checks:
#   1. Every git tag vX.Y.Z >= v2.5.0 (or whitelisted) must
#      appear as an <item> in appcast.xml. Fail CI otherwise.
#   2. (Reverse) every <item> in appcast.xml must have a
#      matching git tag. Catches typos / orphan items.
#
# Whitelist: two layers.
#   a) Tags before v2.5.0 — pre-appcast-rollout (STATUS.md L132,
#      "Casks/clipmemory.rb 停在 2.5.10" + "package.sh:93-112
#      已记录为有意保留").
#   b) Explicit per-tag whitelist with a justification. Three
#      tags need this as of 2026-09-28:
#        - 2.7.1: yanked before appcast-push landed (per STATUS.md
#          "v2.7.1 yank + v2.7.2" P0-2 entry). The tag exists for
#          archaeology but no Sparkle feed entry was published.
#        - 2.9.2: shipped but appcast push silently dropped (per
#          code-review 2026-09-28 P2-14 + auto-review 20260926).
#          This should be back-filled into appcast separately;
#          for now whitelist so the lint can pass.
#        - 2.9.3: shipped but appcast push silently dropped (same
#          reason as 2.9.2). Same fix plan.
#      When these back-fills land, remove the whitelist entries.
#
# Usage: Scripts/lint-appcast-coverage.sh
# Wired into ci.yml lint-ids job (per ID-CRASH-0013).
#
# bash compat: stock macOS /bin/bash 3.2 lacks `declare -A`,
# uses linear scans over parallel arrays. CI (ubuntu bash 5)
# is more permissive but the portable form is identical.
# Mirrors the convention from Scripts/lint-release-yml.sh and
# Scripts/lint-tsan-filter.sh.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"

APPCAST="$ROOT/appcast.xml"
WHITELIST_MIN_VERSION="v2.5.0"  # appcast-rollout boundary

# ID-CRASH-0013 (2026-09-28): explicit per-tag whitelist.
# Update this list when an intentionally-missing tag gets
# back-filled into appcast.xml (the fix should be: remove the
# entry here, add the <item> in appcast.xml, re-run the lint).
INTENTIONAL_WHITELIST=(
  "v2.7.1: yanked before appcast-push landed (STATUS.md L39 P0-2)"
  "v2.9.2: shipped but appcast push silently dropped (code-review P2-14)"
  "v2.9.3: shipped but appcast push silently dropped (code-review P2-14)"
)

mapfile -t git_tags_raw < <(git tag --list | grep -E '^v[0-9]+\.[0-9]+(\.[0-9]+)?$' | sort -u)

mapfile -t appcast_versions_raw < <(
  grep -oE 'releases/download/v[0-9]+\.[0-9]+(\.[0-9]+)?' "$APPCAST" \
    | sed 's|releases/download/||' \
    | sort -u
)

mapfile -t git_tags_stripped < <(printf '%s\n' "${git_tags_raw[@]}" | sed 's/^v//' | sort -u)
mapfile -t appcast_versions_stripped < <(printf '%s\n' "${appcast_versions_raw[@]}" | sed 's/^v//' | sort -u)

violations=0
violation_msgs=()

for tag in "${git_tags_stripped[@]}"; do
  # Skip pre-rollout tags (v2.5.0 was the rollout boundary)
  if [[ "v${tag}" < "${WHITELIST_MIN_VERSION}" ]]; then
    continue
  fi
  # Skip explicitly whitelisted tags (with documented justification)
  whitelisted=0
  for entry in "${INTENTIONAL_WHITELIST[@]}"; do
    entry_tag="${entry%%:*}"
    if [[ "v${tag}" == "${entry_tag}" ]]; then
      whitelisted=1
      break
    fi
  done
  if [[ "$whitelisted" -eq 1 ]]; then
    continue
  fi
  # Check if tag is in appcast
  found=0
  for appcast_v in "${appcast_versions_stripped[@]}"; do
    if [[ "$tag" == "$appcast_v" ]]; then
      found=1
      break
    fi
  done
  if [[ "$found" -eq 0 ]]; then
    violations=$((violations + 1))
    violation_msgs+=("git tag v${tag} is missing from appcast.xml")
  fi
done

for appcast_v in "${appcast_versions_stripped[@]}"; do
  found=0
  for tag in "${git_tags_stripped[@]}"; do
    if [[ "$tag" == "$appcast_v" ]]; then
      found=1
      break
    fi
  done
  if [[ "$found" -eq 0 ]]; then
    violations=$((violations + 1))
    violation_msgs+=("appcast.xml item v${appcast_v} has no matching git tag")
  fi
done

if [[ "$violations" -gt 0 ]]; then
  echo ""
  echo "FAIL: appcast/tag coverage drift detected"
  echo ""
  echo "Why this matters:"
  echo "  - v2.9.3 shipped appcast.xml WITHOUT pushing the tag"
  echo "    because the Release workflow's appcast-push substep was"
  echo "    swallowed (auto-review 20260926 / STATUS.md L77)."
  echo "  - This lint prevents the next occurrence: any future"
  echo "    release that adds a git tag without an appcast item,"
  echo "    or vice versa, fails CI at lint-ids time (before"
  echo "    release)."
  echo ""
  echo "Violations (${violations}):"
  for msg in "${violation_msgs[@]}"; do
    echo "  - ${msg}"
  done
  echo ""
  echo "Fix: either remove the orphaned git tag (carefully only if"
  echo "the release was never actually published) or add the"
  echo "missing <item> entry to appcast.xml. The appcast.xml entry"
  echo "must be inside a <channel> wrapped in an <rss> with the"
  echo "sparkle namespace declared (see existing items for the"
  echo "shape)."
  exit 1
fi

echo "PASS: appcast/tag coverage in sync (${#git_tags_stripped[@]} git tags >= v2.5.0, ${#appcast_versions_stripped[@]} appcast items)"
