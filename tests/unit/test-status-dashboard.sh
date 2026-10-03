#!/bin/bash
# test-status-dashboard.sh — issue #12. Extends the INV-81 status.sh coverage
# (tests/unit/test-status.sh, TC-RUN-ARTIFACTS-040..051) with the fleet /
# selector / machine-readable surface added by issue #12:
#   --all, --issue <n>, --json, stale-run/PID/heartbeat diagnostics, and
#   tolerance for missing logs + corrupt agent-result.json + absent PRs.
# Test IDs: TC-STATUS-DASH-001..021 (docs/test-cases/status-dashboard.md).
#
# Strategy (same as test-status.sh): run status.sh as a subprocess with a stub
# `gh` on PATH, an isolated PID dir (MERGEMILL_PID_DIR) and run-dir base
# (MERGEMILL_RUN_DIR_BASE). The stub answers issue view / issue list / pr
# lookups from a JSON fixture. Liveness uses our own $$ (alive) or an old-mtime
# dead PID file. Portable across GNU + BSD tooling (macOS has no `date -d`, so
# mtimes are set with `touch -t`).
#
# Run: bash tests/unit/test-status-dashboard.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STATUS_SH="$PROJECT_ROOT/skills/MergeMill-dispatcher/scripts/status.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
PASS=0; FAIL=0
ok()   { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad()  { echo -e "  ${RED}FAIL${NC}: $1"; [[ -n "${2:-}" ]] && echo "      $2"; FAIL=$((FAIL + 1)); }
assert_contains()     { local d="$1" n="$2" h="$3"; [[ "$h" == *"$n"* ]] && ok "$d" || bad "$d" "expected to contain: $n"; }
assert_not_contains() { local d="$1" n="$2" h="$3"; [[ "$h" != *"$n"* ]] && ok "$d" || bad "$d" "unexpected: $n"; }
assert_eq()           { local d="$1" e="$2" a="$3"; [[ "$a" == "$e" ]] && ok "$d" || bad "$d" "expected='$e' actual='$a'"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"
PID_DIR="$TMP/piddir"; mkdir -p "$PID_DIR"
RUN_BASE="$TMP/state/MergeMill-test-proj"; mkdir -p "$RUN_BASE/runs"
EMPTY_CONF="$TMP/empty-MergeMill.conf"; : > "$EMPTY_CONF"

# ---- stub gh -------------------------------------------------------------
# Answers:
#   gh issue view N --json ...                    → $GH_FIXTURE .issue
#   gh issue list ... --json number,title,labels,comments,assignees
#                                                 → $GH_FIXTURE .issuelist (RAW
#                                                   gh shape: labels as [{name}])
#   gh api graphql ...                            → .pr reshaped to the GraphQL
#                                                   pullRequests envelope
#   gh pr list ...                                → .pr
# Records every invocation to $GH_CALLS for the read-only assertion.
cat > "$BIN/gh" <<'GH'
#!/bin/bash
echo "gh $*" >> "${GH_CALLS:-/dev/null}"
fixture="${GH_FIXTURE:-}"
q=""; want=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    api)   [[ "${args[$((i+1))]:-}" == "graphql" ]] && want="graphql" ;;
    issue) [[ "${args[$((i+1))]:-}" == "view" ]] && want="issue"
           [[ "${args[$((i+1))]:-}" == "list" ]] && want="issuelist" ;;
    pr)    [[ "${args[$((i+1))]:-}" == "list" ]] && want="pr" ;;
    -q)    q="${args[$((i+1))]:-}" ;;
  esac
done
[[ -f "$fixture" ]] || { echo ""; exit 0; }
case "$want" in
  issue)     jq -c '.issue // {}' "$fixture" ;;
  issuelist) jq -c '.issuelist // []' "$fixture" ;;
  graphql)
    jq -c '.pr // []
      | map(. + {closingIssuesReferences: {nodes: (if (.closingIssuesReferences|type)=="array" then .closingIssuesReferences else [] end)}})
      | {data:{repository:{pullRequests:{
          pageInfo:{endCursor:null,hasNextPage:false},
          nodes: . }}}}' "$fixture" ;;
  pr)
    if [[ -n "$q" ]]; then jq -c '.pr // []' "$fixture" | jq -c "$q" 2>/dev/null || echo ""
    else jq -c '.pr // []' "$fixture"; fi ;;
  *) echo "" ;;
