#!/bin/bash
# test-scripts-symlink.sh — lock the repository's top-level `scripts/` symlink
# contract (issue #26).
#
# `scripts` is committed as a symlink to skills/MergeMill-dispatcher/scripts
# (git tree mode 120000). Every dispatcher entry point is invoked as
# "$PROJECT_DIR/scripts/<name>.sh", so if the symlink is replaced by a real
# directory or repointed, those invocation paths break silently — nothing in
# CI catches it today. This test fails loudly instead.
#
# Hermetic: reads the repo tree read-only; negative fixtures live in a single
# mktemp dir removed on EXIT. No network, no writes outside the temp dir.
#
# Run: bash tests/unit/test-scripts-symlink.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

SCRIPTS_REL="scripts"
EXPECTED_TARGET_REL="skills/MergeMill-dispatcher/scripts"
ENTRY_POINT="dispatcher-tick.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

PASS=0
FAIL=0

# check_scripts_symlink <project_root>
#   0 when <root>/scripts is a symlink resolving to
#   <root>/skills/MergeMill-dispatcher/scripts and <root>/scripts/dispatcher-tick.sh
#   is readable; non-zero otherwise.
check_scripts_symlink() {
  local root="$1"
  local scripts="$root/$SCRIPTS_REL"
  local expected="$root/$EXPECTED_TARGET_REL"
  local resolved expected_resolved

  # 1. Must be a symlink (lstat), not a regular directory or file.
  [[ -L "$scripts" ]] || return 1

  # 2. Must resolve to the expected directory. `cd -P` follows the link and
  #    yields a physical path, so a relative or an absolute readlink value
  #    (and multi-hop chains) all normalize to the same answer.
  resolved="$(cd "$scripts" 2>/dev/null && pwd -P)" || return 1
  expected_resolved="$(cd "$expected" 2>/dev/null && pwd -P)" || return 1
  [[ "$resolved" == "$expected_resolved" ]] || return 1

  # 3. The known entry point must be readable through the link.
  [[ -r "$scripts/$ENTRY_POINT" ]] || return 1
}

# ---------------------------------------------------------------------------
echo "=== TC-SYMLINK-001: scripts/ is a symlink to skills/MergeMill-dispatcher/scripts ==="
# ---------------------------------------------------------------------------
if check_scripts_symlink "$PROJECT_ROOT"; then
  echo -e "  ${GREEN}PASS${NC}: scripts -> skills/MergeMill-dispatcher/scripts, dispatcher-tick.sh readable"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: scripts/ does not satisfy the dispatcher symlink contract:" >&2
  echo "      -L '$PROJECT_ROOT/scripts': $( [[ -L "$PROJECT_ROOT/scripts" ]] && echo yes || echo no )" >&2
  echo "      readlink: $(readlink "$PROJECT_ROOT/scripts" 2>/dev/null || echo '<not-a-symlink>')" >&2
  echo "      -r '$PROJECT_ROOT/scripts/$ENTRY_POINT': $( [[ -r "$PROJECT_ROOT/scripts/$ENTRY_POINT" ]] && echo yes || echo no )" >&2
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# Negative fixtures. Same predicate, deliberately broken roots — proves the
# check discriminates instead of trivially succeeding.
# ---------------------------------------------------------------------------
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

echo ""
echo "=== TC-SYMLINK-002: negative — scripts/ replaced by a regular directory ==="
DIR_ROOT="$TMPROOT/regular-dir"
mkdir -p "$DIR_ROOT/$SCRIPTS_REL" "$DIR_ROOT/$EXPECTED_TARGET_REL"
if check_scripts_symlink "$DIR_ROOT"; then
  echo -e "  ${RED}FAIL${NC}: predicate accepted a regular directory as scripts/" >&2
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: predicate rejects a regular directory (regular dir no longer silently accepted)"
  PASS=$((PASS + 1))
fi

echo ""
echo "=== TC-SYMLINK-003: negative — scripts/ symlink repointed elsewhere ==="
REPOINT_ROOT="$TMPROOT/repointed"
mkdir -p "$REPOINT_ROOT/$EXPECTED_TARGET_REL" "$TMPROOT/repointed-other"
ln -s "$TMPROOT/repointed-other" "$REPOINT_ROOT/$SCRIPTS_REL"
if check_scripts_symlink "$REPOINT_ROOT"; then
  echo -e "  ${RED}FAIL${NC}: predicate accepted a repointed scripts/ symlink" >&2
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: predicate rejects a symlink that does not resolve to the dispatcher scripts dir"
  PASS=$((PASS + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Results ==="
echo -e "Total: $((PASS + FAIL))  ${GREEN}Passed: $PASS${NC}  ${RED}Failed: $FAIL${NC}"

[[ "$FAIL" -eq 0 ]]
