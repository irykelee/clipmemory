#!/bin/bash
# ClipMemory appcast update script (Sparkle)
#
# Sources cleanly (defines insert_appcast_item) when `source`'d from tests.
# Runs the insertion when executed directly.
#
# Usage: update_appcast.sh <appcast_path> <version> <tarball_path> <ed_signature>

set -euo pipefail

# --- Pure functions (testable) ---

# Insert a new <item> for $2 into the appcast at $1, right before </channel>.
# Idempotent: if an item for $2 already exists, this is a no-op (exit 0).
# Fails (exit 1) when the appcast has no </channel> tag instead of silently
# rewriting the file unchanged.
# Args:
#   $1 — absolute path to appcast.xml
#   $2 — version string (e.g. "2.4.0")
#   $3 — absolute path to the release tarball (for byte length)
#   $4 — EdDSA signature of the tarball (from Sparkle's sign_update)
insert_appcast_item() {
    local appcast_path="$1"
    local version="$2"
    local tarball_path="$3"
    local ed_signature="$4"

    # REL-4: a missing </channel> used to make the awk below a silent no-op
    # (pattern never matched, file rewritten unchanged, "Inserted" logged) —
    # the release workflow then pushed an appcast WITHOUT the new item.
    if ! grep -qF '</channel>' "$appcast_path"; then
        echo "ERROR: ${appcast_path} has no </channel> tag; refusing to update a malformed appcast" >&2
        return 1
    fi

    # REL-4: idempotency — re-running the release workflow (or this script)
    # for the same version must not insert a duplicate <item>; Sparkle
    # clients tolerate it but the feed grows a stale duplicate pubDate/sig.
    if grep -qF "<sparkle:version>${version}</sparkle:version>" "$appcast_path"; then
        echo "appcast already has an item for v${version}; skipping (idempotent)"
        return 0
    fi

    local length pub_date url tmp
    length=$(stat -f %z "$tarball_path")
    pub_date=$(date -R) # RFC-822, e.g. "Sat, 18 Jul 2026 08:00:00 +0800"
    url="https://github.com/irykelee/clipmemory/releases/download/v${version}/ClipMemory.tar.gz"

    # NB: the awk variable must not be named "length" — that is awk's builtin
    # (bare `length` evaluates to length($0) of the current line).
    tmp=$(mktemp)
    awk -v version="$version" -v pubdate="$pub_date" -v url="$url" -v filesize="$length" -v sig="$ed_signature" '
        /<\/channel>/ {
            print "    <item>"
            print "      <title>Version " version "</title>"
            print "      <sparkle:shortVersionString>" version "</sparkle:shortVersionString>"
            print "      <sparkle:version>" version "</sparkle:version>"
            print "      <pubDate>" pubdate "</pubDate>"
            print "      <enclosure url=\"" url "\""
            print "                 length=\"" filesize "\""
            print "                 type=\"application/octet-stream\""
            print "                 sparkle:edSignature=\"" sig "\" />"
            print "    </item>"
        }
        { print }
    ' "$appcast_path" > "$tmp"
    mv "$tmp" "$appcast_path"

    echo "Inserted appcast item for v${version} (length=${length})"
}

# --- Main body: only runs when executed, not sourced ---
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    if [ "$#" -ne 4 ]; then
        echo "Usage: $0 <appcast_path> <version> <tarball_path> <ed_signature>" >&2
        exit 1
    fi
    insert_appcast_item "$@"
fi