esac
GH
chmod +x "$BIN/gh"

# write_fixture <file> <labels> <pr-json> [<issuelist-numbers-csv>]
write_fixture() {
  local f="$1" labels="$2" pr="${3:-[]}" nums="${4:-}"
  local labelarr
  labelarr="$(jq -cn --arg s "$labels" '$s | split(" ") | map(select(length>0)) | map({name:.})')"
  local issuelist='[]'
  if [[ -n "$nums" ]]; then
    issuelist="$(jq -cn --arg csv "$nums" --argjson labels "$labelarr" \
      '$csv | split(",") | map(select(length>0)) | map({number:(.|tonumber), title:("issue #"+.),
        labels:$labels, comments:[], assignees:[]})')"
  fi
  jq -cn --argjson labels "$labelarr" --argjson pr "$pr" --argjson il "$issuelist" \
    '{issue:{state:"OPEN", title:"test issue", labels:$labels}, pr:$pr, issuelist:$il}' > "$f"
}

run_status() {  # run_status [args...]
  env -u PROJECT_DIR \
  PATH="$BIN:$PATH" \
  REPO="panzi-hub/MergeMill" REPO_OWNER="zxkane" PROJECT_ID="test-proj" \
  MAX_RETRIES=3 MAX_CONCURRENT=5 \
  MERGEMILL_PID_DIR="$PID_DIR" MERGEMILL_RUN_DIR_BASE="$RUN_BASE" \
  MERGEMILL_CONF="$EMPTY_CONF" \
    bash "$STATUS_SH" "$@" 2>&1
}

