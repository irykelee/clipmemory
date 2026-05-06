#!/bin/bash
# ClipMemory 打包脚本
VERSION=${1:-1.0.0}
APP_NAME="ClipMemory"
PROJECT_DIR="/Users/iryke/Projects/ClipPaste"
OUTPUT_DIR="/Users/iryke/Projects/ClipMemory/Releases"

echo "开始打包 ClipMemory v${VERSION}..."

mkdir -p "${OUTPUT_DIR}"

cd "${PROJECT_DIR}"
xcodebuild -project ClipPaste.xcodeproj -scheme ClipPaste -configuration Release build -quiet

APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/ClipPaste-*/Build/Products/Release -name "ClipPaste.app" | head -1)

if [ -z "$APP_PATH" ]; then
    echo "错误: 找不到编译产物"
    exit 1
fi

cp -r "$APP_PATH" "/tmp/${APP_NAME}.app"
cd /tmp
tar -czvf "${OUTPUT_DIR}/${APP_NAME}.tar.gz" "${APP_NAME}.app"

SHA256=$(shasum -a 256 "${OUTPUT_DIR}/${APP_NAME}.tar.gz" | awk "{print \$1}")
echo "SHA256: $SHA256"

cp "${OUTPUT_DIR}/${APP_NAME}.tar.gz" ~/Projects/ClipMemory/Homebrew/

echo ""
echo "打包完成！"
echo "文件: ${OUTPUT_DIR}/${APP_NAME}.tar.gz"
echo "SHA256: $SHA256"
