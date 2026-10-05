#!/bin/bash
# test-dispatcher-step3-empty-seq.sh — regression coverage for issue #28.
#
# dispatcher-tick.sh enumerated its per-step issue lists with
# `for i in $(seq 0 $((n - 1)))`. On BSD/macOS `seq 0 -1` prints `0\n-1`
# (GNU prints nothing), so an empty list iterated twice; `jq '.[0].number'`
# on an empty array yields `null`, and `dispatch review null` aborted the
# whole tick under `set -euo pipefail` before Steps 4/5 (crash recovery).
#
# The fix replaces the `seq` enumeration with bash-native arithmetic
# enumeration (`for ((i = 0; i < n; i++))`), which runs 0 times for an empty
# list on every host. These cases are GNU-CI-safe: a `seq` PATH shim emits
# the BSD output for the exact `seq 0 -1` call, and TC-D3SEQ-007 is the stub
# control proving that shim reproduces the macOS hazard on GNU `seq`.
#
# Run: bash tests/unit/test-dispatcher-step3-empty-seq.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TICK="$PROJECT_ROOT/skills/MergeMill-dispatcher/scripts/dispatcher-tick.sh"

PASS=0
FAIL=0
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$desc"
  else
    fail "$desc -- expected='$expected' actual='$actual'"
  fi
}

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/d3seq.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

# --- BSD `seq` shim --------------------------------------------------------
# Emits the BSD/macOS output for the exact empty-boundary call; delegates
# every other invocation to the host `seq`. When SEQ_CALL_LOG is set, records
# each invocation so a case can prove the tick's loop never calls `seq`.
BSDDIR="$TMPROOT/bsdseq"
mkdir -p "$BSDDIR"
cat > "$BSDDIR/seq" <<'SHIM'
#!/bin/bash
[[ -n "${SEQ_CALL_LOG:-}" ]] && echo "seq $*" >> "$SEQ_CALL_LOG"
if [[ "${1:-}" == "0" && "${2:-}" == "-1" ]]; then
  printf '0\n-1\n'
  exit 0
fi
exec /usr/bin/seq "$@"
SHIM
chmod +x "$BSDDIR/seq"

# ===========================================================================
echo "=== TC-D3SEQ-001: dispatcher-tick.sh has no seq-based enumeration ==="
# ===========================================================================
# Pre-fix the file contains three `$(seq 0 $((<var> - 1)))` loops; post-fix
# none. This is the primary fail-before / pass-after discriminator.
# Count only NON-comment lines: explanatory comments may legitimately quote
# the retired `seq` form. A real enumeration is a non-comment line.
seq_loops="$(grep -E 'seq 0 \$\(\(.*- 1\)\)' "$TICK" 2>/dev/null | grep -vcE '^[[:space:]]*#' || true)"
assert_eq "zero 'seq 0 \$((N - 1))' enumerations remain" "0" "$seq_loops"

# ===========================================================================
echo ""
echo "=== TC-D3SEQ-002: Step 3/4/5 loops use bash-native arithmetic enumeration ==="
# ===========================================================================
for var in pr_count pd_count cand_count; do
  if grep -qF "for ((i = 0; i < ${var}; i++)); do" "$TICK"; then
    pass "Step loop enumerates '${var}' with for ((i = 0; i < ${var}; i++))"
  else
    fail "Step loop for '${var}' is not the expected bash-native for-loop"
  fi
done

# ===========================================================================
echo ""
echo "=== TC-D3SEQ-003: extract the Step 3 loop body ==="
# ===========================================================================
# Extract ONLY the for-loop (not the surrounding `(( pr_count > 0 ))` guard),
# so the case exercises the loop construct's own empty-safety. index() gives a
# literal, start-of-line match — no regex escaping of `((`/`++`.
STEP3_LOOP="$(awk 'index($0, "for ((i = 0; i < pr_count; i++)); do") == 1 { f=1 } f { print } f && /^done$/ { exit }' "$TICK")"
if [[ -n "$STEP3_LOOP" ]] && grep -q 'dispatching review for issue' <<<"$STEP3_LOOP"; then
  pass "Step 3 loop extracted and contains the review-dispatch marker ($(wc -l <<<"$STEP3_LOOP") lines)"
else
  fail "Step 3 loop extraction is empty or missing the review-dispatch marker -- the loop is not in the expected bash-native form"
fi

