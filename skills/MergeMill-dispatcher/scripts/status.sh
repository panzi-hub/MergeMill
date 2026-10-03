#!/bin/bash
# status.sh — one-command operator view of MergeMill pipeline state. Issue #235
# / [INV-81], extended by issue #12 with a fleet view + machine-readable mode.
# READ-ONLY: issues NO label edits, NO comments, NO merges, NO lease writes.
#
# Usage:
#   scripts/status.sh <issue> [--project <id>]
#   scripts/status.sh --issue <n> [--project <id>]
#   scripts/status.sh --all [--project <id>]
#   scripts/status.sh <issue>|--issue <n>|--all [--project <id>] [--json]
#
# Single-issue mode answers "why is it stuck and what will the next dispatcher
# tick do?" by sourcing the dispatcher's REAL predicate functions
# (lib-dispatch.sh) — NOT a reimplementation. Predicate parity is the whole
# point: a divergent answer here would be a NEW false-signal source, worse than
# no tool (issue #235 Design Considerations). So the "next tick" verdicts below
# are derived from the SAME pid_alive / dev_near_success / review_near_success /
# count_retries / fetch_pr_for_issue functions the tick calls.
#
# --all enumerates every OPEN issue carrying the `MergeMill` label via the
# abstract `itp_list_by_state` contract (the same enumeration point the
# dispatcher's Step-2 scan uses) and renders one compact block per issue.
#
# --json emits a STABLE machine-readable object (schema_version 1). Every field
# is always present; anything undeterminable is `null` (JSON) / `unknown` (text)
# with a `diagnostics` entry explaining why — missing logs, corrupt
# agent-result.json, absent PRs and stale/expired PID + heartbeat files never
# crash the command. Secrets are never included: only operational fields.
#
# Exit codes: 0 success; 2 usage; 3 missing dependency (gh/jq); 4 issue
# enumeration failed (--all); 5 named issue not found / unreadable.

set -euo pipefail

# [INV-65] Two-dir resolution (mirrors dispatcher-tick.sh): SCRIPT_DIR is the
# UNRESOLVED dirname so a project-side symlink keeps it on the project's scripts/
# where MergeMill.conf lives [INV-14]; LIB_DIR is the REAL path so sibling libs
# source from the skill tree regardless of per-project symlink coverage (#227).
_SELF="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
if command -v realpath >/dev/null 2>&1; then
  _REAL_SELF="$(realpath "$_SELF")"
else
  _REAL_SELF="$(readlink -f "$_SELF")"
fi
LIB_DIR="$(cd "$(dirname "$_REAL_SELF")" && pwd)"

usage() {
  cat >&2 <<'USAGE'
Usage:
  status.sh <issue> [--project <id>]
  status.sh --issue <n> [--project <id>]
  status.sh --all [--project <id>]
  status.sh <issue>|--issue <n>|--all [--project <id>] [--json]

Read-only MergeMill runtime status. --all lists every OPEN `MergeMill` issue;
--json emits a stable machine-readable object (schema_version 1).
Exit codes: 0 ok, 2 usage, 3 missing dependency, 4 enumeration failed, 5 issue not found.
USAGE
}

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
ISSUE_NUMBER=""
PROJECT_OVERRIDE=""
ALL_MODE=false
JSON_MODE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      [[ $# -ge 2 ]] || { echo "Error: --project requires argument" >&2; exit 2; }
      PROJECT_OVERRIDE="$2"; shift 2 ;;
    --issue)
      [[ $# -ge 2 ]] || { echo "Error: --issue requires argument" >&2; exit 2; }
      [[ -z "$ISSUE_NUMBER" ]] || { echo "Error: --issue given more than once" >&2; exit 2; }
      ISSUE_NUMBER="$2"; shift 2 ;;
    --all)
      ALL_MODE=true; shift ;;
    --json)
      JSON_MODE=true; shift ;;
    -h|--help)
      usage; exit 0 ;;
    -*)
      echo "Unknown option: $1" >&2; exit 2 ;;
    *)
      if [[ -z "$ISSUE_NUMBER" ]]; then ISSUE_NUMBER="$1"; shift
      else echo "Error: unexpected argument '$1'" >&2; exit 2; fi ;;
  esac
done

if [[ "$ALL_MODE" == "true" && -n "$ISSUE_NUMBER" ]]; then
  echo "Error: --all and an explicit issue are mutually exclusive" >&2
  exit 2
fi
if [[ "$ALL_MODE" != "true" ]]; then
  if [[ -z "$ISSUE_NUMBER" ]] || ! [[ "$ISSUE_NUMBER" =~ ^[0-9]+$ ]]; then
    usage
    echo "Error: an issue number (positive integer) or --all is required" >&2
    exit 2
  fi
fi

# ---------------------------------------------------------------------------
# Load config + the REAL predicate libs (same order dispatcher-tick.sh uses).
# ---------------------------------------------------------------------------
# shellcheck source=lib-config.sh
source "${LIB_DIR}/lib-config.sh"
load_MergeMill_conf "${SCRIPT_DIR}" || true

# --project overrides PROJECT_ID AFTER the conf load (conf sets PROJECT_ID).
[[ -n "$PROJECT_OVERRIDE" ]] && PROJECT_ID="$PROJECT_OVERRIDE"

# lib-dispatch.sh has top-level `: "${REPO:?}"` / `${REPO_OWNER:?}` /
# `${PROJECT_ID:?}` guards. Preflight so a missing key is a clean error, not a
# raw bash abort.
for _req in REPO REPO_OWNER PROJECT_ID; do
  if [[ -z "${!_req:-}" ]]; then
    echo "Error: ${_req} is unset — run from a project dir with scripts/MergeMill.conf, or pass --project <id>." >&2
    exit 2
  fi
