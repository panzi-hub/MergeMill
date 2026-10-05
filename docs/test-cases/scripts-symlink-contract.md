# Test cases: `scripts/` symlink contract (#26)

**Test file:** `tests/unit/test-scripts-symlink.sh`
**Run:** `bash tests/unit/test-scripts-symlink.sh`

| ID | Scenario | Setup | Expected |
|----|----------|-------|----------|
| TC-SYMLINK-001 | Live repo: `scripts` is a symlink resolving to `skills/MergeMill-dispatcher/scripts`, and `dispatcher-tick.sh` is readable through it | Unmodified checkout | Predicate passes; script exits 0 |
| TC-SYMLINK-002 | Negative: `scripts` is a regular directory | `mktemp -d` fixture with `<root>/scripts/` as a real dir and the real target dir present | Predicate returns non-zero |
| TC-SYMLINK-003 | Negative: `scripts` is a symlink repointed elsewhere | Fixture with `scripts -> <other dir>`, real target dir also present | Predicate returns non-zero |

## Negative-path rationale

TC-SYMLINK-002 and TC-SYMLINK-003 exercise the exact acceptance criterion
"the test exits non-zero if `scripts` is replaced by a regular directory"
without mutating the live repo. They use the same `check_scripts_symlink`
predicate that guards the live assertion, so the negative fixtures prove
the predicate discriminates rather than trivially returning success.

## Hermeticity

The test only reads the repo tree. Fixtures live under a single
`mktemp -d` removed on `EXIT`. No network, no fixed `/tmp` paths, no
writes to tracked files — satisfies `tests/unit/README.md`.
