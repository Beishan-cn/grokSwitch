#!/usr/bin/env bash
# Backward-compatible entrypoint: same as scripts/dev-run.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$ROOT/scripts/dev-run.sh"
