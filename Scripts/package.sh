#!/bin/bash
# ClipMemory packaging script
#
# Sources cleanly (defines update_cask_sha) when `source`'d from tests.
# Runs the full build + package + Cask SHA update when executed directly.

set -euo pipefail

APP_NAME="ClipMemory"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${PROJECT_DIR}/Releases"

# --- Pure functions (testable) ---

# Read MARKETING_VERSION from project.yml
get_marketing_version() {
    awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' "${PROJECT_DIR}/project.yml"
}

# Write back the actual tarball SHA256 and version into Casks/clipmemory.rb.
# Args:
#   $1 — absolute path to the Cask .rb file
#   $2 — absolute path to the tarball whose SHA we want to embed
#   $3 — new version string (e.g. "2.2.5")
update_cask_sha() {
    local cask_path="$1"
    local tarball_path="$2"
    local new_version="$3"
    local new_sha
    new_sha=$(shasum -a 256 "$tarball_path" | awk '{print $1}')

    # macOS BSD sed in-place. Only touch the version/sha256 stanzas.
    sed -i '' -E "s|^([[:space:]]*)version \"[^\"]*\"|\1version \"${new_version}\"|" "$cask_path"
    sed -i '' -E "s|^([[:space:]]*)sha256 \"[^\"]*\"|\1sha256 \"${new_sha}\"|" "$cask_path"

    echo "Updated Cask ${cask_path}: version=${new_version}, sha256=${new_sha}"
}

# D4 (2026-07-23 ship-review): post-package self-check. Catches the v2.5.11
# class of "package succeeded but tarball / Cask / Info.plist are inconsistent"
# regressions before they reach the release workflow. Pure function so it
# can be sourced and exercised from tests.
# Args:
#   $1 — absolute path to the .app bundle inside /tmp
#   $2 — absolute path to the tarball in Releases/
#   $3 — absolute path to the reference Casks/clipmemory.rb
#   $4 — expected version string (MARKETING_VERSION)
# Returns: 0 on all checks pass; non-zero with diagnostic output otherwise.
verify_package() {
    local app_path="$1"
    local tarball_path="$2"
    local cask_path="$3"
    local expected_version="$4"
    local fails=0

    fail() { echo "  ✗ $*"; fails=$((fails + 1)); }
    ok()   { echo "  ✓ $*"; }

    echo "=== Self-check ==="

    # 1. .app bundle exists.
    if [[ -d "$app_path" ]]; then
        ok ".app bundle exists at ${app_path}"
    else
        fail ".app bundle missing at ${app_path}"
        return $fails
    fi

    # 2. Info.plist CFBundleShortVersionString matches expected.
    local info_plist="${app_path}/Contents/Info.plist"
    if [[ -f "$info_plist" ]]; then
        local bundle_version
        bundle_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$info_plist" 2>/dev/null || echo "")
        if [[ "$bundle_version" == "$expected_version" ]]; then
            ok "Info.plist CFBundleShortVersionString matches ($bundle_version)"
        else
            fail "Info.plist CFBundleShortVersionString ($bundle_version) != expected ($expected_version)"
        fi
    else
        fail "Info.plist missing at ${info_plist}"
    fi

    # 3. Tarball exists and is non-empty.
    if [[ -s "$tarball_path" ]]; then
        local tarball_size
        tarball_size=$(stat -f%z "$tarball_path" 2>/dev/null || stat -c%s "$tarball_path")
        ok "tarball exists (size=${tarball_size} bytes)"
    else
        fail "tarball missing or empty at ${tarball_path}"
        return $fails
    fi

    # 4. Local Cask is reference-only (per P0-4: the live Cask in the tap
    # repo is updated by the Release workflow, not by package.sh). The local
    # copy exists for human reference and release.sh preflight syntax checks
    # sha256 is intentionally stale by design (tar -czvf embeds gzip mtime
    # so the tarball sha differs every run, and we cannot pre-fill a sha for
    # a tarball that does not exist yet). The previous sha256/version
    # equality gate was unsatisfiable in CI — every tag push would have hung
    # on this check. Check existence + ruby syntax instead, aligned with
    # only — checks inlined in Scripts/release.sh (check_cask_template).
    if [[ -f "$cask_path" ]]; then
        if ruby -c "$cask_path" >/dev/null 2>&1; then
            ok "Local Cask present and syntactically valid (reference-only)"
        else
            fail "Local Cask ${cask_path} has Ruby syntax errors — fix before next release"
        fi
    else
        # Missing local Cask is not fatal — it is reference-only. Warn so a
        # future branch removal doesn't go unnoticed.
        echo "  ⚠ Cask ${cask_path} not found (reference-only — live Cask lives in tap repo)"
    fi

    if [[ $fails -gt 0 ]]; then
        echo ""
        echo "❌ ${fails} self-check failure(s). Do NOT push the tag — fix and re-run package.sh."
        return 1
    fi
    echo ""
    echo "✅ All self-check checks passed."
    return 0
}

