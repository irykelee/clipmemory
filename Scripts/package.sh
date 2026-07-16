#!/bin/bash
# ClipMemory packaging script
APP_NAME="ClipMemory"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=${1:-$(awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' "${PROJECT_DIR}/project.yml")}
OUTPUT_DIR="${PROJECT_DIR}/Releases"

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

echo ""
echo "Packaging complete!"
echo "File: ${OUTPUT_DIR}/${APP_NAME}.tar.gz"
echo "SHA256: $SHA256"
