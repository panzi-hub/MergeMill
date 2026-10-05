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

So on macOS, before the `(( n > 0 ))` guard was added, an empty `pending-review`
(`pr_count=0`) made the loop body run with `i=0`; `jq -r '.[0].number'` on an
empty array yields `null`, and the unguarded `label_swap "null"` reached
`gh issue edit null` (`invalid issue format: "null"`, rc=1), aborting the whole
tick under `set -euo pipefail` — **before Step 4 (resume) and Step 5
(stale/crash recovery) ran**.

That loop-boundary guard `if (( n > 0 )); then … fi` is present in the current
tree and already prevents the abort. What remained was the platform-specific
`seq` enumeration itself. This change replaces `seq` with bash-native
arithmetic enumeration (`for ((i = 0; i < n; i++))`), which runs 0 times for an
empty list on **every** host and removes the platform dependency entirely. The
`(( n > 0 ))` guards are kept as a fast-path short-circuit (defense in depth).

> Scope note: this documents Step 3 (the reported abort) plus the same-shape
> enumerations in Step 4 and Step 5, per the issue's "一并核查" instruction.
> Step 2 already used a bash-native C-style loop. The `seq` loop in
> `lib-dispatch.sh::run_hygiene_pass` (invoked as the tick's Step 0) is out of
> scope: it lives in `lib-dispatch.sh` rather than as a `for` loop in
> `dispatcher-tick.sh`, and it is already bounded by an early
> `if [[ "$count" -eq 0 ]]; then return 0; fi`.

## Test Cases

Test file: `tests/unit/test-dispatcher-step3-empty-seq.sh` (`TC-D3SEQ-*`).

| ID | Kind | Fixture | Expected | Discriminates pre/post fix |
|----|------|---------|----------|----------------------------|
| TC-D3SEQ-001 | structural | `dispatcher-tick.sh` | zero `seq 0 $((N - 1))` enumerations remain | yes — fails pre-fix |
| TC-D3SEQ-002 | structural | `dispatcher-tick.sh` | Step 3/4/5 loops are `for ((i = 0; i < <var>; i++))` | yes — fails pre-fix |
| TC-D3SEQ-003 | control | extracted Step 3 loop | extraction non-empty and contains the review-dispatch marker | yes — the C-style `for` line does not exist pre-fix |
| TC-D3SEQ-004 | behavioral | `pr_count=0`, `[]` | 0 review dispatches, 0 label swaps, rc 0 | no — pre-fix extraction is empty, so it passes vacuously |
| TC-D3SEQ-005 | behavioral | `pr_count=1`, one issue | exactly 1 dispatch for that issue | yes — empty extraction would yield 0 |
| TC-D3SEQ-006 | behavioral | `pr_count=3` | 3 dispatches in list order | yes — empty extraction would yield 0 |
| TC-D3SEQ-007 | control | synthetic unguarded `for i in $(seq 0 -1)` | BSD-shim yields 2 iterations | proves the shim reproduces the macOS hazard on GNU CI |
| TC-D3SEQ-008 | behavioral | `pr_count=0` and `pr_count=3` | the extracted Step 3 loop never invokes `seq` | pins removal of the platform dependency |

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
- TC-D3SEQ-004 passes on both sides (non-discriminating): pre-fix the C-style
  loop header does not exist, so the extraction is empty and the case reports 0
  dispatches **vacuously**; post-fix the empty C-style loop genuinely runs 0
  times. The real tick's reported abort is not reproduced here because
  TC-D3SEQ-003 intentionally extracts only the loop body, excluding the
  upstream `(( pr_count > 0 ))` guard that already prevented it. This change
  additionally removes the underlying `seq` portability dependency.
- TC-D3SEQ-005/006 (non-empty behavior) unchanged on both sides.
- `pr_count >= 1` dispatch behavior is byte-identical (same issue numbers, same order).
- E2E: N/A (no user interface).
