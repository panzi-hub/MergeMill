#!/bin/bash
# install-dispatcher-timer.sh — the only supported dispatcher clock.
#
# Installs one macOS launchd user agent that runs dispatcher-tick.sh every
# 300 seconds. Cron and OpenClaw are not clocks for this pipeline; this
# script has no fallback. A non-macOS host fails loud.
#
# Usage:
#   install-dispatcher-timer.sh [--tick-script PATH] [--uninstall]
#
# --tick-script defaults to the dispatcher-tick.sh beside this installer.
# Point it at the live checkout when installing from a temporary worktree.
#
# Exit codes: 0 success; 1 error or unsupported platform.

set -euo pipefail

_SELF="${BASH_SOURCE[0]:-$0}"
if command -v realpath >/dev/null 2>&1; then
  _REAL_SELF="$(realpath "$_SELF")"
else
  _REAL_SELF="$(readlink -f "$_SELF")"
fi
LIB_DIR="$(cd "$(dirname "$_REAL_SELF")" && pwd)"

LABEL="com.mergemill.dispatcher"
INTERVAL=300
UNINSTALL=false
TICK_SCRIPT="${LIB_DIR}/dispatcher-tick.sh"

_dispatch_uname() {
  echo "${_DISPATCH_UNAME_OVERRIDE:-$(uname -s 2>/dev/null || echo unknown)}"
}

_xml_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  printf '%s' "$s"
}

_reject_unsafe_path() {
  local path="$1" label="$2"
  if [[ "$path" == *"%"* || "$path" == *"'"* || "$path" == *$'\n'* || "$path" == *"&"* || "$path" == *"<"* || "$path" == *">"* ]]; then
    echo "install-dispatcher-timer.sh: ${label} contains an unsafe character — refusing to install: ${path}" >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --uninstall) UNINSTALL=true ;;
    --tick-script)
      shift
      TICK_SCRIPT="${1:-}"
      if [[ -z "$TICK_SCRIPT" ]]; then
        echo "install-dispatcher-timer.sh: --tick-script requires a path" >&2
        exit 1
      fi
      ;;
    -h|--help)
      echo "Usage: install-dispatcher-timer.sh [--tick-script PATH] [--uninstall]" >&2
      exit 0
      ;;
    *)
      echo "install-dispatcher-timer.sh: unknown argument: $1" >&2
      exit 1
      ;;
  esac
  shift
done

if [[ "$(_dispatch_uname)" != "Darwin" ]]; then
  echo "install-dispatcher-timer.sh: dispatcher clock is launchd-only; refusing to install cron or any other scheduler on $(_dispatch_uname)" >&2
  exit 1
fi

if [[ -z "${HOME:-}" ]]; then
  echo "install-dispatcher-timer.sh: HOME is unset" >&2
  exit 1
fi

PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"

if [[ "$UNINSTALL" == true ]]; then
  launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
  rm -f "$PLIST"
  echo "install-dispatcher-timer.sh: removed launchd dispatcher agent"
  exit 0
fi

if [[ ! -f "$TICK_SCRIPT" ]]; then
  echo "install-dispatcher-timer.sh: dispatcher-tick.sh not found at ${TICK_SCRIPT}" >&2
  exit 1
fi
if command -v realpath >/dev/null 2>&1; then
  TICK_SCRIPT="$(realpath "$TICK_SCRIPT")"
else
  TICK_SCRIPT="$(readlink -f "$TICK_SCRIPT")"
fi
_reject_unsafe_path "$TICK_SCRIPT" "dispatcher-tick.sh path"

TICK_DIR="$(cd "$(dirname "$TICK_SCRIPT")" && pwd)"
case "$TICK_DIR" in
  */skills/MergeMill-dispatcher/scripts)
    WORK_DIR="$(cd "${TICK_DIR}/../../.." && pwd)"
    ;;
  *)
    echo "install-dispatcher-timer.sh: tick script is not inside skills/MergeMill-dispatcher/scripts: ${TICK_SCRIPT}" >&2
    exit 1
    ;;
esac
_reject_unsafe_path "$WORK_DIR" "working directory"

LOG_DIR="${HOME}/.local/state"
LOG_FILE="${LOG_DIR}/mergemill-dispatcher-launchd.log"
_reject_unsafe_path "$LOG_FILE" "log path"
mkdir -p "$LOG_DIR" "$(dirname "$PLIST")"

BASH_BIN="$(command -v bash)"
_reject_unsafe_path "$BASH_BIN" "bash path"

PATH_XML="$(_xml_escape "${PATH:-/usr/bin:/bin}")"
HOME_XML="$(_xml_escape "$HOME")"
TICK_XML="$(_xml_escape "$TICK_SCRIPT")"
BASH_XML="$(_xml_escape "$BASH_BIN")"
WORK_XML="$(_xml_escape "$WORK_DIR")"
LOG_XML="$(_xml_escape "$LOG_FILE")"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>WorkingDirectory</key>
  <string>${WORK_XML}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${BASH_XML}</string>
    <string>${TICK_XML}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>${HOME_XML}</string>
    <key>PATH</key>
    <string>${PATH_XML}</string>
  </dict>
  <key>StartInterval</key>
  <integer>${INTERVAL}</integer>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>${LOG_XML}</string>
  <key>StandardErrorPath</key>
  <string>${LOG_XML}</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
if ! launchctl bootstrap "gui/$(id -u)" "$PLIST"; then
  echo "install-dispatcher-timer.sh: launchctl bootstrap failed; plist written to ${PLIST} but not loaded" >&2
  exit 1
fi
echo "install-dispatcher-timer.sh: installed launchd dispatcher agent (every ${INTERVAL}s): ${TICK_SCRIPT}"
