#!/bin/bash
# test-dispatcher-wake.sh — hermetic unit tests for the webhook wake
# receiver (issue #35, docs/test-cases/dispatcher-webhook-wake.md).
#
# The receiver reads ONE raw HTTP delivery on stdin, verifies
# X-Hub-Signature-256, gates on repository + event, then coalesces and
# kicks dispatcher-tick.sh under its own mutual exclusion. A stub tick
# counts invocations and records a marker if two ever overlap.
#
# Run: bash tests/unit/test-dispatcher-wake.sh

set -uo pipefail

PASS=0
FAIL=0
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WAKE="$ROOT/skills/MergeMill-dispatcher/scripts/dispatcher-wake.sh"
INSTALLER="$ROOT/skills/MergeMill-dispatcher/scripts/install-dispatcher-timer.sh"

REPO="owner/repo"
SECRET="s3cret-hmac-key"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_eq() { local d="$1" e="$2" a="$3"
  if [[ "$e" == "$a" ]]; then echo -e "  ${GREEN}PASS${NC}: $d"; PASS=$((PASS+1));
  else echo -e "  ${RED}FAIL${NC}: $d (want '$e' got '$a')"; FAIL=$((FAIL+1)); fi; }
assert_ne() { local d="$1" u="$2" a="$3"
  if [[ "$u" != "$a" ]]; then echo -e "  ${GREEN}PASS${NC}: $d"; PASS=$((PASS+1));
  else echo -e "  ${RED}FAIL${NC}: $d (unexpectedly '$a')"; FAIL=$((FAIL+1)); fi; }
assert_rc() { local d="$1" e="$2" a="$3"
  if [[ "$e" == "$a" ]]; then echo -e "  ${GREEN}PASS${NC}: $d"; PASS=$((PASS+1));
  else echo -e "  ${RED}FAIL${NC}: $d (want rc=$e got rc=$a)"; FAIL=$((FAIL+1)); fi; }
assert_has() { local d="$1" n="$2" h="$3"
  if [[ "$h" == *"$n"* ]]; then echo -e "  ${GREEN}PASS${NC}: $d"; PASS=$((PASS+1));
  else echo -e "  ${RED}FAIL${NC}: $d (missing '$n')"; FAIL=$((FAIL+1)); fi; }
assert_not_has() { local d="$1" n="$2" h="$3"
  if [[ "$h" != *"$n"* ]]; then echo -e "  ${GREEN}PASS${NC}: $d"; PASS=$((PASS+1));
  else echo -e "  ${RED}FAIL${NC}: $d (unexpected '$n')"; FAIL=$((FAIL+1)); fi; }
assert_file() { local d="$1" f="$2"
  if [[ -f "$f" ]]; then echo -e "  ${GREEN}PASS${NC}: $d"; PASS=$((PASS+1));
  else echo -e "  ${RED}FAIL${NC}: $d (no $f)"; FAIL=$((FAIL+1)); fi; }

if [[ ! -f "$WAKE" ]]; then
  echo "missing receiver: $WAKE" >&2
  exit 1
fi

ALL_TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-dispatcher-wake.XXXXXX")"
trap 'rm -rf "$ALL_TMP"' EXIT

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

write_conf() { # $1 = secret value ("" => omit the key entirely)
  {
    printf 'REPO="%s"\n' "$REPO"
    printf 'PROJECT_ID="%s"\n' "test-wake"
    printf 'PROJECT_DIR="%s"\n' "$CASE_DIR"
    if [[ -n "$1" ]]; then printf 'WEBHOOK_SECRET="%s"\n' "$1"; fi
  } > "$CONF"
}

