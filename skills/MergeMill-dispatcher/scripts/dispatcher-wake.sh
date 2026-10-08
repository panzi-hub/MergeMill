#!/bin/bash
# dispatcher-wake.sh — local webhook wake for the MergeMill dispatcher (#35).
#
# A GitHub webhook delivery is a HINT that something dispatchable changed.
# This receiver verifies it, gates it, then kicks the SAME entry point a
# manual debug run uses — `dispatcher-tick.sh` — so the change is picked up
# sooner than the launchd 300 s interval. It is not a second scheduler: it
# never reads labels, never decides what to spawn, and never hands the
# webhook body to an agent. launchd stays the only clock.
#
# Usage:
#   dispatcher-wake.sh [--tick-script PATH] [--state-dir DIR]
#                      [--window-seconds N] < delivery.http
#
# Input: ONE raw HTTP delivery (request line + headers + blank line + body)
# on stdin. The receiver opens NO socket — a loopback listener/tunnel
# (Tailscale, SSH, a self-hosted runner, a test harness) is the operator's
# transport. Because it binds nothing, it cannot bind a public interface.
#
# Config: REPO and WEBHOOK_SECRET via load_MergeMill_conf (lib-config.sh),
# the same resolution the tick uses. Unset WEBHOOK_SECRET fails closed.
#
# Exit codes: 0 accepted / coalesced / deferred (no retry needed);
#             3 rejected (missing, malformed, or mismatched signature, or
#               no configured secret); 5 environment/config error.
#
# See docs/pipeline/webhook-wake.md for the operator contract.
# See docs/test-cases/dispatcher-webhook-wake.md for the test matrix.

set -euo pipefail

# Byte-counting header parsing and ASCII header folding both assume C.
export LC_ALL=C

_SELF="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
if command -v realpath >/dev/null 2>&1; then
  _REAL_SELF="$(realpath "$_SELF")"
else
  _REAL_SELF="$(readlink -f "$_SELF")"
fi
LIB_DIR="$(cd "$(dirname "$_REAL_SELF")" && pwd)"

# Default tick script is the dispatcher-tick.sh beside this receiver — the
# same file a manual `bash "$PROJECT_DIR/scripts/dispatcher-tick.sh"` resolves
# to via the project-side symlink ([INV-14]). Overridable for tests.
TICK_SCRIPT="${LIB_DIR}/dispatcher-tick.sh"
WINDOW_SECONDS="${WAKE_WINDOW_SECONDS:-15}"
STATE_DIR=""

log() { echo "[dispatcher-wake] $(date -u +%H:%M:%S) $*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tick-script)
      shift
      TICK_SCRIPT="${1:-}"
      [[ -n "$TICK_SCRIPT" ]] || { log "--tick-script requires a path"; exit 5; }
      ;;
    --state-dir)
      shift
      STATE_DIR="${1:-}"
      [[ -n "$STATE_DIR" ]] || { log "--state-dir requires a path"; exit 5; }
      ;;
    --window-seconds)
      shift
      WINDOW_SECONDS="${1:-}"
      [[ "$WINDOW_SECONDS" =~ ^[0-9]+$ ]] || { log "--window-seconds requires a non-negative integer"; exit 5; }
      ;;
    -h|--help)
      echo "Usage: dispatcher-wake.sh [--tick-script PATH] [--state-dir DIR] [--window-seconds N] < delivery.http" >&2
      exit 0
      ;;
    *)
      log "unknown argument: $1"
      exit 5
      ;;
  esac
  shift
done

if [[ -z "$STATE_DIR" ]]; then
  STATE_DIR="${WAKE_STATE_DIR:-${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}/mergemill-dispatcher-wake}"
fi
LOCK_DIR="${STATE_DIR}/tick.lock"
PENDING_FILE="${STATE_DIR}/pending"
WINDOW_FILE="${STATE_DIR}/window.stamp"

# ---------------------------------------------------------------------------
# Mutual exclusion — the receiver's own mutex for this wake. It is how "a
# tick is already running" is detected (not by parsing launchd). A dead
# holder's lock is stolen so a crashed wake cannot wedge the lane.
# ---------------------------------------------------------------------------
# _take_lock — create the lock dir and record our pid; false if it exists.
_take_lock() {
  mkdir "$LOCK_DIR" 2>/dev/null || return 1
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
  return 0
}

acquire_lock() {
  _take_lock && return 0
  local holder=""
  holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")"
  # Steal the lock only from a dead holder, so a crashed wake cannot wedge
  # the lane forever.
  if [[ "$holder" =~ ^[0-9]+$ ]] && ! kill -0 "$holder" 2>/dev/null; then
    log "stealing stale wake lock held by dead pid ${holder}"
    rm -rf "$LOCK_DIR"
    _take_lock && return 0
  fi
  return 1
}

release_lock() { rm -rf "$LOCK_DIR"; }

# window_fresh <now> — true while an accepted delivery's coalesce window is
# open, i.e. a tick has already been (or is being) run for this burst.
window_fresh() {
  local now="$1" stamp=""
  [[ -f "$WINDOW_FILE" ]] || return 1
  stamp="$(cat "$WINDOW_FILE" 2>/dev/null || echo "")" || stamp=""
  [[ "$stamp" =~ ^[0-9]+$ ]] || return 1
  (( now - stamp < WINDOW_SECONDS ))
}

