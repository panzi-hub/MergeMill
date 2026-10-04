#!/bin/bash
# test-state-manager-macos-portability.sh — issue #23 regression guard
#
# state-manager.sh (reachable via the tracked `hooks` symlink) must work on
# stock macOS: BSD `date` (no `-d`) and bash 3.2 (no `mapfile` builtin).
#
# Two defects are pinned here:
#   1. check_action's BSD `date` fallback omitted `-u`, parsing the UTC stamp
#      written by mark_action as LOCAL time. At TZ=UTC+8 the age is inflated
#      by 28800 s, so a just-written mark is rm'd and the push stays blocked.
#   2. mark_action used `mapfile`, absent in bash 3.2 — `mark` died before
#      writing any state.
#
# The test drives the REAL hook against a scratch git repo and an isolated
# CLAUDE_PROJECT_DIR, emulating macOS with a BSD-`date` PATH shim + a `gdate`
# shim that exits 127, and emulating bash 3.2 with `enable -n mapfile`.
#
# Run: bash tests/unit/test-state-manager-macos-portability.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STATE_MANAGER="$PROJECT_ROOT/skills/MergeMill-common/hooks/state-manager.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}PASS${NC}: $1"; ((PASS++)); }
bad()  { echo -e "  ${RED}FAIL${NC}: $1"; ((FAIL++)); }

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
WORK="$(mktemp -d)"
SHIM="$(mktemp -d)"
REPO="$WORK/repo"
PROJ="$WORK/proj"           # isolated CLAUDE_PROJECT_DIR -> isolated state dir
REAL_DATE="$(command -v date)"
STATE_FILE="$PROJ/.agents/state/pr-review.json"

cleanup() { rm -rf "$WORK" "$SHIM"; }
trap cleanup EXIT

mkdir -p "$PROJ"
git init -q "$REPO"
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name test
echo a > "$REPO/a.txt"
git -C "$REPO" add a.txt
git -C "$REPO" commit -qm init
echo b > "$REPO/b.txt"
git -C "$REPO" add b.txt            # staged, uncommitted -> get_staged_files

# --- BSD/macOS `date` shim -------------------------------------------------
# Rejects `-d` (BSD has none); `-j -f <fmt> <str> +%s` parses LOCAL; `-u -j -f`
# parses UTC. Arithmetic delegated to the real GNU date.
cat > "$SHIM/gdate" <<'EOF'
#!/bin/sh
exit 127
EOF
cat > "$SHIM/date" <<SHIMEOF
#!/usr/bin/env bash
set -u
real="$REAL_DATE"
utc=0; fmtout=""; datestr=""; infmt=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -u) utc=1; shift ;;
    -j) shift ;;
    -d) echo "date: illegal option -- d" >&2; exit 1 ;;
    -f) infmt="\$2"; shift 2 ;;
    +*) fmtout="\$1"; shift ;;
    *)  datestr="\$1"; shift ;;
  esac
done
# Parse \$2 in zone \$1, delegating to whichever date the host really has.
emit_epoch() {
  if "\$real" -d "1970-01-01" +%s >/dev/null 2>&1; then
    TZ="\$1" "\$real" -d "\$2" "\$fmtout"
  else
    TZ="\$1" "\$real" -j -f "\${3%Z}" "\$2" "\$fmtout"
  fi
}
if [[ -n "\$datestr" ]]; then
  naive="\${datestr%Z}"
  if [[ \$utc -eq 1 ]]; then
    emit_epoch UTC "\$naive" "\$infmt"
  else
    emit_epoch "\${TZ_LOCAL:-UTC}" "\$naive" "\$infmt"
  fi
elif [[ \$utc -eq 1 ]]; then
  TZ=UTC "\$real" "\$fmtout"
else
  "\$real" "\$fmtout"
fi
SHIMEOF
chmod +x "$SHIM/date" "$SHIM/gdate"

HOST_TZ="Asia/Shanghai"   # UTC+8, the reported failing host

reset_state() { rm -rf "$PROJ/.agents"; }

echo ""
echo "=== TC-SMP-001..002: no-mapfile path (bash 3.2 emulation) ==="
echo ""

reset_state
# `enable -n mapfile` disables the builtin -> calling it fails, exactly as on
# bash 3.2. Source with positional args so the hook's dispatch sees `mark`.
( cd "$REPO" && CLAUDE_PROJECT_DIR="$PROJ" \
    bash -c 'enable -n mapfile; source "$1" mark code-simplifier' _ "$STATE_MANAGER" ) \
    >/dev/null 2>&1
rc=$?
if [[ $rc -eq 0 ]]; then
  ok "TC-SMP-001 mark succeeds with mapfile builtin disabled (rc=0)"
else
  bad "TC-SMP-001 mark with mapfile disabled expected rc=0, got rc=$rc"
