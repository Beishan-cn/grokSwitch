#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/.build"
APP_NAME="GrokSwitch"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"
SOURCES=(
  "$ROOT/Sources/GrokSwitch/Models.swift"
  "$ROOT/Sources/GrokSwitch/UsageModels.swift"
  "$ROOT/Sources/GrokSwitch/Paths.swift"
  "$ROOT/Sources/GrokSwitch/AuthReader.swift"
  "$ROOT/Sources/GrokSwitch/UsageFetcher.swift"
  "$ROOT/Sources/GrokSwitch/ShellHook.swift"
  "$ROOT/Sources/GrokSwitch/TerminalLauncher.swift"
  "$ROOT/Sources/GrokSwitch/MenuBarIcon.swift"
  "$ROOT/Sources/GrokSwitch/ProfileStore.swift"
  "$ROOT/Sources/GrokSwitch/MenuBarView.swift"
  "$ROOT/Sources/GrokSwitch/GrokSwitchApp.swift"
)

echo "==> Compiling $APP_NAME"
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

echo "==> Built: $APP_DIR"
echo "    Run:   open \"$APP_DIR\""
echo "    Install to /Applications:"
echo "           cp -R \"$APP_DIR\" /Applications/"