write_stub() {
  cat > "$STUB" <<'STUB'
#!/bin/bash
d="${WAKE_TEST_DIR:?}"
n=$(( $(cat "$d/count" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$d/count"
echo "$n" >> "$d/calls"
if [[ -e "$d/running" ]]; then echo "overlap @${n}" >> "$d/overlap"; fi
: > "$d/running"
# Record stdin and argv so we can prove no body/args reach the tick.
if [[ -n "$(cat)" ]]; then echo "stdin-nonempty @${n}" >> "$d/stdin_nonempty"; fi
printf '%s\n' "argv=[$*]" >> "$d/args"
# Block (only when the harness asks) so a wake can be observed mid-run.
if [[ -e "$d/want_block" && ! -e "$d/release" && ! -e "$d/started" ]]; then
  : > "$d/started"
  while [[ ! -e "$d/release" ]]; do sleep 0.05; done
fi
rm -f "$d/running"
exit 0
STUB
  chmod +x "$STUB"
}

setup_case() { # $1 = secret ("" => omit)
  CASE_DIR="$(mktemp -d "$ALL_TMP/case.XXXXXX")"
  STATE="$CASE_DIR/state"; mkdir -p "$STATE"
  D="$CASE_DIR/tick"; mkdir -p "$D"
  echo 0 > "$D/count"
  CONF="$CASE_DIR/MergeMill.conf"
  STUB="$CASE_DIR/tick-stub.sh"
  LOGF="$CASE_DIR/wake.log"; : > "$LOGF"
  write_conf "$1"
  write_stub
}

build_request() { # outfile event body sigmode(auto|none|malformed|bad) [secret]
  local out="$1" event="$2" body="$3" mode="${4:-auto}" secret="${5:-$SECRET}"
  local sig=""
  if command -v openssl >/dev/null 2>&1; then
    sig="$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$secret" | awk '{print $NF}')"
  fi
  {
    printf 'POST /wake HTTP/1.1\r\n'
    printf 'Host: 127.0.0.1\r\n'
    case "$mode" in
      auto)      printf 'X-Hub-Signature-256: sha256=%s\r\n' "$sig" ;;
      malformed) printf 'X-Hub-Signature-256: not-a-signature\r\n' ;;
      bad)       printf 'X-Hub-Signature-256: sha256=%064d\r\n' 0 ;;
      none)      : ;;
    esac
    printf 'X-GitHub-Event: %s\r\n' "$event"
    printf 'Content-Type: application/json\r\n'
    printf 'Content-Length: %d\r\n' "${#body}"
    printf '\r\n'
    printf '%s' "$body"
  } > "$out"
}

run_wake() { # $1 = request file; remaining args appended
  local req="$1"; shift
  MERGEMILL_CONF="$CONF" WAKE_STATE_DIR="$STATE" WAKE_TEST_DIR="$D" \
    bash "$WAKE" --tick-script "$STUB" "$@" < "$req" >>"$LOGF" 2>&1
}

run_wake_bg() {
  local req="$1"; shift
  MERGEMILL_CONF="$CONF" WAKE_STATE_DIR="$STATE" WAKE_TEST_DIR="$D" \
    bash "$WAKE" --tick-script "$STUB" "$@" < "$req" >>"$LOGF" 2>&1 &
  WAKE_BG_PID=$!
}

tick_count() { cat "$D/count" 2>/dev/null || echo 0; }

# JSON body builders ---------------------------------------------------------
body_issue_labeled() { printf '{"action":"labeled","repository":{"full_name":"%s"},"label":{"name":"%s"},"issue":{"number":35}}' "$1" "$2"; }
body_issue_action()  { printf '{"action":"%s","repository":{"full_name":"%s"},"label":{"name":"bug"},"issue":{"number":35}}' "$1" "$2"; }
body_pr()            { printf '{"action":"%s","repository":{"full_name":"%s"},"pull_request":{"number":7}}' "$1" "$2"; }
body_check_run()     { printf '{"action":"%s","repository":{"full_name":"%s"},"check_run":{"id":1}}' "$1" "$2"; }
body_check_suite()   { printf '{"action":"%s","repository":{"full_name":"%s"},"check_suite":{"id":1}}' "$1" "$2"; }
body_comment()       { printf '{"action":"created","repository":{"full_name":"%s"},"issue":{"number":35}}' "$1"; }
body_push()          { printf '{"repository":{"full_name":"%s"},"ref":"refs/heads/main"}' "$1"; }