done

# Provider leaves own host-I/O dependencies; the dashboard only requires jq.
command -v jq >/dev/null 2>&1 || {
  echo "Error: required dependency 'jq' not found on PATH." >&2; exit 3; }

# shellcheck source=lib-run-artifacts.sh
source "${LIB_DIR}/lib-run-artifacts.sh" 2>/dev/null || true
# shellcheck source=lib-dispatch.sh
source "${LIB_DIR}/lib-dispatch.sh"

MAX_RETRIES="${MAX_RETRIES:-3}"
# A run dir with no end marker older than this many seconds is treated as an
# ABANDONED (stale) run rather than an in-flight one (#12 stale-run diagnostic).
STATUS_STALE_RUN_SECONDS="${STATUS_STALE_RUN_SECONDS:-3600}"

# Mutable per-issue collected state (set by _collect_issue). Declared empty up
# front so `set -u` is satisfied when an issue has no runs / no PR.
ISSUE_STATE=""; ISSUE_TITLE=""; LABELS=""
_PR_STATE=""; PR_NUMBER=""; PR_REVIEW_DECISION=""; PR_MERGEABLE=""
DEV_PID=""; REVIEW_PID=""; DEV_ALIVE="no"; REVIEW_ALIVE="no"
RETRIES="?"
RUNS_PARENT=""
STATUS_LABEL="none"; AGENT="unknown"
LATEST_RUN_ID=""; LATEST_RUN_DIR=""; LATEST_RUN_ATTEMPT=""
LAST_RESULT_RUN_ID=""; LAST_RESULT_RC=""; LAST_RESULT_CLASS=""
LAST_RESULT_SESSION=""; LAST_RESULT_ENDED=""; LAST_RESULT_CLI=""; LAST_RESULT_MODE=""
STALE_PID=false; STALE_RUN=false; HEARTBEAT_STALE=false
ISSUE_FOUND=false
NEXT_ACTION=""
_ISSUE_JSON=""
DIAGNOSTICS=()

has_label() { [[ " $LABELS " == *" $1 "* ]]; }

# ---------------------------------------------------------------------------
# Derive "what the next dispatcher tick will do" — SAME predicates as the tick.
# ---------------------------------------------------------------------------
_next_action() {
  if [[ "$ISSUE_STATE" != "OPEN" ]]; then
    echo "none — issue is ${ISSUE_STATE} (terminal)."; return
  fi
  if has_label stalled; then
    echo "none — \`stalled\` is terminal (retry budget MAX_RETRIES=${MAX_RETRIES} exhausted); operator intervention required."; return
  fi
  if has_label approved; then
    if has_label no-auto-close; then
      echo "none — \`approved\` + \`no-auto-close\`: review passed but auto-merge is gated; operator merges manually."
    else
      echo "none — \`approved\` is terminal (auto-close handled by GitHub via the PR's Closes #N on merge)."
    fi
    return
  fi
  if has_label reviewing; then
    if [[ "$REVIEW_ALIVE" == "yes" ]]; then
      echo "Step 5a: leave alone — review wrapper lease is ALIVE (review has its own polling/timeout)."
    elif review_near_success "$ISSUE_NUMBER" >/dev/null 2>&1; then
      echo "Step 5b: DEFER crash declaration — pid_alive miss but review_near_success signal positive ([INV-24]); re-checks next tick."
    else
      echo "Step 5b: declare review crash → swap \`reviewing\`→\`pending-dev\` (then Step 4 re-evaluates; retry ${RETRIES}/${MAX_RETRIES})."
    fi
    return
  fi
  if has_label in-progress; then
    if [[ "$DEV_ALIVE" == "yes" ]]; then
      if [[ -n "$PR_NUMBER" ]]; then
        echo "Step 5a: dev lease ALIVE with PR #${PR_NUMBER} present — if CI is green AND PR idle >300s, SIGTERM the dev wrapper and swap \`in-progress\`→\`pending-review\`; else leave alone."
      else
        echo "Step 5a: leave alone — dev lease ALIVE, no PR yet."
      fi
    elif dev_near_success "$ISSUE_NUMBER" >/dev/null 2>&1; then
      echo "Step 5b: DEFER crash declaration — pid_alive miss but dev_near_success signal positive ([INV-27]); re-checks next tick."
    else
      echo "Step 5b: declare dev crash (\"Task appears to have crashed (no PR found)\") → swap \`in-progress\`→\`pending-dev\` (retry ${RETRIES}/${MAX_RETRIES})."
    fi
    return
  fi
  if has_label pending-review; then
    echo "Step 3: dispatch review → swap \`pending-review\`→\`reviewing\` (subject to MAX_CONCURRENT)."; return
  fi
  if has_label pending-dev; then
    if [[ "$RETRIES" =~ ^[0-9]+$ ]] && [[ "$RETRIES" -ge "$MAX_RETRIES" ]]; then
      echo "Step 4: retries (${RETRIES}) ≥ MAX_RETRIES (${MAX_RETRIES}) → mark_stalled (swap \`pending-dev\`→\`stalled\`)."
    elif [[ -n "$PR_NUMBER" ]]; then
      echo "Step 4: PR #${PR_NUMBER} exists → if HEAD advanced, swap \`pending-dev\`→\`pending-review\`; else stale-verdict re-poll. (retry ${RETRIES}/${MAX_RETRIES})"
    else
      echo "Step 4: dispatch dev-resume → swap \`pending-dev\`→\`in-progress\` (retry ${RETRIES}/${MAX_RETRIES}), subject to MAX_CONCURRENT."
    fi
    return
  fi
  if has_label MergeMill; then
    echo "Step 2: dispatch dev-new → swap to \`in-progress\` (once ## Dependencies are resolved + MAX_CONCURRENT allows)."; return
  fi
  echo "none — issue is not \`MergeMill\`; the dispatcher ignores it."
}