# run_session — hold the lock across a tick and, at most once, a follow-up
# for any accepted delivery that arrived while the tick was running.
run_session() {
  local followups=0
  while :; do
    date +%s > "$WINDOW_FILE"
    log "kicking $(basename "$TICK_SCRIPT")"
    # Body is deliberately NOT forwarded: the tick scans GitHub for truth.
    bash "$TICK_SCRIPT" </dev/null || log "tick exited rc=$? (continuing)"
    if [[ -f "$PENDING_FILE" && "$followups" -lt 1 ]]; then
      rm -f "$PENDING_FILE"
      followups=$(( followups + 1 ))
      log "accepted delivery arrived during the run — starting exactly one follow-up"
      continue
    fi
    break
  done
}

# wake — decide, under the mutex, whether this delivery starts a tick.
wake() {
  if acquire_lock; then
    if window_fresh "$(date +%s)"; then
      release_lock
      log "coalesced into the open window (no second tick)"
      return 0
    fi
    run_session
    release_lock
    return 0
  fi
  # A live session holds the lock. Request exactly one follow-up; it runs
  # after the current tick exits.
  : > "$PENDING_FILE"
  log "a wake tick is running — one follow-up requested"
  return 0
}

# event_accepted <event> <body-file> — true only for the dispatchable set.
event_accepted() {
  local event="$1" body="$2" action="" label=""
  # Every dispatchable event is gated on .action, so read it once.
  action="$(jq -r '.action // empty' "$body" 2>/dev/null)" || action=""
  case "$event" in
    issues)
      [[ "$action" == "labeled" ]] || return 1
      label="$(jq -r '.label.name // empty' "$body" 2>/dev/null)" || label=""
      case "$label" in
        MergeMill|pending-review|pending-dev) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    pull_request)
      case "$action" in
        opened|synchronize) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    check_run|check_suite)
      [[ "$action" == "completed" ]] && return 0
      return 1
      ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
[[ -f "$TICK_SCRIPT" ]] || { log "tick script not found: ${TICK_SCRIPT}"; exit 5; }
command -v jq >/dev/null 2>&1 || { log "jq not found in PATH"; exit 5; }
command -v openssl >/dev/null 2>&1 || { log "openssl not found in PATH; cannot verify signature"; exit 5; }

# shellcheck source=lib-config.sh
source "${LIB_DIR}/lib-config.sh"
load_MergeMill_conf "${SCRIPT_DIR}" || true

if [[ -z "${WEBHOOK_SECRET:-}" ]]; then
  log "REJECT: WEBHOOK_SECRET is unset — dropping delivery (fail closed)"
  exit 3
fi
if [[ -z "${REPO:-}" ]]; then
  log "REPO is unset in MergeMill.conf; cannot gate deliveries"
  exit 5
fi

if ! mkdir -p "$STATE_DIR" 2>/dev/null; then
  log "cannot create state dir: ${STATE_DIR}"
  exit 5
fi
chmod 700 "$STATE_DIR" 2>/dev/null || true

# Slurp the whole delivery, then split headers from the exact body bytes.
# Byte offsets (not field values) are used so the HMAC covers the body
# verbatim, including a trailing newline or its absence.
_REQ="$(mktemp "${TMPDIR:-/tmp}/mergemill-wake-req.XXXXXX")"
_BODY="$(mktemp "${TMPDIR:-/tmp}/mergemill-wake-body.XXXXXX")"
trap 'rm -f "$_REQ" "$_BODY"' EXIT

cat > "$_REQ"

consumed=0
sig=""
event=""
while IFS= read -r line; do
  consumed=$(( consumed + ${#line} + 1 ))
  line="${line%$'\r'}"
  [[ -z "$line" ]] && break
  field="$(printf '%s' "${line%%:*}" | tr '[:upper:]' '[:lower:]')"
  case "$field" in
    x-hub-signature-256) sig="${line#*:}"; sig="${sig# }" ;;
    x-github-event)      event="${line#*:}"; event="${event# }" ;;
  esac
done < "$_REQ"

tail -c +$(( consumed + 1 )) "$_REQ" > "$_BODY"

if [[ -z "$sig" ]]; then
  log "REJECT: missing X-Hub-Signature-256"
  exit 3
fi
if [[ "$sig" != sha256=* ]]; then
  log "REJECT: malformed X-Hub-Signature-256"
  exit 3
fi
_expected="${sig#sha256=}"
_got="$(openssl dgst -sha256 -hmac "$WEBHOOK_SECRET" < "$_BODY" | awk '{print $NF}')"
if [[ "$_got" != "$_expected" ]]; then
  log "REJECT: X-Hub-Signature-256 does not match the body"
  exit 3
fi

_full_name="$(jq -r '.repository.full_name // empty' "$_BODY" 2>/dev/null)" || _full_name=""
if [[ "$_full_name" != "$REPO" ]]; then
  log "IGNORE: repository '${_full_name:-<none>}' is not ${REPO}"
  exit 0
fi

if ! event_accepted "$event" "$_BODY"; then
  log "IGNORE: event '${event:-<none>}' is not dispatchable"
  exit 0
fi

log "accepted: event=${event} repo=${REPO}"
wake
