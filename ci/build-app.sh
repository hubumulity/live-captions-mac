#!/usr/bin/env bash
# 在 macOS 上把 SwiftPM 可执行文件打包为可直接运行的 LiveCaptions.app（Apple Silicon, macOS 15+）。
# 用法：ci/build-app.sh            （在仓库根目录执行）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/LiveCaptions"
DIST="$ROOT/dist"
APP="$DIST/LiveCaptions.app"
ARCH="${ARCH:-arm64}"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${GITHUB_RUN_NUMBER:-1}"

echo "==> swift build (release, $ARCH)"
cd "$PKG"
swift build -c release --arch "$ARCH" 2>&1 | tee "$ROOT/build.log"
BIN="$(swift build -c release --arch "$ARCH" --show-bin-path)/LiveCaptions"
test -x "$BIN"

echo "==> assemble bundle"
rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LiveCaptions"
cp "$PKG/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"

echo "==> codesign (ad-hoc, hardened runtime off so TCC prompts work without a Developer ID)"
# 不使用 App Sandbox entitlements：ad-hoc 签名 + 沙盒在部分系统上会导致启动即被终止。
# 麦克风 / 屏幕录制权限由 Info.plist 的用途说明 + 系统 TCC 弹窗负责。
codesign --force --deep --sign - --identifier "com.hubumulity.LiveCaptions" "$APP"
codesign --verify --verbose=2 "$APP"

echo "==> zip"
ZIP="$DIST/LiveCaptions-macOS15-$ARCH.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> done"
find "$APP" -type f
ls -la "$DIST"
file "$APP/Contents/MacOS/LiveCaptions"
