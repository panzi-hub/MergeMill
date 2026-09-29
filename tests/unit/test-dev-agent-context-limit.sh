#!/bin/bash
# test-dev-agent-context-limit.sh — bound untrusted Issue history before it is
# embedded in a dev-agent prompt. The provider read remains complete; only the
# prompt projection is intentionally bounded.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEV_WRAPPER="$PROJECT_ROOT/skills/MergeMill-dispatcher/scripts/MergeMill-dev.sh"

PASS=0
FAIL=0
ok() { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq is required"; exit 0; }

# Extract only the pure projection helper; sourcing the wrapper would start its
# normal config/auth lifecycle and is intentionally outside this unit test.
eval "$(awk '
  /^bound_agent_issue_context\(\) \{$/ { on=1 }
  on { print }
  on && /^\}$/ { exit }
' "$DEV_WRAPPER")"

fixture='{"title":"t","body":"BODY","state":"OPEN","labels":["MergeMill"],"comments":[{"id":1,"author":"old","authorKind":"human","body":"old-1","createdAt":"2026-01-01T00:00:00Z"},{"id":2,"author":"mid","authorKind":"human","body":"mid","createdAt":"2026-01-02T00:00:00Z"},{"id":3,"author":"new","authorKind":"human","body":"new","createdAt":"2026-01-03T00:00:00Z"}]}'

bounded=$(MERGEMILL_AGENT_CONTEXT_MAX_COMMENTS=2 \
  MERGEMILL_AGENT_CONTEXT_COMMENT_CHARS=3 \
  bound_agent_issue_context "$fixture")

[[ "$(jq -r '.body' <<<"$bounded")" == "BODY" ]] && ok "issue body is preserved" || bad "issue body is preserved"
[[ "$(jq '.comments | length' <<<"$bounded")" == "3" ]] && ok "truncation marker plus newest comments retained" || bad "comment count is bounded"
[[ "$(jq -r '.comments[0].body' <<<"$bounded")" == *"older Issue comments omitted"* ]] && ok "omission is explicit" || bad "omission marker missing"
[[ "$(jq -r '.comments[-1].body' <<<"$bounded")" == "new" ]] && ok "newest comment is retained" || bad "newest comment missing"
[[ "$(jq -r '.comments[1].body' <<<"$bounded")" == "mid" ]] && ok "second-newest comment is retained" || bad "second-newest comment missing"

long_body=$(jq -nc '{title:"t",body:("x" * 20),state:"OPEN",labels:[],comments:[]}' 2>/dev/null || true)
short_body=$(MERGEMILL_AGENT_CONTEXT_BODY_CHARS=5 bound_agent_issue_context "$long_body")
[[ "$(jq -r '.body' <<<"$short_body")" == xxxxx* ]] && ok "issue body has a per-field cap" || bad "issue body cap missing"

echo "DEV-CONTEXT-SUMMARY pass=$PASS fail=$FAIL"
[[ "$FAIL" -eq 0 ]]
