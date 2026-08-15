#!/bin/bash
# 构建 DSHNotch.app —— 纯 swiftc 编译，无需 Xcode 工程
set -euo pipefail
cd "$(dirname "$0")"

APP="dist/DSHNotch.app"
ICONSET="$PWD/build/AppIcon.iconset"
ICON_RENDERER="$PWD/build/render-app-icon"
echo "==> 清理旧构建"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

echo "==> swiftc 编译（-O -swift-version 5）"
mkdir -p build/module-cache
swiftc -O -swift-version 5 \
  -module-cache-path "$PWD/build/module-cache" \
  -o "$APP/Contents/MacOS/DSHNotch" \
  Sources/main.swift

echo "==> 渲染 App 图标（概念 C：午夜蓝 + 光点环）"
rm -rf "$ICONSET"
mkdir -p "$APP/Contents/Resources" "$ICONSET"
swiftc -O -swift-version 5 \
  -module-cache-path "$PWD/build/module-cache" \
  -o "$ICON_RENDERER" \
  "$PWD/icon/render_icons.swift"
# 10 个标准尺寸（macOS iconset 命名）
for spec in \
  "icon_16x16.png 16" "icon_16x16@2x.png 32" \
  "icon_32x32.png 32" "icon_32x32@2x.png 64" \
  "icon_128x128.png 128" "icon_128x128@2x.png 256" \
  "icon_256x256.png 256" "icon_256x256@2x.png 512" \
  "icon_512x512.png 512" "icon_512x512@2x.png 1024"; do
  set -- $spec
  "$ICON_RENDERER" C "$ICONSET" "$2" >/dev/null
  mv "$ICONSET/concept-C-$2.png" "$ICONSET/$1"
done
iconutil --convert icns \
  --output "$APP/Contents/Resources/AppIcon.icns" \
  "$ICONSET"

echo "==> 写入 Info.plist"
cp Info.plist "$APP/Contents/Info.plist"

echo "==> ad-hoc 签名（Apple Silicon 必须）"
codesign --force --sign - "$APP" >/dev/null 2>&1

echo ""
echo "✅ 构建完成：$APP"
echo "   启动：open $APP"
echo "   退出：点击菜单栏图标 → 退出 DSH Notch"
