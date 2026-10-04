#!/bin/bash
# test-chp-ci-advisory-check-name-sot.sh — #21 cross-file single-source-of-truth
# guard for the label-gated advisory CI check name.
#
# `chp_github_ci_status` normalizes exactly ONE check from SKIPPED → SUCCESS so
# the label-gated live-smoke job does not block merges (the rule-4 exception).
# That check is named by `_CHP_GITHUB_ADVISORY_SKIPPED_CHECK` in
# providers/chp-github.sh, and the name MUST byte-match the `name:` of the
# label-gated live-smoke job in .github/workflows/ci.yml. If the workflow job is
# renamed and the constant is not (or vice versa), the provider keeps matching
# the OLD name, the advisory check silently reverts to blocking (`pending`), and
# no runtime test fails. This test is that guard.
#
# It reads BOTH literals from their REAL files (never a paraphrase) and asserts
# byte equality, so it fails if EITHER side is changed to a value the other does
# not match.
#
# Run: bash tests/unit/test-chp-ci-advisory-check-name-sot.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHP_GITHUB="$PROJECT_ROOT/skills/MergeMill-dispatcher/scripts/providers/chp-github.sh"
CI_YML="$PROJECT_ROOT/.github/workflows/ci.yml"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'

command -v awk >/dev/null 2>&1 || { echo "awk required"; exit 2; }
[[ -f "$CHP_GITHUB" ]] || { echo "FATAL: missing $CHP_GITHUB"; exit 2; }
[[ -f "$CI_YML" ]] || { echo "FATAL: missing $CI_YML"; exit 2; }

echo "=== TC-SOT-CI-ADVISORY-NAME: chp-github.sh constant == ci.yml live-smoke job name ==="

# (1) Read the declared constant from the REAL provider file. Sourcing it in a
# subshell reads the actual assignment (not a regex over the source line), so a
# rename/removal of the variable yields an empty read and fails loudly rather
# than letting the equality check pass vacuously.
#
# `env -u` clears any inherited value before the source: the declaration is
# guarded by `declare -p … || readonly …` (chp-github.sh), so a pre-set/
# exported `_CHP_GITHUB_ADVISORY_SKIPPED_CHECK` would make the file's literal —
# the real source of truth — invisible to this read (a false PASS). stderr is
# captured rather than discarded: on an empty read it distinguishes "constant
# absent" from "provider failed to source" instead of misreporting the latter.
_advisory_err="$(mktemp)"
_advisory_from_provider="$(
  env -u _CHP_GITHUB_ADVISORY_SKIPPED_CHECK \
    bash -c 'source "$1" && printf "%s" "$_CHP_GITHUB_ADVISORY_SKIPPED_CHECK"' _ "$CHP_GITHUB" 2>"$_advisory_err"
)"

# (2) Read the `name:` of the label-gated live-smoke job from the REAL workflow.
# The job key is the 2-space-indented `live-smoke:` (an optional trailing YAML
# comment is tolerated); its `name:` is the first 4-space-indented `name:`
# within that block, with surrounding YAML quotes stripped. Anchoring on the job
# key (not on the name string itself) keeps this a genuine cross-file
# comparison.
_advisory_from_ci="$(
  awk '
    /^  live-smoke:[[:space:]]*(#.*)?$/ { in_job=1; next }
    in_job && /^  [^[:space:]]/ { exit }
    in_job && /^    name:[[:space:]]/ {
      sub(/^    name:[[:space:]]*/, "")
      gsub(/^["\047]|["\047]$/, "")
      print; exit
    }
  ' "$CI_YML"
)"

# Both sides MUST be non-empty: an empty read on either side would make the
# equality check vacuous. These two checks fail-closed on a botched read.
if [[ -n "$_advisory_from_provider" ]]; then
  echo -e "  ${GREEN}PASS${NC}: provider declares a non-empty advisory check name (|$_advisory_from_provider|)"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: provider read yielded an EMPTY name — _CHP_GITHUB_ADVISORY_SKIPPED_CHECK is undeclared in providers/chp-github.sh OR the file failed to source; source stderr:"; FAIL=$((FAIL + 1))
  if [[ -s "$_advisory_err" ]]; then sed 's/^/      /' "$_advisory_err"; fi
fi
rm -f "$_advisory_err"
if [[ -n "$_advisory_from_ci" ]]; then
  echo -e "  ${GREEN}PASS${NC}: ci.yml live-smoke job declares a non-empty name (|$_advisory_from_ci|)"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: ci.yml read yielded an EMPTY name — is the 'live-smoke:' job's 4-space 'name:' still present?"; FAIL=$((FAIL + 1))
fi

# (3) The core invariant: byte equality (and both non-empty — the `-n` guard
# keeps an empty-vs-empty pair from passing vacuously).
if [[ -n "$_advisory_from_provider" && "$_advisory_from_provider" == "$_advisory_from_ci" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-SOT-CI-ADVISORY-NAME provider constant == ci.yml live-smoke job name"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-SOT-CI-ADVISORY-NAME MISMATCH: provider=|${_advisory_from_provider}| ci.yml=|${_advisory_from_ci}| — a rename on either side silently re-blocks the advisory check; update both in the same change"; FAIL=$((FAIL + 1))
fi

# Sanity: the constant must actually be consumed by the ci-status leaf (as the
# jq `--arg advisory` value), so a later refactor that drops the normalization
# is caught. Comment lines are stripped first, so a comment that merely mentions
# the invocation cannot satisfy the assertion. (The comment-stripped source is
# captured into a variable rather than piped straight into `grep -q`, because an
# early-exiting consumer in a `pipefail` pipeline would trip on the upstream
# writer's SIGPIPE and report a spurious FAIL.)
_noncomment_src="$(grep -v '^[[:space:]]*#' "$CHP_GITHUB")"
if grep -qF -- '--arg advisory "$_CHP_GITHUB_ADVISORY_SKIPPED_CHECK"' <<<"$_noncomment_src"; then
  echo -e "  ${GREEN}PASS${NC}: chp_github_ci_status consumes _CHP_GITHUB_ADVISORY_SKIPPED_CHECK"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: _CHP_GITHUB_ADVISORY_SKIPPED_CHECK is declared but never consumed by the ci-status leaf"; FAIL=$((FAIL + 1))
fi

echo
echo "=== Results ==="
TOTAL=$((PASS + FAIL))
echo -e "Total: $TOTAL  ${GREEN}Passed: $PASS${NC}  ${RED}Failed: $FAIL${NC}"
echo
[[ $FAIL -gt 0 ]] && exit 1
exit 0