# ---------------------------------------------------------------------------
# TC-WHWAKE-001..004: accepted deliveries call the stub exactly once
# ---------------------------------------------------------------------------
echo ""
echo "=== TC-WHWAKE-001..004: valid signature + allowed event => one tick ==="
run_case_expect_one() { # $1 label, $2 event, $3 body
  setup_case "$SECRET"
  build_request "$CASE_DIR/req" "$2" "$3"
  run_wake "$CASE_DIR/req"; local rc=$?
  assert_rc "$1 rc" 0 "$rc"
  assert_eq "$1 one tick" 1 "$(tick_count)"
}
run_case_expect_one "TC-WHWAKE-001 issue labeled MergeMill" "issues" "$(body_issue_labeled "$REPO" "MergeMill")"
run_case_expect_one "TC-WHWAKE-002 issue labeled pending-review" "issues" "$(body_issue_labeled "$REPO" "pending-review")"
run_case_expect_one "TC-WHWAKE-002 issue labeled pending-dev" "issues" "$(body_issue_labeled "$REPO" "pending-dev")"
run_case_expect_one "TC-WHWAKE-003 PR opened" "pull_request" "$(body_pr "opened" "$REPO")"
run_case_expect_one "TC-WHWAKE-003 PR synchronize" "pull_request" "$(body_pr "synchronize" "$REPO")"
run_case_expect_one "TC-WHWAKE-004 check_run completed" "check_run" "$(body_check_run "completed" "$REPO")"
run_case_expect_one "TC-WHWAKE-004 check_suite completed" "check_suite" "$(body_check_suite "completed" "$REPO")"

# ---------------------------------------------------------------------------
# TC-WHWAKE-010..013: signature / secret gates reject, zero ticks
# ---------------------------------------------------------------------------
echo ""
echo "=== TC-WHWAKE-010..013: bad signature/secret => zero ticks ==="
run_case_expect_zero() { # $1 label, $2 event, $3 body, $4 sigmode, $5 secret, $6 expected log (optional)
  setup_case "$5"
  build_request "$CASE_DIR/req" "$2" "$3" "$4"
  run_wake "$CASE_DIR/req"; local rc=$?
  assert_ne "$1 non-zero rc" 0 "$rc"
  assert_eq "$1 zero ticks" 0 "$(tick_count)"
  assert_has "$1 log names the rejection" "REJECT" "$(cat "$LOGF")"
  if [[ -n "${6:-}" ]]; then
    assert_has "$1 log names the reason" "$6" "$(cat "$LOGF")"
  fi
}
run_case_expect_zero "TC-WHWAKE-010 missing signature" "issues" "$(body_issue_labeled "$REPO" "MergeMill")" none "$SECRET" "missing X-Hub-Signature-256"
run_case_expect_zero "TC-WHWAKE-011 malformed signature" "issues" "$(body_issue_labeled "$REPO" "MergeMill")" malformed "$SECRET" "malformed X-Hub-Signature-256"
run_case_expect_zero "TC-WHWAKE-012 mismatched signature" "issues" "$(body_issue_labeled "$REPO" "MergeMill")" bad "$SECRET" "does not match the body"
run_case_expect_zero "TC-WHWAKE-013 secret unset (fail closed)" "issues" "$(body_issue_labeled "$REPO" "MergeMill")" auto "" "WEBHOOK_SECRET is unset"

# ---------------------------------------------------------------------------
# TC-WHWAKE-020..026: repo / event gates ignore, zero ticks
# ---------------------------------------------------------------------------
echo ""
echo "=== TC-WHWAKE-020..026: repo/event gates ignore => zero ticks ==="
run_case_expect_ignore() { # $1 label, $2 event, $3 body
  setup_case "$SECRET"
  build_request "$CASE_DIR/req" "$2" "$3" auto "$SECRET"
  run_wake "$CASE_DIR/req" || true
  assert_eq "$1 zero ticks" 0 "$(tick_count)"
}
run_case_expect_ignore "TC-WHWAKE-020 repo mismatch" "issues" "$(body_issue_labeled "evil/other" "MergeMill")"
run_case_expect_ignore "TC-WHWAKE-021 non-allowlisted label" "issues" "$(body_issue_labeled "$REPO" "bug")"
run_case_expect_ignore "TC-WHWAKE-022 issue_comment" "issue_comment" "$(body_comment "$REPO")"
run_case_expect_ignore "TC-WHWAKE-023 push event" "push" "$(body_push "$REPO")"
run_case_expect_ignore "TC-WHWAKE-024 issues edited" "issues" "$(body_issue_action "edited" "$REPO")"
run_case_expect_ignore "TC-WHWAKE-025 PR closed" "pull_request" "$(body_pr "closed" "$REPO")"
run_case_expect_ignore "TC-WHWAKE-026 check_run created" "check_run" "$(body_check_run "created" "$REPO")"

