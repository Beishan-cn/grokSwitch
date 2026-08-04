#!/usr/bin/env bash
# Fast dev rebuild + relaunch loop (Cutboard-style).
#
# Builds with swiftc into a stable .build path, installs in-place to
# /Applications, then re-signs with a stable identity + entitlements so
# Automation / TCC grants survive rebuilds (no rm -rf of the live bundle).
#
# Usage:
#   ./scripts/dev-run.sh
#   LANG=C LC_ALL=C ./scripts/dev-run.sh   # safer when backgrounded (bash 3.2)
#
# Optional env:
#   BUILD_DIR                      override local build directory
#   GROKSWITCH_CODESIGN_IDENTITY   force a codesign identity
set -euo pipefail

# Avoid macOS bash 3.2 "unbound variable" quirks under non-C locales.
export LANG="${LANG:-C}"
export LC_ALL="${LC_ALL:-C}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/.build}"
APP_NAME="GrokSwitch"
PROCESS_NAME="GrokSwitch"
BUILT_APP="$BUILD_DIR/$APP_NAME.app"
INSTALLED_APP="/Applications/$APP_NAME.app"
BUILT_BIN="$BUILT_APP/Contents/MacOS/$APP_NAME"
INSTALLED_BIN="$INSTALLED_APP/Contents/MacOS/$APP_NAME"
APP_ENTITLEMENTS="$ROOT_DIR/Resources/GrokSwitch.entitlements"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

choose_sign_identity() {
  if [[ -n "${GROKSWITCH_CODESIGN_IDENTITY:-}" ]]; then
    printf '%s\n' "$GROKSWITCH_CODESIGN_IDENTITY"
    return
  fi

  local identities identity
  identities="$(security find-identity -p codesigning -v 2>/dev/null || true)"

  # Prefer a *stable* identity so Automation / TCC grants survive rebuilds.
  # Ad-hoc ("-") changes CDHash every install → prior grants stop matching.
  local pattern
  for pattern in \
    'Apple Development' \
    'GrokSwitch Local Development' \
    'Equity Local Development' \
    'Developer ID Application' \
    'Mac Developer'
  do
    identity="$(printf '%s\n' "$identities" | awk -F'"' -v p="$pattern" 'index($2, p) { print $2; exit }')"
    if [[ -n "$identity" ]]; then
      printf '%s\n' "$identity"
      return
    fi
  done

  # Any remaining valid identity is better than ad-hoc for TCC stability.
  identity="$(printf '%s\n' "$identities" | awk -F'"' '/^[[:space:]]*[0-9]+\)/{ print $2; exit }')"
  if [[ -n "$identity" ]]; then
    printf '%s\n' "$identity"
  else
    printf '%s\n' "-"
  fi
}

