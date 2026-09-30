#!/bin/bash
# test-setup-live-runner.sh — [INV-77] rule 4: tests/e2e/setup-live-runner.sh
# is the ONE standard live-runner onboarding form — hermetic unit tests.
#
# Fixture: a local "origin" repo carrying tests/e2e/e2e.conf.example on main,
# cloned so origin/main exists; the script is copied into the clone (no repo
# tree → the supported-CLI set falls back to the builtin list, which the test
# pins). Fork safety is proven STRUCTURALLY: the clone's working-tree copy of
# the template is poisoned with a marker, and the generated conf + saved
# template must carry the ORIGIN-MAIN marker instead — the script never reads
# the working tree ([INV-77] rule 5).
#
# Also pins the canonical-path contract across all three artifacts: the
# script's default --conf path, ci.yml's live-smoke preflight path, and the
# path documented in tests/e2e/e2e.conf.example must be the SAME string.
#
# Run: bash tests/unit/test-setup-live-runner.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SETUP="$PROJECT_ROOT/tests/e2e/setup-live-runner.sh"
CI_YML="$PROJECT_ROOT/.github/workflows/ci.yml"
EXAMPLE="$PROJECT_ROOT/tests/e2e/e2e.conf.example"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_rc()     { local d="$1" e="$2" a="$3"; if [[ "$e" == "$a" ]]; then echo -e "  ${GREEN}PASS${NC}: $d"; PASS=$((PASS+1)); else echo -e "  ${RED}FAIL${NC}: $d (want rc=$e got rc=$a)"; FAIL=$((FAIL+1)); fi; }
assert_eq()     { local d="$1" e="$2" a="$3"; if [[ "$e" == "$a" ]]; then echo -e "  ${GREEN}PASS${NC}: $d"; PASS=$((PASS+1)); else echo -e "  ${RED}FAIL${NC}: $d (want '$e' got '$a')"; FAIL=$((FAIL+1)); fi; }
assert_has()    { local d="$1" n="$2" h="$3"; if [[ "$h" == *"$n"* ]]; then echo -e "  ${GREEN}PASS${NC}: $d"; PASS=$((PASS+1)); else echo -e "  ${RED}FAIL${NC}: $d (missing '$n')"; FAIL=$((FAIL+1)); fi; }
assert_not_has(){ local d="$1" n="$2" h="$3"; if [[ "$h" != *"$n"* ]]; then echo -e "  ${GREEN}PASS${NC}: $d"; PASS=$((PASS+1)); else echo -e "  ${RED}FAIL${NC}: $d (unexpected '$n')"; FAIL=$((FAIL+1)); fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-setup-live-runner.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# --- fixture: origin repo with the template on main + a clone ---------------
ORIGIN="$TMP/origin"
mkdir -p "$ORIGIN/tests/e2e"
git init -q "$ORIGIN"
printf '# smoke matrix template — MARKER:FROM-ORIGIN-MAIN\nclaude-bedrock|claude|sonnet|export CLAUDE_CODE_USE_BEDROCK=1\n' \
  > "$ORIGIN/tests/e2e/e2e.conf.example"
git -C "$ORIGIN" add -A
git -C "$ORIGIN" -c user.name=t -c user.email=t@example.com commit -qm template
git -C "$ORIGIN" branch -M main
CLONE="$TMP/clone"
git clone -q "$ORIGIN" "$CLONE"
mkdir -p "$CLONE/tests/e2e"
cp "$SETUP" "$CLONE/tests/e2e/"
# Fork-safety probe: poison the clone's WORKING-TREE template copy.
printf '# MARKER:WORKING-TREE-POISON\n' > "$CLONE/tests/e2e/e2e.conf.example"

SHIM="$TMP/shim"
mkdir -p "$SHIM"
mkcli() { printf '#!/bin/sh\nexit 0\n' > "$SHIM/$1"; chmod +x "$SHIM/$1"; }
mkcli claude
mkcli codex

echo ""
echo "=== TC-SLR-001..003: probe + generate + write + fork-safe seed (claude+codex) ==="
CLONE_CONF="$TMP/conf/e2e.conf"
out=$(cd "$CLONE" && PATH="$SHIM:$PATH" bash tests/e2e/setup-live-runner.sh --conf "$CLONE_CONF" 2>&1); rc=$?
assert_rc    "TC-SLR-001a onboarding rc" 0 "$rc"
conf=$(cat "$CLONE_CONF" 2>/dev/null || echo "")
assert_has     "TC-SLR-001b claude entry generated"    "claude-default|claude||" "$conf"
assert_has     "TC-SLR-001c codex entry generated"     "codex-default|codex||"   "$conf"
assert_not_has "TC-SLR-001d undetected CLI absent"     "kiro-default"            "$conf"
assert_has     "TC-SLR-002a template saved beside conf" "MARKER:FROM-ORIGIN-MAIN" "$(cat "$TMP/conf/e2e.conf.example" 2>/dev/null || echo '')"
assert_not_has "TC-SLR-002b saved template is NOT the poisoned working-tree copy" "MARKER:WORKING-TREE-POISON" "$(cat "$TMP/conf/e2e.conf.example" 2>/dev/null || echo '')"
assert_not_has "TC-SLR-002c generated conf is NOT from the working tree" "MARKER:WORKING-TREE-POISON" "$conf"
assert_has     "TC-SLR-003 doctor summary present"      "Live runner onboarded"   "$out"

echo ""
echo "=== TC-SLR-004: every generated entry is exactly 4 |-fields (harness contract) ==="
bad_fields=$(awk -F'|' '/^[[:space:]]*[^#[:space:]]/ && NF != 4 { c++ } END { print c + 0 }' "$CLONE_CONF")
assert_eq "TC-SLR-004 malformed entry count" "0" "$bad_fields"

echo ""
echo "=== TC-SLR-005: canonical-path contract (script == ci.yml == e2e.conf.example) ==="
path_ci=$(grep -oE '\$HOME/\.config/[^"]*e2e\.conf' "$CI_YML" | head -1)
path_script=$(grep -oE '\$\{HOME\}/\.config/[^"]*e2e\.conf' "$SETUP" | head -1 | sed 's/\${HOME}/\$HOME/')
path_example=$(grep -oE '\$HOME/\.config/[^"]*e2e\.conf' "$EXAMPLE" | head -1)
assert_eq "TC-SLR-005a script default == ci.yml preflight path"  "$path_ci"      "$path_script"
assert_eq "TC-SLR-005b example documented path == ci.yml path"   "$path_ci"      "$path_example"
assert_not_has "TC-SLR-005c path is non-empty (fixtures actually matched)" "NONE" "${path_ci:-NONE}"

echo ""
echo "=== TC-SLR-006..009: clobber guard / --force / --dry-run / bad --ref ==="
out=$(cd "$CLONE" && PATH="$SHIM:$PATH" bash tests/e2e/setup-live-runner.sh --conf "$CLONE_CONF" 2>&1); rc=$?
assert_rc "TC-SLR-006 existing matrix refuses clobber" 3 "$rc"
out=$(cd "$CLONE" && PATH="$SHIM:$PATH" bash tests/e2e/setup-live-runner.sh --conf "$CLONE_CONF" --force 2>&1); rc=$?
assert_rc "TC-SLR-007 --force replaces" 0 "$rc"
DRY_CONF="$TMP/dry/e2e.conf"
out=$(cd "$CLONE" && PATH="$SHIM:$PATH" bash tests/e2e/setup-live-runner.sh --dry-run --conf "$DRY_CONF" 2>&1); rc=$?
assert_rc    "TC-SLR-008a --dry-run rc" 0 "$rc"
assert_has   "TC-SLR-008b --dry-run prints entries" "claude-default|claude||" "$out"
[[ -e "$DRY_CONF" ]] && { echo -e "  ${RED}FAIL${NC}: TC-SLR-008c --dry-run must not write"; FAIL=$((FAIL+1)); } || { echo -e "  ${GREEN}PASS${NC}: TC-SLR-008c --dry-run wrote nothing"; PASS=$((PASS+1)); }
out=$(cd "$CLONE" && PATH="$SHIM:$PATH" bash tests/e2e/setup-live-runner.sh --conf "$TMP/x.conf" --ref refs/heads/nonexistent 2>&1); rc=$?
assert_rc    "TC-SLR-009a unknown --ref fails loudly" 1 "$rc"
assert_has   "TC-SLR-009b error names the template fetch" "template fetch failed" "$out"

echo ""
echo "=== TC-SLR-010: no supported CLI on the box → loud rc 1 ==="
out=$(cd "$CLONE" && bash tests/e2e/setup-live-runner.sh --conf "$TMP/none.conf" 2>&1); rc=$?
assert_rc  "TC-SLR-010a rc" 1 "$rc"
assert_has "TC-SLR-010b loud remediation" "no supported agent CLI" "$out"

echo ""
echo "=== TC-SLR-011: kiro entry pins the safe workspace-agent default ==="
KSHIM="$TMP/kshim"; mkdir -p "$KSHIM"
mkcli_dir() { printf '#!/bin/sh\nexit 0\n' > "$1/$2"; chmod +x "$1/$2"; }
mkcli_dir "$KSHIM" kiro
out=$(cd "$CLONE" && PATH="$KSHIM:$PATH" bash tests/e2e/setup-live-runner.sh --conf "$TMP/k.conf" 2>&1); rc=$?
assert_rc  "TC-SLR-011a rc" 0 "$rc"
assert_has "TC-SLR-011b kiro entry carries KIRO_AGENT_NAME default" \
  'export KIRO_AGENT_NAME="${KIRO_AGENT_NAME:-default}"' "$(cat "$TMP/k.conf")"

echo ""
echo "=== TC-SLR-012: machine Bedrock env honored for the claude entry ==="
BSHIM="$TMP/bshim"; mkdir -p "$BSHIM"
mkcli_dir "$BSHIM" claude
out=$(cd "$CLONE" && PATH="$BSHIM:$PATH" CLAUDE_CODE_USE_BEDROCK=1 AWS_REGION=us-east-2 \
  bash tests/e2e/setup-live-runner.sh --conf "$TMP/b.conf" 2>&1); rc=$?
assert_rc  "TC-SLR-012a rc" 0 "$rc"
assert_has "TC-SLR-012b claude entry routes Bedrock with the box's region" \
  'export CLAUDE_CODE_USE_BEDROCK=1; export AWS_REGION="us-east-2"' "$(cat "$TMP/b.conf")"

echo ""
echo "========================================"
echo -e "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "========================================"

[[ "$FAIL" -eq 0 ]]
