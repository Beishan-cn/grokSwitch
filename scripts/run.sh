#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/GrokSwitch.app"

# Kill previous instance if running
pkill -x GrokSwitch 2>/dev/null || true
sleep 0.2

"$ROOT/scripts/build.sh"
open "$APP"
