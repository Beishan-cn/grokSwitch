#!/usr/bin/env bash
# Rebuild and relaunch GrokSwitch. Fails loudly if the old process cannot be
# stopped or the new instance does not come up (no silent "open while still running").
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/GrokSwitch.app"
BIN="$APP/Contents/MacOS/GrokSwitch"
APP_NAME="GrokSwitch"

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# PIDs of real GrokSwitch app instances only.
#
# - pgrep -x by process name (normal LaunchServices case)
# - argv0 == our binary (covers odd process-name truncation)
#
# Never substring-match the path in arbitrary command lines — agent shells,
# `awk -v bin=...`, etc. false-positive and look "unkillable".
list_pids() {
  local -a raw=()
  local p args exe

  while read -r p; do
    [[ "$p" =~ ^[0-9]+$ ]] || continue
    # Never signal this script.
    [[ "$p" == "$$" || "$p" == "$PPID" ]] && continue
    raw+=("$p")
  done < <(pgrep -x "$APP_NAME" 2>/dev/null || true)

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
    if [[ "$exe" == "$BIN" ]]; then
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
    log "No running ${APP_NAME} instance"
    return 0
  fi

  log "Stopping ${APP_NAME} (PID: $(echo "$pids" | tr '\n' ' '))"
  signal_pids TERM <<<"$pids"

  if wait_until_gone 3000; then
    log "Stopped cleanly"
    return 0
  fi

  log "Still running after SIGTERM; sending SIGKILL"
  pids="$(list_pids || true)"
  signal_pids KILL <<<"$pids"

  if wait_until_gone 2000; then
    log "Force-killed"
    return 0
  fi

  die "failed to stop ${APP_NAME} (still running: $(list_pids | tr '\n' ' '))"
}

verify_launched() {
  local timeout_ms="${1:-5000}"
  local elapsed=0
  local pids
  while (( elapsed < timeout_ms )); do
    pids="$(list_pids || true)"
    if [[ -n "${pids}" ]]; then
      log "Launched ${APP_NAME} (PID: $(echo "$pids" | tr '\n' ' '))"
      return 0
    fi
    sleep 0.1
    elapsed=$((elapsed + 100))
  done
  die "app did not start within ${timeout_ms}ms — open may have failed"
}

# --- main ---
kill_existing

"$ROOT/scripts/build.sh"

[[ -x "$BIN" ]] || die "binary missing after build: $BIN"

log "Opening ${APP}"
open "$APP"
verify_launched 5000
