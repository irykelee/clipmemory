#!/bin/bash
# ClipMemory appcast backfill — add `sparkle:minimumSystemVersion` to existing <item>s
#
# Why this exists:
#   Sparkle 2.10 made `sparkle:minimumSystemVersion` a recommended field
#   (code-review-2026-10-01 §3 + §九). `update_appcast.sh` now writes the
#   field on insert; this script backfills the existing feed so Sparkle
#   2.10+ clients see consistent minimum-version semantics across the
#   whole history.
#
# Idempotency:
#   Re-running on an already-backfilled feed is a no-op — the awk guard
#   in `in_item` mode emits the original line unchanged when the field
#   is already present. (`<sparkle:minimumSystemVersion>` appears
#   inside the buffered `<item>…</item>` block.)
#
# Args:
#   $1 — absolute path to appcast.xml
#
# Exit codes:
#   0 — success (no-op or backfill applied)
#   1 — invalid args or missing file
#
# Self-test (runs when sourced from `Scripts/test-update-appcast.sh`):
#   - writes a feed with two items, runs the backfill, asserts both
#     items carry `<sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>`
#   - runs again, asserts file byte-equal to post-backfill version
#     (idempotent re-run)

set -euo pipefail

# Pure function: takes the feed path on stdin via awk pattern, rewrites
# the file in place via a temp file. Backfills `<sparkle:minimumSystemVersion>`
# inside each `<item>` block if not already present.
#
# The min_sysver constant mirrors `MACOSX_DEPLOYMENT_TARGET` in project.yml;
# keep them in sync if the deployment target changes.
#
# Args:
#   $1 — absolute path to appcast.xml
backfill_min_sysver() {
    local appcast_path="$1"
    local min_sysver="13.0"

    if [ "$#" -ne 1 ]; then
        echo "Usage: backfill_min_sysver <appcast_path>" >&2
        return 1
    fi
    if [ ! -f "$appcast_path" ]; then
        echo "ERROR: ${appcast_path} not found" >&2
        return 1
    fi

    local tmp
    tmp=$(mktemp)
    # Buffer each <item>…</item> block; emit original lines verbatim if
    # the minimumSystemVersion field is already present (idempotency),
    # otherwise inject the field right after the <sparkle:version> line.
    awk -v min_sysver="$min_sysver" '
        /<item>/ {
            in_item = 1
            buf = $0
            has_sysver = 0
            next
        }
        in_item && /<sparkle:minimumSystemVersion>/ {
            has_sysver = 1
        }
        in_item {
            buf = buf ORS $0
            if ($0 ~ /<\/item>/) {
                if (!has_sysver) {
                    # Inject the field on a new line with 6-space indent,
                    # matching the <sparkle:version> indentation in the
                    # original block (see appcast.xml). Preserve the close
                    # tag in the replacement — sub() swaps the matched
                    # substring wholesale, so the closing tag must be
                    # re-emitted explicitly.
                    sub(/<\/sparkle:version>/,
                        "</sparkle:version>\n      <sparkle:minimumSystemVersion>" min_sysver "</sparkle:minimumSystemVersion>",
                        buf)
                }
                print buf
                in_item = 0
                buf = ""
                has_sysver = 0
            }
            next
        }
        { print }
    ' "$appcast_path" > "$tmp"
    mv "$tmp" "$appcast_path"
}

# Main body: only runs when executed, not sourced.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    backfill_min_sysver "$@"
fi