#!/bin/bash
# ProxyPulse 构建脚本
#   ./build.sh            只构建本机的 .app（开发用，快）
#   ./build.sh --package  构建通用版（arm64 + Intel）并打包成 DMG / ZIP，可拷到其他 Mac
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="ProxyPulse"
APP="${APP_NAME}.app"
BIN="${APP}/Contents/MacOS/${APP_NAME}"
BUNDLE_ID="local.proxypulse.menubar"
VERSION="1.1"
PACKAGE=0
[ "${1:-}" = "--package" ] && PACKAGE=1

echo "▸ 清理旧产物"
rm -rf "$APP" build dist
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" build dist

FLAGS=(-O -swift-version 5 -framework AppKit -framework Foundation)

if [ "$PACKAGE" = "1" ]; then
  echo "▸ 编译 arm64"
  swiftc "${FLAGS[@]}" -target arm64-apple-macos13.0 Sources/*.swift -o build/${APP_NAME}-arm64
  echo "▸ 编译 x86_64（Intel）"
  swiftc "${FLAGS[@]}" -target x86_64-apple-macos13.0 Sources/*.swift -o build/${APP_NAME}-x86_64
  echo "▸ 合并为通用二进制"
  lipo -create -output "$BIN" build/${APP_NAME}-arm64 build/${APP_NAME}-x86_64
else
  echo "▸ 编译（本机架构）"
  swiftc "${FLAGS[@]}" -target "$(uname -m)-apple-macos13.0" Sources/*.swift -o "$BIN"
fi
chmod +x "$BIN"

echo "▸ 写入 Info.plist"
cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>ProxyPulse — 本地代理链路监控</string>
</dict>
</plist>
PLIST

echo "▸ 签名（ad-hoc）"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "  (签名跳过)"
codesign --verify --verbose=2 "$APP" 2>&1 | tail -2 || true

echo "✅ 构建完成：$(pwd)/${APP}"

if [ "$PACKAGE" = "1" ]; then
  STAGE="build/dmg"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  cp docs/使用说明.txt "$STAGE/" 2>/dev/null || true

  echo "▸ 生成 DMG"
  rm -f "dist/${APP_NAME}.dmg"
  hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" \
    -fs HFS+ -format UDZO -ov "dist/${APP_NAME}.dmg"

  echo "▸ 生成 ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/${APP_NAME}.zip"

  echo "▸ 清理中间产物"
  rm -rf build
  echo
  echo "📦 可分发包："
  ls -lh dist/
  echo "   架构：$(lipo -archs "$APP/Contents/MacOS/${APP_NAME}")"
fi