# --- Main body: only runs when executed, not sourced ---
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    VERSION=${1:-$(get_marketing_version)}

    if [ -z "${VERSION}" ]; then
        echo "Error: MARKETING_VERSION not found in project.yml" >&2
        exit 1
    fi

    echo "Packaging ClipMemory v${VERSION}..."

    mkdir -p "${OUTPUT_DIR}"

    cd "${PROJECT_DIR}"
    DERIVED_DATA_PATH="${PROJECT_DIR}/.build/DerivedData"
    xcodebuild -project ClipMemory.xcodeproj -scheme ClipMemory -configuration Release \
        -derivedDataPath "${DERIVED_DATA_PATH}" build -quiet

    APP_PATH="${DERIVED_DATA_PATH}/Build/Products/Release/ClipMemory.app"

    if [ ! -d "$APP_PATH" ]; then
        echo "Error: Build artifact not found at ${APP_PATH}"
        exit 1
    fi

    rm -rf "/tmp/${APP_NAME}.app"
    mkdir -p "/tmp/${APP_NAME}.app"
    cp -r "${APP_PATH}/." "/tmp/${APP_NAME}.app/"
    cd /tmp
    tar -czvf "${OUTPUT_DIR}/${APP_NAME}.tar.gz" "${APP_NAME}.app"

    SHA256=$(shasum -a 256 "${OUTPUT_DIR}/${APP_NAME}.tar.gz" | awk "{print \$1}")
    echo "SHA256: $SHA256"

    mkdir -p "${PROJECT_DIR}/Homebrew"
    cp "${OUTPUT_DIR}/${APP_NAME}.tar.gz" "${PROJECT_DIR}/Homebrew/"

    echo ""
    echo "Packaging complete!"
    echo "File: ${OUTPUT_DIR}/${APP_NAME}.tar.gz"
    echo "SHA256: $SHA256"
    echo ""
    echo "Note: Casks/clipmemory.rb is reference-only — live Cask lives in the"
    echo "      homebrew-clipmemory tap repo and is updated by the Release workflow"
    echo "      (per docs/RELEASE_PROCESS_AUDIT_2026-07-22.md P0-4). To verify the"
    echo "      local Cask template still parses: ruby -c Casks/clipmemory.rb"

    # D4 (2026-07-23 ship-review): post-package self-check. Fail the script
    # (exit 1) if the .app / tarball / Cask / Info.plist are inconsistent.
    # Prevents the v2.5.11 class of "package silently succeeded but the
    # Release workflow then publishes a broken release" regressions.
    verify_package \
        "/tmp/${APP_NAME}.app" \
        "${OUTPUT_DIR}/${APP_NAME}.tar.gz" \
        "${PROJECT_DIR}/Casks/clipmemory.rb" \
        "${VERSION}" || exit 1
fi
