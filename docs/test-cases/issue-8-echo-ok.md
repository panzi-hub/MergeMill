# Test Cases — `scripts/echo-ok.sh` (issue #8)

Test file: `tests/unit/test-echo-ok.sh` (`TC-EOK-NNN`).

Run: `bash tests/unit/test-echo-ok.sh` (or via `tests/run-unit-tests.sh`).

## Scope

A one-line smoke helper: print `ok`, exit `0`. No inputs, no arguments, no
side effects. The acceptance criteria from the issue body map directly onto
observable process behavior (path, mode bit, stdout, exit status).

| ID | Scenario | Expected |
|----|----------|----------|
| TC-EOK-001 | Helper file exists at `scripts/echo-ok.sh` (through the `scripts/` symlink, i.e. `skills/MergeMill-dispatcher/scripts/echo-ok.sh`) | regular file present at both resolutions |
| TC-EOK-002 | Helper carries the executable bit | `[[ -x ]]` true |
| TC-EOK-003 | `bash scripts/echo-ok.sh` | stdout is exactly `ok`; exit status `0` |
| TC-EOK-004 | Direct execution `scripts/echo-ok.sh` (exec bit + shebang honored) | stdout is exactly `ok`; exit status `0` |

## Notes

- TC-EOK-003 matches the issue's literal acceptance command (`bash scripts/echo-ok.sh`).
- TC-EOK-004 guards the `#!` shebang and mode bit, which TC-EOK-003 alone would
  not cover (an interpreter-invoked script runs even without the exec bit).
- No error-path case: the helper takes no input and has no failure mode.