fi
if [[ -f "$PROJ/.agents/state/code-simplifier.json" ]] \
     && grep -q 'b.txt' "$PROJ/.agents/state/code-simplifier.json"; then
  ok "TC-SMP-001 staged file list recorded without mapfile"
else
  bad "TC-SMP-001 staged file list missing from state (read-loop path broken)"
fi

# Static guard: the bash-4-only builtin must not reappear. Strip comments first
# so a prose mention ("... has no mapfile") cannot mask a real invocation.
if sed 's/#.*$//' "$STATE_MANAGER" \
     | grep -qE '(^|[^A-Za-z0-9_])mapfile([^A-Za-z0-9_]|$)'; then
  bad "TC-SMP-002 hook source still invokes mapfile (bash 3.2 incompatible)"
else
  ok "TC-SMP-002 no mapfile invocation in hook source"
fi

echo ""
echo "=== TC-SMP-003..005: BSD date path at TZ=UTC+8 ==="
echo ""

# Sanity: the shim really reproduces Bug 1 (local parse is 28800 s behind UTC).
ts_fixed="2026-10-04T14:27:33Z"
loc_epoch=$(PATH="$SHIM:$PATH" TZ="$HOST_TZ" TZ_LOCAL="$HOST_TZ" \
              date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts_fixed" +%s)
utc_epoch=$(PATH="$SHIM:$PATH" TZ="$HOST_TZ" TZ_LOCAL="$HOST_TZ" \
              date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts_fixed" +%s)
if [[ $((utc_epoch - loc_epoch)) -eq 28800 ]]; then
  ok "TC-SMP-005 shim reproduces Bug 1 (UTC parse is 28800 s ahead of local)"
else
  bad "TC-SMP-005 shim sanity failed (utc-loc=$((utc_epoch - loc_epoch)), want 28800)"
fi

reset_state
( cd "$REPO" && PATH="$SHIM:$PATH" TZ="$HOST_TZ" TZ_LOCAL="$HOST_TZ" CLAUDE_PROJECT_DIR="$PROJ" \
    bash "$STATE_MANAGER" mark pr-review ) >/dev/null 2>&1
mark_rc=$?
if [[ $mark_rc -eq 0 && -f "$STATE_FILE" ]]; then
  ok "TC-SMP-003 mark pr-review under BSD date shim (rc=0, state written)"
else
  bad "TC-SMP-003 mark pr-review under BSD date shim expected rc=0 + state, got rc=$mark_rc"
fi

sleep 1
( cd "$REPO" && PATH="$SHIM:$PATH" TZ="$HOST_TZ" TZ_LOCAL="$HOST_TZ" CLAUDE_PROJECT_DIR="$PROJ" \
    bash "$STATE_MANAGER" check pr-review ) >/dev/null 2>&1
check_rc=$?
if [[ $check_rc -eq 0 && -f "$STATE_FILE" ]]; then
  ok "TC-SMP-004 UTC mark still valid ~1 s later at UTC+8 (no false expiry)"
else
  bad "TC-SMP-004 check pr-review falsely expired a fresh UTC mark (rc=$check_rc, state_present=$([[ -f "$STATE_FILE" ]] && echo yes || echo no))"
fi

echo ""
echo "=== TC-SMP-006: GNU/Linux behaviour unchanged ==="
echo ""

reset_state
( cd "$REPO" && CLAUDE_PROJECT_DIR="$PROJ" bash "$STATE_MANAGER" mark pr-review ) >/dev/null 2>&1
g_mark=$?
( cd "$REPO" && CLAUDE_PROJECT_DIR="$PROJ" bash "$STATE_MANAGER" check pr-review ) >/dev/null 2>&1
g_check=$?
if [[ $g_mark -eq 0 && $g_check -eq 0 ]]; then
  ok "TC-SMP-006 native date/bash mark+check pass (rc=0)"
else
  bad "TC-SMP-006 native mark+check expected 0/0, got $g_mark/$g_check"
fi

echo ""
echo "=== TC-SMP-007: gate still HEAD-bound (not weakened) ==="
echo ""

reset_state
( cd "$REPO" && CLAUDE_PROJECT_DIR="$PROJ" bash "$STATE_MANAGER" mark pr-review ) >/dev/null 2>&1
git -C "$REPO" commit -q --allow-empty -m "new head"
( cd "$REPO" && CLAUDE_PROJECT_DIR="$PROJ" bash "$STATE_MANAGER" check pr-review ) >/dev/null 2>&1
stale_rc=$?
if [[ $stale_rc -ne 0 && ! -f "$STATE_FILE" ]]; then
  ok "TC-SMP-007 pr-review mark invalidated by a new HEAD (state removed)"
else
  bad "TC-SMP-007 stale-HEAD mark expected rc!=0 + removal, got rc=$stale_rc, state_present=$([[ -f "$STATE_FILE" ]] && echo yes || echo no)"
fi

echo ""
echo "========================================"
echo -e "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "========================================"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