DEAD_PID=999999
mk_run() {  # mk_run <run-id> <started_at> <rc-or-empty> <ended_at-or-empty> [attempt]
  local d="$RUN_BASE/runs/$1"; mkdir -p "$d"
  jq -cn --arg s "$2" --arg rc "$3" --arg e "$4" --arg at "${5:-}" \
    '{started_at:$s} + (if $rc!="" then {rc:($rc|tonumber)} else {} end)
       + (if $e!="" then {ended_at:$e} else {} end)
       + (if $at!="" then {attempt:($at|tonumber)} else {} end)' > "$d/meta.json"
}
# old_mtime <path> — portable "make this look old" (BSD touch has no -d).
old_mtime() { touch -t 202001010000 "$1" 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# TC-001: --issue <n> is identical to the positional form.
# ---------------------------------------------------------------------------
echo "== TC-001 --issue == positional =="
export GH_FIXTURE="$TMP/fx-idle.json"
write_fixture "$GH_FIXTURE" "MergeMill pending-dev" "[]"
out_pos="$(run_status 40)"
out_opt="$(run_status --issue 40)"
assert_eq "TC-001a --issue 40 output == positional 40 output" "$out_pos" "$out_opt"

# ---------------------------------------------------------------------------
# TC-002/003: --all lists the fixture's MergeMill issues; a non-listed number
# never appears.
# ---------------------------------------------------------------------------
echo "== TC-002/003 --all enumeration =="
export GH_FIXTURE="$TMP/fx-all.json"
write_fixture "$GH_FIXTURE" "MergeMill pending-review" "[]" "40,41"
out="$(run_status --all)"
assert_contains "TC-002a --all shows issue #40" "#40" "$out"
assert_contains "TC-002b --all shows issue #41" "#41" "$out"
assert_contains "TC-002c --all shows status label" "pending-review" "$out"
assert_contains "TC-002d --all shows a header count" "issues: 2" "$out"
assert_not_contains "TC-003 non-listed issue #99 absent" "#99" "$out"

# ---------------------------------------------------------------------------
# TC-004: --all --json is valid and correctly sized.
# ---------------------------------------------------------------------------
echo "== TC-004 --all --json =="
out="$(run_status --all --json)"
assert_eq "TC-004a --all --json .issues|length == 2" "2" "$(jq -r '.issues|length' <<<"$out" 2>/dev/null)"
assert_eq "TC-004b --all --json schema_version == 1" "1" "$(jq -r '.schema_version' <<<"$out" 2>/dev/null)"
assert_contains "TC-004c --all --json carries repo" "panzi-hub/MergeMill" "$out"

# ---------------------------------------------------------------------------
# TC-005: single-issue --json has the required stable keys.
# ---------------------------------------------------------------------------
echo "== TC-005 --json shape =="
export GH_FIXTURE="$TMP/fx-shape.json"
write_fixture "$GH_FIXTURE" "MergeMill in-progress" "[]"
out="$(run_status --json 42)"
assert_eq "TC-005a --json is valid JSON" "0" "$(jq -e . >/dev/null 2>&1 <<<"$out"; echo $?)"
for k in schema_version issue title issue_state status_label labels agent run_id attempt last_result pr retries max_retries stale next_action diagnostics; do
  assert_eq "TC-005b key .${k} present" "true" "$(jq -r "has(\"${k}\")" <<<"$out" 2>/dev/null)"
done

# ---------------------------------------------------------------------------
# TC-006: normal run — rc=0 success + failure_class echoed.
# ---------------------------------------------------------------------------
echo "== TC-006 normal run =="
export GH_FIXTURE="$TMP/fx-ok.json"
write_fixture "$GH_FIXTURE" "MergeMill pending-review" "[]"
mk_run "test-proj-60-review-20260601T000000Z" "2026-06-01T00:00:00Z" "0" "2026-06-01T00:05:00Z" "1"
printf '%s' '{"schema_version":1,"event":"agent_completed","session_id":"sess-ok","mode":"new","cli":"claude","rc":0,"failure_class":"agent","ended_at":"2026-06-01T00:05:00Z"}' \
  > "$RUN_BASE/runs/test-proj-60-review-20260601T000000Z/agent-result.json"
out="$(run_status --json 60)"
assert_eq "TC-006a outcome=success" "success" "$(jq -r '.last_result.outcome' <<<"$out")"
assert_eq "TC-006b rc=0" "0" "$(jq -r '.last_result.rc' <<<"$out")"
assert_eq "TC-006c failure_class echoed" "agent" "$(jq -r '.last_result.failure_class' <<<"$out")"

# ---------------------------------------------------------------------------
# TC-007: failed run — rc=1 + failure_class=code.
# ---------------------------------------------------------------------------
echo "== TC-007 failed run =="
export GH_FIXTURE="$TMP/fx-fail.json"
write_fixture "$GH_FIXTURE" "MergeMill pending-dev" "[]"
mk_run "test-proj-61-dev-20260602T000000Z" "2026-06-02T00:00:00Z" "1" "2026-06-02T00:05:00Z" "2"
printf '%s' '{"schema_version":1,"event":"agent_completed","session_id":"sess-bad","mode":"new","cli":"codex","rc":1,"failure_class":"code","ended_at":"2026-06-02T00:05:00Z"}' \
  > "$RUN_BASE/runs/test-proj-61-dev-20260602T000000Z/agent-result.json"
out="$(run_status --json 61)"
assert_eq "TC-007a outcome=failure" "failure" "$(jq -r '.last_result.outcome' <<<"$out")"
assert_eq "TC-007b rc=1" "1" "$(jq -r '.last_result.rc' <<<"$out")"
assert_eq "TC-007c failure_class=code" "code" "$(jq -r '.last_result.failure_class' <<<"$out")"
assert_contains "TC-007d agent=dev" "dev" "$(jq -r '.agent' <<<"$out")"

# ---------------------------------------------------------------------------
# TC-008: corrupt agent-result.json tolerated.
# ---------------------------------------------------------------------------
echo "== TC-008 corrupt result tolerated =="
export GH_FIXTURE="$TMP/fx-corrupt.json"
write_fixture "$GH_FIXTURE" "MergeMill in-progress" "[]"
mk_run "test-proj-62-dev-20260603T000000Z" "2026-06-03T00:00:00Z" "" ""
printf 'this is not json {{{' > "$RUN_BASE/runs/test-proj-62-dev-20260603T000000Z/agent-result.json"
out="$(run_status 62; echo "rc=$?")"
assert_contains "TC-008a does not crash (rc=0)" "rc=0" "$out"
assert_contains "TC-008b reports unreadable agent-result" "unreadable or malformed" "$out"
outj="$(run_status --json 62)"
assert_eq "TC-008c failure_class=unknown" "unknown" "$(jq -r '.last_result.failure_class' <<<"$outj")"
assert_eq "TC-008d diagnostic present in JSON" "1" "$(jq -r '[.diagnostics[]|select(test("unreadable or malformed"))]|length' <<<"$outj")"

# ---------------------------------------------------------------------------
# TC-009: missing run dir / logs tolerated.
# ---------------------------------------------------------------------------
echo "== TC-009 missing runs tolerated =="
export GH_FIXTURE="$TMP/fx-norun.json"
write_fixture "$GH_FIXTURE" "MergeMill pending-dev" "[]"
outj="$(run_status --json 63)"
assert_eq "TC-009a run_id null" "null" "$(jq -r '.run_id' <<<"$outj")"
assert_eq "TC-009b last_result null" "null" "$(jq -r '.last_result' <<<"$outj")"
out="$(run_status 63; echo "rc=$?")"
assert_contains "TC-009c rc=0" "rc=0" "$out"

# ---------------------------------------------------------------------------
# TC-010/011: PR absent vs present.
# ---------------------------------------------------------------------------
echo "== TC-010/011 PR =="
export GH_FIXTURE="$TMP/fx-nopr.json"
write_fixture "$GH_FIXTURE" "MergeMill pending-dev" "[]"
outj="$(run_status --json 64)"
assert_eq "TC-010a pr null when absent" "null" "$(jq -r '.pr' <<<"$outj")"
assert_contains "TC-010b text <none linked>" "<none linked>" "$(run_status 64)"

export GH_FIXTURE="$TMP/fx-pr.json"
write_fixture "$GH_FIXTURE" "MergeMill pending-review" \
  '[{"number":777,"reviewDecision":"APPROVED","mergeable":"MERGEABLE","state":"OPEN","body":"Closes #65","closingIssuesReferences":[{"number":65}],"headRefName":"fix/issue-65"}]'
outj="$(run_status --json 65)"
assert_eq "TC-011a pr number" "777" "$(jq -r '.pr.number' <<<"$outj")"
assert_eq "TC-011b pr state" "OPEN" "$(jq -r '.pr.state' <<<"$outj")"
assert_eq "TC-011c pr review_decision" "APPROVED" "$(jq -r '.pr.review_decision' <<<"$outj")"

# ---------------------------------------------------------------------------
# TC-012/013: stale PID vs live PID.
# ---------------------------------------------------------------------------
echo "== TC-012/013 stale vs live PID =="
export GH_FIXTURE="$TMP/fx-stale.json"
write_fixture "$GH_FIXTURE" "MergeMill in-progress" "[]"
echo "$DEAD_PID" > "$PID_DIR/issue-70.pid"; old_mtime "$PID_DIR/issue-70.pid"
outj="$(run_status --json 70)"
assert_eq "TC-012a stale_pid true" "true" "$(jq -r '.stale.stale_pid' <<<"$outj")"
assert_contains "TC-012b text flags stale" "stale PID" "$(run_status 70)"
rm -f "$PID_DIR/issue-70.pid"

echo "$$" > "$PID_DIR/issue-71.pid"
outj="$(run_status --json 71)"
assert_eq "TC-013a live pid → stale_pid false" "false" "$(jq -r '.stale.stale_pid' <<<"$outj")"
assert_eq "TC-013b dev_pid_alive true" "true" "$(jq -r '.stale.dev_pid_alive' <<<"$outj")"
rm -f "$PID_DIR/issue-71.pid"

# ---------------------------------------------------------------------------
# TC-014: stale heartbeat.
# ---------------------------------------------------------------------------
echo "== TC-014 stale heartbeat =="
export GH_FIXTURE="$TMP/fx-hb.json"
write_fixture "$GH_FIXTURE" "MergeMill in-progress" "[]"
echo "$DEAD_PID" > "$PID_DIR/issue-72.pid"; old_mtime "$PID_DIR/issue-72.pid"
: > "$PID_DIR/issue-72.heartbeat"; old_mtime "$PID_DIR/issue-72.heartbeat"
outj="$(run_status --json 72)"
assert_eq "TC-014 heartbeat_stale true" "true" "$(jq -r '.stale.heartbeat_stale' <<<"$outj")"
rm -f "$PID_DIR/issue-72.pid" "$PID_DIR/issue-72.heartbeat"

# ---------------------------------------------------------------------------
# TC-015: stale / abandoned run (no end marker + old).
# ---------------------------------------------------------------------------
echo "== TC-015 stale run =="
export GH_FIXTURE="$TMP/fx-stalerun.json"
write_fixture "$GH_FIXTURE" "MergeMill in-progress" "[]"
_d="$RUN_BASE/runs/test-proj-73-dev-20200101T000000Z"; mkdir -p "$_d"
jq -cn '{started_at:"2020-01-01T00:00:00Z", attempt:1}' > "$_d/meta.json"   # no ended_at
old_mtime "$_d"
outj="$(run_status --json 73)"
assert_eq "TC-015 stale_run true" "true" "$(jq -r '.stale.stale_run' <<<"$outj")"

# ---------------------------------------------------------------------------
# TC-016: attempt + agent surfaced.
# ---------------------------------------------------------------------------
echo "== TC-016 attempt + agent =="
export GH_FIXTURE="$TMP/fx-attempt.json"
write_fixture "$GH_FIXTURE" "MergeMill reviewing" "[]"
mk_run "test-proj-74-review-20260605T000000Z" "2026-06-05T00:00:00Z" "" "" "2"
outj="$(run_status --json 74)"
assert_eq "TC-016a attempt==2" "2" "$(jq -r '.attempt' <<<"$outj")"
assert_eq "TC-016b agent==review" "review" "$(jq -r '.agent' <<<"$outj")"

# ---------------------------------------------------------------------------
# TC-017: next dispatch action present.
# ---------------------------------------------------------------------------
echo "== TC-017 next action =="
export GH_FIXTURE="$TMP/fx-next.json"
write_fixture "$GH_FIXTURE" "MergeMill pending-review" "[]"
outj="$(run_status --json 75)"
assert_contains "TC-017a next_action mentions Step 3" "Step 3" "$(jq -r '.next_action' <<<"$outj")"
assert_contains "TC-017b text shows next tick section" "next dispatcher tick" "$(run_status 75)"

# ---------------------------------------------------------------------------
# TC-018: read-only contract — no mutation verbs in calls or source.
# ---------------------------------------------------------------------------
echo "== TC-018 read-only =="
export GH_FIXTURE="$TMP/fx-ro.json"
export GH_CALLS="$TMP/gh-calls.log"; : > "$GH_CALLS"
write_fixture "$GH_FIXTURE" "MergeMill pending-review" "[]" "40,41"
run_status --all >/dev/null
run_status --json 40 >/dev/null
calls="$(cat "$GH_CALLS")"
assert_not_contains "TC-018a no issue edit" "issue edit" "$calls"
assert_not_contains "TC-018b no issue comment" "issue comment" "$calls"
assert_not_contains "TC-018c no pr merge" "pr merge" "$calls"
assert_not_contains "TC-018d no pr review" "pr review" "$calls"
unset GH_CALLS
src="$(cat "$STATUS_SH")"
assert_not_contains "TC-018e source has no 'gh issue edit'" "gh issue edit" "$src"
assert_not_contains "TC-018f source has no 'gh pr merge'" "gh pr merge" "$src"
assert_not_contains "TC-018g source has no 'gh issue comment'" "gh issue comment" "$src"

# ---------------------------------------------------------------------------
# TC-019: usage errors.
# ---------------------------------------------------------------------------
echo "== TC-019 usage =="
out="$(env -u PROJECT_DIR PATH="$BIN:$PATH" REPO=x/y REPO_OWNER=x PROJECT_ID=test-proj MERGEMILL_CONF="$EMPTY_CONF" bash "$STATUS_SH" 2>&1; echo "rc=$?")"
assert_contains "TC-019a no-arg usage error" "Usage:" "$out"
assert_contains "TC-019b no-arg rc=2" "rc=2" "$out"
out="$(env -u PROJECT_DIR PATH="$BIN:$PATH" REPO=x/y REPO_OWNER=x PROJECT_ID=test-proj MERGEMILL_CONF="$EMPTY_CONF" bash "$STATUS_SH" --all --issue 5 2>&1; echo "rc=$?")"
assert_contains "TC-019c --all + --issue rejected" "mutually exclusive" "$out"
assert_contains "TC-019d rc=2" "rc=2" "$out"
out="$(env -u PROJECT_DIR PATH="$BIN:$PATH" REPO=x/y REPO_OWNER=x PROJECT_ID=test-proj MERGEMILL_CONF="$EMPTY_CONF" bash "$STATUS_SH" notanumber 2>&1; echo "rc=$?")"
assert_contains "TC-019e bad positional rc=2" "rc=2" "$out"

# ---------------------------------------------------------------------------
# TC-020: secrets never leak into --json.
# ---------------------------------------------------------------------------
echo "== TC-020 no secret leak =="
export GH_FIXTURE="$TMP/fx-secret.json"
write_fixture "$GH_FIXTURE" "MergeMill pending-dev" "[]"
out="$(env -u PROJECT_DIR PATH="$BIN:$PATH" REPO="panzi-hub/MergeMill" REPO_OWNER="zxkane" PROJECT_ID="test-proj" \
  MAX_RETRIES=3 MERGEMILL_PID_DIR="$PID_DIR" MERGEMILL_RUN_DIR_BASE="$RUN_BASE" MERGEMILL_CONF="$EMPTY_CONF" \
  GH_TOKEN="supersecret-token-xyz" MERGEMILL_SECRET="topsecretvalue" \
  bash "$STATUS_SH" --json 40 2>&1)"
assert_not_contains "TC-020a GH_TOKEN absent from JSON" "supersecret-token-xyz" "$out"
assert_not_contains "TC-020b custom secret absent from JSON" "topsecretvalue" "$out"

# ---------------------------------------------------------------------------
# TC-021: last_result is the NEWEST run across BOTH sides. A newer dev run must
# win over an older review run. A lexical path sort ranks `-dev-` before
# `-review-` regardless of the run timestamp, so this pins the TIME ordering
# (dir mtimes are pinned so GNU `date -d` and BSD mtime-fallback agree).
# ---------------------------------------------------------------------------
echo "== TC-021 newest result across dev/review sides =="
export GH_FIXTURE="$TMP/fx-crossside.json"
write_fixture "$GH_FIXTURE" "MergeMill pending-dev" "[]"
mk_run "test-proj-80-review-20260601T000000Z" "2026-06-01T00:00:00Z" "1" "2026-06-01T00:05:00Z" "1"
printf '%s' '{"schema_version":1,"event":"agent_completed","rc":1,"failure_class":"code","ended_at":"2026-06-01T00:05:00Z"}' \
  > "$RUN_BASE/runs/test-proj-80-review-20260601T000000Z/agent-result.json"
mk_run "test-proj-80-dev-20260602T000000Z" "2026-06-02T00:00:00Z" "0" "2026-06-02T00:05:00Z" "2"
printf '%s' '{"schema_version":1,"event":"agent_completed","rc":0,"failure_class":"agent","ended_at":"2026-06-02T00:05:00Z"}' \
  > "$RUN_BASE/runs/test-proj-80-dev-20260602T000000Z/agent-result.json"
touch -t 202606010000 "$RUN_BASE/runs/test-proj-80-review-20260601T000000Z" 2>/dev/null || true
touch -t 202606020000 "$RUN_BASE/runs/test-proj-80-dev-20260602T000000Z" 2>/dev/null || true
outj="$(run_status --json 80)"
assert_eq "TC-021a newest result rc=0 (dev run wins over older review)" "0" "$(jq -r '.last_result.rc' <<<"$outj")"
assert_eq "TC-021b newest result failure_class=agent" "agent" "$(jq -r '.last_result.failure_class' <<<"$outj")"
assert_eq "TC-021c last_result.run_id is the newer dev run" \
  "test-proj-80-dev-20260602T000000Z" "$(jq -r '.last_result.run_id' <<<"$outj")"

echo ""
echo "================================================"
echo -e "status-dashboard: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
echo "================================================"
[[ "$FAIL" -eq 0 ]]
