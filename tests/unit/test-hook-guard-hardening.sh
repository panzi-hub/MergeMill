#!/bin/bash
# test-hook-guard-hardening.sh — [INV-122] hook guard hardening regression tests
#
# Closes the unintentional-bypass vectors in the blocking-hook layer that do
# NOT require adversarial intent (agents habitually emit these forms):
#   1. PATH-qualified interpreters: `/usr/bin/git push origin main`
#   2. command substitution / subshells: `$(git push …)`, backticks
#   3. wrapper `-c` payloads: `bash -c "git push origin main"` (nested ≤ 3)
# and pins the fail-closed parse gate: both blocking hooks MUST exit 2 (the
# only blocking rc for a PreToolUse hook) when the payload cannot be parsed
# (jq missing/broken or malformed JSON) — a bare parse death under `set -e`
# exits 1, which PreToolUse treats as a NON-blocking error, i.e. fail-open.
#
# Run: bash tests/unit/test-hook-guard-hardening.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/MergeMill-common/hooks/lib.sh"
HOOK_PUSH="$PROJECT_ROOT/skills/MergeMill-common/hooks/block-push-to-main.sh"
HOOK_COMMIT="$PROJECT_ROOT/skills/MergeMill-common/hooks/block-commit-outside-worktree.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# shellcheck source=/dev/null
source "$LIB"

assert_match() {
  local desc="$1" operation="$2" command="$3"
  if is_git_command "$operation" "$command"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    ((PASS++))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected is_git_command $operation '$command' to match)"
    ((FAIL++))
  fi
}

assert_no_match() {
  local desc="$1" operation="$2" command="$3"
  if ! is_git_command "$operation" "$command"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    ((PASS++))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected is_git_command $operation '$command' NOT to match)"
    ((FAIL++))
  fi
}

