#!/bin/bash
# gh-with-token-refresh.sh — Wrapper around `gh` that reads the latest token
# from a token file before each invocation. Used by MergeMill dev/review scripts
# to keep GH_TOKEN fresh when the original token may have expired.
#
# Locating the real `gh` binary:
#   1. If `REAL_GH` is set in the environment AND points to an executable
#      file, use it directly. This is the escape hatch for installs outside
#      the minimal POSIX PATH (Homebrew, nvm, asdf, ~/bin, /snap/bin,
#      container /opt/gh, etc.) when the wrapper is spawned from a
#      non-interactive shell that didn't source rc files (cron, systemd,
#      AWS SSM, GitHub Actions, nohup). Closes #92.
#   2. Otherwise, fall back to `command -v gh` against PATH minus our own
#      directory (avoid self-recursion).
#
# This wrapper is placed earlier in PATH so Claude Code's Bash tool uses it.

# [INV-14] Use BASH_SOURCE[0] (NOT readlink -f). SELF_DIR is then used to
# strip our own dir from PATH for self-recursion avoidance — the previously
# resolved location and the symlink-source location are identical for that
# purpose, but BASH_SOURCE keeps behavior consistent under shared-install
# topology.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [[ -n "${REAL_GH:-}" && -x "$REAL_GH" ]]; then
  : # explicit override — fall through to the exec at the bottom
else
  # Search the caller's PATH first (minus this wrapper's directory). This
  # preserves hermetic PATH overrides and avoids selecting an unrelated system
  # gh ahead of an explicitly arranged PATH. Bound lookup because `command -v`
  # stats every PATH entry and can hang on a dead automount.
  CLEAN_PATH=$(echo "$PATH" | tr ':' '\n' | grep -v "^${SELF_DIR}$" | tr '\n' ':' | sed 's/:$//')
  if command -v timeout >/dev/null 2>&1; then
    REAL_GH=$(PATH="$CLEAN_PATH" timeout 5 bash -c 'command -v gh' 2>/dev/null) || REAL_GH=""
  else
    REAL_GH=$(PATH="$CLEAN_PATH" bash -c 'command -v gh' 2>/dev/null) || REAL_GH=""
  fi
  if [[ -z "${REAL_GH:-}" || ! -x "$REAL_GH" ]]; then
    echo "ERROR: Cannot find real gh binary on PATH minus ${SELF_DIR}. Set REAL_GH in MergeMill.conf to override (e.g. REAL_GH=/home/ubuntu/.linuxbrew/homebrew/bin/gh)." >&2
    exit 1
  fi
fi

# Read latest token from file if available.
# Retry briefly if the file is momentarily empty (race during daemon refresh).
# IMPORTANT: Never fall through without a token — the host `gh auth` session
# may be logged in as a different user (e.g., the repo owner), which would
# cause comments to be attributed to that user instead of the bot.
if [[ -n "${GH_TOKEN_FILE:-}" ]]; then
  for _attempt in 1 2 3; do
    if [[ -s "$GH_TOKEN_FILE" ]]; then
      export GH_TOKEN=$(cat "$GH_TOKEN_FILE")
      export GITHUB_PERSONAL_ACCESS_TOKEN="$GH_TOKEN"
      break
    fi
    sleep 1
  done
  if [[ -z "${GH_TOKEN:-}" ]]; then
    echo "ERROR: GH_TOKEN_FILE is set but token file is empty after retries: $GH_TOKEN_FILE" >&2
    exit 1
  fi
fi

exec "$REAL_GH" "$@"
