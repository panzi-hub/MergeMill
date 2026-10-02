#!/usr/bin/env bash
# recover.sh — conservative operator recovery helper.
# It never mutates GitHub unless --apply is explicitly supplied.
set -euo pipefail
SELF="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd)"
issue=""; apply=0; project=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) apply=1; shift ;;
    --project) project="${2:?--project requires a value}"; shift 2 ;;
    -h|--help) echo "Usage: $0 <issue> [--apply] [--project ID]"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) [[ -z "$issue" ]] || { echo "unexpected argument: $1" >&2; exit 2; }; issue="$1"; shift ;;
  esac
done
[[ "$issue" =~ ^[0-9]+$ ]] || { echo "issue must be numeric" >&2; exit 2; }
status_args=("$issue")
[[ -n "$project" ]] && status_args+=(--project "$project")
"$SCRIPT_DIR/status.sh" "${status_args[@]}"

if (( ! apply )); then
  echo "dry-run: no state was changed" >&2
  exit 0
fi

# The only automatic recovery currently permitted is a stale dev handoff:
# in-progress + dead lease + linked PR -> pending-review. Every other state is
# refused rather than guessed, so this tool cannot manufacture progress.
if command -v realpath >/dev/null 2>&1; then
  LIB_DIR="$(cd "$(dirname "$(realpath "$SCRIPT_DIR/recover.sh")")" && pwd)"
else
  LIB_DIR="$SCRIPT_DIR"
fi
source "${LIB_DIR}/lib-config.sh"
load_MergeMill_conf "$SCRIPT_DIR" || true
[[ -n "$project" ]] && PROJECT_ID="$project"
for _req in REPO REPO_OWNER PROJECT_ID; do
  [[ -n "${!_req:-}" ]] || { echo "refusing recovery: ${_req} is unset" >&2; exit 1; }
done
source "${LIB_DIR}/lib-dispatch.sh"

_RECOVER_JSON="$(itp_read_task "$issue" state,labels 2>/dev/null || echo '{}')"
_RECOVER_STATE="$(jq -r '.state // "UNKNOWN"' <<<"$_RECOVER_JSON")"
_RECOVER_LABELS="$(jq -r '[.labels[]] | join(" ")' <<<"$_RECOVER_JSON" 2>/dev/null || echo '')"
if [[ " $_RECOVER_LABELS " != *" in-progress "* ]]; then
  echo "refusing recovery: issue is not in-progress" >&2
  exit 1
fi
if pid_alive issue "$issue" >/dev/null 2>&1; then
  echo "refusing recovery: dev lease is still alive" >&2
  exit 1
fi
_RECOVER_PR="$(fetch_pr_for_issue "$issue" "number,state" 2>/dev/null || true)"
_RECOVER_PR_NUMBER="$(jq -r '.number // empty' <<<"$_RECOVER_PR" 2>/dev/null || true)"
[[ -n "$_RECOVER_PR_NUMBER" ]] || { echo "refusing recovery: no linked PR" >&2; exit 1; }
[[ "$_RECOVER_STATE" == "OPEN" ]] || { echo "refusing recovery: issue is terminal ($_RECOVER_STATE)" >&2; exit 1; }

if itp_transition_state "$issue" "in-progress" "pending-review" "manual recovery: dead dev lease with linked PR"; then
  echo "recovery applied: issue #${issue} moved in-progress -> pending-review (PR #${_RECOVER_PR_NUMBER})"
else
  echo "recovery failed: transition was not applied" >&2
  exit 1
fi
