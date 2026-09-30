#!/bin/bash
# test-token-refresh-daemon-resilience.sh — [INV-123] token-refresh daemon
# resilience regression tests.
#
# Pins three behaviors:
#   1. A transient refresh failure must be SURVIVED (WARNING logged, retry on
#      the next interval, token file intact). Pre-fix, `((FAIL_COUNT++))` — a
#      post-increment whose old value 0 makes the arithmetic command return
#      rc 1 under `set -euo pipefail` — killed the daemon on the FIRST
#      failure; the MAX_CONSECUTIVE_FAILURES retry ladder was unreachable
#      dead code and even the WARNING never printed.
#   2. Giving up (MAX_CONSECUTIVE_FAILURES) removes the token file: by then
#      it is guaranteed expired (MAX × interval ≫ TTL) and can only produce
#      silent 401s — consumers must fail loud on the missing file (same
#      posture as the pre-existing parent-death cleanup).
#   3. An operator TERM keeps the (still possibly fresh) token file —
#      graceful degradation until TTL, unlike the abandoned-refresh case.
#   4. Both GitHub API curl calls in gh-app-token.sh are time-bounded
#      (--connect-timeout/--max-time): a stalled connection must not wedge
#      the daemon forever (grep-pin; behavioral network tests are out of
#      scope for a hermetic suite).
#
# Harness: the daemon sources gh-app-token.sh from ITS OWN directory
# (realpath-resolved LIB_DIR), so dropping a mock gh-app-token.sh next to a
# copy of the daemon gives a clean injection seam with zero sed of the
# source line. The 60s interval clamp and MAX_CONSECUTIVE_FAILURES are
# sed-patched on the copy for test speed (same pattern as
# test-run-unit-tests.sh's SERIAL_TESTS patching).
#
# Run: bash tests/unit/test-token-refresh-daemon-resilience.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DAEMON_SRC="$PROJECT_ROOT/skills/MergeMill-dispatcher/scripts/gh-token-refresh-daemon.sh"
APP_TOKEN_SRC="$PROJECT_ROOT/skills/MergeMill-dispatcher/scripts/gh-app-token.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TMP="$(mktemp -d)"
trap '[[ -n "${DAEMON_PID:-}" ]] && kill -9 "$DAEMON_PID" 2>/dev/null; rm -rf "$TMP"' EXIT

# wait_log <log> <pattern> [tries] — poll until the pattern appears (0.25s
# granularity). Tries default bounds each scenario to ~10s.
wait_log() {
  local log="$1" pattern="$2" tries="${3:-40}" i
  for ((i = 0; i < tries; i++)); do
    grep -q "$pattern" "$log" 2>/dev/null && return 0
    sleep 0.25
  done
  return 1
}

# make_env <name> <fail_until> <max_failures>
#   fail_until: mock mint fails for mint-calls n where n>1 && (fail_until==0
#   || n<=fail_until); n==1 (the initial mint) always succeeds. fail_until=0
#   = fail forever after the initial mint.
make_env() {
  local name="$1" fail_until="$2" max_failures="$3"
  local dir="$TMP/$name"
  mkdir -p "$dir"
  sed -e 's/REFRESH_INTERVAL=60/REFRESH_INTERVAL=1/' \
      -e "s/^MAX_CONSECUTIVE_FAILURES=10\$/MAX_CONSECUTIVE_FAILURES=${max_failures}/" \
      "$DAEMON_SRC" > "$dir/gh-token-refresh-daemon.sh"
  cat > "$dir/gh-app-token.sh" <<EOF
# mock gh-app-token.sh — hermetic get_gh_app_token driven by a counter file
get_gh_app_token() {
  local n
  n=\$(cat "$dir/state" 2>/dev/null || echo 0)
  n=\$((n + 1))
  printf '%s' "\$n" > "$dir/state"
  if [[ "\$n" -gt 1 && ( "\${MOCK_FAIL_UNTIL}" == "0" || "\$n" -le "\${MOCK_FAIL_UNTIL}" ) ]]; then
    echo "mock mint failure #\$n" >&2
    return 1
  fi
  echo "mock-token-\$n"
}
EOF
  echo "$dir"
}

start_daemon() {
  local dir="$1" token_file="$2" log="$3"
  MOCK_FAIL_UNTIL="${MOCK_FAIL_UNTIL:?}" MOCK_STATE="$dir/state" \
    GH_TOKEN_REFRESH_INTERVAL=1 \
    bash "$dir/gh-token-refresh-daemon.sh" \
      "$token_file" app-id dummy.pem owner repo >"$log" 2>&1 &
  DAEMON_PID=$!
}

echo ""
echo "=== TC-TRD-001: transient refresh failure is survived (the ((x++)) regression) ==="
echo ""

DIR_A="$(make_env a 3 10)"
TOKEN_A="$TMP/a-token.file"
LOG_A="$TMP/a.log"
MOCK_FAIL_UNTIL=3 start_daemon "$DIR_A" "$TOKEN_A" "$LOG_A"