# Build a runner that defines every symbol the extracted loop body touches,
# records dispatch/label calls to a log, and echoes RC=0 on clean completion.
make_runner() {
  local out="$1" count="$2" list="$3"
  {
    echo '#!/bin/bash'
    echo 'set -euo pipefail'
    echo "pr_count=${count}"
    printf 'pending_review=%q\n' "$list"
    echo 'MAX_CONCURRENT=5'
    echo 'count_active() { echo 0; }'
    echo 'log() { :; }'
    echo 'acquire_dispatch_marker() { return 0; }'
    echo 'label_swap() { echo "SWAP $*" >> "$DISPATCH_LOG"; }'
    echo 'post_dispatch_token() { :; }'
    echo 'dispatch() { echo "DISPATCH $*" >> "$DISPATCH_LOG"; return 0; }'
    echo 'is_dispatch_deferred_rc() { return 1; }'
    echo 'handle_dispatch_deferred() { :; }'
    echo 'dispatch_marker_confirm_launched() { :; }'
    echo 'JUST_DISPATCHED=()'
    printf '%s\n' "$STEP3_LOOP"
    echo 'echo "RC=0"'
  } > "$out"
}

run_step3() {
  local count="$1" list="$2" log="$3"
  : > "$log"
  make_runner "$TMPROOT/runner.sh" "$count" "$list"
  DISPATCH_LOG="$log" PATH="$BSDDIR:$PATH" bash "$TMPROOT/runner.sh"
}

# ===========================================================================
echo ""
echo "=== TC-D3SEQ-004: empty pending-review -> 0 iterations, clean exit ==="
# ===========================================================================
LOG4="$TMPROOT/log4"
OUT4="$(run_step3 0 '[]' "$LOG4")"
assert_eq "empty list -> loop completes and echoes RC=0" "RC=0" "$OUT4"
assert_eq "empty list -> 0 dispatch calls" "0" "$(grep -c DISPATCH "$LOG4" || true)"
assert_eq "empty list -> 0 label swaps" "0" "$(grep -c SWAP "$LOG4" || true)"

# ===========================================================================
echo ""
echo "=== TC-D3SEQ-005: single pending-review issue dispatches exactly once ==="
# ===========================================================================
LOG5="$TMPROOT/log5"
OUT5="$(run_step3 1 '[{"number":101}]' "$LOG5")"
assert_eq "one item -> loop completes" "RC=0" "$OUT5"
assert_eq "one item -> exactly 1 dispatch" "1" "$(grep -c DISPATCH "$LOG5" || true)"
assert_eq "one item -> dispatched for issue #101" "DISPATCH review 101" "$(grep DISPATCH "$LOG5" || true)"

# ===========================================================================
echo ""
echo "=== TC-D3SEQ-006: N pending-review issues dispatch in list order ==="
# ===========================================================================
LOG6="$TMPROOT/log6"
OUT6="$(run_step3 3 '[{"number":101},{"number":102},{"number":103}]' "$LOG6")"
assert_eq "three items -> loop completes" "RC=0" "$OUT6"
assert_eq "three items -> exactly 3 dispatches" "3" "$(grep -c DISPATCH "$LOG6" || true)"
assert_eq "three items -> dispatch order preserved" "101,102,103" \
  "$(grep DISPATCH "$LOG6" | awk '{print $3}' | paste -sd, -)"

# ===========================================================================
echo ""
echo "=== TC-D3SEQ-007 (stub control): BSD shim reproduces the macOS hazard ==="
# ===========================================================================
# A synthetic UNGUARDED seq loop under the shim MUST iterate twice, proving
# the shim genuinely reproduces the BSD `seq 0 -1` behavior on GNU CI (a green
# suite cannot be an artifact of GNU seq returning empty).
HAZARD="$TMPROOT/hazard.sh"
cat > "$HAZARD" <<'EOF'
#!/bin/bash
n=0
for i in $(seq 0 -1); do n=$((n + 1)); done
echo "$n"
EOF
hazard_iters="$(PATH="$BSDDIR:$PATH" bash "$HAZARD")"
assert_eq "BSD shim: unguarded 'seq 0 -1' iterates 2 times" "2" "$hazard_iters"

# ===========================================================================
echo ""
echo "=== TC-D3SEQ-008: the tick's loop never invokes seq (platform-independent) ==="
# ===========================================================================
SEQLOG="$TMPROOT/seqcalls"
: > "$SEQLOG"
SEQ_CALL_LOG="$SEQLOG" run_step3 0 '[]' "$TMPROOT/log8a" >/dev/null
SEQ_CALL_LOG="$SEQLOG" run_step3 3 '[{"number":101},{"number":102},{"number":103}]' "$TMPROOT/log8b" >/dev/null
assert_eq "no seq invocation for empty or non-empty list" "" "$(cat "$SEQLOG")"

# ===========================================================================
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
