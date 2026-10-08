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
#   --tick-script PATH   override the dispatcher-tick.sh to kick (tests)
#   --state-dir DIR      override the wake state dir (default below; tests)
#   --window-seconds N   coalesce window in seconds (default 15)
#   -h, --help           print this usage and exit 0
#
# Input: ONE raw HTTP delivery (request line + headers + blank line + body)
# on stdin. The receiver opens NO socket — a loopback listener/tunnel
# (Tailscale, SSH, a self-hosted runner, a test harness) is the operator's
# transport. Because it binds nothing, it cannot bind a public interface.
#
# Config: REPO and WEBHOOK_SECRET via load_MergeMill_conf (lib-config.sh),
# the same resolution the tick uses. Unset WEBHOOK_SECRET fails closed.
#
# Exit codes: 0 accepted / coalesced / deferred / ignored (no retry needed);
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
# A not-yet-stamped lock is only stolen after this grace, so we never race a
# live holder between mkdir and its pid write; a lock whose live pid has
# outlived the max age is presumed PID reuse and stolen.
LOCK_GRACE_SECONDS="${WAKE_LOCK_GRACE_SECONDS:-5}"
LOCK_MAX_AGE_SECONDS="${WAKE_LOCK_MAX_AGE_SECONDS:-3600}"
# Cap the delivery buffered from stdin so an unbounded feed cannot exhaust
# disk/memory. Exceeding it rejects the delivery — never a partial verify.
MAX_REQUEST_BYTES="${WAKE_MAX_REQUEST_BYTES:-1048576}"
_LOCK_HELD=0
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

# require_uint <env-name> <value> — exit 5 unless value is a non-negative int.
# A bad numeric knob would otherwise abort later with an arithmetic error.
require_uint() {
  [[ "$2" =~ ^[0-9]+$ ]] || { log "$1 must be a non-negative integer (got '$2')"; exit 5; }
}
require_uint WAKE_WINDOW_SECONDS "$WINDOW_SECONDS"
require_uint WAKE_MAX_REQUEST_BYTES "$MAX_REQUEST_BYTES"
require_uint WAKE_LOCK_GRACE_SECONDS "$LOCK_GRACE_SECONDS"
require_uint WAKE_LOCK_MAX_AGE_SECONDS "$LOCK_MAX_AGE_SECONDS"

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
# _take_lock — create the lock dir and record our pid; false if it exists or
# if we cannot stamp the pid (never keep a lock we cannot later attribute).
_take_lock() {
  mkdir "$LOCK_DIR" 2>/dev/null || return 1
  if ! printf '%s\n' "$$" > "$LOCK_DIR/pid" 2>/dev/null; then
    rm -rf "$LOCK_DIR"
    return 1
  fi
  _LOCK_HELD=1
  return 0
}

# _lock_age — whole seconds since the lock dir was created, or "" if unknown.
_lock_age() {
  local mtime="" now="" age=""
  mtime="$(stat -f %m "$LOCK_DIR" 2>/dev/null || stat -c %Y "$LOCK_DIR" 2>/dev/null || echo "")"
  [[ "$mtime" =~ ^[0-9]+$ ]] || return 0
  now="$(date +%s)" || return 0
  age=$(( now - mtime ))
  (( age < 0 )) && age=0
  printf '%s\n' "$age"
}

# _lock_stale — true when the held lock may be stolen. A numeric pid that is
# gone is a dead holder; a lock with no usable pid is a holder that died
# between mkdir and the pid write (stolen only after LOCK_GRACE_SECONDS, so a
# live holder mid-create is never raced); a still-live pid whose lock has
# outlived LOCK_MAX_AGE_SECONDS is presumed PID reuse.
_lock_stale() {
  local holder="" age=""
  holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")"
  if [[ "$holder" =~ ^[0-9]+$ ]] && ! kill -0 "$holder" 2>/dev/null; then
    return 0
  fi
  age="$(_lock_age)"
  [[ "$age" =~ ^[0-9]+$ ]] || return 1
  if [[ "$holder" =~ ^[0-9]+$ ]]; then
    [[ "$age" -ge "$LOCK_MAX_AGE_SECONDS" ]] && return 0
    return 1
  fi
  [[ "$age" -ge "$LOCK_GRACE_SECONDS" ]] && return 0
  return 1
}

acquire_lock() {
  if ! _take_lock; then
    local holder=""
    holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")"
    # Steal a lock whose holder is dead (or unrecorded past the grace, or
    # presumed PID reuse), so a crashed wake cannot wedge the lane forever.
    _lock_stale || return 1
    log "stealing stale wake lock (holder=${holder:-<none>})"
    rm -rf "$LOCK_DIR"
    _take_lock || return 1
  fi
  # A follow-up is only ever requested while the lock is held, so any pending
  # present once we own the lock is orphaned (a burst that spilled past the
  # one-follow-up cap). Drop it so it cannot force an extra tick later.
  rm -f "$PENDING_FILE"
  return 0
}

release_lock() { rm -rf "$LOCK_DIR"; _LOCK_HELD=0; }

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
if ! source "${LIB_DIR}/lib-config.sh"; then
  log "cannot load lib-config.sh from ${LIB_DIR}"
  exit 5
fi
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
# Release a lock held at error-abort time (set -e unwinding past release_lock),
# plus the temp files. A receiver killed by a signal leaves its lock, which the
# stale-lock path above reclaims.
_cleanup() {
  [[ "$_LOCK_HELD" -eq 1 ]] && rm -rf "$LOCK_DIR"
  rm -f "${_REQ:-}" "${_BODY:-}"
}
trap _cleanup EXIT

# Bounded read: never buffer more than MAX_REQUEST_BYTES of delivery. One
# extra byte detects overflow so a truncated body is rejected, not verified.
if ! head -c "$(( MAX_REQUEST_BYTES + 1 ))" > "$_REQ"; then
  log "failed to read a delivery from stdin"
  exit 5
fi
if [[ "$(wc -c < "$_REQ")" -gt "$MAX_REQUEST_BYTES" ]]; then
  log "REJECT: delivery exceeds ${MAX_REQUEST_BYTES} bytes"
  exit 3
fi

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

tail -c +$(( consumed + 1 )) "$_REQ" > "$_BODY" || { log "cannot split delivery body"; exit 5; }

if [[ -z "$sig" ]]; then
  log "REJECT: missing X-Hub-Signature-256"
  exit 3
fi
if [[ "$sig" != sha256=* ]]; then
  log "REJECT: malformed X-Hub-Signature-256"
  exit 3
fi
_expected="${sig#sha256=}"
# NB: the secret reaches openssl via argv and the digests are compared with a
# plain string test. Both are fine for a same-user, loopback-only receiver;
# constant-time compare and out-of-argv key passing add moving parts without
# moving the trust boundary (the operator's own host). A failed hash is a
# rejected delivery, never a partial verify.
if ! _got="$(openssl dgst -sha256 -hmac "$WEBHOOK_SECRET" < "$_BODY" 2>/dev/null | awk '{print $NF}')"; then
  log "REJECT: could not compute the HMAC over the body"
  exit 3
fi
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
