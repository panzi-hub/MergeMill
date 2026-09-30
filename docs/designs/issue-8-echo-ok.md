# Design Canvas — `scripts/echo-ok.sh` (issue #8)

- **Feature ID**: F8
- **Feature Name**: echo-ok smoke helper
- **Status**: Approved
- **Author**: MergeMill dev agent
- **Date Created**: 2026-09-30
- **Last Updated**: 2026-09-30
- **Issue**: #8

---

## 1. Problem Statement

The pipeline needs a trivial, dependency-free end-to-end fixture that can be
invoked exactly the way the dispatcher invokes real helper scripts, so that
the full path (worktree → commit → PR → CI → review → merge) can be exercised
on a change with **zero** behavioural surface area.

### User Pain Points
- There is no "hello world" target to smoke-test the autonomous pipeline
  without risking a real feature.
- Failures in the harness (hooks, CI wiring, review handoff) are hard to
  distinguish from failures in a real feature's logic.

### Goals
- One script, one observable output (`ok`), one exit status (`0`).
- No inputs, no environment assumptions beyond `bash`.

## 2. Proposed Solution

A two-line bash script that `echo`es `ok` and exits `0`. It carries the
executable bit and a `#!/bin/bash` shebang so it can be run directly, not only
via an interpreter.

### Key Features
- [x] Prints exactly `ok` to stdout
- [x] Exits `0`
- [x] Executable bit + shebang (direct invocation OK)
- [x] `set -euo pipefail` so an accidental edit fails loudly

## 3. Architecture

```
caller (bash scripts/echo-ok.sh  |  scripts/echo-ok.sh)
        │
        ▼
  echo-ok.sh  ──echo "ok"──▶  stdout "ok", exit 0
```

The script is reachable through the repo's `scripts/` symlink
(`scripts -> skills/MergeMill-dispatcher/scripts`), which is the same path the
dispatcher uses for every other helper.

## 4. Interface

| Aspect | Contract |
|---|---|
| Args | none (ignored) |
| stdin | unused |
| stdout | exactly `ok\n` |
| stderr | empty |
| exit | `0` always |
| side effects | none |

## 5. Testing

Test cases: `docs/test-cases/issue-8-echo-ok.md` (`TC-EOK-001..004`).
Implementation: `tests/unit/test-echo-ok.sh`, run directly or via
`tests/run-unit-tests.sh`.

## 6. Out of Scope

- Argument handling, flags, error paths — the helper has no failure mode.
- Any pipeline integration beyond being present at the agreed path.
