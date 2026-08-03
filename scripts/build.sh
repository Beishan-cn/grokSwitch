#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/.build"
APP_NAME="GrokSwitch"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"

# Prefer glob so new Sources/GrokSwitch/*.swift files are not missed.
# Target: Apple Silicon (arm64) macOS 14+. Intel Macs are not supported by this script.
shopt -s nullglob
SOURCES=( "$ROOT/Sources/GrokSwitch/"*.swift )
if [[ ${#SOURCES[@]} -eq 0 ]]; then
  echo "error: no Swift sources under Sources/GrokSwitch/" >&2
  exit 1
fi

echo "==> Compiling $APP_NAME (${#SOURCES[@]} sources, arm64-apple-macos14.0)"
mkdir -p "$MACOS_DIR" "$RES_DIR"

swiftc \
  -O \
  -whole-module-optimization \
  -target arm64-apple-macos14.0 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -parse-as-library \
  -o "$MACOS_DIR/$APP_NAME" \
  "${SOURCES[@]}"

cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
# Bundle menu-bar brand assets (SVG preferred; PNG fallback).
if [[ -f "$ROOT/Resources/MenuBarGrok.svg" ]]; then
  cp "$ROOT/Resources/MenuBarGrok.svg" "$RES_DIR/MenuBarGrok.svg"
fi
if [[ -f "$ROOT/Resources/MenuBarGrok.png" ]]; then
  cp "$ROOT/Resources/MenuBarGrok.png" "$RES_DIR/MenuBarGrok.png"
fi

# PkgInfo is optional but conventional
echo -n "APPL????" > "$APP_DIR/Contents/PkgInfo"

# Ad-hoc sign for local Gatekeeper friendliness (dev).
if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep -s - "$APP_DIR" 2>/dev/null || true
fi

echo "==> Built: $APP_DIR"
echo "    Run:   open \"$APP_DIR\""
echo "    Install to /Applications:"
echo "           cp -R \"$APP_DIR\" /Applications/"