# ---------------------------------------------------------------------------
# Run-dir helpers (#235 durable state). Sort keys are numeric epochs so
# ISO-backed and mtime-fallback dirs compare on the same axis, and the numeric
# disambiguation suffix breaks same-UTC-second ties (`…Z-9` before `…Z-10`).
# ---------------------------------------------------------------------------
# _run_sort_epoch <dir> — echo a NUMERIC epoch sort key for a run dir: the
# `meta.json.started_at` ISO timestamp converted to epoch when present+parseable,
# else the dir's mtime, else 0.
_run_sort_epoch() {
  local d="$1" iso="" key=""
  if [[ -f "$d/meta.json" ]] && command -v jq >/dev/null 2>&1; then
    iso="$(jq -r '.started_at // empty' "$d/meta.json" 2>/dev/null || echo "")"
    [[ -n "$iso" ]] && key="$(date -u -d "$iso" +%s 2>/dev/null || echo "")"
  fi
  [[ -n "${key:-}" ]] || key="$(stat -c %Y "$d" 2>/dev/null || stat -f %m "$d" 2>/dev/null || echo 0)"
  [[ "$key" =~ ^[0-9]+$ ]] || key=0
  printf '%s\n' "$key"
}

# _run_disambig_suffix <run-id-basename> — echo the NUMERIC disambiguation suffix
# used to break a same-UTC-second tie. A name with no `-<n>` tail → 1.
_run_disambig_suffix() {
  local name="$1"
  if [[ "$name" =~ -([0-9]+)$ ]]; then printf '%s\n' "${BASH_REMATCH[1]}"; else printf '1\n'; fi
}

# _side_from_run_name <basename> — echo dev|review|unknown for a wrapper run-id.
_side_from_run_name() {
  local n="$1"
  if [[ "$n" == "${PROJECT_ID}-${ISSUE_NUMBER}-dev-"* ]]; then echo dev
  elif [[ "$n" == "${PROJECT_ID}-${ISSUE_NUMBER}-review-"* ]]; then echo review
  else echo unknown; fi
}

# _latest_run_dir — echo the newest run dir for THIS issue (dev or review), or
# nothing. Same numeric epoch + disambiguation-suffix ordering as _recent_runs.
_latest_run_dir() {
  [[ -n "$RUNS_PARENT" && -d "$RUNS_PARENT" ]] || return 0
  local d name key suffix best="" bestkey=-1 bestsuf=-1
  for d in "$RUNS_PARENT/${PROJECT_ID}-${ISSUE_NUMBER}-dev-"* \
           "$RUNS_PARENT/${PROJECT_ID}-${ISSUE_NUMBER}-review-"*; do
    [[ -d "$d" ]] || continue
    name="$(basename "$d")"
    key="$(_run_sort_epoch "$d")"
    suffix="$(_run_disambig_suffix "$name")"
    if [[ "$key" -gt "$bestkey" ]] \
       || { [[ "$key" -eq "$bestkey" ]] && [[ "$suffix" -gt "$bestsuf" ]]; }; then
      best="$d"; bestkey="$key"; bestsuf="$suffix"
    fi
  done
  [[ -n "$best" ]] && printf '%s\n' "$best"
}

# _latest_result_file — echo the newest agent-result.json for THIS issue only,
# over BOTH sides. The `-<issue>-dev-`/`-<issue>-review-` path delimiters scope
# out a sibling issue's newer result, and the SAME numeric epoch + disambiguation
# ordering as _latest_run_dir picks the newest run that HAS a result (a lexical
# path sort would rank `-dev-` before `-review-` regardless of the timestamp, so
# a newer dev resume would be masked by an older review result).
_latest_result_file() {
  [[ -n "$RUNS_PARENT" && -d "$RUNS_PARENT" ]] || return 0
  local d name key suffix best="" bestkey=-1 bestsuf=-1
  for d in "$RUNS_PARENT/${PROJECT_ID}-${ISSUE_NUMBER}-dev-"* \
           "$RUNS_PARENT/${PROJECT_ID}-${ISSUE_NUMBER}-review-"*; do
    [[ -d "$d" && -f "$d/agent-result.json" ]] || continue
    name="$(basename "$d")"
    key="$(_run_sort_epoch "$d")"
    suffix="$(_run_disambig_suffix "$name")"
    if [[ "$key" -gt "$bestkey" ]] \
       || { [[ "$key" -eq "$bestkey" ]] && [[ "$suffix" -gt "$bestsuf" ]]; }; then
      best="$d/agent-result.json"; bestkey="$key"; bestsuf="$suffix"
    fi
  done
  [[ -n "$best" ]] && printf '%s\n' "$best"
}

