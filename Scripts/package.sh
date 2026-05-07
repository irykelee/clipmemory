#!/bin/bash
# ClipMemory packaging script
VERSION=${1:-1.2.0}
APP_NAME="ClipMemory"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
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
