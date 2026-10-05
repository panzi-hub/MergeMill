#!/bin/bash
# install-gc-timer.sh — Lane-GC series PR-4: idempotent per-host timer
# installer for adt-gc.sh (design: docs/designs/lane-containment-gc.md
# §4-C5/§9 PR-4; docs/designs/lane-gc-p4-adt-gc.md; [INV-117]).
#
# One timer per HOST, not per project — adt-gc.sh itself scans every
# project's registry under ${ADT_STATE_ROOT}/MergeMill-*/lanes/ in one
# invocation, so installing this more than once per host is pointless
# (and installing it once per project would spawn N redundant GC runs
# racing on the same singleton lock).
#
# Supported host: macOS only. This installer writes a launchd user agent
#   (~/Library/LaunchAgents/com.adt.lane-gc.plist, StartInterval=600) and
#   bootstraps it into gui/<uid>. Other operating systems are not maintained
#   in this version; a later adaptation may add them. Non-macOS fails loud.
#
# Usage:
#   install-gc-timer.sh [--uninstall] [-h|--help]
#
# Exit codes: 0 success (incl. already-installed, unchanged); 1 error.

set -uo pipefail

_SELF="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
if command -v realpath >/dev/null 2>&1; then
  _REAL_SELF="$(realpath "$_SELF")"
else
  _REAL_SELF="$(readlink -f "$_SELF")"
fi
LIB_DIR="$(cd "$(dirname "$_REAL_SELF")" && pwd)"
ADT_GC_SH="${LIB_DIR}/adt-gc.sh"

LAUNCHD_LABEL="com.adt.lane-gc"
LAUNCHD_PLIST="${HOME:-}/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"

# _gct_uname — overridable seam for tests, mirrors lib-lane.sh::_lane_uname
# so a unit test can force the macOS branch on Linux CI without a runner.
_gct_uname() {
  echo "${_LANE_UNAME_OVERRIDE:-$(uname -s 2>/dev/null || echo Linux)}"
}

UNINSTALL=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --uninstall) UNINSTALL=true ;;
    -h|--help)
      echo "Usage: install-gc-timer.sh [--uninstall]" >&2
      exit 0
      ;;
    *) echo "install-gc-timer.sh: unknown argument: $1" >&2; exit 1 ;;
  esac
  shift
done

if [[ ! -f "$ADT_GC_SH" ]]; then
  echo "install-gc-timer.sh: adt-gc.sh not found at ${ADT_GC_SH} — cannot install a timer pointing at a missing script" >&2
  exit 1
fi

# [Lane-GC PR-4 review round-2, P2-4] Reject any path that would land
# unescaped inside the cron entry / plist and either break the schedule or
# be silently mis-parsed. `%` is cron's command/stdin-continuation separator
# — an unquoted `%` in a path SILENTLY TRUNCATES the command at that point
# (cron treats everything after the FIRST unescaped `%` as stdin for the
# job, not part of argv), which for `bash ${ADT_GC_SH} ...` means either a
# corrupted invocation or the wrong script running unattended every 10
# minutes. A literal newline would either terminate the crontab line
# early (splitting one entry into two, one of which cron may reject or
# silently ignore) or break `cat > "$LAUNCHD_PLIST"` on the macOS side.
# Fail LOUD naming the offending path rather than installing a broken timer.
_gct_reject_unsafe_path() {
  local path="$1" label="$2"
  # `'` is rejected alongside `%`/newline (review round-3 [P2]): the cron
  # entry single-quotes both paths, and a single quote INSIDE a
  # single-quoted shell string terminates the quoting — a path like
  # /tmp/x'root would split the cron command mid-token and let the
  # remainder parse as fresh shell words (token injection), exactly what
  # the quoting exists to prevent. Escaping ('\'' splicing) was rejected
  # in favor of rejection-with-a-loud-error: no legitimate ADT_STATE_ROOT
  # or skill-tree path contains a quote, so the added complexity would
  # only ever serve a misconfiguration.
  if [[ "$path" == *"%"* || "$path" == *"'"* || "$path" == *$'\n'* ]]; then
    echo "install-gc-timer.sh: ${label} contains '%', a single quote, or a newline — refusing to install a timer with an unsafe path: ${path}" >&2
    exit 1
  fi
}
_gct_reject_unsafe_path "$ADT_GC_SH" "adt-gc.sh path"

_gct_install_macos() {
  mkdir -p "$(dirname "$LAUNCHD_PLIST")" 2>/dev/null || true

  if [[ "$UNINSTALL" == true ]]; then
    launchctl bootout "gui/$(id -u)/${LAUNCHD_LABEL}" 2>/dev/null || true
    rm -f "$LAUNCHD_PLIST" 2>/dev/null || true
    echo "install-gc-timer.sh: removed launchd GC agent"
    return 0
  fi

  local logfile="${ADT_STATE_ROOT:-$HOME/.local/state}/adt-gc-launchd.log"
  _gct_reject_unsafe_path "$logfile" "GC log path (ADT_STATE_ROOT)"
  local bash_bin
  bash_bin="$(command -v bash)"

  cat > "$LAUNCHD_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LAUNCHD_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${bash_bin}</string>
    <string>${ADT_GC_SH}</string>
  </array>
  <key>StartInterval</key>
  <integer>600</integer>
  <key>StandardOutPath</key>
  <string>${logfile}</string>
  <key>StandardErrorPath</key>
  <string>${logfile}</string>
</dict>
</plist>
PLIST

  # bootout-then-bootstrap makes re-run idempotent (a plain re-bootstrap
  # over an already-loaded label is a no-op-with-warning on some macOS
  # versions; bootout first guarantees the fresh plist actually takes).
  launchctl bootout "gui/$(id -u)/${LAUNCHD_LABEL}" 2>/dev/null || true
  if launchctl bootstrap "gui/$(id -u)" "$LAUNCHD_PLIST" 2>/dev/null; then
    echo "install-gc-timer.sh: installed/updated launchd GC agent (every 600s): ${ADT_GC_SH}"
  else
    echo "install-gc-timer.sh: WARN — launchctl bootstrap failed; plist written to ${LAUNCHD_PLIST} but not loaded" >&2
    return 1
  fi
}

case "$(_gct_uname)" in
  Darwin) _gct_install_macos ;;
  *)
    echo "install-gc-timer.sh: macOS is the only supported host; refusing to install a timer on $(_gct_uname)" >&2
    exit 1
    ;;
esac