# Echo the up-to-3 most recent run dirs for THIS issue, newest first.
_recent_runs() {
  [[ -n "$RUNS_PARENT" && -d "$RUNS_PARENT" ]] || return 0
  local d epoch suffix rc ended outcome name
  local -a rows=()
  for d in "$RUNS_PARENT/${PROJECT_ID}-${ISSUE_NUMBER}-dev-"* \
           "$RUNS_PARENT/${PROJECT_ID}-${ISSUE_NUMBER}-review-"*; do
    [[ -d "$d" ]] || continue
    name="$(basename "$d")"
    rc=""; ended=""
    if [[ -f "$d/meta.json" ]] && command -v jq >/dev/null 2>&1; then
      rc="$(jq -r '.rc // empty' "$d/meta.json" 2>/dev/null || echo "")"
      ended="$(jq -r '.ended_at // empty' "$d/meta.json" 2>/dev/null || echo "")"
    fi
    epoch="$(_run_sort_epoch "$d")"
    suffix="$(_run_disambig_suffix "$name")"
    if [[ -z "$ended" ]]; then outcome="in-flight (no end marker)"
    elif [[ "$rc" == "0" ]]; then outcome="rc=0 (success)"
    elif [[ -n "$rc" ]]; then outcome="rc=${rc} (failure)"
    else outcome="ended (rc unknown)"; fi
    rows+=("${epoch}|${suffix}|${name}|${outcome}")
  done
  [[ ${#rows[@]} -gt 0 ]] || return 0
  printf '%s\n' "${rows[@]}" | sort -t'|' -k1,1nr -k2,2nr | head -3 \
    | awk -F'|' '{printf "  %s  —  %s\n", $3, $4}'
}

# Echo the drop reasons from the NEWEST review run dir — but only if THAT run
# actually has a `drops.jsonl`. Selecting the newest run FIRST (regardless of
# whether it has drops) and rendering only its file avoids showing stale drops
# from an OLDER review when the newest review had none (#235 review [P1]).
_latest_review_drops() {
  [[ -n "$RUNS_PARENT" && -d "$RUNS_PARENT" ]] || return 0
  local d name latest="" latest_key=-1 latest_suffix=-1 key suffix
  for d in "$RUNS_PARENT/${PROJECT_ID}-${ISSUE_NUMBER}-review-"*; do
    [[ -d "$d" ]] || continue
    name="$(basename "$d")"
    key="$(_run_sort_epoch "$d")"
    suffix="$(_run_disambig_suffix "$name")"
    if [[ "$key" -gt "$latest_key" ]] \
       || { [[ "$key" -eq "$latest_key" ]] && [[ "$suffix" -gt "$latest_suffix" ]]; }; then
      latest="$d"; latest_key="$key"; latest_suffix="$suffix"
    fi
  done
  [[ -n "$latest" ]] || return 0
  [[ -f "$latest/drops.jsonl" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r '"  " + .agent + ": " + .reason + "  (" + (.ts // "") + ")"' "$latest/drops.jsonl" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Collect one issue's state into the module globals above (READ-ONLY).
# Tolerates every failure mode the issue lists: a missing issue, a missing run,
# a corrupt agent-result.json, an absent PR, and stale PID/heartbeat files.
# ---------------------------------------------------------------------------
_collect_issue() {
  local issue_num="$1"
  ISSUE_NUMBER="$issue_num"
  DIAGNOSTICS=()
  STATUS_LABEL="none"; AGENT="unknown"
  LATEST_RUN_ID=""; LATEST_RUN_DIR=""; LATEST_RUN_ATTEMPT=""
  LAST_RESULT_RUN_ID=""; LAST_RESULT_RC=""; LAST_RESULT_CLASS=""
  LAST_RESULT_SESSION=""; LAST_RESULT_ENDED=""; LAST_RESULT_CLI=""; LAST_RESULT_MODE=""
  STALE_PID=false; STALE_RUN=false; HEARTBEAT_STALE=false
  _PR_STATE=""; PR_NUMBER=""; PR_REVIEW_DECISION=""; PR_MERGEABLE=""
  DEV_PID=""; REVIEW_PID=""; DEV_ALIVE="no"; REVIEW_ALIVE="no"
  ISSUE_FOUND=false
  NEXT_ACTION=""

  # [INV-87] issue-level task read routes through itp_read_task ([W1b] #396) —
  # the ABSTRACT contract: `labels` is a normalized array of NAME strings,
  # `state` passes through as GitHub's own OPEN/CLOSED token.
  # NOTE: this exact line is source-pinned by tests/unit/test-w1b-read-task-contracts.sh
  # (TC source-pin) — keep the `ISSUE_NUMBER` spelling even though `issue_num`
  # holds the same value, or that conformance pin fails.
  ISSUE_JSON="$(itp_read_task "$ISSUE_NUMBER" state,labels,title 2>/dev/null || echo '{}')"
  if [[ -z "$ISSUE_JSON" || "$ISSUE_JSON" == "{}" || "$ISSUE_JSON" == "null" ]] \
     || ! jq -e 'type=="object" and .state != null' >/dev/null 2>&1 <<<"$ISSUE_JSON"; then
    ISSUE_FOUND=false
    ISSUE_STATE="UNKNOWN"; ISSUE_TITLE=""; LABELS=""
    DIAGNOSTICS+=("issue #${issue_num} unreadable or not found")
    RUNS_PARENT=""; return 0
  fi
  ISSUE_FOUND=true
  ISSUE_STATE="$(jq -r '.state // "UNKNOWN"' <<<"$ISSUE_JSON")"
  ISSUE_TITLE="$(jq -r '.title // ""' <<<"$ISSUE_JSON")"
  LABELS="$(jq -r '[.labels[]] | join(" ")' <<<"$ISSUE_JSON" 2>/dev/null || echo "")"

  # Open PR + reviewDecision (via the dispatcher's own fetch_pr_for_issue helper,
  # which binds by GitHub's parsed closingIssuesReferences [INV-86]).
  PR_JSON="$(fetch_pr_for_issue "$issue_num" "number,reviewDecision,mergeable,state,body" 2>/dev/null || echo "")"
  if [[ -n "$PR_JSON" ]] && jq -e 'type=="object"' >/dev/null 2>&1 <<<"$PR_JSON"; then
    PR_NUMBER="$(jq -r '.number // empty' <<<"$PR_JSON" 2>/dev/null || echo "")"
    PR_REVIEW_DECISION="$(jq -r '.reviewDecision // "NONE"' <<<"$PR_JSON" 2>/dev/null || echo "")"
    PR_MERGEABLE="$(jq -r '.mergeable // "UNKNOWN"' <<<"$PR_JSON" 2>/dev/null || echo "")"
    _PR_STATE="$(jq -r '.state // "UNKNOWN"' <<<"$PR_JSON" 2>/dev/null || echo "")"
  elif [[ -n "$PR_JSON" ]]; then
    DIAGNOSTICS+=("PR query returned unparseable JSON for issue #${issue_num}")
  fi

  # Lease / PID liveness via the REAL pid_alive + get_pid (both sides).
  DEV_PID="$(get_pid issue "$issue_num" 2>/dev/null || echo "")"
  REVIEW_PID="$(get_pid review "$issue_num" 2>/dev/null || echo "")"
  if pid_alive issue "$issue_num" >/dev/null 2>&1; then DEV_ALIVE="yes"; else DEV_ALIVE="no"; fi
  if pid_alive review "$issue_num" >/dev/null 2>&1; then REVIEW_ALIVE="yes"; else REVIEW_ALIVE="no"; fi

  # Retry count via the REAL count_retries (the Step-4 stall gate input).
  RETRIES="$(count_retries "$issue_num" 2>/dev/null || echo "?")"

  # Run dirs.
  RUNS_PARENT=""
  if declare -F _runs_parent >/dev/null 2>&1; then
    RUNS_PARENT="$(_runs_parent 2>/dev/null || echo "")"
  fi

  # Status label: the MergeMill state label present (priority = the four
  # canonical states, then terminal).
  local _l
  for _l in in-progress reviewing pending-review pending-dev approved stalled; do
    if has_label "$_l"; then STATUS_LABEL="$_l"; break; fi
  done

  # Latest run dir (+ side, attempt, stale-run detection).
  LATEST_RUN_DIR="$(_latest_run_dir || echo "")"
  if [[ -n "$LATEST_RUN_DIR" ]]; then
    LATEST_RUN_ID="$(basename "$LATEST_RUN_DIR")"
    if [[ -f "$LATEST_RUN_DIR/meta.json" ]]; then
      LATEST_RUN_ATTEMPT="$(jq -r '.attempt // empty' "$LATEST_RUN_DIR/meta.json" 2>/dev/null || echo "")"
      local _ended _started_epoch _now
      _ended="$(jq -r '.ended_at // empty' "$LATEST_RUN_DIR/meta.json" 2>/dev/null || echo "")"
      if [[ -z "$_ended" ]]; then
        _started_epoch="$(_run_sort_epoch "$LATEST_RUN_DIR")"
        _now="$(date -u +%s 2>/dev/null || echo 0)"
        if [[ "$_started_epoch" =~ ^[0-9]+$ ]] && [[ "$_now" =~ ^[0-9]+$ ]] \
           && [[ "$_started_epoch" -gt 0 ]] \
           && [[ $(( _now - _started_epoch )) -ge "$STATUS_STALE_RUN_SECONDS" ]]; then
          STALE_RUN=true
        fi
      fi
    fi
  fi

  # Agent type: prefer the status label's side, else the latest run's side.
  case "$STATUS_LABEL" in
    pending-review|reviewing) AGENT="review" ;;
    pending-dev|in-progress) AGENT="dev" ;;
    *)
      if [[ -n "$LATEST_RUN_ID" ]]; then
        AGENT="$(_side_from_run_name "$LATEST_RUN_ID")"
      elif has_label MergeMill; then AGENT="dev"
      fi ;;
  esac

  # Latest agent-result.json for THIS issue (missing / corrupt tolerated).
  local _lrf
  _lrf="$(_latest_result_file || echo "")"
  if [[ -n "$_lrf" ]]; then
    if jq -e 'type=="object"' >/dev/null 2>&1 <"$_lrf"; then
      LAST_RESULT_RUN_ID="$(basename "$(dirname "$_lrf")")"
      LAST_RESULT_RC="$(jq -r '.rc // empty' "$_lrf" 2>/dev/null || echo "")"
      LAST_RESULT_CLASS="$(jq -r '.failure_class // "unknown"' "$_lrf" 2>/dev/null || echo "unknown")"
      LAST_RESULT_SESSION="$(jq -r '.session_id // ""' "$_lrf" 2>/dev/null || echo "")"
      LAST_RESULT_ENDED="$(jq -r '.ended_at // ""' "$_lrf" 2>/dev/null || echo "")"
      LAST_RESULT_CLI="$(jq -r '.cli // ""' "$_lrf" 2>/dev/null || echo "")"
      LAST_RESULT_MODE="$(jq -r '.mode // ""' "$_lrf" 2>/dev/null || echo "")"
    else
      # A corrupt/malformed result is a DIAGNOSTIC, not a crash: surface the run
      # identity with failure_class=unknown and explain it in diagnostics.
      LAST_RESULT_RUN_ID="$(basename "$(dirname "$_lrf")")"
      LAST_RESULT_CLASS="unknown"
      DIAGNOSTICS+=("agent-result.json unreadable or malformed: ${_lrf}")
    fi
  fi

  # Stale PID / heartbeat diagnostics.
  local _kind _pf _hb _age _thr _now2 _hb_interval
  _hb_interval="${HEARTBEAT_INTERVAL_SECONDS:-120}"
  [[ "$_hb_interval" =~ ^[0-9]+$ ]] || _hb_interval=120
  _thr=$(( _hb_interval * 3 ))
  _now2="$(date -u +%s 2>/dev/null || echo 0)"
  for _kind in issue review; do
    _pf="$(declare -F _pid_file_for >/dev/null 2>&1 && _pid_file_for "$_kind" "$issue_num" 2>/dev/null || echo "")"
    [[ -n "$_pf" && -e "$_pf" ]] || continue
    case "$_kind" in
      issue)  [[ "$DEV_ALIVE" == "yes" ]] || STALE_PID=true ;;
      review) [[ "$REVIEW_ALIVE" == "yes" ]] || STALE_PID=true ;;
    esac
    _hb="${_pf%.pid}.heartbeat"
    if [[ -f "$_hb" && ! -L "$_hb" ]] && [[ "$_now2" =~ ^[0-9]+$ ]]; then
      _age="$(_mtime_epoch "$_hb" 2>/dev/null || echo "")"
      if [[ "$_age" =~ ^[0-9]+$ ]] && [[ "$_age" -gt 0 ]] \
         && [[ $(( _now2 - _age )) -ge "$_thr" ]]; then
        HEARTBEAT_STALE=true
      fi
    fi
  done
  if [[ "${EXECUTION_BACKEND:-local}" == "remote-aws-ssm" ]]; then
    DIAGNOSTICS+=("execution backend remote-aws-ssm: lease/run state read from the dispatcher-host filesystem (may be incomplete)")
  fi

  NEXT_ACTION="$(_next_action)"
  return 0
}

# ---------------------------------------------------------------------------
# Build the stable per-issue JSON object into $_ISSUE_JSON (schema_version 1).
# ---------------------------------------------------------------------------
_build_issue_json() {
  local labels_json last_result_json pr_json retries_json stale_json diag_json
  labels_json="$(jq -cn --arg s "$LABELS" '$s | split(" ") | map(select(length>0))' 2>/dev/null || echo '[]')"

  if [[ -n "$LAST_RESULT_RUN_ID" || -n "$LAST_RESULT_RC" ]]; then
    last_result_json="$(jq -cn \
      --arg run_id "$LAST_RESULT_RUN_ID" \
      --arg rc "$LAST_RESULT_RC" \
      --arg class "${LAST_RESULT_CLASS:-unknown}" \
      --arg session "$LAST_RESULT_SESSION" \
      --arg ended "$LAST_RESULT_ENDED" \
      '{run_id:(if $run_id=="" then null else $run_id end),
        rc:(if $rc=="" then null else ($rc|tonumber?) end),
        outcome:(if $rc=="0" then "success" elif $rc=="" then "unknown" else "failure" end),
        failure_class:$class,
        session_id:(if $session=="" then null else $session end),
        ended_at:(if $ended=="" then null else $ended end)}' 2>/dev/null || echo 'null')"
  else
    last_result_json="null"
  fi

  if [[ -n "$PR_NUMBER" ]]; then
    pr_json="$(jq -cn \
      --arg n "$PR_NUMBER" --arg st "${_PR_STATE:-UNKNOWN}" \
      --arg rd "${PR_REVIEW_DECISION:-NONE}" --arg mg "${PR_MERGEABLE:-UNKNOWN}" \
      '{number:($n|tonumber?), state:$st, review_decision:$rd, mergeable:$mg}' 2>/dev/null || echo 'null')"
  else
    pr_json="null"
  fi

  if [[ "$RETRIES" =~ ^[0-9]+$ ]]; then retries_json="$RETRIES"; else retries_json="null"; fi

  stale_json="$(jq -cn \
    --arg dp "$DEV_PID" --arg rp "$REVIEW_PID" \
    --argjson da "$([[ "$DEV_ALIVE" == "yes" ]] && echo true || echo false)" \
    --argjson ra "$([[ "$REVIEW_ALIVE" == "yes" ]] && echo true || echo false)" \
    --argjson sp "$STALE_PID" --argjson sr "$STALE_RUN" --argjson hs "$HEARTBEAT_STALE" \
    '{dev_pid:(if $dp=="" then null else ($dp|tonumber?) end), dev_pid_alive:$da,
      review_pid:(if $rp=="" then null else ($rp|tonumber?) end), review_pid_alive:$ra,
      stale_pid:$sp, stale_run:$sr, heartbeat_stale:$hs}' 2>/dev/null || echo 'null')"

  diag_json="$(printf '%s\n' "${DIAGNOSTICS[@]:-}" | jq -R -s -c 'split("\n") | map(select(length>0))' 2>/dev/null || echo '[]')"

  _ISSUE_JSON="$(jq -cn \
    --argjson issue "$ISSUE_NUMBER" \
    --arg title "$ISSUE_TITLE" \
    --arg issue_state "$ISSUE_STATE" \
    --arg project "$PROJECT_ID" \
    --arg repo "$REPO" \
    --arg status_label "$STATUS_LABEL" \
    --argjson labels "$labels_json" \
    --arg agent "$AGENT" \
    --arg run_id "$LATEST_RUN_ID" \
    --arg attempt "$LATEST_RUN_ATTEMPT" \
    --argjson last_result "$last_result_json" \
    --argjson pr "$pr_json" \
    --argjson retries "$retries_json" \
    --argjson max_retries "$MAX_RETRIES" \
    --argjson stale "$stale_json" \
    --arg next_action "$NEXT_ACTION" \
    --argjson diagnostics "$diag_json" \
    '{schema_version:1, issue:$issue, title:$title, issue_state:$issue_state,
      project:$project, repo:$repo, status_label:$status_label, labels:$labels,
      agent:$agent,
      run_id:(if $run_id=="" then null else $run_id end),
      attempt:(if $attempt=="" then null else ($attempt|tonumber?) end),
      last_result:$last_result, pr:$pr, retries:$retries, max_retries:$max_retries,
      stale:$stale, next_action:$next_action, diagnostics:$diagnostics}' 2>/dev/null || echo '{}')"
}

