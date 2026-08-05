#!/usr/bin/env bash
# Generate a complete Retina-ready .icns from a square PNG master.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="${1:-$ROOT/Resources/AppIcon-1024.png}"
OUTPUT="${2:-$ROOT/Resources/AppIcon.icns}"

if [[ ! -f "$SOURCE" ]]; then
  echo "error: app icon source not found: $SOURCE" >&2
  exit 1
fi

SOURCE_WIDTH="$(sips -g pixelWidth "$SOURCE" 2>/dev/null | awk '/pixelWidth/{print $2}')"
SOURCE_HEIGHT="$(sips -g pixelHeight "$SOURCE" 2>/dev/null | awk '/pixelHeight/{print $2}')"
if [[ "$SOURCE_WIDTH" != "$SOURCE_HEIGHT" ]]; then
  echo "error: app icon source must be square: ${SOURCE_WIDTH}x${SOURCE_HEIGHT}" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d /tmp/grokswitch-appicon.XXXXXX)"
ICONSET="$TMP_DIR/AppIcon.iconset"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$ICONSET" "$(dirname "$OUTPUT")"

render() {
  local size="$1"
  local filename="$2"
  sips -z "$size" "$size" "$SOURCE" --out "$ICONSET/$filename" >/dev/null
}

render 16 icon_16x16.png
render 32 icon_16x16@2x.png
render 32 icon_32x32.png
render 64 icon_32x32@2x.png
render 128 icon_128x128.png
render 256 icon_128x128@2x.png
render 256 icon_256x256.png
render 512 icon_256x256@2x.png
render 512 icon_512x512.png
render 1024 icon_512x512@2x.png

iconutil -c icns "$ICONSET" -o "$OUTPUT"
echo "==> Generated complete app icon: $OUTPUT"