# ---------------------------------------------------------------------------
# TC-WHWAKE-030..031: coalescing window
# ---------------------------------------------------------------------------
echo ""
echo "=== TC-WHWAKE-030..031: 15s coalesce window ==="
setup_case "$SECRET"
for i in 1 2 3; do
  build_request "$CASE_DIR/req$i" "issues" "$(body_issue_labeled "$REPO" "MergeMill")"
  run_wake "$CASE_DIR/req$i" || true
done
assert_eq "TC-WHWAKE-030 three burst deliveries => one tick" 1 "$(tick_count)"
# Age the window stamp past the window to simulate 15s elapsing.
printf '%s\n' "$(( $(date +%s) - 100 ))" > "$STATE/window.stamp"
build_request "$CASE_DIR/req4" "issues" "$(body_issue_labeled "$REPO" "pending-dev")"
run_wake "$CASE_DIR/req4" || true
assert_eq "TC-WHWAKE-031 delivery after window => second tick" 2 "$(tick_count)"

# ---------------------------------------------------------------------------
# TC-WHWAKE-040..042: running tick => no concurrency, one follow-up
# ---------------------------------------------------------------------------
echo ""
echo "=== TC-WHWAKE-040..042: running tick => one follow-up, no overlap ==="
setup_case "$SECRET"
: > "$D/want_block"
build_request "$CASE_DIR/reqA" "issues" "$(body_issue_labeled "$REPO" "MergeMill")"
build_request "$CASE_DIR/reqB" "pull_request" "$(body_pr "opened" "$REPO")"
run_wake_bg "$CASE_DIR/reqA"
p1="$WAKE_BG_PID"
for _ in $(seq 1 200); do [[ -e "$D/started" ]] && break; sleep 0.05; done
assert_file "TC-WHWAKE-040 first tick started (and is blocked)" "$D/started"
assert_eq "TC-WHWAKE-040 first tick counted" 1 "$(tick_count)"
# A matching delivery arrives WHILE the first tick runs.
run_wake "$CASE_DIR/reqB"; rc2=$?
assert_rc "TC-WHWAKE-040 concurrent wake accepted (deferred)" 0 "$rc2"
assert_eq "TC-WHWAKE-040 no concurrent tick started" 1 "$(tick_count)"
assert_file "TC-WHWAKE-040 follow-up requested (pending)" "$STATE/pending"
# Let the first tick finish; the holder must run exactly one follow-up.
: > "$D/release"
wait "$p1"; rc1=$?
assert_rc "TC-WHWAKE-041 holder session exits 0" 0 "$rc1"
assert_eq "TC-WHWAKE-041 exactly one follow-up tick" 2 "$(tick_count)"
if [[ -s "$D/overlap" ]]; then
  echo -e "  ${RED}FAIL${NC}: TC-WHWAKE-042 ticks overlapped: $(cat "$D/overlap")"; FAIL=$((FAIL+1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-WHWAKE-042 no tick overlap"; PASS=$((PASS+1))
fi

# ---------------------------------------------------------------------------
# TC-WHWAKE-043..044: a crashed holder's lock is stolen (no permanent wedge)
# ---------------------------------------------------------------------------
echo ""
echo "=== TC-WHWAKE-043..044: stale wake lock is stolen => delivery still ticks ==="
# 043: lock dir with no pid file (holder died between mkdir and the pid write).
setup_case "$SECRET"
mkdir -p "$STATE/tick.lock"
build_request "$CASE_DIR/req" "issues" "$(body_issue_labeled "$REPO" "MergeMill")"
export WAKE_LOCK_GRACE_SECONDS=0
run_wake "$CASE_DIR/req"; rc=$?
unset WAKE_LOCK_GRACE_SECONDS
assert_rc "TC-WHWAKE-043 unrecorded stale lock rc" 0 "$rc"
assert_eq "TC-WHWAKE-043 stale lock stolen => one tick" 1 "$(tick_count)"
# 044: lock dir stamped with a pid that has already exited.
setup_case "$SECRET"
sleep 0.1 & dead=$!; wait "$dead" 2>/dev/null
mkdir -p "$STATE/tick.lock"
printf '%s\n' "$dead" > "$STATE/tick.lock/pid"
build_request "$CASE_DIR/req" "issues" "$(body_issue_labeled "$REPO" "MergeMill")"
run_wake "$CASE_DIR/req"; rc=$?
assert_rc "TC-WHWAKE-044 dead-holder lock rc" 0 "$rc"
assert_eq "TC-WHWAKE-044 dead-holder lock stolen => one tick" 1 "$(tick_count)"

# 045: an unrecorded lock within the grace is NOT stolen (no premature steal).
setup_case "$SECRET"
mkdir -p "$STATE/tick.lock"
build_request "$CASE_DIR/req" "issues" "$(body_issue_labeled "$REPO" "MergeMill")"
run_wake "$CASE_DIR/req"; rc=$?
assert_rc "TC-WHWAKE-045 unrecorded lock within grace rc" 0 "$rc"
assert_eq "TC-WHWAKE-045 held lock not stolen => zero ticks" 0 "$(tick_count)"
assert_file "TC-WHWAKE-045 deferred as follow-up (pending)" "$STATE/pending"
# 046: an orphaned pending file with the lock free must not force a double tick.
setup_case "$SECRET"
: > "$STATE/pending"
build_request "$CASE_DIR/req" "issues" "$(body_issue_labeled "$REPO" "MergeMill")"
run_wake "$CASE_DIR/req"; rc=$?
assert_rc "TC-WHWAKE-046 orphaned pending rc" 0 "$rc"
assert_eq "TC-WHWAKE-046 orphaned pending => exactly one tick" 1 "$(tick_count)"

# ---------------------------------------------------------------------------
# TC-WHWAKE-052: the tick receives no args and no body
# ---------------------------------------------------------------------------
echo ""
echo "=== TC-WHWAKE-052: no payload/args reach the tick ==="
setup_case "$SECRET"
build_request "$CASE_DIR/req" "issues" "$(body_issue_labeled "$REPO" "MergeMill")"
run_wake "$CASE_DIR/req" || true
assert_eq "TC-WHWAKE-052 tick got empty argv" "argv=[]" "$(cat "$D/args" 2>/dev/null)"
if [[ -s "$D/stdin_nonempty" ]]; then
  echo -e "  ${RED}FAIL${NC}: TC-WHWAKE-052 body reached tick stdin"; FAIL=$((FAIL+1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-WHWAKE-052 tick stdin stayed empty"; PASS=$((PASS+1))
fi

# ---------------------------------------------------------------------------
# TC-WHWAKE-050..051: structural — no public bind; launchd unchanged
# ---------------------------------------------------------------------------
echo ""
echo "=== TC-WHWAKE-050..051: structural invariants ==="
src="$(cat "$WAKE")"
assert_not_has "TC-WHWAKE-050 no wildcard bind" "0.0.0.0" "$src"
assert_not_has "TC-WHWAKE-050 no netcat listener" "nc -l" "$src"
assert_not_has "TC-WHWAKE-050 no socat" "socat" "$src"
assert_not_has "TC-WHWAKE-050 no --bind" "--bind" "$src"
assert_not_has "TC-WHWAKE-050 receiver never touches launchd" "launchctl" "$src"
assert_has     "TC-WHWAKE-050 receiver consumes stdin" '> "$_REQ"' "$src"
assert_has     "TC-WHWAKE-050 default tick is dispatcher-tick.sh" "dispatcher-tick.sh" "$src"

installer="$(cat "$INSTALLER")"
assert_not_has "TC-WHWAKE-051 installer still has no cron" "crontab" "$installer"
assert_has     "TC-WHWAKE-051 installer interval still 300s" "INTERVAL=300" "$installer"
assert_has     "TC-WHWAKE-051 installer still names dispatcher-tick.sh" "dispatcher-tick.sh" "$installer"

echo ""
echo "passed=$PASS failed=$FAIL"
[[ "$FAIL" -eq 0 ]]
