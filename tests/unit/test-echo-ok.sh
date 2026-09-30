#!/bin/bash
# test-echo-ok.sh — Unit tests for scripts/echo-ok.sh (issue #8).
#
# Acceptance: the helper exists, is executable, prints exactly "ok", and
# exits 0 both via `bash <path>` and direct execution.
# See docs/test-cases/issue-8-echo-ok.md (TC-EOK-NNN).
#
# Run: bash tests/unit/test-echo-ok.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELPER="$PROJECT_ROOT/scripts/echo-ok.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected='$expected', actual='$actual')"
    FAIL=$((FAIL + 1))
  fi
}

echo ""
echo "=== TC-EOK-001: helper exists ==="
assert_eq "scripts/echo-ok.sh resolves to a regular file" "yes" "$([[ -f "$HELPER" ]] && echo yes || echo no)"

echo ""
echo "=== TC-EOK-002: helper is executable ==="
assert_eq "scripts/echo-ok.sh has the executable bit" "yes" "$([[ -x "$HELPER" ]] && echo yes || echo no)"

echo ""
echo "=== TC-EOK-003: bash <path> prints ok and exits 0 ==="
out="$(bash "$HELPER")"
rc=$?
assert_eq "bash scripts/echo-ok.sh prints 'ok'" "ok" "$out"
assert_eq "bash scripts/echo-ok.sh exits 0" "0" "$rc"

echo ""
echo "=== TC-EOK-004: direct execution honors the shebang ==="
out="$("$HELPER")"
rc=$?
assert_eq "direct execution prints 'ok'" "ok" "$out"
assert_eq "direct execution exits 0" "0" "$rc"

echo ""
echo "-------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
