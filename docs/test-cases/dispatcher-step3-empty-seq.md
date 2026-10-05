# Test Cases — dispatcher Step 3 empty `pending-review` enumeration (BSD `seq 0 -1`)

Tracks: issue #28.

## Scenario

`dispatcher-tick.sh` enumerates its per-step issue lists (Step 3 pending-review,
Step 4 pending-dev, Step 5 stale candidates) with a shell loop. The original
enumeration form was `for i in $(seq 0 $((n - 1)))`.

`seq` is not portable at the empty boundary:

| Host | `seq 0 -1` | Result |
|------|------------|--------|
| GNU coreutils (Ubuntu CI) | *(no output)* | loop runs 0 times — correct |
| BSD (macOS) | `0` then `-1` | loop runs **twice** |

So on macOS, when `pending-review` was empty (`pr_count=0`), the loop body ran
with `i=0`; `jq -r '.[0].number'` on an empty array yields `null`, and
`dispatch review null` failed issue-format validation, aborting the whole tick
under `set -euo pipefail` — **before Step 4 and Step 5 (crash recovery) ran**.

The loop-boundary guard `if (( n > 0 )); then … fi` was introduced upstream as
part of the dispatcher-portability sweep; it already prevents the abort. What
remained was the platform-specific `seq` enumeration itself. This change
replaces `seq` with bash-native arithmetic enumeration
(`for ((i = 0; i < n; i++))`), which runs 0 times for an empty list on **every**
host and removes the platform dependency entirely. The `(( n > 0 ))` guards are
kept as a fast-path short-circuit (defense in depth).

> Scope note: this documents Step 3 (the reported abort) plus the same-shape
> enumerations in Step 4 and Step 5, per the issue's "一并核查" instruction.
> Step 2 already used a bash-native C-style loop. The `seq` loop in
> `lib-dispatch.sh::run_hygiene_pass` (Step 0) is out of scope: it is already
> bounded by an early `[[ "$count" -eq 0 ]] && return 0` and is not a tick Step.

## Test Cases

Test file: `tests/unit/test-dispatcher-step3-empty-seq.sh` (`TC-D3SEQ-*`).

| ID | Kind | Fixture | Expected | Discriminates pre/post fix |
|----|------|---------|----------|----------------------------|
| TC-D3SEQ-001 | structural | `dispatcher-tick.sh` | zero `seq 0 $((N - 1))` enumerations remain | yes — fails pre-fix |
| TC-D3SEQ-002 | structural | `dispatcher-tick.sh` | Step 3/4/5 loops are `for ((i = 0; i < <var>; i++))` | yes — fails pre-fix |
| TC-D3SEQ-003 | control | extracted Step 3 loop | extraction non-empty and contains the review-dispatch marker | yes — the C-style `for` line does not exist pre-fix |
| TC-D3SEQ-004 | behavioral | `pr_count=0`, `[]` | 0 review dispatches, 0 label swaps, rc 0 | no — guard already covered the abort |
| TC-D3SEQ-005 | behavioral | `pr_count=1`, one issue | exactly 1 dispatch for that issue | yes — empty extraction would yield 0 |
| TC-D3SEQ-006 | behavioral | `pr_count=3` | 3 dispatches in list order | yes — empty extraction would yield 0 |
| TC-D3SEQ-007 | control | synthetic unguarded `for i in $(seq 0 -1)` | BSD-shim yields 2 iterations | proves the shim reproduces the macOS hazard on GNU CI |
| TC-D3SEQ-008 | behavioral | `pr_count=0` and `pr_count=3` | the tick's loop never invokes `seq` | pins removal of the platform dependency |

### Reproduction mechanism (GNU-CI-safe)

The behavioral cases run the extracted Step 3 loop under a `PATH` shim named
`seq` that emits the BSD output (`0\n-1`) for the exact `seq 0 -1` call and
otherwise delegates to the host `seq`. TC-D3SEQ-007 is the **stub control**: it
drives a synthetic unguarded `for i in $(seq 0 -1)` under the same shim and
asserts it iterates twice — so a passing suite cannot be an artifact of GNU
`seq` returning empty. Because the fixed loop uses bash arithmetic, it never
calls `seq` at all (TC-D3SEQ-008).

## Acceptance

- TC-D3SEQ-001/002/003 fail against the pre-fix `seq`-based loops → pass after the fix.
- TC-D3SEQ-004 (the reported abort path) passes on both sides: the upstream
  `(( pr_count > 0 ))` guard already prevented the empty-list abort; this change
  additionally removes the underlying `seq` portability dependency.
- TC-D3SEQ-005/006 (non-empty behavior) unchanged on both sides.
- `pr_count >= 1` dispatch behavior is byte-identical (same issue numbers, same order).
- E2E: N/A (no user interface).
