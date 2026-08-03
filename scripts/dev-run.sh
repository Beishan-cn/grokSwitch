#!/usr/bin/env bash
# Dev entrypoint: rebuild and relaunch GrokSwitch.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT/scripts/run.sh"
