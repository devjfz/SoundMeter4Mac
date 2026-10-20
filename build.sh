#!/bin/bash
# 构建 AudioCatcher.app（无需 Xcode 工程，直接用 swiftc 组装 bundle）
set -euo pipefail
cd "$(dirname "$0")"

APP="build/AudioCatcher.app"
ARCH="$(uname -m)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Sources/Info.plist "$APP/Contents/Info.plist"
cp Sources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

swiftc -parse-as-library -O \
  -target "${ARCH}-apple-macos13.0" \
  -o "$APP/Contents/MacOS/AudioCatcher" \
  Sources/*.swift

# 麦克风权限依赖稳定的代码签名标识，ad-hoc 签名即可。
codesign --force --sign - "$APP"

echo "构建完成：$APP"
echo "运行：open $APP"