# Human-readable stale summary.
_stale_summary() {
  local -a parts=()
  [[ "$STALE_PID" == "true" ]] && parts+=("stale PID file (process dead)")
  [[ "$HEARTBEAT_STALE" == "true" ]] && parts+=("stale heartbeat")
  [[ "$STALE_RUN" == "true" ]] && parts+=("abandoned run (no end marker > ${STATUS_STALE_RUN_SECONDS}s)")
  if [[ ${#parts[@]} -eq 0 ]]; then echo "none"; else
    local IFS=', '; echo "${parts[*]}"; fi
}

_last_result_summary() {
  if [[ -z "$LAST_RESULT_RUN_ID" && -z "$LAST_RESULT_RC" ]]; then
    if [[ ${#DIAGNOSTICS[@]} -gt 0 ]] && printf '%s\n' "${DIAGNOSTICS[@]}" | grep -q 'agent-result.json'; then
      echo "unknown (agent-result.json unreadable)"
    else
      echo "none recorded"
    fi
  else
    local outcome
    if [[ "$LAST_RESULT_RC" == "0" ]]; then outcome="success"
    elif [[ -z "$LAST_RESULT_RC" ]]; then outcome="unknown"
    else outcome="failure"; fi
    echo "run=${LAST_RESULT_RUN_ID:-unknown}  rc=${LAST_RESULT_RC:-unknown}  ${outcome}  class=${LAST_RESULT_CLASS:-unknown}"
  fi
}

_pr_summary() {
  if [[ -n "$PR_NUMBER" ]]; then
    echo "#${PR_NUMBER}  state=${_PR_STATE:-UNKNOWN}  reviewDecision=${PR_REVIEW_DECISION:-NONE}  mergeable=${PR_MERGEABLE:-UNKNOWN}"
  else
    echo "<none linked>"
  fi
}

_emit_diagnostics_text() {
  [[ ${#DIAGNOSTICS[@]} -gt 0 ]] || return 0
  echo ""
  echo "── diagnostics ───────────────────────────────────────────────────"
  local _d
  for _d in "${DIAGNOSTICS[@]}"; do echo "  ! ${_d}"; done
}

# ---------------------------------------------------------------------------
# Renderers
# ---------------------------------------------------------------------------
_render_issue_text() {
  echo "════════════════════════════════════════════════════════════════"
  echo " issue #${ISSUE_NUMBER} — ${ISSUE_TITLE}"
  echo " project: ${PROJECT_ID}   repo: ${REPO}   state: ${ISSUE_STATE}"
  echo "════════════════════════════════════════════════════════════════"
  echo "labels:        ${LABELS:-<none>}"
  if [[ -n "$PR_NUMBER" ]]; then
    echo "open PR:       #${PR_NUMBER}  reviewDecision=${PR_REVIEW_DECISION:-NONE}  mergeable=${PR_MERGEABLE:-UNKNOWN}"
  else
    echo "open PR:       <none linked>"
  fi
  echo "lease (dev):   pid=${DEV_PID:-<none>}    alive=${DEV_ALIVE}"
  echo "lease (review):pid=${REVIEW_PID:-<none>} alive=${REVIEW_ALIVE}"
  echo "retry count:   ${RETRIES} / ${MAX_RETRIES}   (count_retries, the Step-4 stall gate input)"
  echo "agent:         ${AGENT}   (derived from status label / latest run)"
  echo "status label:  ${STATUS_LABEL}"
  echo "latest run:    ${LATEST_RUN_ID:-<none>}   attempt=${LATEST_RUN_ATTEMPT:-unknown}"
  echo "last result:   $(_last_result_summary)"
  echo "stale:         $(_stale_summary)"

  echo ""
  echo "── last run-ids (newest first) ───────────────────────────────────"
  _runs_out="$(_recent_runs)"
  if [[ -n "$_runs_out" ]]; then echo "$_runs_out"; else echo "  no runs recorded under ${RUNS_PARENT:-<run dir unresolved>}"; fi

  echo ""
  echo "── last drop reasons (latest review run) ─────────────────────────"
  _drops_out="$(_latest_review_drops)"
  if [[ -n "$_drops_out" ]]; then echo "$_drops_out"; else echo "  none recorded"; fi

  echo ""
  echo "── latest agent completion ───────────────────────────────────────"
  if [[ -n "$LAST_RESULT_RUN_ID" || -n "$LAST_RESULT_RC" ]]; then
    echo "  ${LAST_RESULT_ENDED}  ${LAST_RESULT_CLI}  mode=${LAST_RESULT_MODE}  rc=${LAST_RESULT_RC:-unknown}  class=${LAST_RESULT_CLASS:-unknown}  session=${LAST_RESULT_SESSION}"
  elif [[ ${#DIAGNOSTICS[@]} -gt 0 ]] && printf '%s\n' "${DIAGNOSTICS[@]}" | grep -q 'agent-result.json'; then
    echo "  unreadable result"
  else
    echo "  none recorded"
  fi
  echo "── last state transition event ───────────────────────────────────"
  _EVENT_FILE="${MERGEMILL_STATE_DIR:-${HOME:-/tmp}/.local/state/MergeMill-${PROJECT_ID:-unknown}}/state-events/issue-${ISSUE_NUMBER}.jsonl"
  if [[ -s "$_EVENT_FILE" ]] && command -v jq >/dev/null 2>&1; then
    tail -n 1 "$_EVENT_FILE" | jq -r '"  " + (.at // "") + "  " + (.remove // "") + " → " + (.add // "") + "  reason=" + (.reason // "unspecified") + (if (.run_id // "") != "" then "  run=" + .run_id else "" end) + (if (.attempt // "") != "" then "  attempt=" + .attempt else "" end)' 2>/dev/null || echo "  unreadable event record"
  else
    echo "  none recorded"
  fi

  _emit_diagnostics_text

  echo ""
  echo "── next dispatcher tick ──────────────────────────────────────────"
  echo "  ${NEXT_ACTION}"
  echo "════════════════════════════════════════════════════════════════"
}

_render_issue_compact() {
  echo "#${ISSUE_NUMBER}  ${ISSUE_TITLE}"
  echo "  status: ${STATUS_LABEL}   agent: ${AGENT}   issue state: ${ISSUE_STATE}"
  echo "  run: ${LATEST_RUN_ID:-<none>}   attempt: ${LATEST_RUN_ATTEMPT:-unknown}"
  echo "  last result: $(_last_result_summary)"
  echo "  PR: $(_pr_summary)"
  echo "  stale: $(_stale_summary)"
  echo "  next: ${NEXT_ACTION}"
  local _d
  for _d in "${DIAGNOSTICS[@]:-}"; do [[ -n "$_d" ]] && echo "  ! ${_d}"; done
  echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if [[ "$ALL_MODE" == "true" ]]; then
  # Same enumeration point as the Step-2 scan (list_new_issues): the abstract
  # itp_list_by_state contract (state=open, labels-AND="MergeMill") plus the
  # per-instance ISSUE_FILTER slice — so `--all` shows exactly the issues THIS
  # dispatcher instance would act on, not every MergeMill issue on the repo.
  if ! _ALL_JSON="$(itp_list_by_state open "MergeMill" "${ISSUE_SCAN_LIMIT:-100}" "$(issue_filter_fields "number,labels,title")" | issue_filter_apply 2>/dev/null)"; then
    echo "Error: failed to enumerate MergeMill issues (provider ${ISSUE_PROVIDER:-unknown}); check REPO, provider authentication, and ISSUE_FILTER." >&2
    exit 4
  fi
  if ! jq -e 'type=="array"' >/dev/null 2>&1 <<<"${_ALL_JSON:-}"; then
    echo "Error: issue enumeration returned non-array JSON." >&2
    exit 4
  fi
  # Read the sorted issue numbers into an array with a portable `while read`
  # loop rather than `mapfile` — macOS ships bash 3.2 as /bin/bash, where
  # `mapfile` (bash 4+) is undefined and would silently drop the whole list.
  _NUMS=()
  while IFS= read -r _n; do
    [[ -n "$_n" ]] && _NUMS+=("$_n")
  done < <(jq -r '.[].number' <<<"$_ALL_JSON" 2>/dev/null | sort -n)

  if [[ "$JSON_MODE" == "true" ]]; then
    _OBJS=()
    if [[ ${#_NUMS[@]} -gt 0 ]]; then
      for _n in "${_NUMS[@]}"; do
        _collect_issue "$_n"
        _build_issue_json
        _OBJS+=("$_ISSUE_JSON")
      done
      printf '%s\n' "${_OBJS[@]}" | jq -s \
        --arg project "$PROJECT_ID" --arg repo "$REPO" \
        --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')" \
        '{schema_version:1, project:$project, repo:$repo, generated_at:$generated_at, issues: .}'
    else
      jq -n --arg project "$PROJECT_ID" --arg repo "$REPO" \
        --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')" \
        '{schema_version:1, project:$project, repo:$repo, generated_at:$generated_at, issues: []}'
    fi
  else
    echo "════════════════════════════════════════════════════════════════"
    echo " MergeMill status — project: ${PROJECT_ID}   repo: ${REPO}   issues: ${#_NUMS[@]}"
    echo "════════════════════════════════════════════════════════════════"
    if [[ ${#_NUMS[@]} -eq 0 ]]; then
      echo "  no OPEN issues carry the \`MergeMill\` label."
    else
      for _n in "${_NUMS[@]}"; do
        _collect_issue "$_n"
        _render_issue_compact
      done
    fi
  fi
  exit 0
fi

# Single-issue mode.
_collect_issue "$ISSUE_NUMBER"
if [[ "$ISSUE_FOUND" != "true" ]]; then
  echo "Error: issue #${ISSUE_NUMBER} not found or unreadable — check REPO/PROJECT_ID and provider authentication." >&2
  exit 5
fi
if [[ "$JSON_MODE" == "true" ]]; then
  _build_issue_json
  printf '%s\n' "$_ISSUE_JSON"
else
  _render_issue_text
fi
