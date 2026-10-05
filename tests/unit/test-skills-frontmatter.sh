#!/bin/bash
# test-skills-frontmatter.sh — lock the skills/*/SKILL.md frontmatter contract (#27).
#
# Every skill distributed via `npx skills add panzi-hub/MergeMill` depends on
# its SKILL.md YAML frontmatter being discoverable by skills.sh / Agent CLIs:
# `name` must equal the skill directory basename and `description` must be
# non-empty. Before this test nothing under tests/unit/ parsed frontmatter, so
# a malformed field was only surfaced at install time.
#
# This test enumerates <repo-root>/skills/*/SKILL.md, asserts the contract on
# each, and drives the same validator against four mktemp-scoped negative
# fixtures (no frontmatter / name mismatch / empty inline description / empty
# block-scalar description).
#
# Read-only against the repo tree; all fixtures live under a fresh mktemp -d,
# so it is safe to run concurrently with any sibling test (no SERIAL_TESTS
# entry needed — see tests/unit/README.md).
#
# Run: bash tests/unit/test-skills-frontmatter.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILLS_DIR="$PROJECT_ROOT/skills"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

report() {
  local desc="$1" rc="$2"
  if [[ "$rc" -eq 0 ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    FAIL=$((FAIL + 1))
  fi
}

# extract_frontmatter FILE
# Emits the frontmatter body (lines between the opening and closing `---`) and
# returns 0. Returns 1 if line 1 isn't `---` or no later standalone `---` exists.
extract_frontmatter() {
  local file="$1" line n=0
  [[ -f "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    if [[ $n -eq 1 ]]; then
      [[ "$line" == "---" ]] || return 1
      continue
    fi
    [[ "$line" == "---" ]] && return 0
    printf '%s\n' "$line"
  done < "$file"
  return 1
}

# frontmatter_scalar BLOCK KEY — prints the trimmed inline scalar for KEY
# (e.g. `name: foo` -> `foo`); empty output if absent or empty.
frontmatter_scalar() {
  local block="$1" key="$2"
  printf '%s\n' "$block" | awk -v k="$key" '
    index($0, k ":") == 1 {
      v = substr($0, length(k) + 2)
      sub(/^[[:space:]]+/, "", v)
      sub(/[[:space:]]+$/, "", v)
      print v
      exit
    }'
}

# frontmatter_description_nonempty BLOCK — rc 0 iff `description:` is present
# with a non-empty value. Handles both inline scalars and YAML block scalars
# (`>` / `|` variants), whose content is on the following indented lines.
frontmatter_description_nonempty() {
  local block="$1"
  printf '%s\n' "$block" | awk '
    BEGIN { found = 0; pending = 0; nonempty = 0 }
    found && pending {
      if ($0 ~ /^[[:space:]]+[^[:space:]]/) { nonempty = 1 }
      next
    }
    index($0, "description:") == 1 {
      found = 1
      v = substr($0, 13)
      sub(/^[[:space:]]+/, "", v)
      sub(/[[:space:]]+$/, "", v)
      if (v ~ /^[>|]/) { pending = 1 }
      else if (v != "") { nonempty = 1 }
      next
    }
    END { exit ((found && nonempty) ? 0 : 1) }
  '
}

# validate_skill_dir DIR — runs the full contract against DIR/SKILL.md,
# printing one PASS/FAIL line per assertion. Returns 0 iff all assertions pass.
validate_skill_dir() {
  local dir="$1"
  local md="$dir/SKILL.md"
  local label
  label="$(basename "$dir")"
  local ok=0 rc fm name=""

  if [[ ! -f "$md" ]]; then
    report "$label: SKILL.md exists" 1
    return 1
  fi

  fm="$(extract_frontmatter "$md")"; rc=$?
  report "$label: frontmatter opens with --- and closes with ---" "$rc"
  [[ $rc -eq 0 ]] || ok=1

  if [[ $rc -eq 0 ]]; then
    name="$(frontmatter_scalar "$fm" name)"
  fi
  if [[ -n "$name" && "$name" == "$label" ]]; then
    report "$label: name '$name' equals directory basename" 0
  else
    report "$label: name is non-empty and equals directory basename (got '${name:-<empty>}', want '$label')" 1
    ok=1
  fi

  if [[ $rc -eq 0 ]] && frontmatter_description_nonempty "$fm"; then
    report "$label: description is present and non-empty" 0
  else
    report "$label: description is present and non-empty" 1
    ok=1
  fi

  return $ok
}

# run_negative_fixture ID DESC DIR FRAGMENT — asserts the validator REJECTS DIR
# and that the named failure fragment appears in its output. Runs in a command
# substitution so the fixture's PASS/FAIL lines don't pollute the real counters.
run_negative_fixture() {
  local id="$1" desc="$2" dir="$3" fragment="$4"
  local out rc
  out="$(validate_skill_dir "$dir" 2>&1)"; rc=$?
  if [[ $rc -eq 0 ]]; then
    report "$id $desc: validator rejects the fixture (rc != 0)" 1
    return
  fi
  if printf '%s\n' "$out" | grep -qF "$fragment"; then
    report "$id $desc: validator rejects the fixture ($fragment)" 0
  else
    report "$id $desc: validator rejected, but expected failure fragment '$fragment' not found" 1
    printf '%s\n' "$out" | sed 's/^/      /'
  fi
}

# ---------------------------------------------------------------------------
echo "=== Positive: real skills/*/SKILL.md ($SKILLS_DIR)"
# ---------------------------------------------------------------------------
shopt -s nullglob
skill_dirs=("$SKILLS_DIR"/*/)
shopt -u nullglob

if [[ ${#skill_dirs[@]} -gt 0 ]]; then
  report "at least one skills/*/ directory exists" 0
else
  report "at least one skills/*/ directory exists" 1
fi

# Registry guard: the 5 skills shipped by this repo must exist, so a mass
# deletion can't let the per-skill enumeration below pass vacuously.
for known in MergeMill-common MergeMill-dev MergeMill-dispatcher MergeMill-review create-issue; do
  if [[ -d "$SKILLS_DIR/$known" ]]; then
    report "registered skill directory '$known' exists" 0
  else
    report "registered skill directory '$known' exists" 1
  fi
done

for dir in "${skill_dirs[@]}"; do
  echo "  -- $(basename "$dir") --"
  validate_skill_dir "$dir"
done

# ---------------------------------------------------------------------------
echo ""
echo "=== Negative: mktemp-scoped fixtures (real skills/ untouched)"
# ---------------------------------------------------------------------------
FIX="$TMPROOT/fixtures"
mkdir -p "$FIX"

# write_fixture NAME — writes FIX/NAME/SKILL.md from stdin (the heredoc body).
write_fixture() {
  local name="$1"
  mkdir -p "$FIX/$name"
  cat > "$FIX/$name/SKILL.md"
}

# TC-SKILLFM-101: no frontmatter block at all.
write_fixture no-frontmatter <<'EOF'
# Just a heading, no YAML frontmatter
name: no-frontmatter
description: looks fine, but there is no frontmatter block
EOF

# TC-SKILLFM-102: name field != directory basename.
write_fixture name-mismatch <<'EOF'
---
name: some-other-name
description: a perfectly non-empty description
---
EOF

# TC-SKILLFM-103: empty inline description.
write_fixture empty-description <<'EOF'
---
name: empty-description
description:
---
EOF

# TC-SKILLFM-104: block indicator with a blank body. This guards the subtle
# path the real tree exercises — all shipped skills use a `>` folded scalar,
# so a parser that treats the bare `>` as "non-empty" would wrongly pass this.
write_fixture empty-description-block <<'EOF'
---
name: empty-description-block
description: >

---
EOF

run_negative_fixture "TC-SKILLFM-101" "no frontmatter" \
  "$FIX/no-frontmatter" "frontmatter opens with --- and closes with ---"
run_negative_fixture "TC-SKILLFM-102" "name/dir mismatch" \
  "$FIX/name-mismatch" "name is non-empty and equals directory basename"
run_negative_fixture "TC-SKILLFM-103" "empty inline description" \
  "$FIX/empty-description" "description is present and non-empty"
run_negative_fixture "TC-SKILLFM-104" "empty block-scalar description" \
  "$FIX/empty-description-block" "description is present and non-empty"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
