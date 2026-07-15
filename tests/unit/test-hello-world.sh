#!/bin/bash
# test-hello-world.sh — Unit tests for scripts/hello.sh (Issue #1)
#
# Run: bash tests/unit/test-hello-world.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELLO_SCRIPT="$PROJECT_ROOT/scripts/hello.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected='$expected'"
    echo "      actual=  '$actual'"
    FAIL=$((FAIL + 1))
  fi
}

assert_rc() {
  local desc="$1" expected_rc="$2" actual_rc="$3"
  if [[ "$expected_rc" == "$actual_rc" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected_rc=$expected_rc actual_rc=$actual_rc)"
    FAIL=$((FAIL + 1))
  fi
}

# ===========================================================================
# TC-HELLO-001: Execute script, verify output and exit code
# ===========================================================================
echo ""
echo "=== TC-HELLO-001: Script outputs correct message and exits 0 ==="
echo ""

OUT1=$(bash "$HELLO_SCRIPT" 2>&1); RC1=$?
assert_eq "TC-HELLO-001a output is 'Hello from MergeMill!'" "Hello from MergeMill!" "$OUT1"
assert_rc "TC-HELLO-001b exit code is 0" "0" "$RC1"

# ===========================================================================
# TC-HELLO-002: Verify shebang
# ===========================================================================
echo ""
echo "=== TC-HELLO-002: Script has correct shebang ==="
echo ""

SHEBANG=$(head -1 "$HELLO_SCRIPT")
assert_eq "TC-HELLO-002 shebang is '#!/bin/bash'" "#!/bin/bash" "$SHEBANG"

# ===========================================================================
# TC-HELLO-003: Verify set -euo pipefail
# ===========================================================================
echo ""
echo "=== TC-HELLO-003: Script has 'set -euo pipefail' ==="
echo ""

SET_LINE=$(head -2 "$HELLO_SCRIPT" | tail -1)
assert_eq "TC-HELLO-003 second line is 'set -euo pipefail'" "set -euo pipefail" "$SET_LINE"

# ===========================================================================
# TC-HELLO-004: Verify script is executable
# ===========================================================================
echo ""
echo "=== TC-HELLO-004: Script is executable ==="
echo ""

if [[ -x "$HELLO_SCRIPT" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-HELLO-004 script is executable"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-HELLO-004 script is not executable"
  FAIL=$((FAIL + 1))
fi

# ===========================================================================
# TC-HELLO-005: Output has no extra whitespace
# ===========================================================================
echo ""
echo "=== TC-HELLO-005: Output has no extra whitespace ==="
echo ""

OUT5=$(bash "$HELLO_SCRIPT")
TRIMMED=$(echo "$OUT5" | xargs)
assert_eq "TC-HELLO-005 trimmed output matches original (no extra whitespace)" "$OUT5" "$TRIMMED"

echo ""
echo "============================================"
echo -e "  Passed: ${GREEN}${PASS}${NC}   Failed: ${RED}${FAIL}${NC}"
echo "============================================"

[[ "$FAIL" -eq 0 ]]
