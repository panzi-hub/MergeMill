#!/bin/bash
# test-MergeMill-dev-terminal-completion.sh — regression tests for the
# successful-agent/no-new-PR terminal path and terminal-state precedence.
#
# A dev run may legitimately finish after another run merged the linked PR or
# closed the issue. That state must not be routed back to pending-dev or
# pending-review, regardless of exit status or stale open PRs.
#
# Run: bash tests/unit/test-MergeMill-dev-terminal-completion.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$PROJECT_ROOT/skills/MergeMill-dispatcher/scripts/MergeMill-dev.sh"
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

ok() { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }

HELPER_FILE="$TMPROOT/helper.sh"
awk '/^dev_issue_already_complete\(\) \{/,/^\}/' "$WRAPPER" >"$HELPER_FILE"
if [[ ! -s "$HELPER_FILE" ]]; then
  bad "dev_issue_already_complete helper is present"
  exit 1
fi

run_helper() {
  local scenario="$1"
  SCENARIO="$scenario" bash -c '
    set +e
    source "$1"
    itp_read_task() {
      case "${SCENARIO:-}" in
        read-fail) return 1 ;;
        closed) printf "%s\n" "{\"state\":\"CLOSED\"}" ;;
        *) printf "%s\n" "{\"state\":\"OPEN\"}" ;;
      esac
    }
    chp_pr_list() {
      case "${SCENARIO:-}" in
        merged) printf "%s\n" "[{\"number\":14,\"state\":\"MERGED\",\"mergedAt\":\"2026-10-03T05:36:46Z\",\"closingIssueNumbers\":[12]}]" ;;
        *) printf "%s\n" "[{\"number\":99,\"state\":\"OPEN\",\"mergedAt\":null,\"closingIssueNumbers\":[]}]" ;;
      esac
    }
    dev_issue_already_complete 12
  ' _ "$HELPER_FILE"
}

for scenario in closed merged; do
  if run_helper "$scenario" >/dev/null 2>&1; then
    ok "${scenario} issue state is terminal"
  else
    bad "${scenario} issue state is terminal"
  fi
done

for scenario in open read-fail; do
  if run_helper "$scenario" >/dev/null 2>&1; then
    bad "${scenario} state is not treated as complete"
  else
    ok "${scenario} state is not treated as complete"
  fi
done

if grep -q 'ALREADY_COMPLETE' "$WRAPPER" \
  && grep -q 'in-progress,pending-dev,pending-review,approved' "$WRAPPER"; then
  ok "cleanup clears stale pipeline labels for terminal completion"
else
  bad "cleanup clears stale pipeline labels for terminal completion"
fi

terminal_line=$(grep -n 'if \[\[ "\$ALREADY_COMPLETE" -eq 1' "$WRAPPER" | head -1 | cut -d: -f1)
pr_line=$(grep -n 'if \[\[ "\$PR_EXISTS" -gt 0' "$WRAPPER" | tail -1 | cut -d: -f1)
if [[ -n "$terminal_line" && -n "$pr_line" && "$terminal_line" -lt "$pr_line" ]]; then
  ok "terminal state wins before open-PR routing"
else
  bad "terminal state wins before open-PR routing"
fi

if grep -q 'Terminal state always wins over PR/exit routing' "$WRAPPER" \
  && grep -q 'Agent failed (exit' "$WRAPPER"; then
  ok "closed/merged state also suppresses failure retry routing"
else
  bad "closed/merged state also suppresses failure retry routing"
fi

if grep -q 'Push-hook failure guard' "$WRAPPER" \
  && grep -q 'do NOT retry the same push' "$WRAPPER"; then
  ok "agent prompt bounds push-hook retry behavior"
else
  bad "agent prompt bounds push-hook retry behavior"
fi

echo ""
echo "=== SUMMARY: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
