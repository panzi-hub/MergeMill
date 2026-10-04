# Test Cases — advisory label-gated smoke check name single-source-of-truth (#21)

`chp_github_ci_status` normalizes exactly ONE label-gated advisory check from
`SKIPPED` → `SUCCESS` so the `live-smoke` job does not block merges (the rule-4
exception, added in #19). The name was an inline `local` literal duplicated in
three places — `providers/chp-github.sh`, `.github/workflows/ci.yml` (the job
`name:`), and `tests/unit/test-w1d-ci-status-mergeable-parity.sh`. A rename of
the workflow job would leave the provider matching the OLD name, silently
reverting the advisory check to blocking, with NO test failing.

This change hoists the name to `_CHP_GITHUB_ADVISORY_SKIPPED_CHECK` in
`providers/chp-github.sh` and pins it against the workflow job name with a
cross-file consistency test.

Test runner: `bash tests/unit/test-chp-ci-advisory-check-name-sot.sh`
(auto-discovered by the CI `unit` job's `tests/unit/test-*.sh` glob).

## Runtime behavior preserved (AC1, AC3)

The behavioral contract is unchanged; the shipped suite
`tests/unit/test-w1d-ci-status-mergeable-parity.sh` still passes verbatim.

| ID | Scenario | Expected |
|----|----------|----------|
| TC-SOT-001 | named advisory check `SKIPPED` + all others `SUCCESS` | `ci_is_green` rc 0 (non-blocking) — existing TC-W1D-ADVISORY-SKIP-001 |
| TC-SOT-002 | an UNRELATED `SKIPPED` check | `ci_is_green` rc 1 (blocking) — existing TC-W1D-ADVISORY-SKIP-002 |
| TC-SOT-003 | a `FAILURE` of the advisory check | `ci_is_green` rc 1 (blocking) — existing TC-W1D-ADVISORY-SKIP-003 |

## Cross-file single source of truth (AC2)

The new test reads BOTH literals from their REAL files (sourcing the provider
constant; `awk`-scoping the `live-smoke:` job block in `ci.yml`) and asserts byte
equality. Both sides are asserted non-empty so a botched read cannot pass
vacuously.

| ID | Scenario | Expected |
|----|----------|----------|
| TC-SOT-010 | provider declares a non-empty `_CHP_GITHUB_ADVISORY_SKIPPED_CHECK` | non-empty |
| TC-SOT-011 | `ci.yml` `live-smoke:` job declares a non-empty `name:` | non-empty |
| TC-SOT-012 | provider constant == `ci.yml` live-smoke job name (current tree) | equal → PASS |
| TC-SOT-013 | rename the `ci.yml` job `name:` only | test EXITS 1 (mismatch) |
| TC-SOT-014 | rename the provider constant only | test EXITS 1 (mismatch) |
| TC-SOT-015 | leaf actually consumes the constant (grep `$_CHP_GITHUB_ADVISORY_SKIPPED_CHECK`) | present |

TC-SOT-013 / TC-SOT-014 were verified by temporarily mutating each side and
observing rc 1, then restoring.

## Stale comment (requirement 3)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-SOT-020 | `lib-dispatch.sh::ci_is_green` header no longer claims the leaf owns `gh pr checks --json state` (pre-#19 argv) | states `--json name,state` and names the rule-4 advisory normalization |
