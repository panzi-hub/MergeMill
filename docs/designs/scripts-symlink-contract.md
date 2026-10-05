# Test: lock the `scripts/` symlink contract

**Date:** 2026-10-05
**Issue:** #26
**Status:** Approved (MergeMill autonomous mode)

## Problem

The repository commits `scripts` as a symlink to
`skills/MergeMill-dispatcher/scripts` (git tree mode `120000`, verified
with `git ls-files -s scripts`). The dispatcher invokes its wrappers
through that path, e.g. `$PROJECT_DIR/scripts/MergeMill-dev.sh`,
`$PROJECT_DIR/scripts/dispatcher-tick.sh`.

If the symlink is ever replaced by a regular directory, repointed, or a
checkout/tooling step materializes it as a real dir, those invocation
paths break **silently** — the wrapper is simply not found. This test
makes that failure loud. Existing coverage (`test-symlink-resolution.sh`,
`test-entry-point-resolution.sh`) exercises symlink *resolution logic*
inside scripts, not the repository's own top-level `scripts` symlink.

## Goal

Add one small, hermetic unit test that locks the contract:

1. `scripts` is a symlink, not a regular directory/file.
2. It resolves to `skills/MergeMill-dispatcher/scripts` (relative or
   absolute `readlink` value both acceptable — only the resolved
   physical directory matters).
3. The known entry point `dispatcher-tick.sh` is readable through
   `scripts/`.

## Design

- `tests/unit/test-scripts-symlink.sh`, `set -euo pipefail`.
- A single `check_scripts_symlink <project_root>` predicate encodes all
  three assertions, so the same logic runs against the live repo and
  against negative fixtures.
  - Symlink test uses `[[ -L ]]` (lstat — does not follow the link).
  - Resolution test uses `cd "$root/scripts" && pwd -P` compared against
    `cd "$root/skills/MergeMill-dispatcher/scripts" && pwd -P`. `pwd -P`
    normalizes relative vs absolute `readlink` targets and multi-hop
    chains, so both forms pass.
  - Readability test uses `[[ -r .../dispatcher-tick.sh ]]`.
- The live-repo call is the real assertion. Two negative fixtures in a
  `mktemp -d` prove the predicate fails when `scripts` is (a) a regular
  directory, and (b) a symlink repointed elsewhere — the two failure
  modes named in the issue.
- No explicit wiring into `tests/run-unit-tests.sh` is needed: that
  runner globs `"$UNIT_TEST_DIR"/test-*.sh`, so `test-scripts-symlink.sh`
  is discovered automatically. Explicit registration in a glob runner
  would be the wrong fix.

## Hermeticity

Read-only against the repo tree. The only writes are inside a
`mktemp -d` fixture removed on `EXIT`. No network, no fixed paths, no
shared state — matches `tests/unit/README.md`.

## Acceptance

- `bash tests/unit/test-scripts-symlink.sh` exits 0 on a clean checkout.
- Replacing `scripts` with a regular directory makes the running test
  exit non-zero (proved by the negative fixture; the live call then
  fails too).
- Discovered and executed by `tests/run-unit-tests.sh` via the glob.