assert_hook_rc() {
  local desc="$1" expected_rc="$2" hook="$3" payload="$4"
  local rc
  printf '%s' "$payload" | bash "$hook" >/dev/null 2>&1
  rc=$?
  if [[ "$rc" == "$expected_rc" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc (rc=$rc)"
    ((PASS++))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected rc=$expected_rc, got rc=$rc)"
    ((FAIL++))
  fi
}

# Run is_git_command in a FRESH bash under `timeout` — the substitution loops
# added for the `-c` payload scan must satisfy the same termination guarantee
# as the #266 quote-strip loops (#266's hazard class), so the call must be in
# a separate, externally-killable process.
assert_bounded() {
  local desc="$1" operation="$2" command="$3"
  local rc
  # shellcheck disable=SC2016
  timeout 2 bash -c '
    source "$1"
    is_git_command "$2" "$3"
  ' _ "$LIB" "$operation" "$command" >/dev/null 2>&1
  rc=$?
  if [[ $rc -ne 124 ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc (terminated, rc=$rc)"
    ((PASS++))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (TIMED OUT — infinite loop; rc=124)"
    ((FAIL++))
  fi
}

echo ""
echo "=== TC-HGH-001..009: wrapper forms must still be recognized [INV-122] ==="
echo ""

assert_match "TC-HGH-001 PATH-qualified interpreter"        push   "/usr/bin/git push origin main"
assert_match "TC-HGH-002 /usr/local/bin/git commit"         commit "/usr/local/bin/git commit -m x"
assert_match "TC-HGH-003 command substitution"              push   'out=$(git push origin main)'
assert_match "TC-HGH-004 backtick command substitution"     push   'echo `git push origin main`'
assert_match "TC-HGH-005 bash -c dq payload"                push   'bash -c "git push origin main"'
assert_match "TC-HGH-006 sh -c sq payload"                  commit "sh -c 'git commit -m x'"
assert_match "TC-HGH-007 absolute bash -c"                  push   '/bin/bash -c "git push origin main"'
assert_match "TC-HGH-008 env-prefixed bash -c"              push   'env FOO=1 bash -c "git push origin main"'
assert_match "TC-HGH-009 payload containing separators"     push   'bash -c "cd /repo && git push origin main"'

echo ""
echo "=== TC-HGH-010..015: quoted-mention semantics preserved (no false positives) ==="
echo ""

assert_no_match "TC-HGH-010 gh body mention stays inert"    push   'gh issue create --body "see git push docs"'
assert_no_match "TC-HGH-011 echo quoted stays inert"        push   'echo "git push"'
assert_no_match "TC-HGH-012 non-shell -c not unwrapped"     push   'somecmd -c "see git push docs"'
assert_no_match "TC-HGH-013 bash -c without git"            push   'bash -c "echo hello"'
assert_no_match "TC-HGH-014 subcommand substring"           push   "git push-something"
assert_no_match "TC-HGH-015 wrong operation"                commit "git push origin main"

echo ""
echo "=== TC-HGH-016..017: nested -c payload (depth 2) still terminates and matches ==="
echo ""

assert_match "TC-HGH-016 nested bash -c via dq escapes"     push   'bash -c "bash -c \"git push origin main\""'
assert_bounded "TC-HGH-017 nested glob payload terminates"  push   'bash -c "bash -c \"git push [x] * ?\""'

echo ""
echo "=== TC-HGH-018..023: blocking hooks fail CLOSED on unparseable payloads [INV-122] ==="
echo ""

# Baseline (jq on PATH): real gate behavior unchanged.
assert_hook_rc "TC-HGH-018 push to main blocked (jq present)"        2 "$HOOK_PUSH"   '{"tool_input":{"command":"git push origin main"}}'
assert_hook_rc "TC-HGH-019 feature push allowed (jq present)"        0 "$HOOK_PUSH"   '{"tool_input":{"command":"git push origin feat/x"}}'

# jq unavailable → must BLOCK (exit 2), never fail open (exit 0) or die rc 1.
# A shim dir with a failing `jq` is PREPENDED to PATH: it exercises the exact
# parse-gate branch (`parse_command` non-zero → exit 2) portably — a true
# PATH subtraction cannot hide jq on usrmerged systems (/bin → /usr/bin).
_SHIM="$(mktemp -d)"
printf '#!/bin/sh\nexit 127\n' > "$_SHIM/jq"
chmod +x "$_SHIM/jq"
printf '%s' '{"tool_input":{"command":"git push origin main"}}' \
  | PATH="$_SHIM:$PATH" bash "$HOOK_PUSH" >/dev/null 2>&1
rc=$?
if [[ $rc -eq 2 ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-HGH-020 push hook fails CLOSED with jq unavailable (rc=2)"
  ((PASS++))
else
  echo -e "  ${RED}FAIL${NC}: TC-HGH-020 push hook with jq unavailable expected rc=2 (fail-closed), got rc=$rc"
  ((FAIL++))
fi
printf '%s' '{"tool_input":{"command":"git commit -m x"}}' \
  | PATH="$_SHIM:$PATH" bash "$HOOK_COMMIT" >/dev/null 2>&1
rc=$?
if [[ $rc -eq 2 ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-HGH-021 commit hook fails CLOSED with jq unavailable (rc=2)"
  ((PASS++))
else
  echo -e "  ${RED}FAIL${NC}: TC-HGH-021 commit hook with jq unavailable expected rc=2 (fail-closed), got rc=$rc"
  ((FAIL++))
fi
rm -rf "$_SHIM"

# Malformed JSON with jq present → parse fails → fail CLOSED (exit 2).
assert_hook_rc "TC-HGH-022 push hook blocks malformed JSON"          2 "$HOOK_PUSH"   'not-json-at-all'
assert_hook_rc "TC-HGH-023 commit hook blocks malformed JSON"        2 "$HOOK_COMMIT" '{"tool_input": [broken'

echo ""
echo "========================================"
echo -e "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "========================================"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
