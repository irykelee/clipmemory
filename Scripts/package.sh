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
    xcodebuild -project ClipMemory.xcodeproj -scheme ClipMemory -configuration Release build -quiet

    APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/ClipMemory-*/Build/Products/Release -name "ClipMemory.app" | head -1)

    if [ -z "$APP_PATH" ]; then
        echo "Error: Build artifact not found"
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

    # Write back SHA + version into Casks/clipmemory.rb so `brew install`
    # picks up the new build without a manual edit.
    update_cask_sha "${PROJECT_DIR}/Casks/clipmemory.rb" "${OUTPUT_DIR}/${APP_NAME}.tar.gz" "${VERSION}"

    echo ""
    echo "Packaging complete!"
    echo "File: ${OUTPUT_DIR}/${APP_NAME}.tar.gz"
    echo "SHA256: $SHA256"
fi
