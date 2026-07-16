#!/bin/bash
# ClipMemory packaging script
# Default VERSION is read from MARKETING_VERSION in project.yml to avoid the
# pre-v2.2.4 footgun of packaging a stale-stamped tarball when invoked
# without an explicit argument. Pass a version as $1 to override (e.g.
# ./Scripts/package.sh 2.2.4).
set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULT_VERSION=$(awk -F'"' '/^[ \t]*MARKETING_VERSION:[ \t]*"/ {print $2; exit}' "${PROJECT_DIR}/project.yml")

if [ -z "${DEFAULT_VERSION}" ]; then
    echo "Error: could not read MARKETING_VERSION from ${PROJECT_DIR}/project.yml" >&2
    exit 1
fi

VERSION=${1:-${DEFAULT_VERSION}}
APP_NAME="ClipMemory"
OUTPUT_DIR="${PROJECT_DIR}/Releases"

echo "Packaging ClipMemory v${VERSION}..."

mkdir -p "${OUTPUT_DIR}"

cd "${PROJECT_DIR}"
xcodebuild -project ClipMemory.xcodeproj -scheme ClipMemory -configuration Release build -quiet

APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/ClipMemory-*/Build/Products/Release -name "ClipMemory.app" | head -1)

if [ -z "$APP_PATH" ]; then
    echo "Error: Build artifact not found"
    exit 1
fi

cp -r "$APP_PATH" "/tmp/${APP_NAME}.app"
cd /tmp
tar -czvf "${OUTPUT_DIR}/${APP_NAME}.tar.gz" "${APP_NAME}.app"

SHA256=$(shasum -a 256 "${OUTPUT_DIR}/${APP_NAME}.tar.gz" | awk "{print \$1}")
echo "SHA256: $SHA256"

cp "${OUTPUT_DIR}/${APP_NAME}.tar.gz" "${PROJECT_DIR}/Homebrew/"

echo ""
echo "Packaging complete!"
echo "File: ${OUTPUT_DIR}/${APP_NAME}.tar.gz"
echo "SHA256: $SHA256"