if wait_log "$LOG_A" "WARNING: Failed to refresh token"; then
  echo -e "  ${GREEN}PASS${NC}: TC-TRD-001a WARNING logged on first refresh failure (daemon survived)"
  ((PASS++))
else
  echo -e "  ${RED}FAIL${NC}: TC-TRD-001a no WARNING within bound — daemon died on first failure (the ((x++)) bug)"
  ((FAIL++))
fi

if wait_log "$LOG_A" "Token refreshed" 60; then
  echo -e "  ${GREEN}PASS${NC}: TC-TRD-001b daemon recovered and refreshed after failures"
  ((PASS++))
else
  echo -e "  ${RED}FAIL${NC}: TC-TRD-001b no successful refresh within bound"
  ((FAIL++))
fi

if [[ -f "$TOKEN_A" && "$(cat "$TOKEN_A" 2>/dev/null)" == "mock-token-4" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-TRD-001c token file holds the post-recovery mint"
  ((PASS++))
else
  echo -e "  ${RED}FAIL${NC}: TC-TRD-001c token file missing or stale (got '$(cat "$TOKEN_A" 2>/dev/null)')"
  ((FAIL++))
fi

kill -TERM "$DAEMON_PID" 2>/dev/null
wait "$DAEMON_PID" 2>/dev/null

echo ""
echo "=== TC-TRD-002: giving up removes the guaranteed-expired token file ==="
echo ""

DIR_B="$(make_env b 0 2)"
TOKEN_B="$TMP/b-token.file"
LOG_B="$TMP/b.log"
MOCK_FAIL_UNTIL=0 start_daemon "$DIR_B" "$TOKEN_B" "$LOG_B"

if wait_log "$LOG_B" "Initial token written"; then
  if [[ -f "$TOKEN_B" ]]; then
    echo -e "  ${GREEN}PASS${NC}: TC-TRD-002a initial token written"
    ((PASS++))
  else
    echo -e "  ${RED}FAIL${NC}: TC-TRD-002a initial token file missing"
    ((FAIL++))
  fi
else
  echo -e "  ${RED}FAIL${NC}: TC-TRD-002a daemon never wrote the initial token"
  ((FAIL++))
fi

wait "$DAEMON_PID" 2>/dev/null
B_RC=$?

if [[ "$B_RC" -eq 1 ]] && wait_log "$LOG_B" "FATAL: 2 consecutive refresh failures" 10; then
  echo -e "  ${GREEN}PASS${NC}: TC-TRD-002b daemon gave up via the FATAL path (rc=1)"
  ((PASS++))
else
  echo -e "  ${RED}FAIL${NC}: TC-TRD-002b expected FATAL exit rc=1, got rc=$B_RC"
  ((FAIL++))
fi

if [[ ! -e "$TOKEN_B" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-TRD-002c expired token file removed (consumers fail loud)"
  ((PASS++))
else
  echo -e "  ${RED}FAIL${NC}: TC-TRD-002c token file still present after FATAL — silent-401 trap"
  ((FAIL++))
fi

echo ""
echo "=== TC-TRD-003: operator TERM keeps a possibly-fresh token (graceful degradation) ==="
echo ""

DIR_C="$(make_env c 99 10)"
TOKEN_C="$TMP/c-token.file"
LOG_C="$TMP/c.log"
MOCK_FAIL_UNTIL=99 start_daemon "$DIR_C" "$TOKEN_C" "$LOG_C"

if wait_log "$LOG_C" "Initial token written"; then
  kill -TERM "$DAEMON_PID" 2>/dev/null
  wait "$DAEMON_PID" 2>/dev/null
  if [[ -f "$TOKEN_C" ]]; then
    echo -e "  ${GREEN}PASS${NC}: TC-TRD-003 TERM exit keeps the token file"
    ((PASS++))
  else
    echo -e "  ${RED}FAIL${NC}: TC-TRD-003 TERM removed the token file — breaks in-flight sessions"
    ((FAIL++))
  fi
else
  echo -e "  ${RED}FAIL${NC}: TC-TRD-003 daemon never wrote the initial token"
  ((FAIL++))
fi

echo ""
echo "=== TC-TRD-004: both GitHub API curls are time-bounded (grep-pin) ==="
echo ""

N_BOUND=$(grep -c -- "--connect-timeout 10 --max-time 30" "$APP_TOKEN_SRC")
N_CURL=$(grep -c 'curl -s ' "$APP_TOKEN_SRC")
if [[ "$N_BOUND" -eq 2 && "$N_CURL" -eq 2 ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-TRD-004 both curl call sites carry --connect-timeout/--max-time"
  ((PASS++))
else
  echo -e "  ${RED}FAIL${NC}: TC-TRD-004 bounded-curl count=$N_BOUND (want 2), bare 'curl -s ' count=$N_CURL (want 2)"
  ((FAIL++))
fi

echo ""
echo "========================================"
echo -e "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "========================================"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
