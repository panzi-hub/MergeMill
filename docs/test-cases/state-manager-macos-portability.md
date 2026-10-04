# Test cases — state-manager.sh macOS portability

Unit test: `tests/unit/test-state-manager-macos-portability.sh`
Maps to issue #23. Each case is a bash assertion; the test runs the real
`skills/MergeMill-common/hooks/state-manager.sh` against a scratch git repo and
an isolated `CLAUDE_PROJECT_DIR`, with `date`/`gdate` shims on `PATH` and the
`mapfile` builtin disabled to reproduce stock-macOS conditions.

## Setup

- `CLAUDE_PROJECT_DIR` points at a `mktemp` dir → `resolve_state_dir` writes to
  that isolated `.agents/state` (never the real repo state).
- A scratch git repo provides a real `HEAD` and a staged file list.
- **BSD `date` shim**: a script prepended to `PATH` that (a) rejects `-d` (BSD
  has no `-d`), (b) handles `-j -f <fmt> <str> +%s` parsing in the host's local
  zone **without** `-u`, and in **UTC** with `-u`, delegating arithmetic to the
  real GNU `date`. A `gdate` shim that exits 127 emulates a host without
  Homebrew coreutils. `TZ=Asia/Shanghai` (UTC+8) reproduces the reported host.
- **`mapfile` disabled**: `enable -n mapfile` in the sourced child shell turns
  off the builtin, emulating bash 3.2 where `mapfile` does not exist.

## TC-SMP — cases

| ID | Scenario | Expected |
|----|----------|----------|
| TC-SMP-001 | `mark` with no explicit files, `mapfile` shadowed to fail, staged files present | rc 0; state file records the staged file (proves no `mapfile` dependency) |
| TC-SMP-002 | Source contains no `mapfile` invocation (static guard) | `mapfile` token absent from the hook source |
| TC-SMP-003 | BSD-date shim, `TZ=Asia/Shanghai`: `mark pr-review` then `check pr-review` immediately | rc 0; state file still present (no false expiry) |
| TC-SMP-004 | Same shim: `check` after `sleep 1` | rc 0 (mark remains valid ~1 s later) |
| TC-SMP-005 | BSD-date shim sanity: local vs `-u` parse of a UTC stamp differ by the host offset | `utc_epoch - local_epoch == 28800` (confirms the shim reproduces Bug 1) |
| TC-SMP-006 | Real `date`/bash on the host (GNU/Linux path): `mark` + `check` | rc 0 (behaviour preserved) |
| TC-SMP-007 | `pr-review` mark bound to a different `HEAD` is rejected | rc ≠ 0 and state file removed (gate not weakened) |

## Acceptance traceability

- "`mark` succeeds under bash 3.2, mark not expired by immediately following
  `check`" → TC-SMP-001, TC-SMP-003.
- "mark written in UTC valid ~1 s later at UTC+8" → TC-SMP-003, TC-SMP-004,
  TC-SMP-005.
- "GNU/Linux unchanged" → TC-SMP-006.
- "unit test covers BSD-date path and no-mapfile path" → TC-SMP-001..005.
- "no gate bypass" → TC-SMP-007.