# PIDs of real GrokSwitch app instances only.
#
# - pgrep -x by process name (normal LaunchServices case)
# - argv0 == our binary (covers .build or /Applications paths)
#
# Never substring-match the path in arbitrary command lines — agent shells,
# `awk -v bin=...`, etc. false-positive and look "unkillable".
list_pids() {
  local -a raw=()
  local p args exe

  while read -r p; do
    [[ "$p" =~ ^[0-9]+$ ]] || continue
    [[ "$p" == "$$" || "$p" == "$PPID" ]] && continue
    raw+=("$p")
  done < <(pgrep -x "$PROCESS_NAME" 2>/dev/null || true)

  while IFS= read -r line; do
    [[ -n "${line:-}" ]] || continue
    p="${line#"${line%%[![:space:]]*}"}"  # ltrim
    p="${p%% *}"
    [[ "$p" =~ ^[0-9]+$ ]] || continue
    [[ "$p" == "$$" || "$p" == "$PPID" ]] && continue
    args="${line#"${line%%[![:space:]]*}"}"
    args="${args#"$p"}"
    args="${args#"${args%%[![:space:]]*}"}"
    exe="${args%% *}"
    if [[ "$exe" == "$BUILT_BIN" || "$exe" == "$INSTALLED_BIN" ]]; then
      raw+=("$p")
    fi
  done < <(ps -ax -o pid=,args= 2>/dev/null || true)

  if ((${#raw[@]} == 0)); then
    return 0
  fi
  printf '%s\n' "${raw[@]}" | sort -u
}

wait_until_gone() {
  local timeout_ms="${1:-3000}"
  local elapsed=0
  while (( elapsed < timeout_ms )); do
    if [[ -z "$(list_pids)" ]]; then
      return 0
    fi
    sleep 0.1
    elapsed=$((elapsed + 100))
  done
  return 1
}

signal_pids() {
  local sig="$1"
  local p
  while read -r p; do
    [[ "$p" =~ ^[0-9]+$ ]] || continue
    [[ "$p" == "$$" || "$p" == "$PPID" ]] && continue
    kill "-$sig" "$p" 2>/dev/null || true
  done
}

kill_existing() {
  local pids
  pids="$(list_pids || true)"
  if [[ -z "${pids}" ]]; then
    echo "▶︎ No running ${PROCESS_NAME} instance"
    return 0
  fi

  echo "▶︎ Quitting running ${PROCESS_NAME} (PID: $(echo "$pids" | tr '\n' ' '))"
  # Prefer a clean Apple Event quit when the app is registered; fall back to signals.
  osascript -e "tell application \"${PROCESS_NAME}\" to quit" >/dev/null 2>&1 || true
  if wait_until_gone 3000; then
    echo "▶︎ Stopped cleanly"
    return 0
  fi

  pids="$(list_pids || true)"
  echo "▶︎ Still running after quit; sending SIGTERM"
  signal_pids TERM <<<"$pids"

  if wait_until_gone 3000; then
    echo "▶︎ Stopped after SIGTERM"
    return 0
  fi

  pids="$(list_pids || true)"
  echo "▶︎ Still running after SIGTERM; sending SIGKILL"
  signal_pids KILL <<<"$pids"

  if wait_until_gone 2000; then
    echo "▶︎ Force-killed"
    return 0
  fi

  echo "✗ failed to stop ${PROCESS_NAME} (still running: $(list_pids | tr '\n' ' '))" >&2
  exit 1
}

verify_launched() {
  local timeout_ms="${1:-5000}"
  local elapsed=0
  local pids
  while (( elapsed < timeout_ms )); do
    pids="$(list_pids || true)"
    if [[ -n "${pids}" ]]; then
      echo "✓ Done — running ${INSTALLED_APP} (PID: $(echo "$pids" | tr '\n' ' '))"
      return 0
    fi
    sleep 0.1
    elapsed=$((elapsed + 100))
  done
  echo "✗ app did not start within ${timeout_ms}ms — open may have failed" >&2
  exit 1
}

# --- main ---
SIGN_IDENTITY="$(choose_sign_identity)"

cd "$ROOT_DIR"

if [[ ! -f "$APP_ENTITLEMENTS" ]]; then
  echo "✗ entitlements not found: $APP_ENTITLEMENTS" >&2
  exit 1
fi

echo "▶︎ Building…"
BUILD_DIR="$BUILD_DIR" "$ROOT_DIR/scripts/build.sh"

if [[ ! -d "$BUILT_APP" ]]; then
  echo "✗ Built app not found: $BUILT_APP" >&2
  exit 1
fi
if [[ ! -x "$BUILT_BIN" ]]; then
  echo "✗ Binary missing after build: $BUILT_BIN" >&2
  exit 1
fi

kill_existing

echo "▶︎ Installing to ${INSTALLED_APP}…"
# In-place replace (no rm -rf). Deleting the bundle can break path/CDHash-bound
# TCC entries (System Settings still shows grants while the new binary is untrusted).
mkdir -p "$(dirname "$INSTALLED_APP")"
ditto "$BUILT_APP" "$INSTALLED_APP"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "⚠︎ No code-signing identity found; falling back to ad-hoc signing."
  echo "  Automation grants will NOT stick across rebuilds. Create a local cert or set GROKSWITCH_CODESIGN_IDENTITY."
else
  echo "▶︎ Using stable signing identity (TCC / Automation survives rebuilds)."
fi
echo "▶︎ Code signing with ${SIGN_IDENTITY}…"
# --timestamp=none: local/self-signed certs often cannot reach Apple timestamp servers.
codesign --force --sign "$SIGN_IDENTITY" \
  --entitlements "$APP_ENTITLEMENTS" \
  --options runtime \
  --timestamp=none \
  "$INSTALLED_APP"

echo "▶︎ Verifying signature and Hardened Runtime…"
codesign --verify --deep --strict "$INSTALLED_APP"
if ! codesign -dvv "$INSTALLED_APP" 2>&1 | grep -E 'flags=.*runtime' >/dev/null; then
  echo "✗ Hardened Runtime flag missing after signing" >&2
  exit 1
fi

echo "▶︎ Refreshing LaunchServices…"
"$LSREGISTER" -f "$INSTALLED_APP"

echo "▶︎ Launching…"
open "$INSTALLED_APP"
verify_launched 5000
